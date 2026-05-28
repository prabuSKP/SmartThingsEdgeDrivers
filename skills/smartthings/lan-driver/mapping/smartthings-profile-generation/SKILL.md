---
name: smartthings-profile-generation
description: >
  Generate SmartThings device profile YAML files from 3rd-party hub device schemas.
  Covers profile YAML format with components, capabilities, categories, and metadata.
  Includes multi-component profiles for dual/triple outlets, sensor-only profiles,
  actuator profiles, and composite profiles. Provides a complete catalog of all
  Fibaro driver profiles as reference. Use when creating new device profiles for
  a hub bridge Edge driver or extending an existing driver with new device types.
---

# SmartThings Profile Generation

Device profiles define what a SmartThings device looks like in the app — its
capabilities, UI components, and device category.

## Profile YAML Structure

```yaml
name: my-device-profile        # Must match the profile name used in mapper.lua
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
name: my-switch
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
name: my-dimmer
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
name: my-contact
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
name: my-motion
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
name: my-temperature-sensor
components:
  - id: main
    capabilities:
      - id: temperatureMeasurement
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: TemperatureSensor
```

### Humidity Sensor

```yaml
name: my-humidity-sensor
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
name: my-illuminance-sensor
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
name: my-water-sensor
components:
  - id: main
    capabilities:
      - id: waterSensor
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: WaterSensor
```

### Smoke Detector

```yaml
name: my-smoke-detector
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
name: my-blind
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
      - name: BlindController
```

### Generic Sensor (Catch-all)

```yaml
name: my-generic-sensor
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
name: my-default
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
name: my-double-switch
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
name: my-triple-switch
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
name: my-multi-sensor
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
name: my-bridge
components:
  - id: main
    capabilities:
      - id: refresh
        version: 1
    categories:
      - name: Bridge
preferences:
  - title: "Hub IP Address"
    name: "host"
    description: "IP address or hostname of the hub"
    required: true
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
    required: true
    preferenceType: "string"
    definition:
      stringType: "text"
      default: ""
  - title: "Password"
    name: "password"
    required: true
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

## Profile Naming Conventions

| Convention | Example | Usage |
|---|---|---|
| `{vendor}-{type}` | `fibaro-switch` | Vendor-specific profiles |
| `{vendor}-{type}-{variant}` | `fibaro-double-switch` | Variant profiles |
| `{vendor}-bridge` | `hc2-bridge` | Bridge/gateway profiles |
| `{vendor}-default` | `fibaro-default` | Default fallback profile |

## Adding a New Profile Checklist

1. Create `profiles/{profile-name}.yml` with correct YAML syntax
2. Add the profile name in `mapper.lua` `MAPPING_RULES` table
3. Register capabilities in `init.lua` `supported_capabilities`
4. Add state emission in `sync.lua` `emit_child_state()`
5. Add command handlers in `commands.lua` if the device is controllable
6. Register command handlers in `commands.capability_handlers` table
7. Test with `smartthings edge:drivers:package` to validate YAML syntax

## Category Reference

| Category | Icon/Card |
|---|---|
| `Switch` | Toggle switch |
| `Light` | Light bulb |
| `SmartPlug` | Smart outlet |
| `BlindController` | Window blind |
| `ContactSensor` | Door sensor |
| `MotionSensor` | Motion detector |
| `TemperatureSensor` | Thermometer |
| `HumiditySensor` | Water droplet |
| `LightSensor` | Sun icon |
| `WaterSensor` | Water leak |
| `SmokeDetector` | Smoke alarm |
| `Bridge` | Network bridge |
| `GenericSensor` | Generic sensor |
| `Thermostat` | Climate control |
| `Fan` | Fan blade |
| `Lock` | Lock icon |
