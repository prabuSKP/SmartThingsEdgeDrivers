---
name: matter
description: >
  Develop SmartThings Edge drivers for Matter-connected devices.
  Covers importing st.matter, registering cluster attribute handlers, formatting
  Invoke commands, mapping Interaction Model reports to capability events, and
  configuring device fingerprints. Use when building or debugging Matter Edge drivers.
---

# SmartThings Edge Matter Driver Integration

This skill covers the development of local SmartThings Edge drivers for Matter devices (connected over Thread or Wi-Fi) using the standard Matter libraries provided by the SmartThings Edge SDK.

---

## 1. Driver Boilerplate & Registration

Matter drivers register attribute and command handlers under the `matter_handlers` section of the driver definition:

```lua
local capabilities = require "st.capabilities"
local MatterDriver = require "st.matter"
local clusters = require "st.matter.clusters"
local OnOff = clusters.OnOff

-- 1. Handler for Matter Attribute Reports (State Sync)
local function on_off_attr_handler(driver, device, ib, response)
  -- ib (Interaction Block) contains the field value
  if ib.data.value then
    device:emit_event(capabilities.switch.switch.on())
  else
    device:emit_event(capabilities.switch.switch.off())
  end
end

-- 2. Handler for Capability Commands (SmartThings App -> Device)
local function handle_switch_on(driver, device, command)
  -- Send Matter OnOff Invoke Command
  device:send(OnOff.commands.On(device))
end

local function handle_switch_off(driver, device, command)
  device:send(OnOff.commands.Off(device))
end

-- 3. Instantiate Driver
local matter_switch_driver = MatterDriver("matter_switch", {
  supported_capabilities = {
    capabilities.switch
  },
  matter_handlers = {
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

matter_switch_driver:run()
```

---

## 2. Standard Matter Clusters & Attributes

The Edge SDK maps Matter clusters under `st.matter.clusters`:

| Cluster Name | Cluster ID | Attribute ID | Description |
|---|---|---|---|
| **`OnOff`** | `0x0006` | `0x0000` (OnOff) | Binary state (switch) |
| **`LevelControl`** | `0x0008` | `0x0000` (CurrentLevel) | Light level, dimmers |
| **`ColorControl`** | `0x0300` | Multiple (CurrentHue, etc.) | Colors, light temperature |
| **`Thermostat`** | `0x0201` | Multiple (LocalTemp, etc.) | Climate control systems |
| **`FlowMeasurement`** | `0x0404` | `0x0000` (MeasuredValue) | Sensors |

---

## 3. Interaction Model Terminology

Matter operates using an **Interaction Model** consisting of:
- **Read / Write Attributes**: Read current configuration or write parameters (e.g. setting an occupancy delay parameter).
- **Subscribe**: Establishes a connection to receive reports when attributes change (the ST Edge Matter runtime manages subscriptions automatically based on your registered `matter_handlers`).
- **Invoke Commands**: Executing actions on the device (e.g., calling `OnOff.commands.On()`).

### Writing an Attribute Example
To configure a device parameter, send a write attribute request:
```lua
local clusters = require "st.matter.clusters"
local LevelControl = clusters.LevelControl

-- Set the OnLevel attribute (value 255)
device:send(LevelControl.attributes.OnLevel:write(device, 255))
```

---

## 4. Matter Fingerprints (`fingerprints.yml`)

Matter drivers match devices using their **Device Type ID**, **Vendor ID (VID)**, and **Product ID (PID)**.

Example Matter `fingerprints.yml`:
```yaml
matter:
  - id: "my-matter-switch"
    deviceTypes:
      - id: 0x010A # On/Off Light
    deviceProfile: switch-profile
  - id: "specific-vendor-plug"
    vendorId: 0x1234
    productId: 0x5678
    deviceProfile: switch-profile
```
---

## 5. Troubleshooting & Best Practices
- **Endpoint Routing**: In Matter, devices expose functionality on numbered **Endpoints** (e.g., Endpoint 1 for switch, Endpoint 2 for sub-switch). The SDK routes reports automatically. To route commands explicitly, use:
  ```lua
  device:send(OnOff.commands.On(device):to_endpoint(2))
  ```
- **Handling Structs & Arrays**: Unlike Zigbee which uses basic primitives, Matter reports can return complex structs or arrays. Inspect `ib.data` carefully using standard JSON formatting when logging unknown Matter payloads.
