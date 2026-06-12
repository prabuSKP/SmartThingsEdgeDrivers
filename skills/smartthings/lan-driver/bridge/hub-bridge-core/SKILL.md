---
name: hub-bridge-core
description: >
  Build the bridge/gateway architecture for SmartThings Edge drivers that integrate
  3rd-party hubs (Fibaro, Home Assistant, Hubitat, OpenHAB, etc.). Covers bridge
  device creation, child device linking via parent_device_id, bootstrap validation
  (loginStatus → settings/info → adapter selection), API client construction with
  Basic Auth and TLS, bridge endpoint configuration from preferences and persisted
  fields, and the adapter pattern for multi-controller-family support.
  Use when building a driver that represents a 3rd-party hub as a bridge device
  with multiple child devices in SmartThings.
---

# Hub Bridge Core Architecture

The bridge pattern is the primary architecture for integrating 3rd-party smart home hubs
into SmartThings via Edge drivers. One bridge device represents the hub, and child devices
represent the individual devices managed by that hub.

## Architecture Overview

```
SmartThings App
    ↓
SmartThings Cloud
    ↓
SmartThings Hub (runs Edge Driver)
    ↓ LAN HTTP/HTTPS
3rd-Party Hub (Fibaro HC2/HC3, Home Assistant, etc.)
    ↓
Physical Devices (switches, sensors, blinds, etc.)
```

### Device Hierarchy in SmartThings

```
Bridge Device (type = "LAN")
├── Child Device 1 (type = "EDGE_CHILD", profile = "switch")
├── Child Device 2 (type = "EDGE_CHILD", profile = "dimmer")
├── Child Device 3 (type = "EDGE_CHILD", profile = "contact-sensor")
└── ...
```

## Bridge Profile

The bridge device profile defines what the hub itself exposes in the SmartThings app.
At minimum it needs `refresh` capability and bridge-level preferences for connection config.

```yaml
# profiles/my-bridge.yml
name: my-bridge
components:
  - id: main
    capabilities:
      - id: refresh
        version: 1
    categories:
      - name: Bridge
preferences:
  - title: "Hub Host/IP"
    name: "host"
    description: "IP address or hostname of the hub"
    required: false
    preferenceType: "string"
    definition:
      stringType: "text"
      default: ""
  - title: "Port"
    name: "port"
    description: "HTTP port (default: 80)"
    required: false
    preferenceType: "integer"
    definition:
      default: 80
      minimum: 1
      maximum: 65535
  - title: "Username"
    name: "username"
    description: "Hub login username"
    required: false
    preferenceType: "string"
    definition:
      stringType: "text"
      default: ""
  - title: "Password"
    name: "password"
    description: "Hub login password"
    required: false
    preferenceType: "string"
    definition:
      stringType: "password"
      default: ""
  - title: "Protocol"
    name: "scheme"
    description: "Connection protocol. Auto-detect uses the value found via mDNS. Many HTTPS hubs (e.g. Fibaro HC3) are detected automatically."
    required: false
    preferenceType: "enumeration"
    definition:
      options:
        auto: "Auto-detect (recommended)"
        http: "HTTP"
        https: "HTTPS"
      default: "auto"
  - title: "Poll Interval (seconds)"
    name: "pollInterval"
    description: "How often to poll for device state changes"
    required: false
    preferenceType: "integer"
    definition:
      default: 30
      minimum: 10
      maximum: 300
```

## Driver Manifest

```yaml
# config.yml
name: 'My Hub Bridge'
packageKey: 'my-hub-bridge'
permissions:
  lan: {}
  discovery: {}
description: "SmartThings Edge driver for My Hub via Local API"
vendorSupportInformation: "https://example.com/support"
```

**Permissions required:**
- `lan: {}` — LAN HTTP/HTTPS access to the hub
- `discovery: {}` — mDNS/SSDP scanning for hub auto-discovery

## Bootstrap Flow

Before inventory sync, validate the hub is reachable and identify its type:

