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

## 0. Required Function Ordering in `src/vendor/sync.lua`

> **Critical Lua scoping rule.** Lua resolves names lexically at compile time. A `local function`
> is only visible from its declaration onwards — any reference to it that appears **earlier** in the
> file compiles as a global lookup (`_ENV["name"]`), which returns `nil` at runtime. The `pcall`
> wrapper in the lifecycle/poll path catches the crash, so **the driver stays alive but sync fails
> silently — the bridge comes online yet no child devices are ever created** ("hub devices not
> visible"). This applies **helper-to-helper, not just helpers-before-public**: if helper `A` calls
> helper `B`, then `B` must be defined **above** `A`, even though both are locals.
>
> **Fix: topologically order every local helper so each callee is defined above its first caller**,
> then the public `sync.XXX` functions last. A correct dependency order for the helpers:
>
> 1. Leaf helpers with no intra-file deps: `find_bridge_by_dni`, `child_exists`, `api_for_bridge`,
>    `fetch_rooms`, `prime_refresh_states_cursor`, `bootstrap_bridge`, `emit_child_state`,
>    `cache_child_metadata`, `build_child_metadata`, `delete_child`, `bridge_has_inventory_config`
> 2. **`enqueue_child_create`** — must come **before** `ensure_child_device` (which calls it)
> 3. **`ensure_child_device`** — calls `emit_child_state` (1) and `enqueue_child_create` (2)
> 4. Public functions last: `sync.drain_create_queue`, **`sync.drain_pending`** (calls
>    `sync.drain_create_queue`, so define it after), `sync.execute_child_action`,
>    `sync.refresh_child`, `sync.poll_bridge`, `sync.sync_bridge_inventory`,
>    `sync.cancel_bridge_timer`, `sync.start_poll_timer`
>
> ⚠️ The #1 real-world miss is putting `ensure_child_device` above `enqueue_child_create` — both are
> locals, both sit above the public functions, but `ensure_child_device` calls `enqueue_child_create`
> a few lines *below* it → nil-global crash on the first child create. `luac -p` will **not** catch
> this (valid syntax). **Verify with the `edge-validation` Stage 1b runtime-nil lint**
> (`diagnostics/edge-validation/scripts/check-lua-nils.js`) before handover — a header comment
> claiming "ordered correctly" is not proof.
>
> Also: if a helper is exported as `sync.prime_cursor`, always call it as `sync.prime_cursor(...)`
> — a bare `prime_cursor(...)` is a different (global) lookup that also resolves to `nil`.

## 1. Full Inventory Sync

Runs on first boot, bridge refresh, and when incremental polling detects unknown devices.

> **⚠️ Mapping a device does NOT create it. The sync MUST create the child.** `mapper.map_device`
> only *classifies* a device (returns `kind`/`profile`/`key`); it never touches the platform. For
> **every in-scope mapped device** the inventory loop MUST then call
> `ensure_child_device(driver, bridge, mapped, existing)` (which emits state if the child already
> exists, else `enqueue_child_create`), and the sync MUST end by draining the queue with
> `sync.drain_create_queue(driver, MAX_CREATES_PER_INVENTORY)`. The drain is what calls
> `driver:try_create_device{ type = "EDGE_CHILD", parent_device_id = bridge.id, parent_assigned_child_key = key, profile = mapped.profile, … }`.
>
> **A sync that logs `"... mapped as switch/dimmer/…"` but is NOT followed by a `try_create_device`
> (EDGE_CHILD) is broken — it silently creates zero child devices.** Symptom: the bridge connects,
> `/api/devices` returns 200, the logs show devices being mapped, yet nothing appears in the app
> because the mapped result was computed and discarded. Verify generated/edited sync code by
> confirming each mapped device reaches `ensure_child_device` and that `drain_create_queue` runs at
> the end of `sync_bridge_inventory` (and at the top of each poll). Never "map and move on."

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

  -- 10. Drain the create queue — via the self-scheduling helper, NOT a bare
  --     drain_create_queue (see §8a). This creates the first batch now and
  --     auto-schedules the rest, so the user never has to pull-to-refresh.
  sync.drain_pending(driver, bridge)

  -- 11. Prime the incremental polling cursor
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

  -- Drain any queued creates first (self-scheduling — see §8a). NEVER a bare
  -- drain_create_queue here, or large hubs need repeated pull-to-refresh.
  sync.drain_pending(driver, bridge)

  -- Periodic full reconcile (§9c) — catches silent late additions.
  local n = (tonumber(bridge:get_field(fields.POLL_COUNT)) or 0) + 1
  bridge:set_field(fields.POLL_COUNT, n, { persist = false })
  if n % FULL_SYNC_EVERY_N_POLLS == 0 then
    return sync.sync_bridge_inventory(driver, bridge)
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
      -- Unknown device changed — new device exists, need full resync (§9b)
      should_resync = true
    end
    ::continue::
  end

  -- Honor topology events — primary late-addition path (§9a). A newly paired
  -- but idle device appears here even when it never shows up in `changes`.
  for _, event in ipairs(payload.events or {}) do
    local etype = tostring(event.type or "")
    if etype:find("DeviceCreated") or etype:find("DeviceRemoved") or etype:find("DeviceModified") then
      should_resync = true
    end
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

`call_on_schedule` intervals are seconds, not milliseconds. Do not multiply a
seconds preference by 1000. Store the returned timer handle and cancel it before
rescheduling or when the bridge is removed.

```lua
local function get_poll_interval(device)
  local poll_value = tonumber(device.preferences and device.preferences.pollInterval) or 30
  return math.max(10, poll_value)
end

local function cancel_bridge_timer(bridge)
  local existing_timer = bridge:get_field(fields.POLL_TIMER)
  if existing_timer ~= nil then
    bridge.thread:cancel_timer(existing_timer)
    bridge:set_field(fields.POLL_TIMER, nil, { persist = false })
  end
end

-- In lifecycle init handler:
local function device_init(driver, device)
  if is_bridge(device) then
    cancel_bridge_timer(device)
    local timer = device.thread:call_on_schedule(get_poll_interval(device), function()
      local ok, err = pcall(sync.poll_bridge, driver, device)
      if not ok then
        log.error_with({ hub_logs = true },
          "Poll crashed: " .. tostring(err))
      end
    end, device.id .. "-poll")
    device:set_field(fields.POLL_TIMER, timer, { persist = false })
  end
end
```

## 8. Rate-Limit-Safe Bulk Child Creation (REQUIRED for large hubs)

A hub with hundreds of devices will exceed the SmartThings cloud device-creation rate
limit if you call `try_create_device` for every device in one pass. **Never create
children inline inside the inventory loop.** Instead, enqueue them and drain the queue
in paced batches across poll ticks, retrying failures with backoff. The queue lives in
`driver.datastore` so nothing is lost across a hub reboot.

> **⚠️ `driver.datastore` is copy-in / copy-out — you MUST write the queue back.** Reading
> `driver.datastore.pending_create_queue` returns a **snapshot**: `table.insert(queue, x)` on it
> does **not** persist, and `#queue` reports the *committed* length (so it prints **`0` right
> after an insert**). The enqueue function must therefore read a **materialized copy**, mutate
> it, and **reassign the whole table back**:
> ```lua
> local function enqueue_child_create(driver, bridge, mapped)
>   local queue = {}
>   for _, e in ipairs(driver.datastore.pending_create_queue or {}) do queue[#queue+1] = e end
>   -- ... dedup + table.insert(queue, { ... }) ...
>   driver.datastore.pending_create_queue = queue      -- REQUIRED: persist (top-level set)
> end
> ```
> `drain_create_queue` already reassigns `driver.datastore.pending_create_queue = remaining`, but
> **enqueue must do the same** or the item is silently lost and **no child is ever created** —
> the bridge connects, `/api/devices` returns 200, the log says "Queued child create … (queue
> size 0)", and `try_create_device` never fires. (Same rule for `inflight_creates` and any other
> datastore-backed table.)

