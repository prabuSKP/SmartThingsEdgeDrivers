---
name: zwave
description: >
  Develop SmartThings Edge drivers for Z-Wave-connected devices.
  Covers importing st.zwave, registering Command Class (CC) handlers, constructing
  set payloads, parsing status reports, and configuring device parameters (Configuration CC).
  Use when building or debugging Z-Wave Edge drivers.
---

# SmartThings Edge Z-Wave Driver Integration

This skill covers the development of local SmartThings Edge drivers for Z-Wave devices using the standard Command Class (CC) modules provided by the SmartThings Edge SDK.

---

## 1. Driver Boilerplate & Registration

Z-Wave drivers register command-class message handlers under the `zwave_handlers` section:

```lua
local capabilities = require "st.capabilities"
local ZwaveDriver = require "st.zwave"
local cc = require "st.zwave.CommandClass"
local SwitchBinary = cc.SwitchBinary

-- 1. Handler for SwitchBinary Reports (State Sync)
local function switch_binary_report_handler(driver, device, cmd)
  -- cmd.args.target_value or cmd.args.value indicates switch state
  if cmd.args.value == SwitchBinary.value.ON_DISABLE_KEY then
    device:emit_event(capabilities.switch.switch.off())
  elseif cmd.args.value == SwitchBinary.value.ON_ENABLE_KEY or cmd.args.value > 0 then
    device:emit_event(capabilities.switch.switch.on())
  end
end

-- 2. Handler for Capability Commands (SmartThings App -> Device)
local function handle_switch_on(driver, device, command)
  -- Send Z-Wave SwitchBinary Set command (value 0xFF turns switch ON)
  device:send(SwitchBinary:Set({ target_value = 0xFF }))
end

local function handle_switch_off(driver, device, command)
  -- Value 0x00 turns switch OFF
  device:send(SwitchBinary:Set({ target_value = 0x00 }))
end

-- 3. Instantiate Driver
local zwave_switch_driver = ZwaveDriver("zwave_switch", {
  supported_capabilities = {
    capabilities.switch
  },
  zwave_handlers = {
    [SwitchBinary.ID] = {
      [SwitchBinary.REPORT] = switch_binary_report_handler
    }
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handle_switch_off
    }
  }
})

zwave_switch_driver:run()
```

---

## 2. Common Z-Wave Command Classes

The Edge SDK encapsulates command classes under `st.zwave.CommandClass`:

| Command Class Name | CC Hex ID | Key Cmds / Reports | Description |
|---|---|---|---|
| **`Basic`** | `0x20` | `Set`, `Report` | Generic fallback status |
| **`SwitchBinary`** | `0x25` | `Set`, `Report` | Simple on/off switches |
| **`SwitchMultilevel`** | `0x26` | `Set`, `Report` | Dimmers, window shades |
| **`SensorMultilevel`** | `0x31` | `Report` | Temperature, light sensors |
| **`Configuration`** | `0x70` | `Set`, `Report` | Config parameters |
| **`Battery`** | `0x80` | `Report` | Battery percentage updates |

---

## 3. Configuring Device Parameters

Z-Wave parameters (such as LED colors, motion sensitivity, or auto-off timers) are configured using the `Configuration` Command Class during initialization:

```lua
local Configuration = cc.Configuration

local function device_configure(driver, device)
  -- Set parameter 1 (size 1 byte) to value 10
  device:send(Configuration:Set({
    parameter_number = 1,
    size = 1,
    configuration_value = 10
  }))
end
```

---

## 4. Troubleshooting & Best Practices
- **Security Levels**: Z-Wave devices join with various security profiles (S0, S2 Unauthenticated, S2 Authenticated). Check `device.zwave_security` before sending raw commands.
- **Multichannel Associations**: For multi-endpoint (multichannel) Z-Wave devices, endpoints are addressed using the `MultiChannel` CC wrapper:
  ```lua
  local MultiChannel = cc.MultiChannel
  device:send(MultiChannel:CmdEncap({
    source_endpoint = 0,
    destination_endpoint = 2,
    command_class = SwitchBinary.ID,
    command = SwitchBinary.SET,
    parameter = string.char(0xFF)
  }))
  ```
- **Z-Wave Network Busy**: Rapidly sending commands can flood the Z-Wave mesh. Use short sleeps or space out commands if triggering multiple Z-Wave devices simultaneously.
