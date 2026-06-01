---
name: smartthings-capability-mapping
description: >
  Complete reference for SmartThings capability IDs, commands, events, and argument
  formats for use in Edge drivers. Covers all standard capabilities used in hub bridge
  drivers — switch, switchLevel, colorControl, colorTemperature, contactSensor,
  motionSensor, temperatureMeasurement, relativeHumidityMeasurement,
  illuminanceMeasurement, waterSensor, smokeDetector, windowShade, windowShadeLevel,
  lock, thermostat, fanSpeed, audioVolume, audioMute, audioNotification, mediaPlayback,
  mediaTrackControl, refresh, battery, energyMeter, powerMeter, voltageMeasurement,
  and more. Includes Lua event emission syntax, command handler signatures, argument
  destructuring, and unit specifications. Use when building capability handlers or
  mapping hub device values to SmartThings events.
---

# SmartThings Capability Mapping Reference

## Capability Registration

Register capabilities in `init.lua`:

Important: SmartThings Edge drivers register capability handlers by passing the
`capability_handlers` table into the `Driver(...)` constructor. Do not generate
code that calls `driver:register_capability_handler(...)`; that method is not
available in the Edge runtime and will crash the driver during startup.

```lua
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local commands = require "handlers.commands"

local driver = Driver("my-driver", {
  supported_capabilities = {
    capabilities.refresh,
    capabilities.switch,
    capabilities.switchLevel,
    capabilities.contactSensor,
    capabilities.motionSensor,
    capabilities.temperatureMeasurement,
    capabilities.relativeHumidityMeasurement,
    capabilities.illuminanceMeasurement,
    capabilities.waterSensor,
    capabilities.smokeDetector,
    capabilities.windowShade,
    capabilities.windowShadeLevel,
    capabilities.battery,
  },
  capability_handlers = commands.capability_handlers,
})
```

## Capability Handlers Table

Export the handler table from `handlers/commands.lua` and reference it from
`init.lua`. Do not create a `commands.register_handlers(driver)` function that
mutates the driver object after construction.

```lua
local capabilities = require "st.capabilities"

local commands = {}

local function handle_refresh(driver, device, command)
  -- refresh implementation
end

local function handle_switch_on(driver, device, command)
  -- on implementation
end

local function handle_switch_off(driver, device, command)
  -- off implementation
end

local function handle_set_level(driver, device, command)
  -- setLevel implementation
end

commands.capability_handlers = {
  [capabilities.refresh.ID] = {
    [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
  },
  [capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME] = handle_switch_on,
    [capabilities.switch.commands.off.NAME] = handle_switch_off,
  },
  [capabilities.switchLevel.ID] = {
    [capabilities.switchLevel.commands.setLevel.NAME] = handle_set_level,
  },
  [capabilities.windowShade.ID] = {
    [capabilities.windowShade.commands.open.NAME] = handle_shade_open,
    [capabilities.windowShade.commands.close.NAME] = handle_shade_close,
  },
  [capabilities.windowShadeLevel.ID] = {
    [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = handle_set_shade_level,
  },
}

return commands
```

## Capability Reference Table

### Actuator Capabilities (Controllable)

| Capability | Commands | Events | Profile Category |
|---|---|---|---|
| `switch` | `on()`, `off()` | `.switch.on()`, `.switch.off()` | Switch, Light |
| `switchLevel` | `setLevel(level, rate)` | `.level(0-100)` | Dimmer, Light |
| `windowShade` | `open()`, `close()`, `pause()` | `.windowShade.open/closed/partially_open/opening/closing` | Blind |
| `windowShadeLevel` | `setShadeLevel(level)` | `.shadeLevel(0-100)` | Blind |
| `colorControl` | `setColor({hue, saturation})` | `.hue(0-100)`, `.saturation(0-100)` | Color Light |
| `colorTemperature` | `setColorTemperature(temp)` | `.colorTemperature(min-max)` | Tunable Light |
| `thermostatMode` | `setThermostatMode(mode)` | `.thermostatMode(auto/cool/heat/off)` | Thermostat |
| `thermostatSetpoint` | `setHeatingSetpoint(temp)` | `.heatingSetpoint(temp)` | Thermostat |
| `fanSpeed` | `setFanSpeed(speed)` | `.fanSpeed({speed = "low"/"medium"/"high"/"auto"/"off"})` | Fan |
| `lock` | `lock()`, `unlock()` | `.lock.locked()/.unlocked()/.jammed()` | Lock |
| `alarm` | `siren()`, `strobe()`, `off()` | `.alarm.siren/strobe/both/off` | Siren |
| `audioVolume` | `setVolume(volume)`, `volumeUp()`, `volumeDown()` | `.volume(0-100)` | Speaker |
| `audioMute` | `mute()`, `unmute()`, `setMute(mute)` | `.mute.muted()/.unmuted()` | Speaker |
| `audioNotification` | `playTrack(url)`, `playTrackAndResume(url)` | — (fire-and-forget) | Speaker |
| `mediaPlayback` | `play()`, `pause()`, `stop()` | `.playbackStatus.playing()/.paused()/.stopped()` | Speaker |
| `mediaTrackControl` | `nextTrack()`, `previousTrack()` | — (fire-and-forget) | Speaker |
| `thermostatHeatingSetpoint` | `setHeatingSetpoint(temp)` | `.heatingSetpoint({value, unit})` | Thermostat |
| `thermostatCoolingSetpoint` | `setCoolingSetpoint(temp)` | `.coolingSetpoint({value, unit})` | Thermostat |