```lua
local function bootstrap_bridge(bridge)
  -- Step 1: Create API client (may use anonymous auth for bootstrap)
  local api, err = api_for_bridge(bridge, { allow_anonymous = true })
  if api == nil then return nil, err end

  -- Step 2: Validate hub is reachable (e.g., GET /api/loginStatus)
  local _, login_err, login_status = api:get_login_status()
  if login_err ~= nil or (login_status ~= 200 and login_status ~= 401 and login_status ~= 403) then
    api:shutdown()
    return nil, login_err or ("unexpected status " .. tostring(login_status))
  end

  -- Step 3: Get hub identity info (e.g., GET /api/settings/info)
  local info, info_err, info_status = api:get_settings_info()
  api:shutdown()
  if info_err ~= nil or info_status ~= 200 then
    return nil, info_err or ("unexpected status " .. tostring(info_status))
  end

  -- Step 4: Select adapter based on hub type
  local adapter = select_adapter(bridge, info)
  return { info = info, adapter = adapter }, nil
end
```

## Bridge Endpoint Configuration

The bridge endpoint (host, port, scheme) can come from multiple sources with a priority cascade.

> **⚠️ Non-empty default trap (mDNS-detected scheme/port silently ignored).** If the scheme
> preference has default `"http"` (non-empty), the guard `if not scheme or scheme == ""` is
> always `false`, so `bridge:get_field("bridge_scheme")` (set to `"https"` by mDNS for port-443
> hubs) is NEVER reached. The driver always connects via `http:80` even when the hub requires
> `https:443`. Same problem for port: default `80` makes `tonumber(prefs.port)` always truthy
> so the mDNS-detected `BRIDGE_PORT` field is never used.
>
> **Fix:** use `"auto"` as the scheme default so the code can distinguish "user hasn't chosen yet"
> from "user explicitly chose http". For port, treat `80` as "not explicitly overridden" and
> let the mDNS-detected field take priority.
>
> **Historical note:** the old `== ""` empty-string guard is still needed for `host` (whose
> default really is `""`), but is insufficient alone for scheme/port whose defaults are non-empty.

```lua
local function get_bridge_endpoint_config(bridge)
  local prefs = bridge.preferences or {}

  -- host: profile default is "" so empty means "not configured yet"
  local host = prefs.host
  if not host or host == "" then host = bridge:get_field("bridge_host") end
  if not host or host == "" then return nil, "bridge host unavailable" end

  -- scheme: profile default is "auto". Explicit "http"/"https" overrides the
  -- mDNS-detected field; "auto" (or anything else) falls through to the field.
  local pref_scheme = prefs.scheme or "auto"
  local field_scheme = bridge:get_field("bridge_scheme") or ""
  local scheme
  if pref_scheme == "https" or pref_scheme == "http" then
    scheme = pref_scheme   -- explicit user choice
  elseif field_scheme ~= "" then
    scheme = field_scheme  -- use mDNS-detected value (e.g. "https" for HC3)
  else
    scheme = "http"        -- safe fallback before any discovery has run
  end

  -- port: profile default 80. Only override the mDNS-detected field when the
  -- user has explicitly changed the port away from the default (80).
  local field_port = tonumber(bridge:get_field("bridge_port"))
  local pref_port  = tonumber(prefs.port)
  local port
  if pref_port ~= nil and pref_port ~= 80 then
    port = pref_port   -- explicit non-default user choice
  elseif field_port ~= nil then
    port = field_port  -- use mDNS-detected value (e.g. 443)
  else
    port = (scheme == "https") and 443 or 80
  end

  return { scheme = scheme, host = host, port = port }, nil
end
```

## API Client Construction

Do not assume `cosock.http` exists in the target hub runtime. For REST APIs,
prefer a packaged client that uses `cosock.socket` / `cosock.ssl`. If generated
code requires `lunchbox.rest`, the driver package must include
`src/lunchbox/rest.lua` and `src/lunchbox/util.lua`; otherwise the driver will
crash during `require`.

```lua
local base64 = require "st.base64"
local json = require "st.json"
local RestClient = require "lunchbox.rest"

local function api_new(config, label)
  local headers = {
    ["Accept"] = "application/json",
    ["Content-Type"] = "application/json",
  }

  -- Add Basic Auth if credentials provided
  if (config.username or "") ~= "" then
    headers["Authorization"] = "Basic " ..
      base64.encode(config.username .. ":" .. (config.password or ""))
  end

  -- Build SSL context for HTTPS
  local ssl_params = nil
  if config.scheme == "https" then
    ssl_params = {
      mode = "client",
      protocol = "any",
      verify = "none",      -- Required for self-signed local certs
      options = "all",
    }
  end

  local socket_builder = labeled_socket_builder(label, ssl_params)
  local base_url = string.format("%s://%s:%d", config.scheme, config.host, config.port)

  return {
    client = RestClient.new(base_url, socket_builder),
    headers = headers,
  }
end
```

