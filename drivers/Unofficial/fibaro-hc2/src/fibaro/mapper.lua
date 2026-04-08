local utils = require "utils"

local mapper = {}

local function has_action(actions, action_name)
  return type(actions) == "table" and actions[action_name] ~= nil
end

local function has_value(device)
  return type(device) == "table"
    and type(device.properties) == "table"
    and device.properties.value ~= nil
end

function mapper.map_device(device)
  if type(device) ~= "table" or device.id == nil then
    return nil, "invalid device payload"
  end

  local actions = device.actions or {}
  local device_type = tostring(device.type or "")
  local label = device.name or ("Fibaro Device " .. tostring(device.id))

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

  if device_type:find("motionSensor", 1, true) then
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

  if device_type:find("doorSensor", 1, true) or device_type:find("windowSensor", 1, true) then
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
