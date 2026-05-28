---
name: hub-event-sync
description: >
  Implement state synchronization between a 3rd-party hub and SmartThings Edge driver.
  Covers full inventory sync, incremental polling with cursor-based change feeds
  (refreshStates), targeted child device refresh, state emission for all device kinds,
  optimistic state updates, command execution with confirmation polling, and stale
  child cleanup. Use when building the sync layer of a hub bridge Edge driver.
---

# Hub Event Synchronization

This skill covers all state synchronization patterns for a hub bridge Edge driver.
State sync ensures SmartThings always reflects the current state of devices on the 3rd-party hub.

## Sync Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Sync Engine                        │
│                                                      │
│  ┌──────────┐    ┌──────────────┐    ┌───────────┐  │
│  │  Full     │    │ Incremental  │    │ Targeted  │  │
│  │ Inventory │    │   Polling    │    │  Refresh  │  │
│  │   Sync    │    │ (refreshSt.) │    │  (child)  │  │
│  └────┬─────┘    └──────┬───────┘    └─────┬─────┘  │
│       │                 │                   │        │
│       └────────┬────────┘                   │        │
│                ↓                            │        │
│       ┌────────────────┐                    │        │
│       │  emit_child_   │←───────────────────┘        │
│       │    state()     │                             │
│       └────────────────┘                             │
└─────────────────────────────────────────────────────┘
```

## 1. Full Inventory Sync

Runs on first boot, bridge refresh, and when incremental polling detects unknown devices.

```lua
function sync.sync_bridge_inventory(driver, bridge)
  -- 1. Validate bridge has credentials and endpoint config
  local has_config, config_err = bridge_has_inventory_config(bridge)
  if not has_config then
    bridge:offline()
    return nil, config_err
  end

  -- 2. Bootstrap: validate hub identity and select adapter
  local bootstrap, bootstrap_err = bootstrap_bridge(bridge)
  if bootstrap == nil then
    bridge:offline()
    return nil, bootstrap_err
  end

  -- 3. Create authenticated API client
  local api, api_err = api_for_bridge(bridge)
  if api == nil then
    bridge:offline()
    return nil, api_err
  end

  -- 4. Fetch all devices from hub
  local payload, err, status = api:get_devices()
  if err ~= nil or status ~= 200 then
    api:shutdown()
    bridge:offline()
    return nil, err or ("unexpected status " .. tostring(status))
  end

  -- 5. Fetch rooms for label enrichment (optional)
  local rooms = fetch_rooms(api)
  api:shutdown()

  bridge:online()

  -- 6. Normalize device list via adapter
  local adapter = bootstrap.adapter
  local discovered = adapter.normalize_device_list(payload)

  -- 7. Build parent-sibling map for multi-channel filtering
  local parents_with_named_siblings = {}
  local normalized_devices = {}
  for _, raw_device in ipairs(discovered) do
    local nd = adapter.normalize_device(raw_device)
    table.insert(normalized_devices, nd)
    local parent_id = nd.parent_id or 0
    if parent_id > 1 then
      local is_unnamed = (nd.label or ""):match("^%d+%.%d+$")
        or (nd.label or ""):match("^%d+%.%d+%.%d+$")
      if not is_unnamed then
        parents_with_named_siblings[parent_id] = true
      end
    end
  end

  -- 8. Map and create/update child devices
  local children_by_key = child_devices_for_bridge(driver, bridge)
  local seen = {}

  for _, nd in ipairs(normalized_devices) do
    local parent_id = nd.parent_id or 0
    local has_named_sibling = parent_id > 1 and parents_with_named_siblings[parent_id]
    local mapped, map_err = mapper.map_device(nd, rooms, has_named_sibling)

    if mapped ~= nil then
      seen[mapped.key] = true
      ensure_child_device(driver, bridge, mapped, children_by_key[mapped.key])
    end
  end

  -- 9. Delete stale children not seen in this sync
  for child_key, child in pairs(children_by_key) do
    if not seen[child_key] then
      delete_child(driver, child)
    end
  end

  -- 10. Prime the incremental polling cursor
  prime_refresh_states_cursor(api, bridge)

  return true, nil
