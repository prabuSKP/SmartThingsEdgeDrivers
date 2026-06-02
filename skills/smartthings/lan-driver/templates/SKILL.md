---
name: templates
description: >
  Provide production-ready boilerplate skeletons for SmartThings Edge LAN drivers.
  Contains complete code templates for a LAN bridge driver structure, including init.lua,
  discovery.lua, profiles, and API clients. Use when starting a new LAN/bridge driver
  project or scaffolding standard component files.
---

# SmartThings Edge LAN Driver Skeletons

This skill contains standard, production-ready boilerplates for building SmartThings Edge LAN drivers. Use these templates to quickly scaffold your driver and ensure it follows cooperative multitasking (`cosock`) and parent-child architecture best practices.

---

## 0. Mandatory Generation Rules

Generated LAN bridge drivers must satisfy these rules before they are considered usable:

1. Put a startup log at the very top of `src/init.lua`, immediately after `local log = require "log"` and before vendor/API imports. This makes hub logs prove whether `init.lua` started or failed during `require(...)`.
2. Use the current Edge driver constructor key `discovery = discovery.discover` or `discovery = discovery.start`. Do not use `discovery_handler` in newly generated drivers.
3. **One hub = exactly one bridge.** Do NOT create a manual/fixed-IP placeholder unconditionally before the scan loop while auto-discovery (mDNS/SSDP) also creates a bridge — that makes the same hub appear twice in the app ("one for mDNS, one for fixed IP"). Run auto-discovery first; create the manual placeholder only as a *fallback after the loop* when nothing was discovered; and reconcile every bridge create by DNI/serial/host so all sources converge on one device. See `discovery/hub-discovery` → "Single-Bridge Reconciliation".
4. Every `profile = "..."` string used in Lua must match a `name:` in one file under `profiles/*.yml`.
5. Avoid broad SSDP terms such as `upnp:rootdevice` unless discovery validates manufacturer/model/TXT/description before creating a device.
6. Prefer `require "st.base64"` for Basic Auth unless the target runtime is known to provide a plain `base64` module.
7. Do not expose an `https` preference unless the generated API client actually implements TLS. If only raw TCP HTTP is implemented, generate HTTP-only preferences.
8. Pass capability handlers into the `Driver(...)` constructor as `capability_handlers = commands.capability_handlers`. Do not generate `driver:register_capability_handler(...)`; that method is not available in the Edge runtime.
9. Do not generate `require "cosock.http"` as the default REST client. Use packaged `lunchbox.rest` or raw `cosock.socket` / `cosock.ssl`; if `lunchbox.rest` is required, include `src/lunchbox/rest.lua` and `src/lunchbox/util.lua`.
10. Include a final validation checklist in the generated output: package with SmartThings CLI, compare mapper profile names to profile YAML names, and confirm startup/discovery logs on the hub.

---

## 1. Project Directory Structure

Ensure your project folder matches this layout:

```
my-bridge-driver/
├── src/
│   ├── init.lua                 # Main driver entrypoint
│   ├── discovery.lua            # SSDP/mDNS & Manual Discovery
│   ├── fields.lua               # Datastore Field Constants
│   ├── utils.lua                # Helper utilities
│   └── vendor/
│       ├── api.lua              # REST API Client
│       └── mapper.lua           # Device normalization
├── profiles/
│   ├── bridge.yml               # Parent device profile
│   └── switch.yml               # Child device profile (example)
├── config.yml                   # Driver packaging manifest
└── search-parameters.yml        # mDNS/SSDP search targets (optional)
```

---

## 2. Core Skeletons

### A. Main Entrypoint: `src/init.lua`
This skeleton manages the lifecycle events, registers capability commands, and boots up polling/event synchronization.

