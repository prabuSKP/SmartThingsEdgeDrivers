# Device Profiles & Capabilities

## Device Profiles

A Device Profile is a blueprint defining a device's capabilities on SmartThings. It includes Components, Capabilities, and metadata.

### Profile Structure

```json
{
  "id": "custom-device-profile-id",
  "name": "My Custom Light Profile",
  "components": [
    {
      "id": "main",
      "label": "main",
      "capabilities": [
        { "id": "switch", "version": 1 },
        { "id": "switchLevel", "version": 1 },
        { "id": "colorControl", "version": 1 },
        { "id": "colorTemperature", "version": 1 },
        { "id": "healthCheck", "version": 1 }
      ],
      "categories": []
    }
  ],
  "metadata": {
    "vid": "custom-vid",
    "deviceType": "Light",
    "mnmn": "YOUR-MNID",
    "ocfDeviceType": "oic.d.light",
    "deviceTypeId": "Light"
  },
  "status": "DEVELOPMENT",
  "preferences": []
}
```

### Using Existing Profiles

C2C device profiles follow the pattern `c2c-{device-type}`. Common built-in profiles:
- `c2c-switch`
- `c2c-color-temperature-bulb`
- `c2c-color-bulb`
- `c2c-dimmable-light`
- `c2c-motion-sensor`
- `c2c-contact-sensor`
- `c2c-temperature-humidity-sensor`
- `c2c-lock`
- `c2c-thermostat`
- `c2c-window-shade`

Create custom profiles via SmartThings CLI:
```bash
smartthings deviceprofiles:create
```

### Categories

Required parameter. Maps to a device icon in the SmartThings app.

Supported categories: `Light`, `Switch`, `Sensor`, `Lock`, `Thermostat`, `Outlet`, `Fan`, `Vacuum`, `RobotCleaner`, `AirConditioner`, `AirPurifier`, `WaterHeater`, `Washer`, `Dryer`, `Refrigerator`, `Oven`, `Cooktop`, `CoffeeMaker`, `Dishwasher`, `WindowCovering`, `GarageDoor`, `Sprinkler`, `SmokeDetector`, `SecurityPanel`, `Siren`, `Camera`, `Hub`, `EnergyMonitor`, `Vehicle`, `Tag`, `Unknown`.

## Capabilities

### Key Standard Capabilities

| Capability ID | Attributes | Commands |
|---|---|---|
| `st.switch` | `switch` (on/off) | `on`, `off` |
| `st.switchLevel` | `level` (0-100) | `setLevel(level)`, `setLevelWithDuration(level, duration)` |
| `st.colorControl` | `hue` (0-100), `saturation` (0-100) | `setColor({hue, saturation})` |
| `st.colorTemperature` | `colorTemperature` (Kelvin) | `setColorTemperature(temperature)` |
| `st.healthCheck` | `healthStatus` (online/offline) | — |
| `st.battery` | `battery` (0-100) | — |
| `st.powerMeter` | `power` (Watts) | — |
| `st.energyMeter` | `energy` (kWh) | — |
| `st.motionSensor` | `motion` (active/inactive) | — |
| `st.contactSensor` | `contact` (open/closed) | — |
| `st.temperatureMeasurement` | `temperature` (C) | — |
| `st.humidityMeasurement` | `humidity` (%) | — |
| `st.thermostat` | `temperatureSetpoint`, `coolingSetpoint`, `heatingSetpoint` | `setCoolingSetpoint`, `setHeatingSetpoint`, `setThermostatMode` |
| `st.thermostatMode` | `thermostatMode` (off/heat/cool/auto) | `setThermostatMode(mode)` |
| `st.thermostatFanMode` | `thermostatFanMode` (auto/circulate/on) | `setThermostatFanMode(mode)` |
| `st.lock` | `lock` (locked/unlocked/jammed) | `lock`, `unlock` |
| `st.windowShade` | `windowShade` (open/closed/partially_open) | `open`, `close`, `pause` |

Full list: [Production Capabilities Reference](https://developer.smartthings.com/docs/devices/capabilities/capabilities-reference)

### Custom Capabilities

If standard capabilities don't cover your device's functionality:

1. Create via SmartThings CLI: `smartthings capabilities:create`
2. Reference Docs: [Custom Capabilities](https://developer.smartthings.com/docs/devices/capabilities/custom-capabilities)

**⚠️ Note:** Devices with custom capabilities **cannot** be WWST certified. Use only standard capabilities for certification submissions.

## Components

Components group related capabilities. Nearly all C2C devices use a single `main` component. Advanced devices (e.g., dual-outlet plugs) can have multiple components.

```json
"components": [
  { "id": "main", "capabilities": [...] },
  { "id": "outlet1", "capabilities": [...] },
  { "id": "outlet2", "capabilities": [...] }
]
```

## Preferences (Optional)

Define user-configurable settings for your device:
```json
"preferences": [
  {
    "name": "ledIndicator",
    "title": "LED Indicator",
    "description": "Enable LED indicator on device",
    "preferenceType": "boolean",
    "definition": { "defaultValue": true }
  }
]
```