end
```

## 2. Incremental Polling (refreshStates)

More efficient than full inventory sync. Uses a cursor to fetch only changes since last poll.

```lua
function sync.poll_bridge(driver, bridge)
  local last = bridge:get_field(fields.LAST_REFRESH_STATES)
  if last == nil then
    -- No cursor yet — do full sync first
    return sync.sync_bridge_inventory(driver, bridge)
  end

  -- Fetch changes since last cursor
  local api, api_err = api_for_bridge(bridge)
  if api == nil then
    bridge:offline()
    return nil, api_err
  end

  local payload, err, status = api:get_refresh_states(last)
  api:shutdown()

  if err ~= nil or status ~= 200 or type(payload) ~= "table" then
    -- Incremental polling failed — fall back to full sync
    return sync.sync_bridge_inventory(driver, bridge)
  end

  bridge:online()

  -- Update cursor for next poll
  if payload.last ~= nil then
    bridge:set_field(fields.LAST_REFRESH_STATES, payload.last, { persist = true })
  end

  -- Process changes
  local changes = payload.changes or {}
  local should_resync = false
  local touched = {}

  for _, change in ipairs(changes) do
    local device_id = change.id
    if device_id == nil then goto continue end

    local child = find_child_by_device_id(driver, bridge, device_id)
    if child ~= nil then
      touched[device_id] = child
    else
      -- Unknown device changed — need full resync
      should_resync = true
    end
    ::continue::
  end

  -- Refresh only changed children
  for device_id, child in pairs(touched) do
    sync.refresh_child(driver, child)
  end

  -- If new devices detected, do full inventory
  if should_resync then
    return sync.sync_bridge_inventory(driver, bridge)
  end

  return true, nil
end
```

## 3. Targeted Child Refresh

Refresh a single child device's state from the hub API.

```lua
function sync.refresh_child(driver, child)
  local bridge = find_parent_bridge(driver, child)
  if bridge == nil then return nil, "bridge not found" end

  local api, api_err = api_for_bridge(bridge)
  if api == nil then
    child:offline()
    return nil, api_err
  end

  local adapter = controller_for_bridge(bridge)
  local device_id = child:get_field(fields.HC2_DEVICE_ID)
  local kind = child:get_field(fields.HC2_DEVICE_KIND) or "generic-sensor"

  -- Fetch single device from hub
  local payload, err, status = api:get_device(device_id)
  api:shutdown()

  if err ~= nil or status ~= 200 then
    child:offline()
    bridge:offline()
    return nil, err
  end

  -- Normalize and emit state
  local normalized = adapter.normalize_device(payload)
  bridge:online()
  emit_child_state(child, normalized, kind)

  return true, nil