> **`ApiClient.new` / `api_new` must NOT be wrapped in `pcall`.** It is a pure Lua
> constructor (no network I/O) that never throws. Only wrap actual network calls in `pcall`.
> The `pcall` return signature is `(ok_bool, result_or_error)` — NOT `(result, error)`.
> Confusing the two produces a fatal silent bug: the guard `if result == nil or error ~= nil`
> is always true (the ApiClient object is the "error" arg) so every request fails at startup.
> WRONG → CORRECT:
> ```lua
> -- WRONG (confuses pcall return order):
> local api, api_err = pcall(ApiClient.new, config)
> if api == nil or api_err ~= nil then ...  -- api_err is the ApiClient; always non-nil
>
> -- CORRECT (call constructor directly; wrap network ops not constructors):
> local api = ApiClient.new(config)
> ```

## `src/lunchbox/rest.lua` — use `luncheon` for HTTP building

When bundling `src/lunchbox/rest.lua`, build HTTP requests via `luncheon.request` and
`luncheon.response` (system SDK modules), **not** by concatenating raw HTTP strings.
Raw string building is error-prone. Note that the `socket_builder` passed to `RestClient.new`
MUST connect and return a fully established TCP/SSL socket (i.e. `sock:connect(host, port)`).
To parse responses containing chunked payloads (`Transfer-Encoding: chunked`) or arbitrary body bounds without crashing the system luncheon library, use manual chunked parsing.

