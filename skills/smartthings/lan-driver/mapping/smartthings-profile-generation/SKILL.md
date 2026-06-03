---
name: smartthings-profile-generation
description: >
  Generate SmartThings device profile YAML files from 3rd-party hub device schemas.
  Covers profile YAML format with components, capabilities, categories, and metadata.
  Includes multi-component profiles for dual/triple outlets, sensor-only profiles,
  actuator profiles, and composite profiles. Provides a complete catalog of all
  vendor-prefixed driver profiles as reference. Use when creating new device profiles for
  a hub bridge Edge driver or extending an existing driver with new device types.
---

# SmartThings Profile Generation

Device profiles define what a SmartThings device looks like in the app — its
capabilities, UI components, and device category.

## Generate Only the Requested Profiles

**The templates below are a catalog of what's possible, not a list to emit in full.**
Generate a profile YAML **only** for each device kind the user actually requested, plus
the always-required bridge profile.

- "develop a driver for a light on my HC3" → generate `*-bridge` + `*-switch` and/or
  `*-dimmer`. Do **not** also generate blind/contact/motion/sensor/smoke/default profiles.
- Only generate the full catalog (and the `*-default` catch-all) when the user asks for
  "all devices" / a "full/complete integration" or lists many types.
- Keep the profile set, the `MAPPING_RULES`, the `supported_capabilities`, and the command
  handlers in lockstep — generating an unused profile (or a rule that points at one) is the
  over-generation defect. See `mapping/hub-profile-mapping` → "Scope: Generate Only
  Requested Device Types".

## Profile YAML Structure

```yaml
name: vendor-device-profile    # Must match the profile name used in mapper.lua
components:
  - id: main                   # Primary component (required)
    capabilities:
      - id: switch             # Capability ID
        version: 1
      - id: switchLevel
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: Light            # UI category (icon, card layout)
```

## Basic Profile Templates

### Switch (Binary On/Off)

```yaml
name: vendor-switch
components:
  - id: main
    capabilities:
      - id: switch
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: Switch
```

### Dimmer (Variable Level)

```yaml
name: vendor-dimmer
components:
  - id: main
    capabilities:
      - id: switch
        version: 1
      - id: switchLevel
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: Light
```

### Contact Sensor

```yaml
name: vendor-contact
components:
  - id: main
    capabilities:
      - id: contactSensor
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: ContactSensor
```

### Motion Sensor

```yaml
name: vendor-motion
components:
  - id: main
    capabilities:
      - id: motionSensor
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: MotionSensor
```

### Temperature Sensor

```yaml
name: vendor-temperature-sensor
components:
  - id: main
    capabilities:
      - id: temperatureMeasurement
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: TempSensor
```

### Humidity Sensor

```yaml
name: vendor-humidity-sensor
components:
  - id: main
    capabilities:
      - id: relativeHumidityMeasurement
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: HumiditySensor
```

### Illuminance Sensor

```yaml
name: vendor-illuminance-sensor
components:
  - id: main
    capabilities:
      - id: illuminanceMeasurement
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: LightSensor
```

### Water / Flood Sensor

```yaml
name: vendor-water-sensor
components:
  - id: main
    capabilities:
      - id: waterSensor
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: LeakSensor
```

### Smoke Detector

```yaml
name: vendor-smoke-detector
components:
  - id: main
    capabilities:
      - id: smokeDetector
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: SmokeDetector
```

### Blind / Window Shade

```yaml
name: vendor-blind
components:
  - id: main
    capabilities:
      - id: windowShade
        version: 1
      - id: windowShadeLevel
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: Blind
```

### Generic Sensor (Catch-all)

```yaml
name: vendor-generic-sensor
components:
  - id: main
    capabilities:
      - id: refresh
        version: 1
    categories:
      - name: GenericSensor
```

### Default Card (Unrecognized Devices)

```yaml
name: vendor-default
components:
  - id: main
    capabilities:
      - id: refresh
        version: 1
    categories:
      - name: GenericSensor
```

## Multi-Component Profiles

For devices with multiple independent endpoints (e.g., dual/triple relay modules):

### Double Switch (2 Relays)

```yaml
name: vendor-double-switch
components:
  - id: main
    capabilities:
      - id: switch
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: Switch
  - id: switch2
    capabilities:
      - id: switch
        version: 1
    categories:
      - name: Switch
```

