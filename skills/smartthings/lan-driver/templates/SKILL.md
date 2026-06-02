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
2. **Every Lua source file MUST live under `src/`** — including `src/handlers/`, `src/vendor/`, and `src/lunchbox/`. Lua module paths are rooted at `src/`: `require "handlers.commands"` → `src/handlers/commands.lua`; `require "vendor.sync"` → `src/vendor/sync.lua`. **Only `src/` is packaged**, so any `.lua` placed outside it (e.g. a top-level `handlers/commands.lua`) is silently dropped, its `require` fails during load, `init.lua` crashes, the driver never runs, and **no device — not even the bridge — appears when the user scans.** Never emit a `.lua` file outside `src/`. If `init.lua` requires `handlers.commands`, the file must be created at `src/handlers/commands.lua`, not `handlers/commands.lua`.
3. Use the current Edge driver constructor key `discovery = discovery.discover` or `discovery = discovery.start`. Do not use `discovery_handler` in newly generated drivers.
4. **One hub = exactly one bridge — visible during the scan.** Create the manual/fixed-IP placeholder **up front** at the start of `discover()` (idempotent, gated on `any_bridge_exists`) so the user always has a configurable bridge during the scan window — hubs like Fibaro HC2/HC3 never answer mDNS, so a placeholder deferred to after the loop means the hub *never appears*. Singleness comes from **reconciliation, not deferral**: every bridge create reconciles by DNI/serial/host (update the placeholder in place, never mint a second DNI), and the stale unconfigured stub is removed once a real hub is discovered. See `discovery/hub-discovery` → "Single-Bridge Reconciliation".
5. Every `profile = "..."` string used in Lua must match a `name:` in one file under `profiles/*.yml`.
6. Avoid broad SSDP terms such as `upnp:rootdevice` unless discovery validates manufacturer/model/TXT/description before creating a device.
7. Prefer `require "st.base64"` for Basic Auth unless the target runtime is known to provide a plain `base64` module.
8. Do not expose an `https` preference unless the generated API client actually implements TLS. If only raw TCP HTTP is implemented, generate HTTP-only preferences.
9. Pass capability handlers into the `Driver(...)` constructor as `capability_handlers = commands.capability_handlers`. Do not generate `driver:register_capability_handler(...)`; that method is not available in the Edge runtime.
10. Do not generate `require "cosock.http"` as the default REST client. Use packaged `lunchbox.rest` or raw `cosock.socket` / `cosock.ssl`; if `lunchbox.rest` is required, include `src/lunchbox/rest.lua` and `src/lunchbox/util.lua`.
11. Include a final validation checklist in the generated output: package with SmartThings CLI; **confirm no `.lua` exists outside `src/`** (`find . -name '*.lua' -not -path './src/*'` must return nothing); compare mapper/`profile=` names to profile YAML names; and confirm startup/discovery logs on the hub.
12. **Lua local-function ordering in `src/vendor/sync.lua`.** Define every `local function` helper **before** any `function sync.XXX` that calls it. Lua resolves names lexically at compile time: a public function defined before a `local function` compiles that name as a global lookup (`_ENV["name"]`), which is `nil` at runtime. The error is caught by the `pcall` wrapper in the lifecycle handler, so the driver stays alive but **sync fails silently — no child devices are ever created.** Fix: order helpers first, public functions last. Also, if a helper is exported as `sync.prime_cursor`, always call it as `sync.prime_cursor(...)` — a bare `prime_cursor(...)` is a different (global) lookup that also resolves to `nil`.
13. **Do not use variables before they are defined, and do not reference the driver variable before the `Driver(...)` constructor has completed.** A driver-level datastore cache like `driver.datastore.pending_bridge_data = {}` must be initialized *after* `local my_driver = Driver(...)` (e.g. using `my_driver.datastore...`). Accessing it before construction causes an instant nil index crash during startup.
14. **Do not use global variables across files (e.g. `_G.cosock = cosock`).** Handlers and sub-modules must import their dependencies locally (`local cosock = require "cosock"`) instead of relying on globals defined in `init.lua`.
15. **Use correct parent/child checks.** A device is a bridge if it has no parent assigned child key (`device.parent_assigned_child_key == nil`). Do not rely on `parent_device_id == nil` as it can behave inconsistently in the runtime. Ensure that preference schemas for host/IP address are marked `required: false` so that the bridge placeholder can be created during discovery without settings.
16. **Ensure `require "log"` is imported before any logs are printed.** `local log = require "log"` must be the absolute first executable line in `init.lua`, and no logging calls can be made before it.
17. **Always call `driver:run()` at the very end of `src/init.lua`.** The SmartThings Edge runtime requires the event loop to be started by calling `:run()` on the driver instance (e.g., `my_driver:run()`). Leaving this out causes the driver to immediately exit or do nothing upon loading, which prevents discovery and all handlers from executing.
18. **Scheme must never reach the URL builder empty — and beware the empty-string-is-truthy trap.** In Lua `""` is **truthy**, so `value or "http"` does NOT replace an empty string (only `nil`/`false`). When defaulting a possibly-empty config value (especially `scheme`), check `== ""` explicitly: `if not scheme or scheme == "" then scheme = "http" end`. An empty scheme makes the API client build `"://host:port"`, which the URL parser cannot match and silently rewrites the host to **`localhost`** — so every request hits the hub itself and the device "cannot connect." Also give the **bridge profile a `scheme` (http/https) preference** so the value is user-selectable and never empty; default it to `http`.
19. **Use idempotent, NON-persisted init.** Any "already initialized" guard in `device_init` must use `{ persist = false }` (session-only). `init` runs on every boot to (re)start poll timers; a persisted guard makes it return early after a hub reboot and **silently stops state sync**. Make timer setup idempotent (`cancel_timer` then `start_timer`) so re-running init is always safe.

