local log = require "log"
local utils = require "utils"

local mapper = {}

local function has_action(actions, action_name)
  return type(actions) == "table" and actions[action_name] ~= nil
end

local function has_interface(interfaces, needle)
  if type(interfaces) ~= "table" then
    return false
  end

  for _, value in ipairs(interfaces) do
    if tostring(value) == needle then
      return true
    end
  end

  return false
end

local function has_value(device)
  return type(device) == "table" and device.value ~= nil
end

local function contains(haystack, needle)
  return tostring(haystack or ""):find(needle, 1, true) ~= nil
end

-- Multi-attribute mapping rules table
-- Checked in order; first match wins.
-- More specific rules (type+role combinations) must come BEFORE generic action-based rules.
local MAPPING_RULES = {
  -- 1. BLINDS / WINDOW COVERINGS
  {
    match = function(d)
      return contains(d.type, "rollerShutter")
        or contains(d.type, "FGR")
        or contains(d.base_type, "baseShutter")
        or contains(d.role, "BlindsWithPositioning")
        or contains(d.role, "Blind")
        or has_interface(d.interfaces, "windowCovering")
    end,
    kind = "blind",
    profile = "fibaro-blind",
    reason = "BLIND (type/role/interface match)"
  },

  -- 2. SMOKE / HEAT DETECTOR
  {
    match = function(d)
      return contains(d.type, "smokeSensor")
        or contains(d.type, "heatDetector")
        or contains(d.base_type, "lifeDangerSensor")
        or contains(d.role, "Smoke")
        or contains(d.role, "HeatDetector")
        or has_interface(d.interfaces, "smokeDetector")
    end,
    kind = "smoke-detector",
    profile = "fibaro-smoke-detector",
    reason = "SMOKE-DETECTOR (type/role/interface match)"
  },

  -- 3. MOTION SENSOR
  {
    match = function(d)
      return contains(d.type, "motionSensor")
        or contains(d.base_type, "motionSensor")
        or contains(d.role, "Motion")
        or has_interface(d.interfaces, "motionSensor")
    end,
    kind = "motion",
    profile = "fibaro-motion",
    reason = "MOTION (type/role/interface match)"
  },

  -- 4. CONTACT SENSOR (door/window)
  {
    match = function(d)
      return contains(d.type, "doorSensor")
        or contains(d.type, "windowSensor")
        or contains(d.type, "doorWindowSensor")
        or contains(d.base_type, "doorSensor")
        or contains(d.base_type, "windowSensor")
        or contains(d.role, "Door")
        or contains(d.role, "Window")
        or has_interface(d.interfaces, "contactSensor")
        or has_interface(d.interfaces, "doorWindowSensor")
    end,
    kind = "contact",
    profile = "fibaro-contact",
    reason = "CONTACT (type/role/interface match)"
  },

  -- 5. TEMPERATURE SENSOR
  {
    match = function(d)
      return contains(d.type, "temperatureSensor")
        or contains(d.role, "Temperature")
        or has_interface(d.interfaces, "temperatureSensor")
    end,
    kind = "temperature-sensor",
    profile = "fibaro-temperature-sensor",
    reason = "TEMPERATURE-SENSOR (type/role/interface match)"
  },

  -- 6. HUMIDITY SENSOR
  {
    match = function(d)
      return contains(d.type, "humiditySensor")
        or contains(d.role, "Humidity")
        or has_interface(d.interfaces, "humiditySensor")
    end,
    kind = "humidity-sensor",
    profile = "fibaro-humidity-sensor",
    reason = "HUMIDITY-SENSOR (type/role/interface match)"
  },

  -- 7. ILLUMINANCE / LIGHT SENSOR
  {
    match = function(d)
      return contains(d.type, "lightSensor")
        or contains(d.role, "LightSensor")
        or has_interface(d.interfaces, "lightSensor")
    end,
    kind = "illuminance-sensor",
    profile = "fibaro-illuminance-sensor",
    reason = "ILLUMINANCE-SENSOR (type/role/interface match)"
  },

  -- 8. WATER / FLOOD SENSOR
  {
    match = function(d)
      return contains(d.type, "floodSensor")
        or contains(d.type, "waterSensor")
        or contains(d.role, "Water")
        or contains(d.role, "Flood")
        or has_interface(d.interfaces, "waterSensor")
        or has_interface(d.interfaces, "floodSensor")
    end,
    kind = "water-sensor",
    profile = "fibaro-water-sensor",
    reason = "WATER-SENSOR (type/role/interface match)"
  },

  -- 9. DIMMER (has setValue action - checked AFTER specific types above)
  {
    match = function(d)
      return has_action(d.actions, "setValue")
    end,
    kind = "dimmer",
    profile = "fibaro-dimmer",
    reason = "DIMMER (has setValue action)"
  },

  -- 10. SWITCH (has turnOn/turnOff actions)
  {
    match = function(d)
      return has_action(d.actions, "turnOn") and has_action(d.actions, "turnOff")
    end,
    kind = "switch",
    profile = "fibaro-switch",
    reason = "SWITCH (has turnOn/turnOff actions)"
  },

  -- 11. GENERIC SENSOR (has value but no actionable type)
  {
    match = function(d)
      return has_value(d)
    end,
    kind = "generic-sensor",
    profile = "fibaro-generic-sensor",
    reason = "GENERIC-SENSOR (has value property)"
  },
}