### Triple Switch (3 Relays)

```yaml
name: vendor-triple-switch
components:
  - id: main
    capabilities:
      - id: switch
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: Switch
  - id: switch2
    capabilities:
      - id: switch
        version: 1
    categories:
      - name: Switch
  - id: switch3
    capabilities:
      - id: switch
        version: 1
    categories:
      - name: Switch
```

## Composite Profiles (Multiple Sensors)

For multi-sensor devices that report several measurements:

### Multi-Sensor (Motion + Temp + Humidity + Lux)

```yaml
name: vendor-multi-sensor
components:
  - id: main
    capabilities:
      - id: motionSensor
        version: 1
      - id: temperatureMeasurement
        version: 1
      - id: relativeHumidityMeasurement
        version: 1
      - id: illuminanceMeasurement
        version: 1
      - id: battery
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: MotionSensor
```

## Bridge Profile

```yaml
name: vendor-bridge
components:
  - id: main
    capabilities:
      - id: refresh
        version: 1
    categories:
      - name: Bridges
```
preferences:
  - title: "Hub IP Address"
    name: "host"
    description: "IP address or hostname of the hub"
    required: false
    preferenceType: "string"
    definition:
      stringType: "text"
      default: ""
  - title: "Port"
    name: "port"
    description: "HTTP port"
    required: false
    preferenceType: "integer"
    definition:
      default: 80
      minimum: 1
      maximum: 65535
  - title: "Username"
    name: "username"
    required: false
    preferenceType: "string"
    definition:
      stringType: "text"
      default: ""
  - title: "Password"
    name: "password"
    required: false
    preferenceType: "string"
    definition:
      stringType: "password"
      default: ""
  - title: "Protocol"
    name: "scheme"
    required: false
    preferenceType: "enumeration"
    definition:
      options:
        http: "HTTP"
        https: "HTTPS"
      default: "http"
  - title: "Poll Interval (seconds)"
    name: "pollInterval"
    required: false
    preferenceType: "integer"
    definition:
      default: 30
      minimum: 10
      maximum: 300
```

Only include the `Protocol` / `scheme` preference when the generated API client supports every exposed scheme. If the client only opens raw TCP HTTP sockets, omit HTTPS from the generated profile and default to HTTP internally.

## Profile Naming Conventions

| Convention | Example | Usage |
|---|---|---|
| `{vendor}-{type}` | `vendor-switch` | Vendor-specific profiles |
| `{vendor}-{type}-{variant}` | `vendor-double-switch` | Variant profiles |
| `{vendor}-bridge` | `vendor-bridge` | Bridge/gateway profiles |
| `{vendor}-default` | `vendor-default` | Default fallback profile |

Use one naming convention throughout a generated driver. Replace `vendor` with the actual integration prefix, and do not mix `my-*`, generic names such as `switch`, and prefixed names such as `vendor-switch`.

## Adding a New Profile Checklist

1. Create `profiles/{profile-name}.yml` with correct YAML syntax
2. Add the profile name in `mapper.lua` `MAPPING_RULES` table
3. Register capabilities in `init.lua` `supported_capabilities`
4. Add state emission in `sync.lua` `emit_child_state()`
5. Add command handlers in `commands.lua` if the device is controllable
6. Register command handlers in `commands.capability_handlers` table
7. Test with `smartthings edge:drivers:package` to validate YAML syntax
8. Compare every Lua `profile = "..."` to every YAML `name:` and fix any mismatch before packaging

## Category Reference

| Category | Icon/Card |
|---|---|
| `Switch` | Toggle switch |
| `Light` | Light bulb |
| `SmartPlug` | Smart outlet |
| `Blind` | Window blind |
| `ContactSensor` | Door sensor |
| `MotionSensor` | Motion detector |
| `TempSensor` | Thermometer |
| `HumiditySensor` | Water droplet |
| `LightSensor` | Sun icon |
| `LeakSensor` | Water leak |
| `SmokeDetector` | Smoke alarm |
| `Bridges` | Network bridge |
| `GenericSensor` | Generic sensor |
| `Thermostat` | Climate control |
| `Fan` | Fan blade |
| `SmartLock` | Lock icon |