end
```

## 4. State Emission by Device Kind

Map normalized device data to SmartThings capability events:

```lua
local function emit_child_state(device, normalized, kind)
  -- Health check
  if normalized.dead == true then
    device:offline()
  else
    device:online()
  end

  local value = normalized.value

  if kind == "switch" then
    local is_on = value_is_truthy(value)
    device:emit_event(is_on
      and capabilities.switch.switch.on()
      or capabilities.switch.switch.off())

  elseif kind == "dimmer" then
    local level = normalized.level or 0
    device:emit_event(level > 0
      and capabilities.switch.switch.on()
      or capabilities.switch.switch.off())
    device:emit_event(capabilities.switchLevel.level(
      clamp(math.floor(level + 0.5), 0, 99)))

  elseif kind == "blind" then
    local level = safe_tonumber(normalized.level or normalized.value) or 0
    local clamped = clamp(math.floor(level + 0.5), 0, 99)
    if clamped == 0 then
      device:emit_event(capabilities.windowShade.windowShade.closed())
    elseif clamped >= 99 then
      device:emit_event(capabilities.windowShade.windowShade.open())
    else
      device:emit_event(capabilities.windowShade.windowShade.partially_open())
    end
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(clamped))

  elseif kind == "smoke-detector" then
    device:emit_event(value_is_truthy(value)
      and capabilities.smokeDetector.smoke.detected()
      or capabilities.smokeDetector.smoke.clear())

  elseif kind == "temperature-sensor" then
    local temp = safe_tonumber(value)
    if temp then
      device:emit_event(capabilities.temperatureMeasurement.temperature(
        { value = temp, unit = "C" }))
    end

  elseif kind == "humidity-sensor" then
    local hum = safe_tonumber(value)
    if hum then
      device:emit_event(capabilities.relativeHumidityMeasurement.humidity(
        { value = math.floor(hum + 0.5) }))
    end

  elseif kind == "illuminance-sensor" then
    local lux = safe_tonumber(value)
    if lux then
      device:emit_event(capabilities.illuminanceMeasurement.illuminance(
        { value = math.floor(lux + 0.5), unit = "lux" }))
    end

  elseif kind == "water-sensor" then
    device:emit_event(value_is_truthy(value)
      and capabilities.waterSensor.water.wet()
      or capabilities.waterSensor.water.dry())

  elseif kind == "contact" then
    device:emit_event(value_is_truthy(value)
      and capabilities.contactSensor.contact.open()
      or capabilities.contactSensor.contact.closed())

  elseif kind == "motion" then
    device:emit_event(value_is_truthy(value)
      and capabilities.motionSensor.motion.active()
      or capabilities.motionSensor.motion.inactive())
  end
end
```

## 5. Optimistic State Updates

For responsive UX, emit state optimistically before confirming from the hub:

```lua
local function emit_optimistic_switch(device, is_on)
  device:emit_event(is_on
    and capabilities.switch.switch.on()
    or capabilities.switch.switch.off())
end

local function emit_optimistic_level(device, level)
  local scaled = clamp(math.floor(level + 0.5), 0, 99)
  emit_optimistic_switch(device, scaled > 0)
  device:emit_event(capabilities.switchLevel.level(scaled))
end

-- In command handler:
function commands.switch_on(driver, device)
  emit_optimistic_switch(device, true)          -- Instant feedback
  sync.execute_child_action(driver, device, "turnOn", {})  -- Send to hub
end
```

## 6. Command Execution with Confirmation

```lua
function sync.execute_child_action(driver, child, action_name, args)
  local bridge = find_parent_bridge(driver, child)
  local api = api_for_bridge(bridge)
  local adapter = controller_for_bridge(bridge)
  local device_id = child:get_field(fields.HC2_DEVICE_ID)

  -- Send action to hub
  local _, err, status = api:call_action(
    device_id, action_name, adapter.build_action_body(args))

  if err or (status ~= 200 and status ~= 202 and status ~= 204) then
    api:shutdown()
    child:offline()
    return nil, err
  end

  -- Confirmation poll: verify state changed
  socket.sleep(0.5)
  local kind = child:get_field(fields.HC2_DEVICE_KIND)
  refresh_child_with_api(api, bridge, child, adapter, device_id, kind)

  api:shutdown()
  return true, nil
end
```

## 7. Poll Scheduling

```lua
-- In lifecycle init handler:
local function device_init(driver, device)
  if is_bridge(device) then
    local poll_interval = get_poll_interval(device)
    device.thread:call_on_schedule(poll_interval, function()
      local ok, err = pcall(sync.poll_bridge, driver, device)
      if not ok then
        log.error_with({ hub_logs = true },
          "Poll crashed: " .. tostring(err))
      end
    end, device.id .. "-poll")
  end
end
```

## Key Design Principles

1. **Incremental first** — use cursor-based polling whenever available; fall back to full sync
2. **Optimistic + confirm** — emit state immediately, then confirm from hub API
3. **pcall everything** — never let a polling crash kill the driver
4. **Stale cleanup** — delete child devices that no longer exist on the hub
5. **Targeted refresh** — only refresh children that changed, not all children
6. **Health propagation** — bridge offline → children should reflect this
