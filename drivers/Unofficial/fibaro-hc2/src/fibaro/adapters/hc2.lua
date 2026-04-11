local utils = require "utils"

local hc2 = {
  NAME = "hc2",
}

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

function hc2.is_match(raw_device)
  if type(raw_device) ~= "table" then
    return false
  end

  local raw_type = tostring(raw_device.type or "")
  local raw_name = tostring(raw_device.name or "")
  return raw_type:find("HC2", 1, true) ~= nil
    or raw_name:find("Home Center 2", 1, true) ~= nil
    or has_interface(raw_device.interfaces, "gateway")
end

function hc2.normalize_device_list(payload)
  if type(payload) ~= "table" then
    return {}
  end

  if type(payload.devices) == "table" then
    return payload.devices
  end

  return payload
end

function hc2.normalize_scene_list(payload)
  if type(payload) ~= "table" then
    return {}
  end

  if type(payload.scenes) == "table" then
    return payload.scenes
  end

  return payload
end

function hc2.normalize_device(raw_device)
  local props = type(raw_device.properties) == "table" and raw_device.properties or {}
  local actions = type(raw_device.actions) == "table" and raw_device.actions or {}
  local interfaces = type(raw_device.interfaces) == "table" and raw_device.interfaces or {}
  local value = props.value

  return {
    controller = hc2.NAME,
    id = raw_device.id,
    key = utils.child_key_for_id(raw_device.id),
    label = raw_device.name or ("Fibaro Device " .. tostring(raw_device.id)),
    type = tostring(raw_device.type or ""),
    base_type = tostring(raw_device.baseType or ""),
    actions = actions,
    interfaces = interfaces,
    value = value,
    level = utils.safe_tonumber(value),
    dead = props.dead == true,
    visible = raw_device.visible ~= false,
    is_plugin = has_interface(interfaces, "plugin"),
    is_gateway = has_interface(interfaces, "gateway") or tostring(raw_device.baseType or ""):find("gateway", 1, true) ~= nil,
    device_role = tostring(props.deviceRole or ""),
    device_control_type = props.deviceControlType,
    raw = raw_device,
  }
end

function hc2.normalize_scene(raw_scene)
  if type(raw_scene) ~= "table" then
    return nil
  end

  return {
    id = raw_scene.id,
    label = raw_scene.name or ("Scene " .. tostring(raw_scene.id)),
    type = tostring(raw_scene.type or ""),
    raw = raw_scene,
  }
end

function hc2.build_action_body(args)
  return {
    args = args or {},
  }
end

function hc2.command_refresh_attempts(status)
  if status == 202 then
    return 3
  end

  return 4
end

return hc2
