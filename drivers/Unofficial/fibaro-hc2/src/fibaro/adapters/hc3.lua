local utils = require "utils"

local hc3 = {
  NAME = "hc3",
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

local function has_hc3_marker(raw_device)
  if type(raw_device) ~= "table" then
    return false
  end

  local props = type(raw_device.properties) == "table" and raw_device.properties or {}
  return raw_device.modified ~= nil
    or raw_device.view ~= nil
    or raw_device.hasUIView ~= nil
    or raw_device.isPlugin ~= nil
    or props.state ~= nil
    or props.deviceRole ~= nil
    or props.deviceControlType ~= nil
end

function hc3.is_match(raw_device)
  if type(raw_device) ~= "table" then
    return false
  end

  local raw_type = tostring(raw_device.type or "")
  local raw_name = tostring(raw_device.name or "")
  return raw_type:find("HC3", 1, true) ~= nil
    or raw_name:find("Home Center 3", 1, true) ~= nil
    or has_hc3_marker(raw_device)
end

function hc3.normalize_device_list(payload)
  if type(payload) ~= "table" then
    return {}
  end

  if type(payload.devices) == "table" then
    return payload.devices
  end

  return payload
end

function hc3.normalize_scene_list(payload)
  if type(payload) ~= "table" then
    return {}
  end

  if type(payload.scenes) == "table" then
    return payload.scenes
  end

  return payload
end

function hc3.normalize_device(raw_device)
  local props = type(raw_device.properties) == "table" and raw_device.properties or {}
  local actions = type(raw_device.actions) == "table" and raw_device.actions or {}
  local interfaces = type(raw_device.interfaces) == "table" and raw_device.interfaces or {}
  local value = props.value

  if value == nil then
    value = props.state
  end

  local level = utils.safe_tonumber(value)
  if level == nil and type(props.state) == "boolean" and actions.setValue ~= nil then
    level = props.state and 99 or 0
  end

  return {
    controller = hc3.NAME,
    id = raw_device.id,
    key = utils.child_key_for_id(raw_device.id),
    label = raw_device.name or ("Fibaro Device " .. tostring(raw_device.id)),
    type = tostring(raw_device.type or ""),
    base_type = tostring(raw_device.baseType or ""),
    actions = actions,
    interfaces = interfaces,
    value = value,
    level = level,
    dead = props.dead == true,
    visible = raw_device.visible ~= false,
    is_plugin = raw_device.isPlugin == true or has_interface(interfaces, "plugin"),
    is_gateway = has_interface(interfaces, "gateway") or tostring(raw_device.baseType or ""):find("gateway", 1, true) ~= nil,
    device_role = tostring(props.deviceRole or ""),
    device_control_type = props.deviceControlType,
    raw = raw_device,
  }
end

function hc3.normalize_scene(raw_scene)
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

function hc3.build_action_body(args)
  return {
    args = args or {},
    delay = 0,
  }
end

function hc3.command_refresh_attempts(status)
  if status == 202 then
    return 3
  end

  return 1
end

return hc3
