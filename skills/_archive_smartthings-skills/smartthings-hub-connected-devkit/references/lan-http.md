# LAN HTTP Communication for Edge Drivers

Load this when implementing HTTP-based device communication in an Edge driver.

## Pure Lua HTTP Client

`cosock.asyncify "socket.http"` wraps `socket.http` to work with the hub's cooperative threading model:

```lua
local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
```

### Basic GET

```lua
local function http_get(url, headers)
  local resp_body = {}
  local r, status_code, resp_hdrs = http.request {
    url = url,
    method = "GET",
    headers = headers or {},
    sink = ltn12.sink.table(resp_body),
  }
  if not r then
    log.warn("HTTP GET failed: " .. tostring(status_code))
    return nil, status_code
  end
  return table.concat(resp_body), status_code
end
```

### Basic POST

```lua
local function http_post(url, body, headers)
  local resp_body = {}
  local req_headers = headers or {}
  if body then
    req_headers["Content-Type"] = "application/json"
    req_headers["Content-Length"] = #body
  end

  local r, status_code = http.request {
    url = url,
    method = "POST",
    headers = req_headers,
    sink = ltn12.sink.table(resp_body),
    source = body and ltn12.source.string(body) or nil,
  }

  if not r then
    log.warn("HTTP POST failed: " .. tostring(status_code))
    return nil, status_code
  end
  return table.concat(resp_body), status_code
end
```

### General Request

```lua
local function http_request(url, method, headers, body)
  local resp_body = {}
  local req_headers = headers or {}
  local req_body = body or nil

  if req_body then
    req_headers["Content-Length"] = #req_body
  end

  local r, status_code, resp_hdrs = http.request {
    url = url,
    method = method or "GET",
    headers = req_headers,
    sink = ltn12.sink.table(resp_body),
    source = req_body and ltn12.source.string(req_body) or nil,
  }

  if not r then
    log.warn(string.format("HTTP %s %s failed: %s", method, url, tostring(status_code)))
    return nil, status_code
  end

  local body_str = table.concat(resp_body)
  log.trace(string.format("HTTP %s %s → %d (%d bytes)", method, url, status_code, #body_str))
  return body_str, status_code
end
```

### Safe JSON Parsing

```lua
local json = require "dkjson"

local function parse_json(body_str)
  local ok, parsed = pcall(json.decode, body_str)
  if ok and parsed then
    return parsed
  end
  log.warn("JSON parse error: " .. (body_str and body_str:sub(1, 100) or "nil"))
  return nil
end
```

### HTTP 401 Handling

```lua
local body, status_code = http_request(url, "GET", headers)
if status_code == 401 then
  log.warn_with({ hub_logs = true }, "Auth failed — check credentials")
  return nil
end
```

## Basic Auth (Pure Lua, No External Dependencies)

```lua
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
  local bytes = {string.byte(data, 1, #data)}
  local result = {}
  for i = 1, #bytes, 3 do
    local b1, b2, b3 = bytes[i], bytes[i+1], bytes[i+2]
    local a1 = math.floor(b1 / 4)
    local a2 = (b1 % 4) * 16 + math.floor((b2 or 0) / 16)
    local a3
    if b2 then a3 = (b2 % 16) * 4 + math.floor((b3 or 0) / 64)
    else a3 = 64 end
    local a4
    if b3 then a4 = b3 % 64
    else a4 = 64 end
    table.insert(result, b64chars:sub(a1+1, a1+1))
    table.insert(result, b64chars:sub(a2+1, a2+1))
    table.insert(result, (a3 ~= 64 and b64chars:sub(a3+1, a3+1)) or "=")
    table.insert(result, (a4 ~= 64 and b64chars:sub(a4+1, a4+1)) or "=")
  end
  return table.concat(result)
end

-- Usage:
local auth = base64_encode(username .. ":" .. password)
local headers = {
  ["Authorization"] = "Basic " .. auth,
  ["Accept"] = "application/json",
}
```

## Complete Polling Pattern

```lua
local function poll_device(driver, device)
  local ip = device:get_field("host_ip")
  local port = device:get_field("port") or 80
  if not ip then
    log.warn("No IP configured for " .. device.label)
    return
  end

  local body, status = http_request(
    string.format("http://%s:%s/api/status", ip, port),
    "GET"
  )
  if not body then
    if status == 401 then
      log.warn_with({ hub_logs = true }, "Auth failed for " .. device.label)
    end
    device:offline()
    return
  end

  local data = parse_json(body)
  if not data then return end

  -- Update device state based on data
  device:online()
  -- emit events...
end

-- In device_init or device_added:
device.thread:call_on_schedule(30, function()
  poll_device(driver, device)
end, device.id .. "-poll")
```

## IP Change Detection During Discovery

When a device changes IP (common with DHCP), update the persisted field:

```lua
-- In discovery handler or a periodic check:
device:set_field("host_ip", discovered_info.ip, {persist = true})
```

## Error Handling in Polling

Wrap polling in pcall to prevent crashes from killing the driver:

```lua
device.thread:call_on_schedule(30, function()
  local ok, err = pcall(poll_device, driver, device)
  if not ok then
    device.log.error_with({ hub_logs = true }, "Poll crashed: " .. tostring(err))
  end
end, device.id .. "-poll")
```