```lua
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"

log.info_with({ hub_logs = true }, "[Driver] Loading my bridge driver init.lua")

local cosock = require "cosock"
local socket = require "cosock.socket"

local discovery = require "discovery"
local fields = require "fields"
local ApiClient = require "vendor.api"
local mapper = require "vendor.mapper"
local commands = require "handlers.commands"

-- Log message helper
local function device_log(device, msg, ...)
  log.info(string.format("[%s] " .. msg, device.label, ...))
end

-- Polling helper wrapped in pcall
local function start_polling_loop(driver, device)
  if device:get_field(fields.POLLING_TIMER) ~= nil then
    return
  end

  local client = device:get_field(fields.API_CLIENT)
  if not client then return end

  device_log(device, "Starting periodic polling loop")
  local timer = driver:call_on_schedule(30, function()
    local success, err = pcall(function()
      local data, poll_err = client:get_devices_status()
      if data then
        mapper.sync_states(driver, device, data)
      else
        device_log(device, "Poll failed: %s", tostring(poll_err))
      end
    end)
    if not success then
      log.error("Polling loop exception: ", err)
    end
  end)
  device:set_field(fields.POLLING_TIMER, timer)
end

-- Lifecycle Handlers
local function device_added(driver, device)
  device_log(device, "Added to SmartThings")
  if device.parent_device_id == nil then
    -- Parent Bridge
    device:set_field(fields.IS_BRIDGE, true, {persist = true})
  end
end

local function device_init(driver, device)
  device_log(device, "Initializing device")
  if device.parent_device_id == nil then
    -- Rebuild the API client
    local ip = device.preferences.ipAddress or ""
    local port = device.preferences.port or 80
    local client = ApiClient.new(ip, port)
    device:set_field(fields.API_CLIENT, client)

    -- Start polling loop
    start_polling_loop(driver, device)
  else
    -- Child device registration/init logic
    device_log(device, "Child device init")
  end
end

local function device_removed(driver, device)
  device_log(device, "Removed from SmartThings")
  local timer = device:get_field(fields.POLLING_TIMER)
  if timer then
    device.thread:cancel_timer(timer)
    device:set_field(fields.POLLING_TIMER, nil)
  end
  device:set_field(fields.API_CLIENT, nil)
end

local function device_info_changed(driver, device, event, args)
  device_log(device, "Info changed / preferences updated")
  local old_ip = args.old_st_store.preferences.ipAddress
  local new_ip = device.preferences.ipAddress
  
  if old_ip ~= new_ip then
    device_log(device, "IP changed from %s to %s. Restarting connections.", tostring(old_ip), tostring(new_ip))
    device_removed(driver, device)
    device_init(driver, device)
  end
end

-- Capability Command Handlers
local function handle_switch_on(driver, device, command)
  device_log(device, "Command switch ON received")
  local parent = driver:get_device_info(device.parent_device_id)
  local client = parent:get_field(fields.API_CLIENT)
  if client then
    cosock.spawn(function()
      local child_id = device.device_network_id
      local success, err = client:set_device_state(child_id, "on")
      if success then
        device:emit_event(capabilities.switch.switch.on())
      else
        log.error("Failed to send switch ON: ", err)
      end
    end, "switch_on_command")
  end
end

local function handle_switch_off(driver, device, command)
  device_log(device, "Command switch OFF received")
  local parent = driver:get_device_info(device.parent_device_id)
  local client = parent:get_field(fields.API_CLIENT)
  if client then
    cosock.spawn(function()
      local child_id = device.device_network_id
      local success, err = client:set_device_state(child_id, "off")
      if success then
        device:emit_event(capabilities.switch.switch.off())
      else
        log.error("Failed to send switch OFF: ", err)
      end
    end, "switch_off_command")
  end
end

-- Driver declaration
local my_driver = Driver("my_bridge_driver", {
  discovery = discovery.discover,
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    removed = device_removed,
    infoChanged = device_info_changed
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handle_switch_off
    }
  }
})

my_driver:run()
```

For modular drivers, put the command table in `handlers/commands.lua`:

```lua
local capabilities = require "st.capabilities"

local commands = {}

commands.capability_handlers = {
  [capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME] = commands.switch_on,
    [capabilities.switch.commands.off.NAME] = commands.switch_off,
  },
  [capabilities.refresh.ID] = {
    [capabilities.refresh.commands.refresh.NAME] = commands.refresh,
  },
}

return commands
```