---

## 1. Project Directory Structure

Ensure your project folder matches this layout:

```
my-bridge-driver/
├── src/                         # ← ALL .lua files live here, nowhere else
│   ├── init.lua                 # Main driver entrypoint
│   ├── discovery.lua            # SSDP/mDNS & Manual Discovery
│   ├── lifecycle.lua            # added/init/infoChanged/removed handlers
│   ├── fields.lua               # Datastore Field Constants
│   ├── utils.lua                # Helper utilities
│   ├── handlers/
│   │   └── commands.lua         # require "handlers.commands" → THIS path
│   ├── vendor/
│   │   ├── api.lua              # REST API Client      (require "vendor.api")
│   │   ├── adapter.lua          # Controller-family normalization
│   │   ├── mapper.lua           # Device → profile mapping
│   │   └── sync.lua             # State sync engine    (require "vendor.sync")
│   └── lunchbox/                # only if require "lunchbox.rest" is used
│       ├── rest.lua
│       └── util.lua
├── profiles/
│   ├── bridge.yml               # Parent device profile
│   └── switch.yml               # Child device profile (example)
├── config.yml                   # Driver packaging manifest
└── search-parameters.yml        # mDNS/SSDP search targets (optional)
```

**`handlers/`, `vendor/`, and `lunchbox/` are subdirectories of `src/`, not of the project
root.** A file at `./handlers/commands.lua` (sibling of `src/`) will not be packaged, and
`require "handlers.commands"` will fail at load — the driver will not start and nothing
appears on scan. This is a common and silent generation defect; check it explicitly.

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
  -- Bridge = no parent_assigned_child_key (Rule 15). Do NOT use parent_device_id == nil.
  if device.parent_assigned_child_key == nil then
    -- Parent Bridge
    device:set_field(fields.IS_BRIDGE, true, {persist = true})
  end
end

local function device_init(driver, device)
  device_log(device, "Initializing device")
  if device.parent_assigned_child_key == nil then
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
    if device.device_network_id == dni and device.parent_assigned_child_key == nil then
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
    if device.parent_assigned_child_key == nil then return true end
  end
  return false
end