### Sensor Capabilities (Read-Only)

| Capability | Events | Units | Profile Category |
|---|---|---|---|
| `contactSensor` | `.contact.open()`, `.contact.closed()` | — | Contact Sensor |
| `motionSensor` | `.motion.active()`, `.motion.inactive()` | — | Motion Sensor |
| `temperatureMeasurement` | `.temperature({value, unit})` | `"C"` or `"F"` | Temp Sensor |
| `relativeHumidityMeasurement` | `.humidity({value})` | `%` (integer) | Humidity Sensor |
| `illuminanceMeasurement` | `.illuminance({value, unit})` | `"lux"` | Lux Sensor |
| `waterSensor` | `.water.wet()`, `.water.dry()` | — | Water Sensor |
| `smokeDetector` | `.smoke.detected()`, `.smoke.clear()` | — | Smoke Detector |
| `battery` | `.battery(0-100)` | `%` (integer) | — (supplementary) |
| `presenceSensor` | `.presence.present()`, `.presence.not_present()` | — | Presence Sensor |
| `energyMeter` | `.energy({value, unit})` | `"kWh"` | Energy Meter |
| `powerMeter` | `.power({value, unit})` | `"W"` | Power Meter |
| `voltageMeasurement` | `.voltage({value, unit})` | `"V"` | Voltage Meter |
| `carbonDioxideMeasurement` | `.carbonDioxide({value, unit})` | `"ppm"` | CO2 Sensor |

### Utility Capabilities

| Capability | Purpose |
|---|---|
| `refresh` | Manual state refresh (pull-to-refresh in app) |
| `healthCheck` | Device health monitoring |
| `firmwareUpdate` | OTA firmware management |

## Detailed Event Emission Syntax

### Switch

```lua
-- Emit ON/OFF
device:emit_event(capabilities.switch.switch.on())
device:emit_event(capabilities.switch.switch.off())
```

### Switch Level

```lua
-- Emit level (0-100, integer)
device:emit_event(capabilities.switchLevel.level(75))

-- Command handler
function handle_set_level(driver, device, cmd)
  local level = cmd.args.level or 0        -- 0-100
  local rate = cmd.args.rate               -- transition time (optional)
  -- Send level to hub...
end
```

### Temperature

```lua
-- Emit with unit (required)
device:emit_event(capabilities.temperatureMeasurement.temperature({
  value = 22.5,
  unit = "C"    -- must be "C" or "F"
}))
```

### Humidity

```lua
-- Emit as integer percentage
device:emit_event(capabilities.relativeHumidityMeasurement.humidity({
  value = 65     -- integer, 0-100
}))
```

### Illuminance

```lua
-- Emit with unit
device:emit_event(capabilities.illuminanceMeasurement.illuminance({
  value = 450,
  unit = "lux"
}))
```

### Window Shade

```lua
-- State events
device:emit_event(capabilities.windowShade.windowShade.open())
device:emit_event(capabilities.windowShade.windowShade.closed())
device:emit_event(capabilities.windowShade.windowShade.partially_open())
device:emit_event(capabilities.windowShade.windowShade.opening())
device:emit_event(capabilities.windowShade.windowShade.closing())

-- Level event
device:emit_event(capabilities.windowShadeLevel.shadeLevel(50))

-- Command handler
function handle_set_shade_level(driver, device, cmd)
  local level = cmd.args.shadeLevel or 0    -- 0-100
  -- Send to hub...
end
```

### Contact Sensor

```lua
device:emit_event(capabilities.contactSensor.contact.open())
device:emit_event(capabilities.contactSensor.contact.closed())
```

### Motion Sensor

```lua
device:emit_event(capabilities.motionSensor.motion.active())
device:emit_event(capabilities.motionSensor.motion.inactive())
```

### Water Sensor

```lua
device:emit_event(capabilities.waterSensor.water.wet())
device:emit_event(capabilities.waterSensor.water.dry())
```

### Smoke Detector

```lua
device:emit_event(capabilities.smokeDetector.smoke.detected())
device:emit_event(capabilities.smokeDetector.smoke.clear())
device:emit_event(capabilities.smokeDetector.smoke.tested())
```

### Battery

```lua
-- Integer percentage (0-100)
device:emit_event(capabilities.battery.battery(85))
```

