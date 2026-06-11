local base64 = require "st.base64"
local json = require "st.json"
local log = require "log"

local cert = require "fibaro.cert"
local RestClient = require "lunchbox.rest"
local utils = require "utils"

local fibaro_api = {}
fibaro_api.__index = fibaro_api

local DEFAULT_HEADERS = {
  ["Accept"] = "application/json",
  ["Content-Type"] = "application/json",
}

local function retry_fn(attempts)
  local count = 0
  return function()
    count = count + 1
    return count < attempts
  end
end

local function process_response(response, err)
  if err ~= nil then
    log.error_with({hub_logs = true}, string.format("[Fibaro] API response error: %s", tostring(err)))
    return nil, err, nil
  end

  if response == nil then
    log.error_with({hub_logs = true}, "[Fibaro] No response received from server")
    return nil, "no response received", nil
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Response status: %d", response.status or 0))

  local body = response:get_body() or ""
  if body == "" then
    log.info_with({hub_logs = true}, "[Fibaro] Empty response body")
    return nil, nil, response.status
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Response body: %s", body))

  local ok, decoded = pcall(json.decode, body)
  if ok then
    log.info_with({hub_logs = true}, "[Fibaro] Successfully parsed JSON response")
    return decoded, nil, response.status
  end

  log.info_with({hub_logs = true}, "[Fibaro] Response body is not JSON, returning as plain text")
  return body, nil, response.status
end

local function copy_headers(source)
  local headers = {}
  for k, v in pairs(source) do
    headers[k] = v
  end
  return headers
end

local function encode_action_body(body)
  body = body or { args = {} }

  if type(body) ~= "table" then
    return json.encode(body)
  end

  if type(body.args) ~= "table" or next(body.args) ~= nil then
    return json.encode(body)
  end

  local fields = { "\"args\":[]" }
  for k, v in pairs(body) do
    if k ~= "args" then
      table.insert(fields, string.format("%s:%s", json.encode(tostring(k)), json.encode(v)))
    end
  end

  return "{" .. table.concat(fields, ",") .. "}"
end

local function build_base_url(config)
  local port = config.port or (config.scheme == "https" and 443 or 80)
  return string.format("%s://%s:%d", config.scheme or "http", config.host, port)
end

-- Legacy bundled certificate, used only by the "bundled" TLS mode. Relative path is
-- resolved from the driver's src/ working directory at runtime (the SmartThings jbl /
-- Aqara fp2 pattern). The default "auto" mode does NOT use this — it pins the CA fetched
-- live from the hub instead (see fibaro/cert.lua and sync.maybe_provision_ca).
local FIBARO_CAFILE = "./fibaro_server.crt"

-- Build the luasec TLS config (and optional pin verifier) for an HTTPS Fibaro endpoint.
-- tls_verify selects the trust model:
--  * "auto" (default): encrypt-only transport (verify="none") plus dynamic application-layer
--    CA pinning. Until a CA has been fetched (config.ca_fp unset) this is the bootstrap /
--    trust-on-first-use connection; once config.ca_fp is present every connection is
--    validated against it.
--  * "none": encrypt only, never validate. Escape hatch (pure Philips Hue model).
--  * "bundled": legacy static pin against src/fibaro_server.crt (verify="peer", cafile).
-- Returns ssl_config, pin_verify (pin_verify is nil unless dynamic pinning is active).
local function build_https_transport(config, label)
  local prefix = (label and #label > 0) and (label .. " ") or ""
  local mode = tostring(config.tls_verify or "auto"):lower()

  if mode == "none" then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] %sHTTPS transport: encrypt-only (verify=none, no certificate pinning)", prefix))
    return { mode = "client", protocol = "any", verify = "none", options = "all" }, nil
  end

  if mode == "bundled" then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] %sHTTPS transport: static bundled pin (verify=peer, cafile=%s)", prefix, FIBARO_CAFILE))
    return { mode = "client", protocol = "any", verify = "peer", options = "all", cafile = FIBARO_CAFILE }, nil
  end

  -- "auto": verify=none transport with dynamic CA pin enforced after the handshake.
  local ssl_config = { mode = "client", protocol = "any", verify = "none", options = "all" }
  if config.ca_fp ~= nil and config.ca_fp ~= "" then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] %sHTTPS transport: dynamic CA pin ACTIVE (verify=none + post-handshake check, sha256=%s)",
      prefix, tostring(config.ca_fp)))
    return ssl_config, cert.make_pin_verify(config.ca_fp, label)
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] %sHTTPS transport: bootstrap/TOFU (verify=none, awaiting CA fetch from /api/settings/certificates/ca)",
    prefix))
  return ssl_config, nil
