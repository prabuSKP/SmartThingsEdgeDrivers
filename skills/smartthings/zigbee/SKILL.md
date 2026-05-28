---
name: zigbee
description: >
  Develop SmartThings Edge drivers for Zigbee-connected devices.
  Covers importing st.zigbee, configuring cluster attribute handlers, emitting
  standard capability events, constructing command payloads, and writing configuration
  sequences (doConfigure). Use when building or debugging Zigbee Edge drivers.
---

# SmartThings Edge Zigbee Driver Integration

This skill covers the development of local SmartThings Edge drivers for Zigbee devices using the standard Zigbee Cluster Library (ZCL) structures provided by the SmartThings Edge SDK.

---

## 1. Driver Boilerplate & Registration

Zigbee drivers register cluster-specific message handlers under the `zigbee_handlers` section:

```lua
local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local clusters = require "st.zigbee.zcl.clusters"
local OnOff = clusters.OnOff

-- 1. Handler for On/Off Attribute Reports (State Sync)
local function on_off_attr_handler(driver, device, value, zb_rx)
  if value.value then
    device:emit_event(capabilities.switch.switch.on())
  else
    device:emit_event(capabilities.switch.switch.off())
  end
end

-- 2. Handler for Capability Commands (SmartThings App -> Device)
local function handle_switch_on(driver, device, command)
  -- Send standard Zigbee OnOff Cluster command
  device:send(OnOff.server.commands.On(device))
end

local function handle_switch_off(driver, device, command)
  device:send(OnOff.server.commands.Off(device))
end

-- 3. Instantiate Driver
local zigbee_switch_driver = ZigbeeDriver("zigbee_switch", {
  supported_capabilities = {
    capabilities.switch
  },
  zigbee_handlers = {
    attr = {
      [OnOff.ID] = {
        [OnOff.attributes.OnOff.ID] = on_off_attr_handler
      }
    }
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handle_switch_off
    }
  }
})

zigbee_switch_driver:run()
```

---

## 2. Key Zigbee Clusters & Attributes

The Edge SDK encapsulates common clusters under `st.zigbee.zcl.clusters`:

| Cluster Name | Cluster ID | Attribute ID | Description |
|---|---|---|---|
| **`OnOff`** | `0x0006` | `0x0000` (OnOff) | Binary states (switch) |
| **`Level`** | `0x0008` | `0x0000` (CurrentLevel) | Dimmers, level controls |
| **`ColorControl`**| `0x0300` | Multiple (Hue, Sat, Temp) | RGB and Kelvin temperature lights |
| **`PowerConfiguration`** | `0x0001` | `0x0021` (BatteryPercentage) | Battery status reporting |
| **`TemperatureMeasurement`**| `0x0402` | `0x0000` (MeasuredValue) | Temperature sensors |

---

## 3. Configuration Handlers (`doConfigure`)

For Zigbee devices to report their states automatically, you must configure bindings and reporting intervals. This is done inside the `doConfigure` lifecycle event:

```lua
local function device_configure(driver, device)
  -- Configure reporting for On/Off state: min 0s, max 300s
  device:send(OnOff.attributes.OnOff:configure_reporting(device, 0, 300))
  
  -- Request binding to the On/Off cluster
  device:send(OnOff.attributes.OnOff:bind(device))
end
```

---

## 4. Troubleshooting & Best Practices
- **Network Join Signature**: The hub matches devices to drivers using the fingerprints list in `fingerprints.yml`. Make sure to list the correct `inClusters` and `outClusters` IDs.
- **Handling Multi-Endpoint Devices**: If a smart plug has multiple outlets, specify the endpoint parameter when sending commands:
  ```lua
  device:send_to_component("button2", OnOff.server.commands.On(device))
  ```
- **Byte Order**: Zigbee uses Little-Endian representation. Ensure custom payload parsers swap bytes accordingly when converting raw data fields.
