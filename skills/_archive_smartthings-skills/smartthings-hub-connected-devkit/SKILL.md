---
name: smartthings-hub-connected-devkit
description: Build SmartThings Edge drivers (Lua) for hub-connected devices — LAN/HTTP, Zigbee, Z-Wave, or custom protocol bridges. Covers driver project structure, Lua SDK API, device profiles, capability handlers, lifecycle handlers, discovery (mDNS/SSDP/manual), LAN HTTP communication patterns, polling, event emission, driver packaging, and CLI deployment to hubs. Use when the user needs to create, modify, or deploy a SmartThings Edge driver that runs on the hub, especially for bridging third-party devices or protocols. NOT for Cloud-to-Cloud (Schema) integrations — that is covered by the sibling smartthings-c2c-devkit skill.
---

# SmartThings Edge Drivers — Hub-Connected DevKit

Edge drivers are Lua programs that run **on the SmartThings hub**. They bridge devices not natively supported (Zigbee/Z-Wave/Matter) or expose custom protocols via LAN.

**Reference:** Official SDK repo at GitHub — [SmartThingsCommunity/SmartThingsEdgeDrivers](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers). The `drivers/SmartThings/` directory contains first-party reference implementations.

---

## Project Structure

```
my-driver/
├── src/
│   ├── init.lua                 # Driver entrypoint (required)
│   ├── discovery.lua            # mDNS/SSDP discovery logic (optional)
│   ├── command_handlers.lua     # Capability command handlers (optional)
│   ├── protocol.lua             # Device protocol implementation (optional)
│   └── ...                      # Any other Lua modules
├── profiles/
│   ├── switch.yml               # Device profile per device type
│   └── sensor.yml
├── config.yml                   # Driver manifest (required)
└── search-parameters.yml        # LAN discovery filters (optional)
```

Only `src/init.lua` + `profiles/` (at least one profile) + `config.yml` are required. Split into modules for maintainability — real drivers use 5-15 files.

---

## 1. Driver Manifest (`config.yml`)

```yaml
name: 'My Bridge'
packageKey: 'my-bridge.namespace'
permissions:
  lan: {}
  discovery: {}
description: "Bridges MyDevice to SmartThings"
vendorSupportInformation: "https://support.smartthings.com"
```

**File extension is `.yml`, not `.yaml`**

### Permissions

| Permission | When needed |
|---|---|
| `lan: {}` | LAN HTTP/socket access |
| `discovery: {}` | mDNS / SSDP scanning |
| `zigbee: {}` | Zigbee radio |
| `zwave: {}` | Z-Wave radio |
| `matter: {}` | Matter fabric |

---

## 2. Device Profiles (`profiles/*.yml` or `*.yaml`)

Profiles define what capabilities a device exposes. The profile name (from YAML) is used in `try_create_device({ profile = "..." })`.

```yaml
name: my-switch
components:
  - id: main
    capabilities:
      - id: switch
        version: 1
    categories:
      - name: Switch
```

### Profile format

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Matches the YAML filename (minus exthing) — used in `try_create_device()`. Convention: `vendor-device-type.v1` |
| `components` | Yes | Array of components, usually just `main`. Each has `capabilities[]`. |
| `components[].capabilities[].id` | Yes | Capability ID string |
| `components[].capabilities[].version` | Yes | Usually `1` |
| `categories` | No | Array of `{ name: "..." }` — maps to SmartThings device category |

For multi-component devices (e.g., dual outlet):
```yaml
name: dual-outlet
components:
  - id: outlet1
    capabilities:
      - id: switch
        version: 1
  - id: outlet2
    capabilities:
      - id: switch
        version: 1
categories:
  - name: Switch
```

---

## 3. Main Driver (`src/init.lua`)

### Imports

```lua
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"
local cosock = require "cosock"
local socket = require "cosock.socket"
```

**All blocking I/O must use cosock** — the hub runs a single Lua thread. HTTP, socket ops, and sleeps all need cosock wrappers.

### Driver Constructor

```lua
local driver = Driver("my_driver", {
  discovery = discovery_handler,                     -- optional
  lifecycle_handlers = {
    added = device_added,                            -- device paired
    init = device_init,                              -- hub restart / reload
    removed = device_removed,                        -- device removed
    infoChanged = info_changed_handler,              -- device label changed
  },
  lan_info_changed_handler = lan_info_changed,       -- hub IP changed (LAN only)
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_on,
      [capabilities.switch.commands.off.NAME] = handle_off,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_set_level,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
})

driver:run()
```

### Lifecycle Handlers

| Handler | When | Notes |
|---|---|---|
| `added` | Device first paired | Store config, start background tasks |
| `init` | Hub restart / driver reload | Same as added — re-establish everything |
| `removed` | Device unpaired | Cleanup timers, connections |
| `infoChanged` | Device label/name changed | Sync name back to device if needed |
| `lan_info_changed_handler` | Hub IPv4 address changed | Resubscribe event listeners (LAN only) |

