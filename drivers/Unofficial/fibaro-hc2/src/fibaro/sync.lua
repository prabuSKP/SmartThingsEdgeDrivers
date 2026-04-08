local capabilities = require "st.capabilities"
local log = require "log"

local fields = require "fields"
local FibaroApi = require "fibaro.api"
local mapper = require "fibaro.mapper"
local utils = require "utils"

local sync = {}

local DEFAULT_POLL_INTERVAL = 30

local function get_poll_interval(device)
  local poll_value = utils.safe_tonumber(device.preferences and device.preferences.pollInterval) or DEFAULT_POLL_INTERVAL
  return math.max(10, poll_value)
end

local function get_bridge_config(bridge)
  local prefs = bridge.preferences or {}
  local host = utils.trim(prefs.host or "")
  local username = utils.trim(prefs.username or "")
  local password = prefs.password or ""
  local port = utils.safe_tonumber(prefs.port) or 80

  if host == "" or username == "" or password == "" then
    return nil, "bridge preferences incomplete"
  end

  return {
    host = host,
    port = port,
    username = username,
    password = password,
  }, nil
end

local function api_for_bridge(bridge)
  local config, err = get_bridge_config(bridge)
  if err ~= nil then
    return nil, err
  end

  return FibaroApi.new(config, bridge.label or bridge.device_network_id), nil
end

local function normalize_device_list(payload)
  if type(payload) ~= "table" then
    return {}
  end

  if payload.devices and type(payload.devices) == "table" then
    return payload.devices
  end

  return payload
end

local function child_devices_for_bridge(driver, bridge)
  local children = {}
  for _, device in ipairs(driver:get_devices()) do
    if device.parent_device_id == bridge.id and device.parent_assigned_child_key ~= nil then
      children[device.parent_assigned_child_key] = device
    end
  end
  return children
end

local function cache_child_metadata(driver, bridge, mapped)
  driver.datastore.pending_child_data = driver.datastore.pending_child_data or {}
  driver.datastore.pending_child_data[bridge.device_network_id .. "|" .. mapped.key] = {
    bridge_dni = bridge.device_network_id,
    hc2_device_id = mapped.id,
    hc2_device_type = mapped.type,
    hc2_device_kind = mapped.kind,
  }
end

function sync.apply_pending_child_metadata(driver, device)
  if utils.is_bridge(device) then return end

  driver.datastore.pending_child_data = driver.datastore.pending_child_data or {}
  local bridge = utils.find_parent_bridge(driver, device)
  local bridge_dni = bridge and bridge.device_network_id or device:get_field(fields.PARENT_BRIDGE_DNI)
  local child_key = device.parent_assigned_child_key
  if not bridge_dni or not child_key then return end

  local cache_key = bridge_dni .. "|" .. child_key
  local pending = driver.datastore.pending_child_data[cache_key]
  if pending == nil then return end

  device:set_field(fields.PARENT_BRIDGE_DNI, pending.bridge_dni, { persist = true })
  device:set_field(fields.HC2_DEVICE_ID, pending.hc2_device_id, { persist = true })
  device:set_field(fields.HC2_DEVICE_TYPE, pending.hc2_device_type, { persist = true })
  device:set_field(fields.HC2_DEVICE_KIND, pending.hc2_device_kind, { persist = true })
  driver.datastore.pending_child_data[cache_key] = nil
end

local function emit_child_state(device, raw_device, kind)
  local props = raw_device.properties or {}
  if props.dead == true then
    device:offline()
  else
    device:online()
  end

  local value = props.value
  if kind == "switch" then
    local event = utils.value_is_truthy(value) and capabilities.switch.switch.on() or capabilities.switch.switch.off()
    device:emit_event(event)
  elseif kind == "dimmer" then
    local numeric_value = utils.safe_tonumber(value) or 0
    device:emit_event(numeric_value > 0 and capabilities.switch.switch.on() or capabilities.switch.switch.off())
    device:emit_event(capabilities.switchLevel.level(utils.clamp(math.floor(numeric_value + 0.5), 0, 99)))
  elseif kind == "contact" then
    local event = utils.value_is_truthy(value) and capabilities.contactSensor.contact.open() or capabilities.contactSensor.contact.closed()
    device:emit_event(event)
  elseif kind == "motion" then
    local event = utils.value_is_truthy(value) and capabilities.motionSensor.motion.active() or capabilities.motionSensor.motion.inactive()
    device:emit_event(event)
  end
end

