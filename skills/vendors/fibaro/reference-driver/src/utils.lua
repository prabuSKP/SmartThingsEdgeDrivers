local log = require "log"

local utils = {}

local API_VERSION_MATCHER = {
  HC2 = 4,
  HCL = 4,
  HC3 = 5,
  HC3L = 5,
  YH = 5,
  ZB = 5,
}

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

-- Build a socket factory. ssl_config is the luasec table passed to ssl.wrap (must contain
-- only keys luasec understands). pin_verify, when supplied, is a (sock) -> ok, err function
-- run immediately after a successful handshake to enforce application-layer certificate
-- pinning (see fibaro/cert.lua); a false result closes the socket and fails the connection.
function utils.labeled_socket_builder(label, ssl_config, pin_verify)
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
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] %sOpening TCP socket to %s:%s (ssl=%s)",
      label, tostring(host), tostring(port), tostring(wrap_ssl == true)))
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
      log.warn_with({hub_logs = true}, string.format(
        "[Fibaro] %sTCP connect to %s:%s FAILED: %s",
        label, tostring(host), tostring(port), tostring(err)))
      return nil, "connect error: " .. err
    end
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] %sTCP connected to %s:%s", label, tostring(host), tostring(port)))

    _, err = sock:setoption("keepalive", true)
    if err ~= nil then
      return nil, "setoption error: " .. err
    end

    if wrap_ssl then
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] %sWrapping socket with TLS (verify=%s%s)",
        label, tostring(ssl_config.verify),
        (type(pin_verify) == "function") and ", dynamic CA pin" or ""))

      sock, err = ssl.wrap(sock, ssl_config)
      if err ~= nil then
        return nil, "SSL wrap error: " .. err
      end

      -- ssl.wrap returns a fresh object that does not inherit the TCP timeout, so a
      -- silently-dropped or mis-negotiated handshake could otherwise block forever.
      _, err = sock:settimeout(30)
      if err ~= nil then
        return nil, "SSL settimeout error: " .. err
      end

      _, err = sock:dohandshake()
      if err ~= nil then
        log.warn_with({hub_logs = true}, string.format(
          "[Fibaro] %sTLS handshake to %s:%s FAILED: %s", label, tostring(host), tostring(port), tostring(err)))
        return nil, "SSL handshake error: " .. err
      end
      log.info_with({hub_logs = true}, string.format("[Fibaro] %sTLS handshake complete with %s:%s", label, tostring(host), tostring(port)))

      if type(pin_verify) == "function" then
        local pin_ok, pin_err = pin_verify(sock)
        if not pin_ok then
          log.error_with({hub_logs = true}, string.format(
            "[Fibaro] %sTLS certificate pin verification FAILED: %s", label, tostring(pin_err)))
          pcall(function() sock:close() end)
          return nil, "TLS pin verification failed: " .. tostring(pin_err)
        end
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

-- Build the mDNS hostname a Fibaro HC3 answers to from its serial number.
-- A real HC3 does not advertise a browsable mDNS service, but it does run a
-- hostname responder for "hc3-<serial>.local", so this is how the bridge is
-- reached when the user supplies a serial number instead of an IP.
-- Tolerant of what the user actually types: bare serial ("00033787"),
-- prefixed ("hc3-00033787" / "HC3-00033787"), or a full ".local" hostname.
function utils.hostname_for_serial(serial_number)
  local value = utils.trim(tostring(serial_number or "")):lower()
  if value == "" then
    return nil
  end

  -- Already a full hostname: pass through (only append the domain if missing).
  if value:match("%.local$") then
    return value
  end
  -- Preserve an existing "hcX-" prefix (hc3-, hc3l-, hcl-, etc.) so HC3L serials like
  -- "HC3L-12345" produce "hc3l-12345.local" rather than "hc3-hc3l-12345.local".
  if value:match("^hc%w*%-") then
    return value .. ".local"
  end

  return "hc3-" .. value .. ".local"
end

-- Normalize a user-entered host/IP into something the socket layer can dial.
-- People routinely paste "http://192.168.1.50", "192.168.1.50/", or
-- "192.168.1.50:8080" into the host field; passed through verbatim these produce
-- a malformed base URL and the connection silently fails. Strips an accidental
-- scheme prefix, surrounding whitespace, and any trailing path, and pulls out an
-- embedded ":port" (IPv4 / hostname only — IPv6 literals are left untouched).
-- Returns: clean_host (string, may be ""), embedded_port (number or nil).
function utils.sanitize_host(raw)
  local value = utils.trim(tostring(raw or ""))
  if value == "" then
    return "", nil
  end

  -- Drop a leading scheme such as "http://" / "https://".
  value = value:gsub("^[%a][%w+.%-]*://", "")
  -- Drop any path / query / trailing slash (e.g. "/api", "/").
  value = value:gsub("[/?].*$", "")
  value = utils.trim(value)

  -- Pull out an embedded "host:port" for IPv4 / hostnames. A bare IPv6 literal
  -- contains multiple colons, so only treat a single-colon "<host>:<digits>" form
  -- as host+port and leave everything else as-is.
  if select(2, value:gsub(":", ":")) == 1 then
    local host, port = value:match("^(.-):(%d+)$")
    if host and host ~= "" then
      return utils.trim(host), tonumber(port)
    end
  end

  return value, nil
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

function utils.starts_with(value, prefix)
  return type(value) == "string"
    and type(prefix) == "string"
    and value:sub(1, #prefix) == prefix
end

function utils.in_array(values, needle)
  if type(values) ~= "table" then
    return false
  end

  for _, value in ipairs(values) do
    if value == needle then
      return true
    end
  end

  return false
end

function utils.api_version_for_serial(serial_number)
  local serial = tostring(serial_number or "")
  for prefix, version in pairs(API_VERSION_MATCHER) do
    if utils.starts_with(serial, prefix) then
      return version
    end
  end

  return nil
end

function utils.controller_kind_from_info(info)
  if type(info) ~= "table" then
    return nil
  end

  local platform = tostring(info.platform or ""):upper()
  if platform == "HC3" or platform == "HC3L" or platform == "YH" or platform == "ZB" then
    return "hc3"
  end

  if platform == "HC2" or platform == "HCL" then
    return "hc2"
  end

  local api_version = utils.api_version_for_serial(info.serialNumber)
  if api_version == 5 then
    return "hc3"
  elseif api_version == 4 then
    return "hc2"
  end

  return nil
end

return utils
