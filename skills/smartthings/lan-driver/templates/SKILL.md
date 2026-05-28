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
local cosock = require "cosock"
local socket = require "cosock.socket"

local discovery = require "discovery"
local fields = require "fields"
local ApiClient = require "vendor.api"
local mapper = require "vendor.mapper"

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
    driver:cancel_timer(timer)
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
  discovery_handler = discovery.handle_discovery,
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

---

### B. Discovery Handler: `src/discovery.lua`
Handles finding the main vendor bridge via cooperative socket operations and initiating manual discovery loops.

```lua
local log = require "log"
local cosock = require "cosock"
local socket = require "cosock.socket"

local discovery = {}

function discovery.handle_discovery(driver, opts, cons)
  log.info("Starting discovery scan...")
  
  -- Create Bridge device metadata
  local create_device_msg = {
    type = "LAN",
    device_network_id = "my-vendor-bridge-unique-id",
    label = "My Vendor Bridge",
    profile = "bridge",
    manufacturer = "My Vendor",
    model = "SmartBridge v1",
    vendor_provided_label = "My Vendor Bridge"
  }
  
  -- Trigger ST to create device
  assert(driver:try_create_device(create_device_msg))
  log.info("Bridge creation request submitted.")
end

return discovery
```

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
Cooperative HTTP REST client class utilizing `cosock`.

```lua
local socket = require "cosock.socket"
local http = require "cosock.http"
local json = require "st.json"
local log = require "log"

local ApiClient = {}
ApiClient.__index = ApiClient

function ApiClient.new(ip, port)
  local self = setmetatable({}, ApiClient)
  self.ip = ip
  self.port = port or 80
  self.base_url = string.format("http://%s:%d/api", ip, self.port)
  return self
end

function ApiClient:get_devices_status()
  local url = self.base_url .. "/devices"
  log.info("Requesting status from: " .. url)
  
  local response_body = {}
  local _, code, headers, status = http.request({
    url = url,
    method = "GET",
    headers = {
      ["Accept"] = "application/json"
    },
    sink = ltn12.sink.table(response_body)
  })

  if code == 200 then
    local body_str = table.concat(response_body)
    local data, err = json.decode(body_str)
    if not data then
      return nil, "JSON decode error: " .. tostring(err)
    end
    return data, nil
  else
    return nil, string.format("HTTP status: %s, code: %s", tostring(status), tostring(code))
  end
end

function ApiClient:set_device_state(device_id, state)
  local url = string.format("%s/devices/%s/control", self.base_url, device_id)
  local request_payload = json.encode({ status = state })
  
  local response_body = {}
  local _, code, headers, status = http.request({
    url = url,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#request_payload)
    },
    source = ltn12.source.string(request_payload),
    sink = ltn12.sink.table(response_body)
  })

  return code == 200, status
end

return ApiClient
```

---

### E. Parent Bridge Profile: `profiles/bridge.yml`
Defines preferences and settings for the bridge, such as the IP Address input field in the SmartThings app.

```yaml
name: bridge
components:
  - id: main
    capabilities:
      - id: refresh
      - id: switch
    categories:
      - name: Hub
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