-- A bridge we can talk to: an auto-discovered bridge, or the manual placeholder once the
-- user has entered a host. A bare placeholder does not count, so the scan keeps looking.
local function usable_bridge_exists(driver)
  for _, device in ipairs(driver:get_devices()) do
    if device.parent_assigned_child_key == nil then
      if device.device_network_id ~= MANUAL_BRIDGE_DNI then return true end
      local host = device:get_field("bridge_host")
        or (device.preferences and device.preferences.host)
      if host ~= nil and host ~= "" then return true end
    end
  end
  return false
end

-- Once a real hub is discovered/configured, delete the leftover unconfigured manual
-- placeholder so the hub maps to exactly one device.
local function remove_stale_manual_placeholder(driver)
  local manual = driver:get_device_by_dni(MANUAL_BRIDGE_DNI)
  if manual == nil then return end
  local host = manual:get_field("bridge_host")
    or (manual.preferences and manual.preferences.host)
  if host ~= nil and host ~= "" then return end   -- user configured it → keep
  if type(driver.try_delete_device) == "function" then
    log.info_with({ hub_logs = true },
      "[Discovery] Removing stale manual placeholder; real bridge discovered")
    driver:try_delete_device(manual.id)
  end
end

function discovery.discover(driver, opts, should_continue)
  log.info_with({ hub_logs = true }, "[Discovery] Starting discovery")

  -- UP FRONT: create the manual/fixed-IP placeholder NOW (idempotent, gated on
  -- any_bridge_exists) so a configurable bridge is visible during the scan window —
  -- essential for hubs that never answer mDNS. Singleness comes from reconciliation
  -- below, NOT from deferring this. Deferring it hides the bridge when the scan is silent.
  if not any_bridge_exists(driver) then
    discovery.create_manual_bridge(driver)
  end

  while should_continue() do
    -- Add mDNS/SSDP scans here. Validate each result, then reconcile by DNI/serial/host
    -- (update the existing placeholder in place, else create exactly one). For example:
    --   discovery.do_mdns_scan(driver)

    if usable_bridge_exists(driver) then
      -- Real/configured bridge exists → drop the stale unconfigured stub, then stop.
      remove_stale_manual_placeholder(driver)
      break
    end
    socket.sleep(5)
  end

  log.info_with({ hub_logs = true }, "[Discovery] Ending discovery")
end

return discovery
```

> **Single-bridge rule:** the manual placeholder and any auto-discovered bridge must
> resolve to **one** device. Create the manual placeholder **up front** (idempotent, gated
> on `any_bridge_exists`) so it is visible during the scan, and make the scan's create path
> **reconcile by DNI/serial/host** (update the placeholder in place, never mint a second
> DNI), then remove the stale unconfigured stub once a real bridge exists. Singleness comes
> from reconciliation, **not** from deferring the placeholder to after the loop — deferral
> hides the bridge whenever the hub does not answer mDNS. Full reference handler:
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

> **pcall MUST NOT wrap `ApiClient.new`.** Constructors are pure Lua — no network I/O, never
> throw. `pcall` returns `(ok_bool, result_or_error)`, not `(result, error)`. Wrapping a
> constructor in pcall and then checking `if result == nil or error ~= nil` is always true
> (the constructed object is the "error" argument), silently breaking all API calls. Call
> `ApiClient.new(config)` directly. Reserve `pcall` for actual network calls (`:get`, `:post`).
>
> **`src/lunchbox/rest.lua` must use `luncheon.request` / `luncheon.response`** — never build
> HTTP request strings by string concatenation. Raw string building causes the Host: header to
> contain the URL scheme (`"http"`) rather than the hostname, because `_parse_url()` returns
> `(scheme, host, port)` but string concatenation silently takes only the first return value.
> Use `Request.new("GET", path, nil):add_header("host", tostring(self.base_url.host))` with
> `self.base_url` parsed by `lb_utils.force_url_table(base_url)`. See
> `bridge/hub-bridge-core` → "src/lunchbox/rest.lua — use luncheon for HTTP building" for the
> full canonical implementation.

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
    required: false
    preferenceType: string
    definition:
      stringType: text
      default: "192.168.1.100"
  - name: port
    title: "Port Number"
    description: "REST API Port Number"
    required: false
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
