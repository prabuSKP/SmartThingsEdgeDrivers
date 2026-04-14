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

function mapper.map_device(device)
  if type(device) ~= "table" or device.id == nil then
    return nil, "invalid device payload"
  end

  if device.is_gateway then
    return nil, "controller device"
  end

  if device.is_user then
    return nil, "user device"
  end

  if device.is_plugin then
    return nil, "plugin or virtual device"
  end

  if device.enabled == false then
    return nil, "disabled device"
  end

  local actions = device.actions or {}
  local device_type = tostring(device.type or "")
  local base_type = tostring(device.base_type or "")
  local device_role = tostring(device.device_role or "")
  local interfaces = device.interfaces or {}
  local lowered_type = device_type:lower()
  local lowered_base_type = base_type:lower()
  local lowered_role = device_role:lower()
  local label = device.label or ("Fibaro Device " .. tostring(device.id))

  if has_action(actions, "setValue") then
    return {
      id = device.id,
      key = utils.child_key_for_id(device.id),
      kind = "dimmer",
      profile = "fibaro-dimmer",
      label = label,
      type = device_type,
      raw = device,
    }
  end

  if has_action(actions, "turnOn") and has_action(actions, "turnOff") then
    return {
      id = device.id,
      key = utils.child_key_for_id(device.id),
      kind = "switch",
      profile = "fibaro-switch",
      label = label,
      type = device_type,
      raw = device,
    }
  end

  if contains(lowered_type, "motionsensor")
    or contains(lowered_base_type, "motionsensor")
    or contains(lowered_role, "motion")
    or has_interface(interfaces, "motionSensor")
  then
    return {
      id = device.id,
      key = utils.child_key_for_id(device.id),
      kind = "motion",
      profile = "fibaro-motion",
      label = label,
      type = device_type,
      raw = device,
    }
  end

  if contains(lowered_type, "doorsensor")
    or contains(lowered_type, "windowsensor")
    or contains(lowered_type, "doorwindowsensor")
    or contains(lowered_base_type, "doorsensor")
    or contains(lowered_base_type, "windowsensor")
    or contains(lowered_base_type, "doorwindowsensor")
    or contains(lowered_role, "door")
    or contains(lowered_role, "window")
    or has_interface(interfaces, "contactSensor")
    or has_interface(interfaces, "doorWindowSensor")
  then
    return {
      id = device.id,
      key = utils.child_key_for_id(device.id),
      kind = "contact",
      profile = "fibaro-contact",
      label = label,
      type = device_type,
      raw = device,
    }
  end

  if has_value(device) then
    return {
      id = device.id,
      key = utils.child_key_for_id(device.id),
      kind = "generic-sensor",
      profile = "fibaro-generic-sensor",
      label = label,
      type = device_type,
      raw = device,
    }
  end

  return nil, "unsupported device shape"
end

return mapper
