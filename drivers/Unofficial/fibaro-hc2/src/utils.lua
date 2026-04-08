local log = require "log"

local utils = {}

function utils.backoff_builder(max, inc, rand)
  local count = 0
  inc = inc or 1
  return function()
    local randval = 0
    if rand then
      randval = math.random() * rand * 2 - rand
    end

    local base = inc * (2 ^ count - 1)
    count = count + 1
    if max then base = math.min(base, max) end
    return math.max(base + randval, 0)
  end
end

function utils.labeled_socket_builder(label, ssl_config)
  local socket = require "cosock.socket"
  local ssl = require "cosock.ssl"

  label = label or ""
  if #label > 0 then
    label = label .. " "
  end

  if not ssl_config then
    ssl_config = { mode = "client", protocol = "any", verify = "none", options = "all" }
  end

  local function make_socket(host, port, wrap_ssl)
    log.info(string.format("%sCreating TCP socket", label))
    local sock, err = socket.tcp()
    if err ~= nil or not sock then
      return nil, (err or "unknown error creating TCP socket")
    end

    _, err = sock:settimeout(30)
    if err ~= nil then
      return nil, "settimeout error: " .. err
    end

    _, err = sock:connect(host, port)
    if err ~= nil then
      return nil, "connect error: " .. err
    end

    _, err = sock:setoption("keepalive", true)
    if err ~= nil then
      return nil, "setoption error: " .. err
    end

    if wrap_ssl then
      sock, err = ssl.wrap(sock, ssl_config)
      if err ~= nil then
        return nil, "SSL wrap error: " .. err
      end

      _, err = sock:dohandshake()
      if err ~= nil then
        return nil, "SSL handshake error: " .. err
      end
    end

    return sock, nil
  end

  return make_socket
end

function utils.safe_tonumber(value)
  if value == nil then return nil end
  if type(value) == "number" then return value end
  if type(value) == "string" and value ~= "" then
    return tonumber(value)
  end
  return nil
end

function utils.clamp(value, min_value, max_value)
  if value < min_value then return min_value end
  if value > max_value then return max_value end
  return value
end

function utils.trim(value)
  if type(value) ~= "string" then return value end
  return value:match("^%s*(.-)%s*$")
end

function utils.is_bridge(device)
  return device.parent_assigned_child_key == nil
end

function utils.child_key_for_id(device_id)
  return string.format("device:%s", tostring(device_id))
end

function utils.device_id_from_child_key(child_key)
  if type(child_key) ~= "string" then return nil end
  local suffix = child_key:match("^device:(.+)$")
  return utils.safe_tonumber(suffix) or suffix
end

function utils.find_parent_bridge(driver, device)
  if utils.is_bridge(device) then return device end
  if not device.parent_device_id then return nil end

  for _, candidate in ipairs(driver:get_devices()) do
    if candidate.id == device.parent_device_id then
      return candidate
    end
  end

  return nil
end

function utils.value_is_truthy(value)
  if type(value) == "boolean" then return value end

  local numeric = utils.safe_tonumber(value)
  if numeric ~= nil then
    return numeric ~= 0
  end

  if type(value) == "string" then
    local lowered = value:lower()
    return lowered == "true" or lowered == "on" or lowered == "open" or lowered == "active"
  end

  return value ~= nil
end

return utils