```lua
-- Tunables
local MAX_CREATES_PER_INVENTORY = 25   -- inline budget at end of a full sync
local MAX_CREATES_PER_POLL      = 25   -- drained each incremental poll (MUST match
                                       -- MAX_CREATES_PER_INVENTORY — see below)
local CREATE_SPACING_SECONDS    = 0.15 -- pause between create calls
local MAX_CREATE_ATTEMPTS       = 8    -- give up after this many failures
local INFLIGHT_TTL_SECONDS      = 120  -- evict a stuck in-flight create after this
                                       -- so a cloud glitch cannot permanently strand it

-- ensure_child_device: existing → emit state; new → ENQUEUE (do not create inline)
local function ensure_child_device(driver, bridge, mapped, existing_child)
  if existing_child then
    emit_child_state(existing_child, mapped.raw, mapped.kind)
    return existing_child
  end
  enqueue_child_create(driver, bridge, mapped)  -- de-dups against queue + in-flight
  return nil
end

-- Drain paces creation and retries failures with exponential backoff.
function sync.drain_create_queue(driver, max_count)
  local queue = driver.datastore.pending_create_queue or {}
  local now, processed, remaining = os.time(), 0, {}
  for _, entry in ipairs(queue) do
    if processed >= max_count or (entry.next_attempt_at or 0) > now then
      table.insert(remaining, entry)                       -- budget spent / backing off
    else
      local bridge = find_bridge_by_dni(driver, entry.bridge_dni)
      if not bridge then table.insert(remaining, entry)
      elseif child_exists(driver, bridge, entry.key) then  -- created on a prior attempt
        -- drop it
      else
        cache_child_metadata_entry(driver, entry)          -- so lifecycle.init can apply
        local ok, err = driver:try_create_device(build_metadata(bridge, entry))
        processed = processed + 1
        if not ok then
          entry.attempts = (entry.attempts or 0) + 1
          entry.next_attempt_at = now + math.min(300, 5 * 2 ^ (entry.attempts - 1))
          if entry.attempts < MAX_CREATE_ATTEMPTS then table.insert(remaining, entry) end
        end
        socket.sleep(CREATE_SPACING_SECONDS)
      end
    end
  end
  driver.datastore.pending_create_queue = remaining
end
```