local function ensure_child_device(driver, bridge, mapped, existing_child)
  if existing_child then
    emit_child_state(existing_child, mapped.raw, mapped.kind)
    return existing_child
  end

  cache_child_metadata(driver, bridge, mapped)
  local metadata = {
    type = "EDGE_CHILD",
    label = mapped.label,
    profile = mapped.profile,
    manufacturer = "Fibaro",
    model = mapped.type ~= "" and mapped.type or "fibaro-hc2-device",
    vendor_provided_label = mapped.label,
    parent_device_id = bridge.id,
    parent_assigned_child_key = mapped.key,
  }

  local success, err = driver:try_create_device(metadata)
  if not success then
    log.error(string.format("Failed to create HC2 child %s: %s", mapped.key, tostring(err)))
  end

  return nil
end

local function delete_child(driver, child)
  if type(driver.try_delete_device) == "function" then
    driver:try_delete_device(child.id)
  else
    child:offline()
  end
end

function sync.sync_bridge_inventory(driver, bridge)
  local api, api_err = api_for_bridge(bridge)
  if api == nil then
    log.warn(string.format("Skipping bridge sync for %s: %s", bridge.label, tostring(api_err)))
    bridge:offline()
    return nil, api_err
  end

  local payload, err, status = api:get_devices()
  api:shutdown()
  if err ~= nil or status ~= 200 then
    bridge:offline()
    return nil, err or ("unexpected status " .. tostring(status))
  end

  bridge:online()
  local discovered = normalize_device_list(payload)
  local children_by_key = child_devices_for_bridge(driver, bridge)
  local seen = {}

  for _, raw_device in ipairs(discovered) do
    local mapped, map_err = mapper.map_device(raw_device)
    if mapped ~= nil then
      seen[mapped.key] = true
      ensure_child_device(driver, bridge, mapped, children_by_key[mapped.key])
    else
      log.debug(string.format("Skipping HC2 device %s: %s", tostring(raw_device.id), tostring(map_err)))
    end
  end

  for child_key, child in pairs(children_by_key) do
    if not seen[child_key] then
      log.info(string.format("Deleting stale HC2 child %s", child_key))
      delete_child(driver, child)
    end
  end

  return true, nil
end

function sync.refresh_child(driver, child)
  local bridge = utils.find_parent_bridge(driver, child)
  if bridge == nil then
    return nil, "bridge not found"
  end

  local api, api_err = api_for_bridge(bridge)
  if api == nil then
    child:offline()
    bridge:offline()
    return nil, api_err
  end

  local hc2_device_id = child:get_field(fields.HC2_DEVICE_ID) or utils.device_id_from_child_key(child.parent_assigned_child_key)
  local kind = child:get_field(fields.HC2_DEVICE_KIND) or "generic-sensor"
  local payload, err, status = api:get_device(hc2_device_id)
  api:shutdown()

  if err ~= nil or status ~= 200 then
    child:offline()
    bridge:offline()
    return nil, err or ("unexpected status " .. tostring(status))
  end

  bridge:online()
  emit_child_state(child, payload, kind)
  return true, nil
end

function sync.execute_child_action(driver, child, action_name, args)
  local bridge = utils.find_parent_bridge(driver, child)
  if bridge == nil then
    return nil, "bridge not found"
  end

  local api, api_err = api_for_bridge(bridge)
  if api == nil then
    child:offline()
    bridge:offline()
    return nil, api_err
  end

  local hc2_device_id = child:get_field(fields.HC2_DEVICE_ID) or utils.device_id_from_child_key(child.parent_assigned_child_key)
  local _, err, status = api:call_action(hc2_device_id, action_name, args)
  api:shutdown()

  if err ~= nil or (status ~= 200 and status ~= 202 and status ~= 204) then
    child:offline()
    bridge:offline()
    return nil, err or ("unexpected status " .. tostring(status))
  end

  bridge:online()
  return sync.refresh_child(driver, child)
end

local function cancel_bridge_timer(bridge)
  local existing_timer = bridge:get_field(fields.POLL_TIMER)
  if existing_timer ~= nil then
    bridge.thread:cancel_timer(existing_timer)
    bridge:set_field(fields.POLL_TIMER, nil, { persist = false })
  end
end

function sync.reschedule_bridge_poll(driver, bridge)
  cancel_bridge_timer(bridge)

  if get_bridge_config(bridge) == nil then
    return
  end

  local timer = bridge.thread:call_on_schedule(
    get_poll_interval(bridge),
    function()
      sync.sync_bridge_inventory(driver, bridge)
    end,
    "Fibaro HC2 inventory poll"
  )

  bridge:set_field(fields.POLL_TIMER, timer, { persist = false })
end

function sync.on_bridge_removed(driver, bridge)
  cancel_bridge_timer(bridge)

  for _, device in ipairs(driver:get_devices()) do
    if device.parent_device_id == bridge.id and device.parent_assigned_child_key ~= nil then
      delete_child(driver, device)
    end
  end
end

return sync