end

function fibaro_api.new(config, label)
  label = label or "Fibaro HC"
  local headers = copy_headers(DEFAULT_HEADERS)
  if (config.username or "") ~= "" or (config.password or "") ~= "" then
    local auth_header = "Basic " .. base64.encode(string.format("%s:%s", config.username or "", config.password or ""))
    headers["Authorization"] = auth_header
  end
  headers["X-Fibaro-Version"] = "2"

  local base_url = build_base_url(config)
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] API client for %s -> %s (auth: %s, tls_verify: %s)",
    label, base_url,
    (headers["Authorization"] ~= nil) and "basic" or "none",
    (config.scheme == "https") and tostring(config.tls_verify or "auto") or "n/a"))

  local socket_builder
  if config.scheme == "https" then
    local ssl_config, pin_verify = build_https_transport(config, label)
    socket_builder = utils.labeled_socket_builder(label, ssl_config, pin_verify)
  else
    socket_builder = utils.labeled_socket_builder(label)
  end

  return setmetatable({
    client = RestClient.new(base_url, socket_builder),
    headers = headers,
  }, fibaro_api)
end

function fibaro_api:shutdown()
  if self.client then
    self.client:shutdown()
  end
end

function fibaro_api:get_devices()
  log.info_with({hub_logs = true}, "[Fibaro] API Request: GET /api/devices")
  local headers_str = ""
  if self.headers then
    local header_parts = {}
    for k, v in pairs(self.headers) do
      table.insert(header_parts, string.format("%s: %s", tostring(k), tostring(v)))
    end
    headers_str = table.concat(header_parts, ", ")
  end
  log.info_with({hub_logs = true}, string.format("[Fibaro] API Request Headers: %s", headers_str))
  local response, err = self.client:get("/api/devices", self.headers, retry_fn(3))
  return process_response(response, err)
end

function fibaro_api:get_device(device_id)
  log.info_with({hub_logs = true}, string.format("[Fibaro] API Request: GET /api/devices/%s", tostring(device_id)))
  local headers_str = ""
  if self.headers then
    local header_parts = {}
    for k, v in pairs(self.headers) do
      table.insert(header_parts, string.format("%s: %s", tostring(k), tostring(v)))
    end
    headers_str = table.concat(header_parts, ", ")
  end
  log.info_with({hub_logs = true}, string.format("[Fibaro] API Request Headers: %s", headers_str))
  local response, err = self.client:get(string.format("/api/devices/%s", tostring(device_id)), self.headers, retry_fn(3))
  return process_response(response, err)
end

function fibaro_api:get_login_status()
  log.info_with({hub_logs = true}, "[Fibaro] API Request: GET /api/loginStatus")
  local headers_str = ""
  if self.headers then
    local header_parts = {}
    for k, v in pairs(self.headers) do
      table.insert(header_parts, string.format("%s: %s", tostring(k), tostring(v)))
    end
    headers_str = table.concat(header_parts, ", ")
  end
  log.info_with({hub_logs = true}, string.format("[Fibaro] API Request Headers: %s", headers_str))
  local response, err = self.client:get("/api/loginStatus", self.headers, retry_fn(3))
  return process_response(response, err)
end

function fibaro_api:get_settings_info()
  log.info_with({hub_logs = true}, "[Fibaro] API Request: GET /api/settings/info")
  local headers_str = ""
  if self.headers then
    local header_parts = {}
    for k, v in pairs(self.headers) do
      table.insert(header_parts, string.format("%s: %s", tostring(k), tostring(v)))
    end
    headers_str = table.concat(header_parts, ", ")
  end
  log.info_with({hub_logs = true}, string.format("[Fibaro] API Request Headers: %s", headers_str))
  local response, err = self.client:get("/api/settings/info", self.headers, retry_fn(3))
  return process_response(response, err)
end