```lua
-- src/lunchbox/rest.lua — correct pattern
local socket = require "cosock.socket"
local Request = require "luncheon.request"
local Response = require "luncheon.response"
local log = require "log"

local lb_utils = require "lunchbox.util"

local RestClient = {}
RestClient.__index = RestClient

local function copy_response_headers(source, target)
  for header in source.headers:iter() do
    target.headers:append_chunk(header)
  end
end

local function empty_body_response(original_response)
  local full_response = Response.new(original_response.status, nil)
  copy_response_headers(original_response, full_response)
  full_response._received_body = true
  full_response._parsed_headers = true
  log.info_with({hub_logs = true}, string.format(
    "[RestClient] HTTP response has no body framing, treating status %s as empty body",
    tostring(original_response.status)
  ))
  return full_response
end

local function connect(client)
  local use_ssl = client.base_url.scheme == "https"
  -- Note: socket_builder must be a connected socket builder taking (host, port, use_ssl)
  local sock, err = client.socket_builder(client.base_url.host, client.base_url.port, use_ssl)
  if sock == nil then
    client.socket = nil
    return false, err
  end

  client.socket = sock
  return true, nil
end

local function reconnect(client)
  if client.socket ~= nil then
    client.socket:close()
    client.socket = nil
  end

  return connect(client)
end

local function send_request(client, request)
  if client.socket == nil then
    return nil, "no socket available"
  end

  local payload = request:serialize()
  local bytes, err, idx = nil, nil, 0
  repeat
    bytes, err, idx = client.socket:send(payload, idx + 1, #payload)
  until (bytes == #payload) or (err ~= nil)

  return bytes, err
end

local function recv_additional_response(original_response, sock)
  local full_response = Response.new(original_response.status, nil)
  local headers = original_response:get_headers()
  local content_length = tonumber(headers:get_one("Content-Length") or "0")

  copy_response_headers(original_response, full_response)

  if content_length <= 0 then
    full_response._received_body = true
    full_response._parsed_headers = true
    log.info_with({hub_logs = true}, string.format(
      "[RestClient] HTTP response has Content-Length 0, treating status %s as empty body",
      tostring(original_response.status)
    ))
    return full_response
  end

  local total = 0
  repeat
    local next_recv, next_err, partial = sock:receive(content_length - total)

    if next_recv ~= nil and #next_recv >= 1 then
      total = total + #next_recv
      full_response:append_body(next_recv)
    end

    if partial ~= nil and #partial >= 1 then
      total = total + #partial
      full_response:append_body(partial)
    end

    if next_err ~= nil and next_err ~= "closed" then
      return nil, next_err
    end
  until total >= content_length

  full_response._received_body = true
  full_response._parsed_headers = true
  return full_response
end

local function parse_chunked_response(original_response, sock)
  local full_response = Response.new(original_response.status, nil)
  copy_response_headers(original_response, full_response)

  -- Read the first chunk size line directly from the socket.
  -- Do NOT call original_response:get_body() here because that triggers
  -- luncheon's internal chunked body parser which uses self._source(pattern),
  -- but our source function (created in handle_response) only supports
  -- line-by-line reading via sock:receive("*l") and ignores byte-count
  -- arguments, causing tonumber(nil, 16) crash on real devices.
  local chunk_size_line, line_err = sock:receive("*l")
  if not chunk_size_line then
    return nil, "failed to read chunk size: " .. tostring(line_err)
  end

  local next_chunk_bytes = tonumber(chunk_size_line, 16)
  local next_chunk_body = ""
  local bytes_read = 0
  local expecting_body = true

  repeat
    local pattern = expecting_body and next_chunk_bytes or "*l"
    local next_recv, next_err, partial = sock:receive(pattern)

    if next_err ~= nil then
      if string.lower(next_err) == "closed" then
        if partial ~= nil and #partial >= 1 then
          full_response:append_body(partial)
          next_chunk_bytes = 0
        end
      else
        return nil, ("unexpected error reading chunked transfer: " .. next_err)
      end
    end

    if next_recv ~= nil and #next_recv >= 1 then
      if expecting_body then
        bytes_read = bytes_read + #next_recv
        next_chunk_body = next_chunk_body .. next_recv

        if bytes_read >= next_chunk_bytes then
          full_response:append_body(next_chunk_body)
          next_chunk_body = ""
          bytes_read = 0
          expecting_body = false
        end
      else
        next_chunk_bytes = tonumber(next_recv, 16)
        expecting_body = true
      end
    end
  until next_chunk_bytes == 0

  sock:receive("*l")
  full_response._received_body = true
  full_response._parsed_headers = true
  return full_response
end

local function handle_response(sock)
  local initial_recv, initial_err, partial = Response.source(function() return sock:receive("*l") end)
  if initial_recv == nil then
    return nil, initial_err, partial
  end

  local headers = initial_recv:get_headers()
  if headers:get_one("Content-Length") then
    return recv_additional_response(initial_recv, sock)
  end

  if tostring(headers:get_one("Transfer-Encoding") or ""):lower() == "chunked" then
    return parse_chunked_response(initial_recv, sock)
  end

  return empty_body_response(initial_recv), nil, nil
end

local function execute_request(client, request, retry_fn)
  if client.socket == nil then
    local success, err = connect(client)
    if not success then return nil, err end
  end

  local should_retry = retry_fn or function() return false end
  local backoff = function() return 0.5 end

  while true do
    local retry = should_retry()
    local _, send_err = send_request(client, request)
    if send_err == nil then
      local response, recv_err = handle_response(client.socket)
      if recv_err == nil then
        return response, nil
      end

      if not retry then
        return nil, recv_err
      end
    else
      if not retry then
        return nil, send_err
      end
    end

    local success, err = reconnect(client)
    if not success and not retry then
      return nil, err
    end

    socket.sleep(backoff())
  end
end

function RestClient.new(base_url, socket_builder)
  base_url = lb_utils.force_url_table(base_url)
  return setmetatable({
    base_url = base_url,
    socket_builder = socket_builder,
    socket = nil,
  }, RestClient)
end

function RestClient:shutdown()
  if self.socket ~= nil then
    self.socket:close()
    self.socket = nil
  end
end

function RestClient:get(path, additional_headers, retry_fn)
  local request = Request.new("GET", path, nil)
    :add_header("user-agent", "smartthings-lua-edge-driver")
    :add_header("host", tostring(self.base_url.host))
    :add_header("connection", "keep-alive")

  if type(additional_headers) == "table" then
    for k, v in pairs(additional_headers) do
      request = request:add_header(k, v)
    end
  end

  return execute_request(self, request, retry_fn)
end

function RestClient:post(path, body_string, additional_headers, retry_fn)
  local request = Request.new("POST", path, nil)
    :add_header("user-agent", "smartthings-lua-edge-driver")
    :add_header("host", tostring(self.base_url.host))
    :add_header("connection", "keep-alive")

  if type(additional_headers) == "table" then
    for k, v in pairs(additional_headers) do
      request = request:add_header(k, v)
    end
  end

  request = request:append_body(body_string or "")
  return execute_request(self, request, retry_fn)
end

function RestClient:put(path, body_string, additional_headers, retry_fn)
  local request = Request.new("PUT", path, nil)
    :add_header("user-agent", "smartthings-lua-edge-driver")
    :add_header("host", tostring(self.base_url.host))
    :add_header("connection", "keep-alive")

  if type(additional_headers) == "table" then
    for k, v in pairs(additional_headers) do
      request = request:add_header(k, v)
    end
  end

  request = request:append_body(body_string or "")
  return execute_request(self, request, retry_fn)
end

return RestClient
```

