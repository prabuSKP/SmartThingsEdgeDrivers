# Capabilities Catalog for Edge Drivers

Load this when you need capability ID, command signatures, or event constructors.

## Capability Reference

### Switch
| Attribute | Value |
|---|---|
| **ID** | `switch` |
| **Commands** | `on()`, `off()` |
| **Events** | `switch.on()`, `switch.off()` |

### Switch Level
| Attribute | Value |
|---|---|
| **ID** | `switchLevel` |
| **Commands** | `setLevel(level)` — level: 0-100 |
| **Args** | `command.args.level` |
| **Events** | `level(0-100)` |

### Color Control
| Attribute | Value |
|---|---|
| **ID** | `colorControl` |
| **Commands** | `setHue(hue)`, `setSaturation(sat)`, `setColor(hue, sat)` |
| **Events** | `hue(0-360)`, `saturation(0-100)`, `color({hue, saturation})` |

### Color Temperature
| Attribute | Value |
|---|---|
| **ID** | `colorTemperature` |
| **Commands** | `setColorTemperature(kelvin)` |
| **Events** | `colorTemperature({value = kelvin})` |

### Motion Sensor
| Attribute | Value |
|---|---|
| **ID** | `motionSensor` |
| **Commands** | (sensor — no commands) |
| **Events** | `motion.active()`, `motion.inactive()` |

### Contact Sensor
| Attribute | Value |
|---|---|
| **ID** | `contactSensor` |
| **Commands** | (sensor — no commands) |
| **Events** | `contact.open()`, `contact.closed()` |

### Temperature Measurement
| Attribute | Value |
|---|---|
| **ID** | `temperatureMeasurement` |
| **Commands** | (sensor — no commands) |
| **Events** | `temperature({value, unit = "C"|"F"})` |

### Relative Humidity
| Attribute | Value |
|---|---|
| **ID** | `relativeHumidityMeasurement` |
| **Events** | `humidity({value, unit = "%"})` |

### Illuminance
| Attribute | Value |
|---|---|
| **ID** | `illuminanceMeasurement` |
| **Events** | `illuminance({value, unit = "lux"})` |

### Battery
| Attribute | Value |
|---|---|
| **ID** | `battery` |
| **Events** | `battery({value = 0-100, unit = "%"})` |

### Power Meter
| Attribute | Value |
|---|---|
| **ID** | `powerMeter` |
| **Events** | `power({value, unit = "W"})` |

### Energy Meter
| Attribute | Value |
|---|---|
| **ID** | `energyMeter` |
| **Events** | `energy({value, unit = "Wh"})` |

### Voltage Measurement
| Attribute | Value |
|---|---|
| **ID** | `voltageMeasurement` |
| **Events** | `voltage({value, unit = "V"})` |

### Water Sensor
| Attribute | Value |
|---|---|
| **ID** | `waterSensor` |
| **Events** | `water.wet()`, `water.dry()` |

### Smoke Detector
| Attribute | Value |
|---|---|
| **ID** | `smokeDetector` |
| **Events** | `smoke.detected()`, `smoke.clear()` |

### Lock
| Attribute | Value |
|---|---|
| **ID** | `lock` |
| **Commands** | `lock()`, `unlock()` |
| **Events** | `lock.lock()`, `lock.unlock()`, `lock.jammed()` |

### Thermostat Mode
| Attribute | Value |
|---|---|
| **ID** | `thermostatMode` |
| **Commands** | `setThermostatMode({value = mode})` |
| **Modes** | `off`, `heat`, `cool`, `auto`, `emergencyHeat` |
| **Events** | `thermostatMode({value = mode})` |

### Thermostat Heating Setpoint
| Attribute | Value |
|---|---|
| **ID** | `thermostatHeatingSetpoint` |
| **Commands** | `setHeatingSetpoint({value, unit = "C"})` |
| **Events** | `heatingSetpoint({value, unit = "C"})` |

### Thermostat Cooling Setpoint
| Attribute | Value |
|---|---|
| **ID** | `thermostatCoolingSetpoint` |
| **Commands** | `setCoolingSetpoint({value, unit = "C"})` |
| **Events** | `coolingSetpoint({value, unit = "C"})` |

### Fan Speed
| Attribute | Value |
|---|---|
| **ID** | `fanSpeed` |
| **Commands** | `setSpeed({speed = "low"/"medium"/"high"/"auto"/"off"})` |
| **Events** | `fanSpeed({speed = ...})` |

### Audio Volume
| Attribute | Value |
|---|---|
| **ID** | `audioVolume` |
| **Commands** | `setVolume(volume)`, `volumeUp()`, `volumeDown()` |
| **Events** | `volume({value = 0-100})` |

### Audio Mute
| Attribute | Value |
|---|---|
| **ID** | `audioMute` |
| **Commands** | `mute()`, `unmute()`, `setMute({mute = bool})` |
| **Events** | `mute.muted()`, `mute.unmuted()` |

### Audio Notification
| Attribute | Value |
|---|---|
| **ID** | `audioNotification` |
| **Commands** | `playTrack(url)`, `playTrackAndResume(url)`, `playTrackAndRestore(url)` |
| **Args** | `command.args.url` |

### Media Playback
| Attribute | Value |
|---|---|
| **ID** | `mediaPlayback` |
| **Commands** | `play()`, `pause()`, `stop()` |
| **Events** | `playbackStatus.playing()`, `.paused()`, `.stopped()` |

### Media Track Control
| Attribute | Value |
|---|---|
| **ID** | `mediaTrackControl` |
| **Commands** | `nextTrack()`, `previousTrack()` |

### Health Check
| Attribute | Value |
|---|---|
| **ID** | `healthCheck` |
| **Notes** | Framework-managed. Hub pings device automatically. |

### Refresh
| Attribute | Value |
|---|---|
| **ID** | `refresh` |
| **Commands** | `refresh()` |

## Profile Template: Switch

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

## Profile Template: Dimmer

```yaml
name: my-dimmer
components:
  - id: main
    capabilities:
      - id: switch
        version: 1
      - id: switchLevel
        version: 1
    categories:
      - name: Light
```

## Profile Template: Motion Sensor

```yaml
name: my-motion-sensor
components:
  - id: main
    capabilities:
      - id: motionSensor
        version: 1
      - id: temperatureMeasurement
        version: 1
    categories:
      - name: Sensor
```

## Profile Template: Contact Sensor

```yaml
name: my-contact-sensor
components:
  - id: main
    capabilities:
      - id: contactSensor
        version: 1
    categories:
      - name: Sensor
```

## Profile Template: Power Metering Switch

```yaml
name: my-power-switch
components:
  - id: main
    capabilities:
      - id: switch
        version: 1
      - id: powerMeter
        version: 1
      - id: energyMeter
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: SmartPlug
```

## Profile Template: Dual Outlet

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

## Categories Reference

| Category | Use for |
|---|---|
| `Switch` | On/off switches, smart plugs |
| `Light` | Dimmers, lights |
| `Sensor` | Motion, contact, temp, humidity sensors |
| `SmartPlug` | Power-metering plugs |
| `Speaker` | Audio devices |
| `Thermostat` | HVAC controllers |
| `Lock` | Door locks |
| `Fan` | Ceiling/standing fans |
| `Bridge` | Hub/gateway parent devices |