function mapper.map_device(device, rooms)
  if type(device) ~= "table" or device.id == nil then
    log.info_with({hub_logs = true}, "[Fibaro] map_device: invalid device payload")
    return nil, "invalid device payload"
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] map_device: id=%s, name=%s, type=%s, base_type=%s, role=%s",
    tostring(device.id),
    tostring(device.label),
    tostring(device.type),
    tostring(device.base_type),
    tostring(device.device_role)
  ))

  -- Skip non-device types
  if device.is_gateway then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is a gateway/controller, skipping", tostring(device.id)))
    return nil, "controller device"
  end

  if device.is_user then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is a user device, skipping", tostring(device.id)))
    return nil, "user device"
  end

  if device.is_plugin then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is a plugin/virtual device, skipping", tostring(device.id)))
    return nil, "plugin or virtual device"
  end

  if device.enabled == false then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is disabled, skipping", tostring(device.id)))
    return nil, "disabled device"
  end

  -- Prepare normalized attributes for matching
  local actions = device.actions or {}
  local device_type = tostring(device.type or "")
  local base_type = tostring(device.base_type or "")
  local device_role = tostring(device.device_role or "")
  local interfaces = device.interfaces or {}
  local parent_id = device.parent_id or 0
  local room_id = device.room_id or 0
  local raw_label = device.label or ("Fibaro Device " .. tostring(device.id))

  -- Look up room name from rooms table and prefix label
  local room_name = ""
  if type(rooms) == "table" and room_id > 0 then
    room_name = rooms[room_id] or ""
  end

  local label = raw_label
  if room_name ~= "" then
    -- Format: [RoomName:roomId] DeviceLabel
    -- This encodes the Fibaro room_id in the label since SmartThings
    -- does NOT preserve vendorProvidedLabel for EDGE_CHILD devices.
    -- The roomId is essential for the Python room assignment script.
    label = string.format("[%s:%s] %s", room_name, tostring(room_id), raw_label)
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Device %s: roomId=%s, roomName='%s', label='%s', rawLabel='%s'",
    tostring(device.id),
    tostring(room_id),
    tostring(room_name),
    tostring(label),
    tostring(raw_label)
  ))

  local match_context = {
    type = device_type,
    base_type = base_type,
    role = device_role,
    actions = actions,
    interfaces = interfaces,
    value = device.value,
  }

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Device %s: type=%s, base_type=%s, role=%s, actions=%s, interfaces=%s, value=%s",
    tostring(device.id),
    device_type,
    base_type,
    device_role,
    tostring(actions),
    tostring(interfaces),
    tostring(device.value)
  ))

  -- Apply mapping rules in order
  for _, rule in ipairs(MAPPING_RULES) do
    if rule.match(match_context) then
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] Device %s mapped as %s", tostring(device.id), rule.reason))
      return {
        id = device.id,
        key = utils.child_key_for_id(device.id),
        kind = rule.kind,
        profile = rule.profile,
        label = label,
        type = device_type,
        parent_id = parent_id,
        room_id = room_id,
        room_name = room_name,
        raw = device,
      }
    end
  end

  -- DEFAULT: No specific rule matched — give device a default card instead of skipping.
  -- This ensures ALL Fibaro devices are visible in SmartThings, even unrecognized types.
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Device %s mapped as DEFAULT (no specific rule matched, type=%s)", tostring(device.id), device_type))
  return {
    id = device.id,
    key = utils.child_key_for_id(device.id),
    kind = "default",
    profile = "fibaro-default",
    label = label,
    type = device_type,
    parent_id = parent_id,
    room_id = room_id,
    room_name = room_name,
    raw = device,
  }
end

return mapper