### Energy & Power

```lua
device:emit_event(capabilities.energyMeter.energy({
  value = 12.5,
  unit = "kWh"
}))

device:emit_event(capabilities.powerMeter.power({
  value = 150,
  unit = "W"
}))

device:emit_event(capabilities.voltageMeasurement.voltage({
  value = 230,
  unit = "V"
}))
```

### Lock

```lua
device:emit_event(capabilities.lock.lock.locked())
device:emit_event(capabilities.lock.lock.unlocked())
device:emit_event(capabilities.lock.lock.jammed())
```

### Thermostat

```lua
-- Mode
device:emit_event(capabilities.thermostatMode.thermostatMode("heat"))

-- Heating setpoint
device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({
  value = 22,
  unit = "C"
}))

-- Cooling setpoint
device:emit_event(capabilities.thermostatCoolingSetpoint.coolingSetpoint({
  value = 26,
  unit = "C"
}))
```

### Fan Speed

```lua
device:emit_event(capabilities.fanSpeed.fanSpeed({
  speed = "low"   -- "low" | "medium" | "high" | "auto" | "off"
}))
```

### Color Control

```lua
-- Hue (0-360 mapped to 0-100 in ST)
device:emit_event(capabilities.colorControl.hue({ value = 180 }))
device:emit_event(capabilities.colorControl.saturation({ value = 75 }))
device:emit_event(capabilities.colorControl.color({ hue = 180, saturation = 75 }))

-- Command handler
function handle_set_color(driver, device, cmd)
  local hue = cmd.args.color.hue            -- 0-100
  local saturation = cmd.args.color.saturation  -- 0-100
  -- Send to hub...
end
```

### Color Temperature

```lua
device:emit_event(capabilities.colorTemperature.colorTemperature({
  value = 4000   -- Kelvin
}))

-- Command handler
function handle_set_color_temp(driver, device, cmd)
  local temp = cmd.args.temperature   -- Kelvin
  -- Send to hub...
end
```

### Audio Volume

```lua
-- Volume (0-100)
device:emit_event(capabilities.audioVolume.volume(50))

-- Command handler
function handle_set_volume(driver, device, cmd)
  local volume = cmd.args.volume   -- 0-100
  -- Send to hub...
end
```

### Audio Mute

```lua
device:emit_event(capabilities.audioMute.mute.muted())
device:emit_event(capabilities.audioMute.mute.unmuted())
```

### Media Playback

```lua
device:emit_event(capabilities.mediaPlayback.playbackStatus.playing())
device:emit_event(capabilities.mediaPlayback.playbackStatus.paused())
device:emit_event(capabilities.mediaPlayback.playbackStatus.stopped())
```

## Value Conversion Helpers

```lua
-- Truthy check (handles string "0", "false", false, 0, nil)
local function value_is_truthy(value)
  if value == nil then return false end
  if value == false then return false end
  if value == 0 then return false end
  if value == "0" then return false end
  if value == "false" then return false end
  return true
end

-- Safe number conversion
local function safe_tonumber(value)
  if type(value) == "number" then return value end
  if type(value) == "string" then return tonumber(value) end
  if type(value) == "boolean" then return value and 1 or 0 end
  return nil
end

-- Clamp to range
local function clamp(value, min, max)
  if value < min then return min end
  if value > max then return max end
  return value
end
```

## Custom Capabilities

For device features not covered by standard capabilities:

```lua
-- Define custom capability
local customCap = capabilities["colorStar12345.myCustomCapability"]

-- Emit custom event
device:emit_event(customCap.myAttribute("value"))

-- Handle custom command
capability_handlers[customCap.ID] = {
  [customCap.commands.myCommand.NAME] = function(driver, device, cmd)
    local arg1 = cmd.args.myArg
    -- ...
  end,
}
```

## Profile Category Reference

| Category | Use For |
|---|---|
| `Switch` | Binary on/off devices |
| `Light` | Lights, dimmers, color bulbs |
| `SmartPlug` | Smart plugs with energy monitoring |
| `BlindController` | Roller shutters, blinds, curtains |
| `ContactSensor` | Door/window sensors |
| `MotionSensor` | PIR motion detectors |
| `TemperatureSensor` | Standalone temperature probes |
| `HumiditySensor` | Standalone humidity sensors |
| `LightSensor` | Lux/illuminance sensors |
| `WaterSensor` | Flood/leak detectors |
| `SmokeDetector` | Smoke/heat detectors |
| `Bridge` | Hub/gateway bridge devices |
| `GenericSensor` | Catch-all sensor type |
| `Thermostat` | Climate control devices |
| `Fan` | Ceiling/stand fans |
| `Lock` | Smart locks |
| `Speaker` | Audio/media playback devices |
| `Hub` | Smart home hub/gateway |
| `Camera` | IP cameras |
| `Garage` | Garage door controllers |
