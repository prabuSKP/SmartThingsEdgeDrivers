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
    required: true
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
    required: true
    preferenceType: "string"
    definition:
      stringType: "text"
      default: ""
  - title: "Password"
    name: "password"
    description: "Hub login password"
    required: true
    preferenceType: "string"
    definition:
      stringType: "password"
      default: ""
  - title: "Protocol"
    name: "scheme"
    description: "HTTP or HTTPS"
    required: false
    preferenceType: "enumeration"
    definition:
      options:
        http: "HTTP"
        https: "HTTPS"
      default: "http"
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

The bridge endpoint (host, port, scheme) can come from multiple sources with a priority cascade:

```lua
local function get_bridge_endpoint_config(bridge)
  local prefs = bridge.preferences or {}

  -- Priority: user preference override > auto-detected field > default
  local scheme = normalize_scheme(
    get_pref_override(prefs.scheme)
    or bridge:get_field("bridge_scheme")
  )

  local host = trim(
    get_pref_override(prefs.host)
    or bridge:get_field("bridge_host")
    or ""
  )

  local port = tonumber(
    get_pref_override(prefs.port))
    or tonumber(bridge:get_field("bridge_port"))
    or (scheme == "https" and 443 or 80)

  if host == "" then
    return nil, "bridge host unavailable"
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
Raw string building is error-prone: the most common mistake is setting the `Host:` header
to the URL scheme (`"http"`) instead of the hostname, because `_parse_url()` returns
multiple values and string concatenation silently truncates to the first.

```lua
-- src/lunchbox/rest.lua — correct pattern
local socket  = require "cosock.socket"
local Request = require "luncheon.request"    -- SmartThings system SDK module
local Response = require "luncheon.response"  -- SmartThings system SDK module
local lb_utils = require "lunchbox.util"      -- provides force_url_table

local RestClient = {}
RestClient.__index = RestClient

function RestClient.new(base_url, socket_builder)
  base_url = lb_utils.force_url_table(base_url)  -- parses scheme/host/port into table
  return setmetatable({ base_url = base_url, socket_builder = socket_builder, socket = nil }, RestClient)
end

function RestClient:get(path, additional_headers, retry_fn)
  -- Request.new + :add_header sets Host correctly from self.base_url.host (NOT scheme)
  local request = Request.new("GET", path, nil)
    :add_header("host", tostring(self.base_url.host))
    :add_header("connection", "keep-alive")
  for k, v in pairs(additional_headers or {}) do
    request = request:add_header(k, v)
  end
  return execute_request(self, request, retry_fn)
end

function RestClient:post(path, body_string, additional_headers, retry_fn)
  local request = Request.new("POST", path, nil)
    :add_header("host", tostring(self.base_url.host))
    :add_header("connection", "keep-alive")
  for k, v in pairs(additional_headers or {}) do
    request = request:add_header(k, v)
  end
  request = request:append_body(body_string or "")
  return execute_request(self, request, retry_fn)
end
```

Key: `self.base_url` is a parsed URL table (via `lb_utils.force_url_table`), so
`self.base_url.host` is the actual hostname string — never the scheme. The response is
parsed by `Response.source(function() return sock:receive("*l") end)` which handles
chunked transfer encoding, Content-Length, and empty bodies correctly.

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
2. **Preferences cascade** — user overrides > auto-detected > defaults
3. **Adapter normalization** — never trust raw vendor API shapes; normalize first
4. **Field persistence** — all critical config survives hub restarts with `{persist = true}`
5. **Structured metadata** — encode room/label info in `vendor_provided_label` for downstream tools
6. **Graceful degradation** — if bootstrap fails, mark bridge offline and retry on next poll