Key: `self.base_url` is a parsed URL table (via `lb_utils.force_url_table`), so
`self.base_url.host` is the actual hostname string — never the scheme. The response is
parsed by `handle_response` which robustly routes to custom chunked, Content-Length bounded, or empty body read helpers.

## Adapter Pattern (Multi-Controller Support)

When a hub has multiple firmware versions or controller families (e.g., Fibaro HC2 vs HC3),
use an adapter pattern to normalize API responses:

```lua
-- adapter.lua
local hc2 = require "vendor.adapters.hc2"
local hc3 = require "vendor.adapters.hc3"

local adapter = {}

function adapter.for_info(info, scheme)
  local platform = tostring(info.platform or ""):lower()
  if platform:find("hc3") or platform:find("yubii") then
    return hc3
  end
  return hc2
end

function adapter.for_name(name)
  if name == "hc3" then return hc3 end
  return hc2
end

return adapter
```

Each adapter implements a standard interface:

```lua
-- adapters/hc2.lua
local hc2 = {}
hc2.NAME = "hc2"

function hc2.normalize_device(raw)
  return {
    id = raw.id,
    label = raw.name,
    type = raw.type,
    base_type = raw.baseType,
    value = raw.properties and raw.properties.value,
    dead = raw.properties and raw.properties.dead,
    actions = raw.actions or {},
    interfaces = raw.interfaces or {},
    device_role = raw.properties and raw.properties.deviceRole,
    parent_id = raw.parentId or 0,
    room_id = raw.roomID or 0,
    enabled = raw.enabled ~= false,
    -- ... normalize all fields
  }
end

function hc2.normalize_device_list(payload)
  if type(payload) ~= "table" then return {} end
  return payload  -- HC2 returns flat array
end

function hc2.build_action_body(args)
  return { args = args or {} }
end

return hc2
```

## Persisted Field Constants

Use a `fields.lua` module to centralize all persisted field names:

```lua
-- fields.lua
local fields = {}

-- Bridge identity fields
fields.BRIDGE_SCHEME = "bridge_scheme"
fields.BRIDGE_HOST = "bridge_host"
fields.BRIDGE_PORT = "bridge_port"
fields.PLATFORM = "platform"
fields.SERIAL_NUMBER = "serial_number"
fields.API_VERSION = "api_version"
fields.CONTROLLER_KIND = "controller_kind"
fields.LAST_REFRESH_STATES = "last_refresh_states"

-- Child device fields
fields.PARENT_BRIDGE_DNI = "parent_bridge_dni"
fields.HC2_DEVICE_ID = "hc2_device_id"
fields.HC2_DEVICE_TYPE = "hc2_device_type"
fields.HC2_DEVICE_KIND = "hc2_device_kind"
fields.HC2_ROOM_ID = "hc2_room_id"
fields.HC2_ROOM_NAME = "hc2_room_name"

return fields
```

## Bridge Health Management

```lua
-- Bridge goes online when API responds successfully
bridge:online()

-- Bridge goes offline when API fails
bridge:offline()

-- Child devices follow bridge health
if normalized_device.dead == true then
  child:offline()
else
  child:online()
end
```

## Key Design Principles

1. **Bootstrap before inventory** — always validate hub identity before syncing devices
2. **Preferences cascade** — for `host`: user pref > mDNS field > fail. For `scheme`/`port`: explicit non-default user pref > mDNS field > hard default. Never let a non-empty pref default (e.g. `"http"`, `80`) shadow an mDNS-detected field value.
3. **Adapter normalization** — never trust raw vendor API shapes; normalize first
4. **Field persistence** — all critical config survives hub restarts with `{persist = true}`
5. **Structured metadata** — encode room/label info in `vendor_provided_label` for downstream tools
6. **Graceful degradation** — if bootstrap fails, mark bridge offline and retry on next poll