Then reference it during construction:

```lua
local commands = require "handlers.commands"

local my_driver = Driver("my_bridge_driver", {
  discovery = discovery.discover,
  lifecycle_handlers = lifecycle.handlers,
  capability_handlers = commands.capability_handlers,
})
```

Do not call `driver:register_capability_handler(...)` after construction.

---

### B. Discovery Handler: `src/discovery.lua`
Handles finding the main vendor bridge via cooperative socket operations and initiating manual discovery loops.

```lua
local log = require "log"
local socket = require "cosock.socket"

local discovery = {}

local MANUAL_BRIDGE_DNI = "my-vendor-bridge-manual"

local function bridge_exists(driver, dni)
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == dni and device.parent_device_id == nil then
      return true
    end
  end
  return false
end

function discovery.create_manual_bridge(driver)
  if bridge_exists(driver, MANUAL_BRIDGE_DNI) then
    log.info("[Discovery] Manual bridge already exists")
    return
  end

  local create_device_msg = {
    type = "LAN",
    device_network_id = MANUAL_BRIDGE_DNI,
    label = "My Vendor Bridge (configure in settings)",
    profile = "my-vendor-bridge",
    manufacturer = "My Vendor",
    model = "SmartBridge v1",
    vendor_provided_label = MANUAL_BRIDGE_DNI
  }

  local ok, err = driver:try_create_device(create_device_msg)
  if ok then
    log.info_with({ hub_logs = true }, "[Discovery] Manual bridge creation requested")
  else
    log.error_with({ hub_logs = true }, "[Discovery] Manual bridge creation failed: " .. tostring(err))
  end
end

local function any_bridge_exists(driver)
  for _, device in ipairs(driver:get_devices()) do
    if device.parent_device_id == nil then return true end
  end
  return false
end

-- A bridge we can talk to: an auto-discovered bridge, or the manual placeholder once the
-- user has entered a host. A bare placeholder does not count, so the scan keeps looking.
local function usable_bridge_exists(driver)
  for _, device in ipairs(driver:get_devices()) do
    if device.parent_device_id == nil then
      if device.device_network_id ~= MANUAL_BRIDGE_DNI then return true end
      local host = device:get_field("bridge_host")
        or (device.preferences and device.preferences.host)
      if host ~= nil and host ~= "" then return true end
    end
  end
  return false
end

function discovery.discover(driver, opts, should_continue)
  log.info_with({ hub_logs = true }, "[Discovery] Starting discovery")

  -- Auto-discovery FIRST. Do NOT create the manual placeholder here — creating it
  -- unconditionally while a scan also creates a bridge is what makes a hub appear twice.
  while should_continue() do
    -- Add mDNS/SSDP scans here. Validate each result, then reconcile by DNI/serial/host
    -- (update an existing bridge in place, else create exactly one). For example:
    --   discovery.do_mdns_scan(driver)

    if usable_bridge_exists(driver) then
      break
    end
    socket.sleep(5)
  end

  -- Fallback only: nothing discovered → create the manual/fixed-IP placeholder so the
  -- user can still enter an IP. Keeping this out of the loop and gated on "no bridge
  -- exists" is what guarantees a single bridge device per hub.
  if not any_bridge_exists(driver) then
    discovery.create_manual_bridge(driver)
  end

  log.info_with({ hub_logs = true }, "[Discovery] Ending discovery")
end

return discovery
```

> **Single-bridge rule:** the manual placeholder and any auto-discovered bridge must
> resolve to **one** device. Generate the manual placeholder as a post-loop fallback (as
> above), and make the scan's create path reconcile by DNI/serial/host. Never emit
> `discovery.create_manual_bridge(driver)` unconditionally before the loop alongside an
> mDNS/SSDP create — that is the classic "hub appears twice" bug. Full reference handler:
> `discovery/hub-discovery`.

---

### C. Persistent Fields: `src/fields.lua`
Define constants for driver datastore fields to avoid spelling mistakes across different modules.