Mark each device `seen` **before** enqueuing so stale-cleanup never deletes a device that is
only waiting in the queue.

> **❌ DO NOT call `drain_create_queue` directly as the final step of a sync or poll.** A single
> bare `drain_create_queue(driver, MAX_CREATES_PER_INVENTORY)` drains **at most 25** devices and
> then returns, leaving the rest stranded in the queue until the *next* poll tick (up to one
> poll interval later) or a manual pull-to-refresh. On a 50–100 device hub this is the root cause
> of the **"I have to pull-to-refresh the bridge card several times before all my devices show
> up"** bug: each refresh only materialises one more batch of 25. **Always drive draining through
> the self-scheduling `sync.drain_pending` helper below, and add the cascade drain in
> `device_added`.** These two patterns are mandatory for any bridge that can have more devices
> than one batch.

### 8a. Self-scheduling drain (REQUIRED — replaces the bare end-of-sync drain)

`sync.drain_pending` drains one batch, then — **if the queue still has items** — reschedules
itself with `call_with_delay` so the remaining devices are created automatically within seconds,
with **zero** manual refreshes. It is the only thing the sync/poll paths should call.

```lua
-- PUBLIC: self-scheduling batch drain. Call this — never bare drain_create_queue — from
-- the end of sync_bridge_inventory and the top of poll_bridge.
function sync.drain_pending(driver, bridge)
  sync.drain_create_queue(driver, MAX_CREATES_PER_INVENTORY)
  local remaining = driver.datastore.pending_create_queue or {}
  if #remaining > 0 then
    -- More queued than one batch — keep going on this bridge's thread until empty.
    bridge.thread:call_with_delay(2, function()
      pcall(sync.drain_pending, driver, bridge)
    end, bridge.id .. "-drain")
  end
end
```

- **End of `sync_bridge_inventory` (step 10):** call `sync.drain_pending(driver, bridge)` — NOT
  `sync.drain_create_queue(...)`.