**Important:** There's a known bug where `init` may not fire on every device. Guard with a field check:
```lua
if device:get_field("init_started") then return end
device:set_field("init_started", true)
```

### Capability Handlers

Each handler receives `(driver, device, command)`:

```lua
local function handle_on(driver, device, command)
  -- send command to physical device...
  device:emit_event(capabilities.switch.switch.on())
end

local function handle_set_level(driver, device, command)
  local level = command.args.level  -- 0-100
  -- send to device...
  device:emit_event(capabilities.switchLevel.level(level))
end
```

`command.args` contains the parsed arguments for parameterized commands (`setLevel`, `setColorTemperature`, etc).

### Persistent Fields

```lua
device:set_field("host_ip", "192.168.1.100", {persist = true})
device:set_field("port", 80, {persist = true})

local ip = device:get_field("host_ip")
```

Migrate legacy DTH device data on `init`:
```lua
if not device:get_field("host_ip") and device.data and device.data.ip then
  local nu = require "st.net_utils"
  local ip = nu.convert_ipv4_hex_to_dotted_decimal(device.data.ip)
  device:set_field("host_ip", ip, {persist = true})
end
```

### Scheduling (Polling & Periodic Tasks)

**Preferred** — use `device.thread:call_on_schedule()` (runs on device's thread, no manual cosock spawn needed):

```lua
device.thread:call_on_schedule(30, function()
  poll_device(driver, device)
end, device.id .. "-poll")
```

For one-shot delayed calls:
```lua
device.thread:call_with_delay(5, function()
  -- do something after 5 seconds
end)
```

For driver-level (not device-specific) scheduled tasks:
```lua
driver:call_on_schedule(600, function()
  ip_change_check()
end, "IP Change Check")
```

**Alternative** — use `cosock.spawn()` when you need control over the loop:
```lua
cosock.spawn(function()
  while true do
    poll_device(driver, device)
    socket.sleep(30)
  end
end, device.id .. "-poll")
```

### Backoff Pattern for Re-discovery

Official drivers use exponential backoff when retrying LAN discovery during init:

```lua
local function backoff_builder(max, inc, rand)
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

-- Usage in init:
cosock.spawn(function()
  local backoff = backoff_builder(300, 1, 0.25)
  while true do
    discovery.find(device_id, function(found) dev_info = found end)
    if dev_info then break end
    local tm = backoff()
    device.log.info_with({ hub_logs = true },
      string.format("Re-discovering, retry in %.1fs", tm))
    socket.sleep(tm)
  end
  device:set_field("host_ip", dev_info.ip, {persist = true})
  device:online()
end, device.id .. "-init")
```

### Device Health

```lua
device:online()    -- mark as reachable
device:offline()   -- mark as unreachable
```

---

## 4. Logging

Official drivers use two logging surfaces — hub logs and application logs.

```lua
log.info("message")                                    -- app log
log.warn("warning")
log.error("error")

log.info_with({hub_logs = true}, "message")            -- also shows in hub logs
log.warn_with({hub_logs = true}, "warning")
log.error_with({hub_logs = true}, "error")

device.log.info("device-specific msg")                 -- prefixed with device info
device.log.warn("msg")
device.log.error("msg")

device.log.info_with({hub_logs = true}, "hub log")     -- both: device prefix + hub log
device.log.warn_with({hub_logs = true}, "msg")
device.log.error_with({hub_logs = true}, "msg")

log.trace("debug-level message")
```

**Use `{hub_logs = true}` for startup/discovery/fatal errors** — these are visible to developers via:
```bash
smartthings edge:drivers:logcat --hub-address <hub-ip>
```

---

## 5. Discovery (`search-parameters.yml` + `discovery_handler`)

### mDNS Discovery
```yaml
# search-parameters.yml
mdns:
  - service: _http._tcp
```

### SSDP Discovery
```yaml
ssdp:
  - searchTerm: urn:schemas-upnp-org:device:MediaRenderer:1
```

### Discovery Handler

```lua
local function discovery_handler(driver, _, should_continue)
  local known_devices = {}
  local found_devices = {}

  local device_list = driver:get_devices()
  for _, device in ipairs(device_list) do
    known_devices[device.device_network_id] = true
  end

  while should_continue() do
    discovery.find(nil, function(discovered)
      local id = discovered.network_id
      if not known_devices[id] and not found_devices[id] then
        found_devices[id] = true
        driver:try_create_device({
          type = "LAN",
          device_network_id = id,
          label = discovered.name,
          profile = "my-profile",
          manufacturer = discovered.manufacturer,
          model = discovered.model,
          vendor_provided_label = discovered.name,
        })
      end
    end)
  end
end
```

**discovered_info** table from discovery callback:
- `network_id` / `id` — unique ID
- `name` — service name
- `ip` — IP address
- `port` — port number
- `manufacturer` — manufacturer
- `model` — model
- `serial_num` — serial number (wemo)

**`lan_info_changed_handler`** — update event listeners when hub IP changes:
```lua
local function lan_info_changed(driver, hub_ipv4)
  if driver.server and driver.server.listen_ip ~= hub_ipv4 then
    log.info_with({ hub_logs = true }, "hub IP changed, resubscribing")
    driver.server:shutdown()
    driver.server = SubscriptionServer:new_server()
    resubscribe_all(driver)
  end
end
```

---

## 6. Event Emission

```lua
-- Switch
device:emit_event(capabilities.switch.switch.on())
device:emit_event(capabilities.switch.switch.off())

-- Dimmer level (0-100)
device:emit_event(capabilities.switchLevel.level(50))

-- Motion sensor
device:emit_event(capabilities.motionSensor.motion.active())
device:emit_event(capabilities.motionSensor.motion.inactive())

-- Contact sensor
device:emit_event(capabilities.contactSensor.contact.open())
device:emit_event(capabilities.contactSensor.contact.closed())

-- Water sensor
device:emit_event(capabilities.waterSensor.water.wet())
device:emit_event(capabilities.waterSensor.water.dry())

-- Smoke detector
device:emit_event(capabilities.smokeDetector.smoke.detected())
device:emit_event(capabilities.smokeDetector.smoke.clear())

-- Temperature ({ value, unit = "C"|"F" })
device:emit_event(capabilities.temperatureMeasurement.temperature({ value = 25.5, unit = "C" }))

-- Humidity
device:emit_event(capabilities.relativeHumidityMeasurement.humidity({ value = 60, unit = "%" }))

-- Battery
device:emit_event(capabilities.battery.battery({ value = 85, unit = "%" }))

-- Power / Energy meters
device:emit_event(capabilities.powerMeter.power({ value = 120, unit = "W" }))
device:emit_event(capabilities.energyMeter.energy({ value = 500, unit = "Wh" }))

-- Lock
device:emit_event(capabilities.lock.lock.lock())
device:emit_event(capabilities.lock.lock.unlock())
device:emit_event(capabilities.lock.lock.jammed())

-- Color control
device:emit_event(capabilities.colorControl.hue({ value = 180 }))
device:emit_event(capabilities.colorControl.saturation({ value = 75 }))
device:emit_event(capabilities.colorControl.color({ hue = 180, saturation = 75 }))

-- Color temperature (Kelvin)
device:emit_event(capabilities.colorTemperature.colorTemperature({ value = 4000 }))

-- Fan speed
device:emit_event(capabilities.fanSpeed.fanSpeed({ speed = "low" | "medium" | "high" | "auto" | "off" }))

-- Thermostat
device:emit_event(capabilities.thermostatMode.thermostatMode({ value = "heat" }))
device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = 22, unit = "C" }))
device:emit_event(capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = 26, unit = "C" }))
```

---

## 7. CLI: Package & Deploy

### Prerequisites
- `smartthings` CLI installed and authenticated (`smartthings login`)
- A channel created: `smartthings edge:channels:create <channel-name>`
- A hub on the account

### Package
```bash
smartthings edge:drivers:package ./my-driver/
```
→ Generates a `.package` file and registers the driver. Output includes the **driver ID** (UUID).

### Assign to channel
```bash
smartthings edge:channels:assign <driver-id> <version> --channel <channel-id>
```
Version auto-increments on re-packaging.

### Install on hub
```bash
smartthings edge:drivers:install <driver-id> --hub <hub-id> --channel <channel-id>
```

### Useful commands
```bash
smartthings hubs                                           # list hubs
smartthings edge:channels                                  # list channels
smartthings edge:channels:drivers <channel-id>             # drivers on channel
smartthings edge:channels:assignments --channel <channel-id>
smartthings edge:drivers:logcat --hub-address <hub-ip>     # live hub logs
smartthings edge:drivers:uninstall <driver-id> --hub <hub-id>
```

---

## 8. LAN HTTP Communication (Reference)

Load `references/lan-http.md` for the full HTTP communication guide including:
- Pure Lua HTTP client (`socket.http` + `ltn12`)
- Base64 Basic auth implementation
- Safe JSON parsing with `pcall`
- Error handling and HTTP 401 detection
- Complete polling pattern with IP, health checks

---

## 9. Discovery Patterns (Reference)

Load `references/discovery-patterns.md` for:
- mDNS and SSDP discovery in detail
- Manual IP entry onboarding approach
- Full pairing flow for LAN gateway drivers
- Hub restart recovery with backoff re-discovery
- IP change detection
- DTH migration (hex IP → dotted decimal)

---

## 10. Capabilities Catalog (Reference)

Load `references/capabilities-catalog.md` for:
- Complete capability ID / command / event reference
- Profile YAML templates for common device types
- Multi-component device profile example
- Categories reference

---

## 11. Frameowrk Reference (Reference)

Load `references/driver-framework.md` for:
- Full Driver constructor options
- All lifecycle handler signatures
- Device API reference
- Scheduling (`call_on_schedule`, `call_with_delay`)
- Backoff builder function
