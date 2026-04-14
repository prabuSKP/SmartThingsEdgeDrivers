local base64 = require "st.base64"
local json = require "st.json"
local log = require "log"

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
    return nil, err, nil
  end

  if response == nil then
    return nil, "no response received", nil
  end

  local body = response:get_body() or ""
  if body == "" then
    return nil, nil, response.status
  end

  local ok, decoded = pcall(json.decode, body)
  if ok then
    return decoded, nil, response.status
  end

  return body, nil, response.status
end

local function copy_headers(source)
  local headers = {}
  for k, v in pairs(source) do
    headers[k] = v
  end
  return headers
end

local function build_base_url(config)
  return string.format("%s://%s:%d", config.scheme or "http", config.host, config.port)
end

function fibaro_api.new(config, label)
  local headers = copy_headers(DEFAULT_HEADERS)
  if (config.username or "") ~= "" or (config.password or "") ~= "" then
    local auth_header = "Basic " .. base64.encode(string.format("%s:%s", config.username or "", config.password or ""))
    headers["Authorization"] = auth_header
  end
  headers["X-Fibaro-Version"] = "2"

  local socket_builder = utils.labeled_socket_builder(
    label or "Fibaro HC",
    config.scheme == "https" and {
      mode = "client",
      protocol = "any",
      verify = "none",
      options = "all",
    } or nil
  )

  return setmetatable({
    client = RestClient.new(build_base_url(config), socket_builder),
    headers = headers,
  }, fibaro_api)
end

function fibaro_api:shutdown()
  if self.client then
    self.client:shutdown()
  end
end

function fibaro_api:get_devices()
  log.info("Requesting Fibaro inventory: GET /api/devices")
  local response, err = self.client:get("/api/devices", self.headers, retry_fn(3))
  return process_response(response, err)
end

function fibaro_api:get_device(device_id)
  log.info(string.format("Requesting Fibaro device state: GET /api/devices/%s", tostring(device_id)))
  local response, err = self.client:get(string.format("/api/devices/%s", tostring(device_id)), self.headers, retry_fn(3))
  return process_response(response, err)
end

function fibaro_api:get_login_status()
  log.info("Requesting Fibaro bootstrap: GET /api/loginStatus")
  local response, err = self.client:get("/api/loginStatus", self.headers, retry_fn(3))
  return process_response(response, err)
end

function fibaro_api:get_settings_info()
  log.info("Requesting Fibaro bootstrap: GET /api/settings/info")
  local response, err = self.client:get("/api/settings/info", self.headers, retry_fn(3))
  return process_response(response, err)
end

function fibaro_api:get_refresh_states(last)
  local suffix = ""
  if last ~= nil then
    suffix = "?last=" .. tostring(last)
  end

  log.info("Requesting Fibaro incremental state feed: GET /api/refreshStates" .. suffix)
  local response, err = self.client:get("/api/refreshStates" .. suffix, self.headers, retry_fn(3))
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
  log.info(string.format("Executing Fibaro scene %s", tostring(scene_id)))
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
  log.info(string.format("Killing Fibaro scene %s", tostring(scene_id)))
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
  local payload = json.encode(body or { args = {} })
  log.info(string.format("Calling Fibaro action %s for device %s", tostring(action_name), tostring(device_id)))
  local response, err = self.client:post(
    string.format("/api/devices/%s/action/%s", tostring(device_id), tostring(action_name)),
    payload,
    self.headers,
    retry_fn(3)
  )
  return process_response(response, err)
end

return fibaro_api