- **Top of `poll_bridge`:** call `sync.drain_pending(driver, bridge)` — NOT
  `sync.drain_create_queue(driver, MAX_CREATES_PER_POLL)`.
- Keep `MAX_CREATES_PER_POLL == MAX_CREATES_PER_INVENTORY` (both 25). A smaller poll budget only
  re-introduces multi-refresh latency now that draining self-schedules; there is no reason for the
  poll path to drain in smaller batches than the inventory path.

> **Self-scheduling is harmless when the queue is empty:** the `#remaining > 0` guard means the
> recursion stops the moment the queue drains, so there is no idle timer churn. The `bridge.id ..
> "-drain"` name makes the in-flight delayed call easy to identify in logs.

### 8b. Cascade drain from `device_added` (REQUIRED)

`try_create_device` is async: SmartThings fires `device_added` for each child seconds later. That
handler is the *earliest* signal that a create slot has freed up, so it is the right place to kick
the next batch immediately instead of waiting for `drain_pending`'s 2s timer or the next poll. In
the **child** branch of your `device_added` lifecycle handler:

```lua
-- device_added, child branch:
sync.apply_pending_child_metadata(driver, device)
local bridge = find_parent_bridge(driver, device)
if bridge then
  sync.clean_inflight_creates(driver, bridge)        -- free this child's in-flight slot

  -- CASCADE: if more creates are queued, drain the next batch now (don't wait for the poll).
  local remaining = driver.datastore.pending_create_queue or {}
  if #remaining > 0 then
    bridge.thread:call_with_delay(0.5, function()
      pcall(sync.drain_pending, driver, bridge)
    end)
  end
end
```

With 8a + 8b together, a 50-device hub fully populates in **~1–2 seconds with no manual refresh**:
the inventory drain creates 25 and self-schedules; the first `device_added` events cascade-drain
the remaining 25; the self-scheduled timer then finds an empty queue and stops.

### 8c. In-flight tracking WITH a TTL (REQUIRED — never a bare nil-check)

`try_create_device` is async, so the child may not appear in `driver:get_devices()` for several
seconds. Without a guard, the next sync/poll re-enqueues and re-submits it, creating duplicates.
Keep a `driver.datastore.inflight_creates` map keyed by `bridge_dni .. "|" .. child_key`: set it
to `os.time()` right after a successful `try_create_device`, and clear the entry once the child
shows up in `child_devices_for_bridge`.

> **⚠️ The in-flight guard MUST be TTL-bounded — a bare `if inflight[key] ~= nil then return` is a
> bug.** `try_create_device` can return `ok=true` while SmartThings, due to a cloud glitch, never
> fires `device_added`. With a bare nil-check the key then stays in `inflight_creates` **forever**,
> so every future detection cycle (topology event, unknown-id change, periodic reconcile) hits
> `enqueue_child_create`, sees the stale in-flight key, and silently returns — the device is
> **permanently missing** and the only recovery is deleting and re-adding the bridge. Always
> compare the stored timestamp against `INFLIGHT_TTL_SECONDS` and evict on expiry so the create is
> retried:

```lua
-- Inside enqueue_child_create, BEFORE inserting into the queue:
local inflight = driver.datastore.inflight_creates or {}
local inflight_key = bridge.device_network_id .. "|" .. mapped.key
local inflight_ts = inflight[inflight_key]
if inflight_ts ~= nil then
  if (os.time() - inflight_ts) < INFLIGHT_TTL_SECONDS then
    return                       -- genuinely in-flight; device_added still expected
  end
  inflight[inflight_key] = nil   -- TTL expired → assume the create was lost → allow retry
  driver.datastore.inflight_creates = inflight   -- copy-out: persist the eviction
end
-- ... proceed to de-dup against the queue and table.insert(queue, { ... }) ...
```