```lua
return {
  IS_BRIDGE = "is_bridge",
  API_CLIENT = "api_client",
  POLLING_TIMER = "polling_timer",
  CHILD_DEVICES_MAP = "child_devices_map"
}
```

---

### D. REST API Client: `src/vendor/api.lua`
Generate a cooperative HTTP REST client using packaged code and `cosock.socket`.
Do not generate `require "cosock.http"` or `ltn12` for Edge LAN drivers unless the
target runtime and package explicitly provide those modules. A generated driver
that uses `lunchbox.rest` must also include `src/lunchbox/rest.lua` and
`src/lunchbox/util.lua` in the package.

```lua
local base64 = require "st.base64"
local json = require "st.json"
local log = require "log"

local RestClient = require "lunchbox.rest"
local utils = require "utils"

local ApiClient = {}
ApiClient.__index = ApiClient

local DEFAULT_HEADERS = {
  ["Accept"] = "application/json",
  ["Content-Type"] = "application/json",
}

local function copy_headers(source)
  local headers = {}
  for k, v in pairs(source) do
    headers[k] = v
  end
  return headers
end

local function build_base_url(config)
  local scheme = config.scheme or "http"
  local port = config.port or (scheme == "https" and 443 or 80)
  return string.format("%s://%s:%d", scheme, config.host, port)
end

function ApiClient.new(config, label)
  local headers = copy_headers(DEFAULT_HEADERS)
  if (config.username or "") ~= "" or (config.password or "") ~= "" then
    headers["Authorization"] =
      "Basic " .. base64.encode((config.username or "") .. ":" .. (config.password or ""))
  end

  local ssl_params = nil
  if config.scheme == "https" then
    ssl_params = {
      mode = "client",
      protocol = "any",
      verify = "none",
      options = "all",
    }
  end

  return setmetatable({
    client = RestClient.new(build_base_url(config), utils.labeled_socket_builder(label, ssl_params)),
    headers = headers,
  }, ApiClient)
end

local function process_response(response, err)
  if err ~= nil then return nil, err, nil end
  if response == nil then return nil, "no response", nil end

  local body = response:get_body() or ""
  if body == "" then return nil, nil, response.status end

  local ok, decoded = pcall(json.decode, body)
  if ok then return decoded, nil, response.status end
  return body, nil, response.status
end

function ApiClient:get(path)
  log.info_with({ hub_logs = true }, "GET " .. tostring(path))
  return process_response(self.client:get(path, self.headers))
end

function ApiClient:post(path, payload)
  log.info_with({ hub_logs = true }, "POST " .. tostring(path))
  return process_response(self.client:post(path, json.encode(payload or {}), self.headers))
end

function ApiClient:shutdown()
  if self.client then self.client:shutdown() end
end

return ApiClient
```

---

### E. Parent Bridge Profile: `profiles/bridge.yml`
Defines preferences and settings for the bridge, such as the IP Address input field in the SmartThings app.

```yaml
name: my-vendor-bridge
components:
  - id: main
    capabilities:
      - id: refresh
        version: 1
    categories:
      - name: Bridge
preferences:
  - name: ipAddress
    title: "Bridge IP Address"
    description: "IPv4 Address of the Vendor Bridge"
    required: true
    preferenceType: string
    definition:
      stringType: text
      default: "192.168.1.100"
  - name: port
    title: "Port Number"
    description: "REST API Port Number"
    required: true
    preferenceType: integer
    definition:
      minimum: 1
      maximum: 65535
      default: 80
```

The bridge profile `name:` must match the bridge creation metadata `profile` exactly. Child profile names must follow the same rule for every mapper return value.

---

## 3. Generated Driver Validation

Before handing off a generated driver, run or document these checks:

```bash
smartthings edge:drivers:package .
rg -n 'profile = "' src profiles
```

Then compare every Lua `profile = "..."` value to the `name:` values in `profiles/*.yml`. During hub testing, confirm the first hub log includes the top-level `[Driver] Loading ... init.lua` message and then a `[Discovery] Starting discovery` message when Add device scan runs.
