local log = require "log"
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
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] HC2 normalize_device: id=%s, name=%s, type=%s",
    tostring(raw_device.id),
    tostring(raw_device.name),
    tostring(raw_device.type)
  ))
  
  local props = type(raw_device.properties) == "table" and raw_device.properties or {}
  local actions = type(raw_device.actions) == "table" and raw_device.actions or {}
  local interfaces = type(raw_device.interfaces) == "table" and raw_device.interfaces or {}
  local value = props.value
  local dead = props.dead
  if type(dead) == "string" then
    dead = dead:lower() == "true"
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] HC2 device properties: value=%s, level=%s, dead=%s, deviceRole=%s",
    tostring(value),
    tostring(utils.safe_tonumber(value)),
    tostring(dead),
    tostring(props.deviceRole)
  ))

  local normalized = {
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
    dead = dead == true,
    visible = raw_device.visible ~= false,
    enabled = raw_device.enabled ~= false,
    is_plugin = raw_device.isPlugin == true or raw_device.type == "virtual_device" or has_interface(interfaces, "plugin") or has_interface(interfaces, "virtualDevice"),
    is_gateway = has_interface(interfaces, "gateway")
      or tostring(raw_device.baseType or ""):find("gateway", 1, true) ~= nil
      or tostring(raw_device.type or ""):find("PrimaryController", 1, true) ~= nil
      or tostring(raw_device.type or "") == "HC_user",
    is_user = tostring(raw_device.type or "") == "HC_user" or tostring(raw_device.type or "") == "VOIP_user",
    parent_id = utils.safe_tonumber(raw_device.parentId) or 0,
    room_id = utils.safe_tonumber(raw_device.roomID) or 0,
    device_role = tostring(props.deviceRole or ""),
    device_control_type = props.deviceControlType,
    unit = props.unit,
    raw = raw_device,
  }
  
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] HC2 normalized result: id=%s, label=%s, value=%s, level=%s, dead=%s, is_plugin=%s, is_gateway=%s",
    tostring(normalized.id),
    tostring(normalized.label),
    tostring(normalized.value),
    tostring(normalized.level),
    tostring(normalized.dead),
    tostring(normalized.is_plugin),
    tostring(normalized.is_gateway)
  ))
  
  return normalized
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