-- Fetch the hub's CA certificate so the driver can pin/validate TLS dynamically.
-- Returns (pem_or_table, err, status); the body is PEM (possibly JSON-wrapped) which
-- fibaro/cert.extract_pem normalizes. Called over the bootstrap verify=none connection.
function fibaro_api:get_ca_certificate()
  log.info_with({hub_logs = true}, "[Fibaro] API Request: GET /api/settings/certificates/ca")
  local response, err = self.client:get("/api/settings/certificates/ca", self.headers, retry_fn(3))
  return process_response(response, err)
end

function fibaro_api:get_refresh_states(last)
  local suffix = ""
  if last ~= nil then
    suffix = "?last=" .. tostring(last)
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] API Request: GET /api/refreshStates%s", suffix))
  local headers_str = ""
  if self.headers then
    local header_parts = {}
    for k, v in pairs(self.headers) do
      table.insert(header_parts, string.format("%s: %s", tostring(k), tostring(v)))
    end
    headers_str = table.concat(header_parts, ", ")
  end
  log.info_with({hub_logs = true}, string.format("[Fibaro] API Request Headers: %s", headers_str))
  local response, err = self.client:get("/api/refreshStates" .. suffix, self.headers, retry_fn(3))
  return process_response(response, err)
end

function fibaro_api:get_rooms()
  log.info_with({hub_logs = true}, "[Fibaro] API Request: GET /api/rooms")
  local response, err = self.client:get("/api/rooms", self.headers, retry_fn(3))
  return process_response(response, err)
end

function fibaro_api:get_scenes()
  local response, err = self.client:get("/api/scenes", self.headers, retry_fn(3))
  return process_response(response, err)
end

function fibaro_api:start_scene(scene_id)
  local response, err = self.client:post(
    string.format("/api/scenes/%s/action/start", tostring(scene_id)),
    "",
    self.headers,
    retry_fn(3)
  )
  return process_response(response, err)
end

function fibaro_api:stop_scene(scene_id)
  local response, err = self.client:post(
    string.format("/api/scenes/%s/action/stop", tostring(scene_id)),
    "",
    self.headers,
    retry_fn(3)
  )
  return process_response(response, err)
end

function fibaro_api:execute_scene(scene_id, body, headers)
  local payload = json.encode(body or {})
  log.info_with({hub_logs = true}, string.format("[Fibaro] Executing scene %s", tostring(scene_id)))
  local merged_headers = copy_headers(self.headers)
  for k, v in pairs(headers or {}) do
    merged_headers[k] = v
  end
  local response, err = self.client:post(
    string.format("/api/scenes/%s/execute", tostring(scene_id)),
    payload,
    merged_headers,
    retry_fn(3)
  )
  return process_response(response, err)
end

function fibaro_api:kill_scene(scene_id, body, headers)
  local payload = json.encode(body or {})
  log.info_with({hub_logs = true}, string.format("[Fibaro] Killing scene %s", tostring(scene_id)))
  local merged_headers = copy_headers(self.headers)
  for k, v in pairs(headers or {}) do
    merged_headers[k] = v
  end
  local response, err = self.client:post(
    string.format("/api/scenes/%s/kill", tostring(scene_id)),
    payload,
    merged_headers,
    retry_fn(3)
  )
  return process_response(response, err)
end

function fibaro_api:call_action(device_id, action_name, body)
  local payload = encode_action_body(body)
  log.info_with({hub_logs = true}, string.format("[Fibaro] API Request: POST /api/devices/%s/action/%s", tostring(device_id), tostring(action_name)))
  local headers_str = ""
  if self.headers then
    local header_parts = {}
    for k, v in pairs(self.headers) do
      table.insert(header_parts, string.format("%s: %s", tostring(k), tostring(v)))
    end
    headers_str = table.concat(header_parts, ", ")
  end
  log.info_with({hub_logs = true}, string.format("[Fibaro] API Request Headers: %s", headers_str))
  log.info_with({hub_logs = true}, string.format("[Fibaro] API Request Body: %s", payload))
  local response, err = self.client:post(
    string.format("/api/devices/%s/action/%s", tostring(device_id), tostring(action_name)),
    payload,
    self.headers,
    retry_fn(3)
  )
  return process_response(response, err)
end

function fibaro_api:get_rooms()
  log.info_with({hub_logs = true}, "[Fibaro] API Request: GET /api/rooms")
  local response, err = self.client:get("/api/rooms", self.headers, retry_fn(3))
  return process_response(response, err)
end

return fibaro_api