This (alongside the queue's own de-dup) prevents duplicate child devices during the initial bulk
create **and** guarantees a glitched create is retried within `INFLIGHT_TTL_SECONDS` rather than
stranding the device forever.

## 9. Detecting Late-Added / Removed Devices

A device added to the hub *after* the first inventory sync must appear in SmartThings
**automatically**, without the user opening the bridge card or restarting the driver. A single
detection path is **not** enough — implement **all three** below. They cover different hub
behaviours, and a device that slips through one is caught by another.

`refreshStates` returns two distinct arrays, and they are **not interchangeable**:

| Array | Carries | Fires when |
|-------|---------|-----------|
| `changes` | **property** updates (value/level/battery) for *existing* device IDs | a device's state changes |
| `events`  | **topology** events (`DeviceCreatedEvent`, `DeviceRemovedEvent`, `DeviceModifiedEvent`) | a device is paired / removed / reconfigured on the hub |

A newly paired but **idle** device (e.g. a contact sensor that hasn't been triggered yet) emits a
topology `event` but may never appear in `changes`. If you only inspect `changes`, that device is
invisible until it happens to report state — which may be hours, or never. **You must inspect both.**

```lua
-- (a) Topology events — primary path for late additions (esp. HC3-class hubs).
--     Iterate payload.events, NOT just payload.changes.
for _, event in ipairs(payload.events or {}) do
  local etype = tostring(event.type or "")
  if etype:find("DeviceCreated") or etype:find("DeviceRemoved") or etype:find("DeviceModified") then
    should_resync_inventory = true
  end
end

-- (b) Unknown device ID in the change feed — covers hubs that omit topology events.
--     When a change references a device_id with no matching child, a new device exists.
for _, change in ipairs(payload.changes or {}) do
  if change.id and child_for_bridge_and_device_id(driver, bridge, change.id) == nil then
    should_resync_inventory = true
  end
end

-- (c) Periodic full reconcile — catch-all, independent of the change feed.
--     Covers silent additions that emit neither a topology event nor a state change.
local n = (tonumber(bridge:get_field(fields.POLL_COUNT)) or 0) + 1
bridge:set_field(fields.POLL_COUNT, n, { persist = false })
if n % FULL_SYNC_EVERY_N_POLLS == 0 then        -- e.g. every 20 polls ≈ 10 min at 30s
  return sync.sync_bridge_inventory(driver, bridge)
end
```

When any path sets `should_resync_inventory`, run `sync.sync_bridge_inventory` — which enqueues the
new device and (via §8a `sync.drain_pending`) creates it automatically within seconds.

> **❌ Anti-pattern: relying on `changes` alone (path b only).** A driver that detects new devices
> *only* by "unknown device_id appeared in `changes`" will miss every idle late-added device and
> every device on a hub whose firmware doesn't surface state until first interaction. Such a driver
> appears to work in testing (you toggle the new device, it shows up) but fails in the field
> (sensors sit unpaired). **Paths (a) and (c) are not optional extras — they are what make
> late-additions reliable.** This is also the single biggest behavioural gap between a robust
> bridge driver and a naïve one; do not ship without all three.

Without all three, a device added to the hub between full syncs is only picked up on the next
driver restart or manual refresh.

## Key Design Principles

1. **Incremental first** — use cursor-based polling whenever available; fall back to full sync
2. **Optimistic + confirm** — emit state immediately, then confirm from hub API
3. **pcall everything** — never let a polling crash kill the driver
4. **Stale cleanup** — delete child devices that no longer exist on the hub
5. **Targeted refresh** — only refresh children that changed, not all children
6. **Health propagation** — bridge offline → children should reflect this
7. **Never bulk-create inline** — enqueue + drain in paced batches with backoff (§8); a large hub will otherwise trip the cloud creation rate limit and silently lose devices
8. **Drain via self-scheduling `sync.drain_pending`, never a bare `drain_create_queue`** — and cascade-drain from `device_added` (§8a/§8b); a one-shot drain forces the user to pull-to-refresh once per batch
9. **TTL-bound the in-flight guard** — a bare `inflight[key] ~= nil` check strands a device forever on a cloud glitch; evict after `INFLIGHT_TTL_SECONDS` and retry (§8c)
10. **Detect late additions three ways** — topology `events`, unknown ID in `changes`, AND a periodic full reconcile; `changes` alone misses idle late-added devices (§9)
