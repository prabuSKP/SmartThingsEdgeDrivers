# Fibaro HC2/HC3 Driver: Multi-Attribute Device Mapping Plan

## Problem Statement

The current `mapper.lua` uses a **single-attribute, priority-based** mapping chain that checks attributes in a fixed order and maps to the first match. This causes several issues:

1. **Curtain/Blind devices** (`com.fibaro.rollerShutter`, `com.fibaro.FGR223`) with `role=BlindsWithPositioning` are mapped as DIMMER because they have `setValue` action — but they should be window coverings
2. **Heat detectors** (`com.fibaro.heatDetector`) are mapped as GENERIC-SENSOR with only `refresh` capability — no actual sensor state
3. **All binarySwitch devices** are mapped as SWITCH regardless of role (FAN, GYSER, CURTAIN, REPEATER all become "Switch")
4. **Temperature/Humidity/Light sensors** that may exist in Fibaro have no mapping at all
5. **The `deviceRole` field** from Fibaro is available but completely ignored in mapping decisions

### Current Mapping Logic (mapper.lua)

```
Priority 1: is_gateway → SKIP
Priority 2: is_user → SKIP  
Priority 3: is_plugin → SKIP
Priority 4: enabled=false → SKIP
Priority 5: has setValue action → DIMMER
Priority 6: has turnOn + turnOff → SWITCH
Priority 7: type/role/interface contains motion → MOTION
Priority 8: type/role/interface contains door/window/contact → CONTACT
Priority 9: has value property → GENERIC-SENSOR
Priority 10: none of above → SKIP (unsupported)
```

---

## Proposed Solution: Multi-Attribute Mapping

### Design Principles

1. **Use ALL available attributes** for mapping: `type`, `baseType`, `deviceRole`, `actions`, `interfaces`, `properties`
2. **Most specific match wins**: Check device type + role combinations first, then fall back to broader matches
3. **Role-aware mapping**: Use `deviceRole` to differentiate devices of the same type (e.g., binarySwitch with role=Light vs role=BlindsWithPositioning)
4. **Interface-aware mapping**: Use Fibaro `interfaces` array for sensor detection
5. **Property-aware mapping**: Use `properties` fields (temperature, humidity, etc.) for sensor type detection

### Available Fibaro Attributes (from HC3 API)

Each device from `GET /api/devices` returns:

| Attribute | Type | Description | Used in Current Mapper? |
|-----------|------|-------------|------------------------|
| `id` | number | Device ID | ✅ |
| `name` | string | Device name/label | ✅ |
| `type` | string | e.g. `com.fibaro.binarySwitch` | ✅ |
| `baseType` | string | e.g. `com.fibaro.actor` | ✅ |
| `enabled` | boolean | Whether device is enabled | ✅ |
| `visible` | boolean | Whether device is visible | ✅ |
| `isPlugin` | boolean | Whether it's a plugin/virtual device | ✅ |
| `parentId` | number | Parent device ID | ✅ (as parent_id) |
| `interfaces` | array | e.g. `["zwave"]`, `["motionSensor"]` | ✅ (but only for motion/contact) |
| `actions` | object | e.g. `{turnOn=true, turnOff=true, setValue=true}` | ✅ (but only for switch/dimmer) |
| `properties.value` | any | Current device value | ✅ |
| `properties.state` | any | Current device state | ✅ (as fallback for value) |
| `properties.dead` | boolean | Whether device is dead/unreachable | ✅ |
| `properties.deviceRole` | string | e.g. `Light`, `BlindsWithPositioning`, `HeatDetector` | ❌ **NOT USED** |
| `properties.deviceControlType` | string | Control type hint | ❌ **NOT USED** |
| `properties.unit` | string | Unit of measurement | ❌ **NOT USED** |
| `properties.batteryLevel` | number | Battery percentage | ❌ **NOT USED** |
| `properties.energy` | number | Energy consumption | ❌ **NOT USED** |
| `properties.power` | number | Power consumption | ❌ **NOT USED** |
| `properties.temperature` | number | Temperature value | ❌ **NOT USED** |
| `properties.humidity` | number | Humidity value | ❌ **NOT USED** |
| `properties.illuminance` | number | Light level | ❌ **NOT USED** |
| `properties.deviceIcon` | number | Icon ID | ❌ **NOT USED** |

### Device Types Found in Logs

| Fibaro Type | Fibaro baseType | Fibaro Role | Count | Current Mapping | Proposed Mapping |
|-------------|----------------|-------------|-------|----------------|-----------------|
| `com.fibaro.binarySwitch` | `com.fibaro.actor` | `Light` | ~100+ | SWITCH | **SWITCH** (correct) |
| `com.fibaro.multilevelSwitch` | `com.fibaro.binarySwitch` | `Light` | ~21 | DIMMER | **DIMMER** (correct) |
| `com.fibaro.rollerShutter` | `com.fibaro.baseShutter` | `BlindsWithPositioning` | ~18 | DIMMER ❌ | **BLIND** |
| `com.fibaro.FGR223` | `com.fibaro.FGR` | `BlindsWithPositioning` | ~6 | DIMMER ❌ | **BLIND** |
| `com.fibaro.heatDetector` | `com.fibaro.lifeDangerSensor` | `HeatDetector` | ~28 | GENERIC-SENSOR ❌ | **SMOKE-DETECTOR** |
| `com.fibaro.zwaveDevice` | `com.fibaro.device` | `Other` | ~50+ | SKIP | **SKIP** (correct - parent containers) |
| `com.fibaro.remoteController` | `com.fibaro.actor` | `Other` | ~36 | SKIP | **SKIP** (correct) |
| `com.fibaro.zigbeeDevice` | `com.fibaro.device` | `Other` | ~18 | SKIP | **SKIP** (correct) |
| `HC_user` | `com.fibaro.voipUser` | — | ~5 | SKIP | **SKIP** (correct) |
| `iOS_device` | — | — | ~12 | SKIP | **SKIP** (correct) |
| `com.fibaro.yrWeather` | `com.fibaro.weather` | `Other` | ~1 | SKIP | **SKIP** (correct) |
| `com.fibaro.niceEngine` | — | `Other` | ~1 | SKIP | **SKIP** (correct) |
| `com.fibaro.zwavePrimaryController` | — | `Other` | ~1 | SKIP | **SKIP** (correct) |
| `com.fibaro.zigbeePrimaryController` | — | `Other` | ~1 | SKIP | **SKIP** (correct) |

### Future Device Types (not in current logs but exist in Fibaro ecosystem)

| Fibaro Type | Fibaro Role | Proposed Mapping | ST Profile |
|-------------|-------------|-----------------|------------|
| `com.fibaro.temperatureSensor` | `Temperature` | TEMPERATURE-SENSOR | `fibaro-temperature-sensor` |
| `com.fibaro.humiditySensor` | `Humidity` | HUMIDITY-SENSOR | `fibaro-humidity-sensor` |
| `com.fibaro.lightSensor` | `Light` | ILLUMINANCE-SENSOR | `fibaro-illuminance-sensor` |
| `com.fibaro.doorSensor` | `Door` | CONTACT | `fibaro-contact` |
| `com.fibaro.windowSensor` | `Window` | CONTACT | `fibaro-contact` |
| `com.fibaro.doorWindowSensor` | `Door/Window` | CONTACT | `fibaro-contact` |
| `com.fibaro.motionSensor` | `Motion` | MOTION | `fibaro-motion` |
| `com.fibaro.floodSensor` | `Water` | WATER-SENSOR | `fibaro-water-sensor` |
| `com.fibaro.smokeSensor` | `Smoke` | SMOKE-DETECTOR | `fibaro-smoke-detector` |

---

## Proposed New Mapping Logic

### Phase 1: Skip only non-physical-device types (narrowed)

Only skip devices that are truly not physical devices. **All other devices get at least a default card.**

```lua
-- Skip only system-level non-devices
if device.is_gateway then return nil, "controller device" end
if device.is_user then return nil, "user device" end
if device.is_plugin then return nil, "plugin or virtual device" end
-- NOTE: disabled devices are NOT skipped — they still get a default card
-- NOTE: devices with no matching type are NOT skipped — they get a default card
```

### Phase 2: Multi-attribute device type mapping (NEW)

Instead of checking actions first, check the **most specific combination** of type + role + interfaces first:

```lua
-- Mapping decision table (checked in order, first match wins)
-- Each entry: { match_fn, kind, profile, label }

local MAPPING_RULES = {
  -- 1. BLINDS: type or role indicates window covering
  {
    match = function(d)
      return contains(d.type, "rollerShutter")
        or contains(d.type, "FGR") 
        or contains(d.base_type, "baseShutter")
        or contains(d.role, "BlindsWithPositioning")
        or contains(d.role, "Blind")
        or has_interface(d.interfaces, "windowCovering")
    end,
    kind = "blind",
    profile = "fibaro-blind",
    label = "BLIND (type/role/interface match)"
  },

  -- 2. SMOKE/HEAT DETECTOR: type or role indicates smoke/heat
  {
    match = function(d)
      return contains(d.type, "smokeSensor")
        or contains(d.type, "heatDetector")
        or contains(d.base_type, "lifeDangerSensor")
        or contains(d.role, "Smoke")
        or contains(d.role, "HeatDetector")
        or has_interface(d.interfaces, "smokeDetector")
    end,
    kind = "smoke-detector",
    profile = "fibaro-smoke-detector",
    label = "SMOKE-DETECTOR (type/role/interface match)"
  },

  -- 3. MOTION SENSOR: type or role or interface indicates motion
  {
    match = function(d)
      return contains(d.type, "motionSensor")
        or contains(d.base_type, "motionSensor")
        or contains(d.role, "Motion")
        or has_interface(d.interfaces, "motionSensor")
    end,
    kind = "motion",
    profile = "fibaro-motion",
    label = "MOTION (type/role/interface match)"
  },

  -- 4. CONTACT SENSOR: type or role or interface indicates door/window/contact
  {
    match = function(d)
      return contains(d.type, "doorSensor")
        or contains(d.type, "windowSensor")
        or contains(d.type, "doorWindowSensor")
        or contains(d.base_type, "doorSensor")
        or contains(d.base_type, "windowSensor")
        or contains(d.role, "Door")
        or contains(d.role, "Window")
        or has_interface(d.interfaces, "contactSensor")
        or has_interface(d.interfaces, "doorWindowSensor")
    end,
    kind = "contact",
    profile = "fibaro-contact",
    label = "CONTACT (type/role/interface match)"
  },

  -- 5. TEMPERATURE SENSOR: type or role or properties indicate temperature
  {
    match = function(d)
      return contains(d.type, "temperatureSensor")
        or contains(d.role, "Temperature")
        or has_interface(d.interfaces, "temperatureSensor")
        or (d.properties and d.properties.temperature ~= nil and not has_action(d.actions, "setValue"))
    end,
    kind = "temperature-sensor",
    profile = "fibaro-temperature-sensor",
    label = "TEMPERATURE-SENSOR (type/role/property match)"
  },

  -- 6. HUMIDITY SENSOR: type or role or properties indicate humidity
  {
    match = function(d)
      return contains(d.type, "humiditySensor")
        or contains(d.role, "Humidity")
        or has_interface(d.interfaces, "humiditySensor")
        or (d.properties and d.properties.humidity ~= nil and not has_action(d.actions, "setValue"))
    end,
    kind = "humidity-sensor",
    profile = "fibaro-humidity-sensor",
    label = "HUMIDITY-SENSOR (type/role/property match)"
  },

  -- 7. ILLUMINANCE SENSOR: type or role or properties indicate light level
  {
    match = function(d)
      return contains(d.type, "lightSensor")
        or contains(d.role, "LightSensor")
        or has_interface(d.interfaces, "lightSensor")
        or (d.properties and d.properties.illuminance ~= nil and not has_action(d.actions, "setValue"))
    end,
    kind = "illuminance-sensor",
    profile = "fibaro-illuminance-sensor",
    label = "ILLUMINANCE-SENSOR (type/role/property match)"
  },

  -- 8. WATER/LEAK SENSOR: type or role or interface indicates water
  {
    match = function(d)
      return contains(d.type, "floodSensor")
        or contains(d.type, "waterSensor")
        or contains(d.role, "Water")
        or contains(d.role, "Flood")
        or has_interface(d.interfaces, "waterSensor")
        or has_interface(d.interfaces, "floodSensor")
    end,
    kind = "water-sensor",
    profile = "fibaro-water-sensor",
    label = "WATER-SENSOR (type/role/interface match)"
  },

  -- 9. DIMMER: has setValue action AND role=Light (not blinds, which are caught above)
  {
    match = function(d)
      return has_action(d.actions, "setValue")
    end,
    kind = "dimmer",
    profile = "fibaro-dimmer",
    label = "DIMMER (has setValue action)"
  },

  -- 10. SWITCH: has turnOn/turnOff actions
  {
    match = function(d)
      return has_action(d.actions, "turnOn") and has_action(d.actions, "turnOff")
    end,
    kind = "switch",
    profile = "fibaro-switch",
    label = "SWITCH (has turnOn/turnOff actions)"
  },

  -- 11. GENERIC SENSOR: has value property but no actionable type
  {
    match = function(d)
      return has_value(d)
    end,
    kind = "generic-sensor",
    profile = "fibaro-generic-sensor",
    label = "GENERIC-SENSOR (has value property)"
  },
}
```

**Key change**: Blinds, smoke detectors, and sensors are now checked BEFORE actions (setValue/turnOn/turnOff). This ensures that a `rollerShutter` with `setValue` gets mapped as BLIND, not DIMMER.

---

## Files to Change

### 1. NEW: `profiles/fibaro-blind.yml`

```yaml
name: fibaro-blind
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
      - name: Blinds
```

**SmartThings capabilities used:**
- `windowShade` — commands: `open()`, `close()`, events: `open`, `closed`, `partiallyOpen`, `unknown`
- `windowShadeLevel` — commands: `setShadeLevel(level)`, events: `shadeLevel` (0-100)

### 2. NEW: `profiles/fibaro-smoke-detector.yml`

```yaml
name: fibaro-smoke-detector
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

**SmartThings capabilities used:**
- `smokeDetector` — events: `clear`, `detected`, `tested`

### 3. NEW: `profiles/fibaro-temperature-sensor.yml`

```yaml
name: fibaro-temperature-sensor
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

**SmartThings capabilities used:**
- `temperatureMeasurement` — events: `temperature` (value in °C or °F)

### 4. NEW: `profiles/fibaro-humidity-sensor.yml`

```yaml
name: fibaro-humidity-sensor
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

### 5. NEW: `profiles/fibaro-illuminance-sensor.yml`

```yaml
name: fibaro-illuminance-sensor
components:
  - id: main
    capabilities:
      - id: illuminanceMeasurement
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: IlluminanceSensor
```

### 6. NEW: `profiles/fibaro-water-sensor.yml`

```yaml
name: fibaro-water-sensor
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

### 7. NEW: `profiles/fibaro-default.yml` (DEFAULT CARD for unmatched devices)

**Key design principle: No device is ever skipped.** If a device doesn't match any specific type, it gets a default card that shows its name, type, and current value. This ensures visibility of ALL Fibaro devices in SmartThings.

```yaml
name: fibaro-default
components:
  - id: main
    capabilities:
      - id: sensor
        version: 1
      - id: refresh
        version: 1
    categories:
      - name: Other
```

**SmartThings capabilities used:**
- `sensor` — generic sensor capability, events: `sensor` (string value)
- `refresh` — manual refresh capability

This profile acts as a catch-all. Every device from Fibaro will appear in SmartThings, even if we don't have a specific profile for its type. The `sensor` capability allows displaying the device's current value as a string.

### 8. MODIFY: `src/fibaro/mapper.lua`

**Current flow:**
```
skip checks → has setValue? → DIMMER → has turnOn/Off? → SWITCH → motion? → contact? → has value? → GENERIC → skip
```

**New flow:**
```
skip checks → blind? → smoke? → motion? → contact? → temp? → humidity? → illuminance? → water? → has setValue? → DIMMER → has turnOn/Off? → SWITCH → has value? → GENERIC → skip
```

**Full new mapper.lua:**

```lua
local log = require "log"
local utils = require "utils"

local mapper = {}

local function has_action(actions, action_name)
  return type(actions) == "table" and actions[action_name] ~= nil
end

local function has_interface(interfaces, needle)
  if type(interfaces) ~= "table" then
    return false
  end
  for _, value in ipairs(interfaces) do
    if tostring(value) == needle then
      return true
    end
  end
  return false
end

local function has_value(device)
  return type(device) == "table" and device.value ~= nil
end

local function contains(haystack, needle)
  return tostring(haystack or ""):find(needle, 1, true) ~= nil
end

-- Multi-attribute mapping rules table
-- Checked in order; first match wins.
-- More specific rules (type+role combinations) must come BEFORE generic action-based rules.
local MAPPING_RULES = {
  -- 1. BLINDS / WINDOW COVERINGS
  {
    match = function(d)
      return contains(d.type, "rollerShutter")
        or contains(d.type, "FGR")
        or contains(d.base_type, "baseShutter")
        or contains(d.role, "BlindsWithPositioning")
        or contains(d.role, "Blind")
        or has_interface(d.interfaces, "windowCovering")
    end,
    kind = "blind",
    profile = "fibaro-blind",
    reason = "BLIND (type/role/interface match)"
  },

  -- 2. SMOKE / HEAT DETECTOR
  {
    match = function(d)
      return contains(d.type, "smokeSensor")
        or contains(d.type, "heatDetector")
        or contains(d.base_type, "lifeDangerSensor")
        or contains(d.role, "Smoke")
        or contains(d.role, "HeatDetector")
        or has_interface(d.interfaces, "smokeDetector")
    end,
    kind = "smoke-detector",
    profile = "fibaro-smoke-detector",
    reason = "SMOKE-DETECTOR (type/role/interface match)"
  },

  -- 3. MOTION SENSOR
  {
    match = function(d)
      return contains(d.type, "motionSensor")
        or contains(d.base_type, "motionSensor")
        or contains(d.role, "Motion")
        or has_interface(d.interfaces, "motionSensor")
    end,
    kind = "motion",
    profile = "fibaro-motion",
    reason = "MOTION (type/role/interface match)"
  },

  -- 4. CONTACT SENSOR (door/window)
  {
    match = function(d)
      return contains(d.type, "doorSensor")
        or contains(d.type, "windowSensor")
        or contains(d.type, "doorWindowSensor")
        or contains(d.base_type, "doorSensor")
        or contains(d.base_type, "windowSensor")
        or contains(d.role, "Door")
        or contains(d.role, "Window")
        or has_interface(d.interfaces, "contactSensor")
        or has_interface(d.interfaces, "doorWindowSensor")
    end,
    kind = "contact",
    profile = "fibaro-contact",
    reason = "CONTACT (type/role/interface match)"
  },

  -- 5. TEMPERATURE SENSOR
  {
    match = function(d)
      return contains(d.type, "temperatureSensor")
        or contains(d.role, "Temperature")
        or has_interface(d.interfaces, "temperatureSensor")
    end,
    kind = "temperature-sensor",
    profile = "fibaro-temperature-sensor",
    reason = "TEMPERATURE-SENSOR (type/role/interface match)"
  },

  -- 6. HUMIDITY SENSOR
  {
    match = function(d)
      return contains(d.type, "humiditySensor")
        or contains(d.role, "Humidity")
        or has_interface(d.interfaces, "humiditySensor")
    end,
    kind = "humidity-sensor",
    profile = "fibaro-humidity-sensor",
    reason = "HUMIDITY-SENSOR (type/role/interface match)"
  },

  -- 7. ILLUMINANCE / LIGHT SENSOR
  {
    match = function(d)
      return contains(d.type, "lightSensor")
        or contains(d.role, "LightSensor")
        or has_interface(d.interfaces, "lightSensor")
    end,
    kind = "illuminance-sensor",
    profile = "fibaro-illuminance-sensor",
    reason = "ILLUMINANCE-SENSOR (type/role/interface match)"
  },

  -- 8. WATER / FLOOD SENSOR
  {
    match = function(d)
      return contains(d.type, "floodSensor")
        or contains(d.type, "waterSensor")
        or contains(d.role, "Water")
        or contains(d.role, "Flood")
        or has_interface(d.interfaces, "waterSensor")
        or has_interface(d.interfaces, "floodSensor")
    end,
    kind = "water-sensor",
    profile = "fibaro-water-sensor",
    reason = "WATER-SENSOR (type/role/interface match)"
  },

  -- 9. DIMMER (has setValue action - checked AFTER specific types above)
  {
    match = function(d)
      return has_action(d.actions, "setValue")
    end,
    kind = "dimmer",
    profile = "fibaro-dimmer",
    reason = "DIMMER (has setValue action)"
  },

  -- 10. SWITCH (has turnOn/turnOff actions)
  {
    match = function(d)
      return has_action(d.actions, "turnOn") and has_action(d.actions, "turnOff")
    end,
    kind = "switch",
    profile = "fibaro-switch",
    reason = "SWITCH (has turnOn/turnOff actions)"
  },

  -- 11. GENERIC SENSOR (has value but no actionable type)
  {
    match = function(d)
      return has_value(d)
    end,
    kind = "generic-sensor",
    profile = "fibaro-generic-sensor",
    reason = "GENERIC-SENSOR (has value property)"
  },
}

function mapper.map_device(device)
  if type(device) ~= "table" or device.id == nil then
    log.info_with({hub_logs = true}, "[Fibaro] map_device: invalid device payload")
    return nil, "invalid device payload"
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] map_device: id=%s, name=%s, type=%s, base_type=%s, role=%s",
    tostring(device.id),
    tostring(device.label),
    tostring(device.type),
    tostring(device.base_type),
    tostring(device.device_role)
  ))

  -- Skip non-device types
  if device.is_gateway then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is a gateway/controller, skipping", tostring(device.id)))
    return nil, "controller device"
  end

  if device.is_user then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is a user device, skipping", tostring(device.id)))
    return nil, "user device"
  end

  if device.is_plugin then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is a plugin/virtual device, skipping", tostring(device.id)))
    return nil, "plugin or virtual device"
  end

  if device.enabled == false then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is disabled, skipping", tostring(device.id)))
    return nil, "disabled device"
  end

  -- Prepare normalized attributes for matching
  local actions = device.actions or {}
  local device_type = tostring(device.type or "")
  local base_type = tostring(device.base_type or "")
  local device_role = tostring(device.device_role or "")
  local interfaces = device.interfaces or {}
  local label = device.label or ("Fibaro Device " .. tostring(device.id))

  local match_context = {
    type = device_type,
    base_type = base_type,
    role = device_role,
    actions = actions,
    interfaces = interfaces,
    value = device.value,
  }

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Device %s: type=%s, base_type=%s, role=%s, actions=%s, interfaces=%s, value=%s",
    tostring(device.id),
    device_type,
    base_type,
    device_role,
    tostring(actions),
    tostring(interfaces),
    tostring(device.value)
  ))

  -- Apply mapping rules in order
  for _, rule in ipairs(MAPPING_RULES) do
    if rule.match(match_context) then
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] Device %s mapped as %s", tostring(device.id), rule.reason))
      return {
        id = device.id,
        key = utils.child_key_for_id(device.id),
        kind = rule.kind,
        profile = rule.profile,
        label = label,
        type = device_type,
        raw = device,
      }
    end
  end

  -- DEFAULT: No specific rule matched — give device a default card instead of skipping
  -- This ensures ALL Fibaro devices are visible in SmartThings, even unrecognized types.
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Device %s mapped as DEFAULT (no specific rule matched, type=%s)", tostring(device.id), device_type))
  return {
    id = device.id,
    key = utils.child_key_for_id(device.id),
    kind = "default",
    profile = "fibaro-default",
    label = label,
    type = device_type,
    raw = device,
  }
end

return mapper
```

### 8. MODIFY: `src/handlers/commands.lua`

Add new command handlers for blind and smoke-detector device kinds:

```lua
-- Add at top with other requires (no new requires needed)

-- Add after emit_optimistic_level function:

local function emit_optimistic_window_shade(device, shade_level)
  local scaled = utils.clamp(math.floor(shade_level + 0.5), 0, 99)
  if scaled == 0 then
    device:emit_event(capabilities.windowShade.windowShade.closed())
  elseif scaled >= 99 then
    device:emit_event(capabilities.windowShade.windowShade.open())
  else
    device:emit_event(capabilities.windowShade.windowShade.partiallyOpen())
  end
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(scaled))
end

-- New command handlers:

function commands.window_shade_open(driver, device)
  log.info_with({hub_logs = true}, string.format("[Fibaro] window_shade_open for device: %s", device.label))
  if not utils.is_bridge(device) and device:get_field(fields.HC2_DEVICE_KIND) == "blind" then
    emit_optimistic_window_shade(device, 99)
  end
  local ok, err = sync.execute_child_action(driver, device, "setValue", { 99 })
  if not ok and err then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Blind open failed for %s: %s", device.label, tostring(err)))
  end
end

function commands.window_shade_close(driver, device)
  log.info_with({hub_logs = true}, string.format("[Fibaro] window_shade_close for device: %s", device.label))
  if not utils.is_bridge(device) and device:get_field(fields.HC2_DEVICE_KIND) == "blind" then
    emit_optimistic_window_shade(device, 0)
  end
  local ok, err = sync.execute_child_action(driver, device, "setValue", { 0 })
  if not ok and err then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Blind close failed for %s: %s", device.label, tostring(err)))
  end
end

function commands.set_shade_level(driver, device, cmd)
  local level = cmd.args.shadeLevel or 0
  local scaled = utils.clamp(math.floor(level + 0.5), 0, 99)
  log.info_with({hub_logs = true}, string.format("[Fibaro] set_shade_level for device: %s, level=%d, scaled=%d", device.label, level, scaled))
  if not utils.is_bridge(device) and device:get_field(fields.HC2_DEVICE_KIND) == "blind" then
    emit_optimistic_window_shade(device, scaled)
  end
  local ok, err = sync.execute_child_action(driver, device, "setValue", { scaled })
  if not ok and err then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Set shade level failed for %s: %s", device.label, tostring(err)))
  end
end

-- Update capability_handlers table:
commands.capability_handlers = {
  [capabilities.refresh.ID] = {
    [capabilities.refresh.commands.refresh.NAME] = commands.do_refresh,
  },
  [capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME] = commands.switch_on,
    [capabilities.switch.commands.off.NAME] = commands.switch_off,
  },
  [capabilities.switchLevel.ID] = {
    [capabilities.switchLevel.commands.setLevel.NAME] = commands.set_level,
  },
  [capabilities.windowShade.ID] = {
    [capabilities.windowShade.commands.open.NAME] = commands.window_shade_open,
    [capabilities.windowShade.commands.close.NAME] = commands.window_shade_close,
  },
  [capabilities.windowShadeLevel.ID] = {
    [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = commands.set_shade_level,
  },
}
```

### 9. MODIFY: `src/init.lua`

Register new capability handlers in the driver template:

```lua
-- Add to capability_handlers in the driver template:
-- (existing handlers remain)
[capabilities.windowShade.ID] = commands.capability_handlers[capabilities.windowShade.ID],
[capabilities.windowShadeLevel.ID] = commands.capability_handlers[capabilities.windowShadeLevel.ID],
```

### 10. MODIFY: `src/fibaro/sync.lua`

Add state emission logic for new device kinds in the `emit_state` or equivalent function:

```lua
-- In the function that emits state events for child devices, add:

-- For blind devices:
if kind == "blind" then
  local level = utils.safe_tonumber(device.value) or 0
  if level == 0 then
    child:emit_event(capabilities.windowShade.windowShade.closed())
  elseif level >= 99 then
    child:emit_event(capabilities.windowShade.windowShade.open())
  else
    child:emit_event(capabilities.windowShade.windowShade.partiallyOpen())
  end
  child:emit_event(capabilities.windowShadeLevel.shadeLevel(level))
end

-- For smoke-detector devices:
if kind == "smoke-detector" then
  if device.value == true then
    child:emit_event(capabilities.smokeDetector.smoke.detected())
  else
    child:emit_event(capabilities.smokeDetector.smoke.clear())
  end
end

-- For temperature-sensor devices:
if kind == "temperature-sensor" then
  local temp = utils.safe_tonumber(device.value)
  if temp ~= nil then
    child:emit_event(capabilities.temperatureMeasurement.temperature({value = temp, unit = "C"}))
  end
end

-- For humidity-sensor devices:
if kind == "humidity-sensor" then
  local humidity = utils.safe_tonumber(device.value)
  if humidity ~= nil then
    child:emit_event(capabilities.relativeHumidityMeasurement.humidity(humidity))
  end
end

-- For illuminance-sensor devices:
if kind == "illuminance-sensor" then
  local lux = utils.safe_tonumber(device.value)
  if lux ~= nil then
    child:emit_event(capabilities.illuminanceMeasurement.illuminance(lux))
  end
end

-- For water-sensor devices:
if kind == "water-sensor" then
  if device.value == true then
    child:emit_event(capabilities.waterSensor.water.wet())
  else
    child:emit_event(capabilities.waterSensor.water.dry())
  end
end

-- For default/unmatched devices:
if kind == "default" then
  -- Display the device's current value as a generic sensor string
  local val = device.value
  if val ~= nil then
    child:emit_event(capabilities.sensor.sensor(tostring(val)))
  end
end
```

---

## Impact Analysis: Current Logs vs New Mapping

### Devices that CHANGE mapping

| Fibaro ID | Name | Type | Role | Current → New | Impact |
|-----------|------|------|------|---------------|--------|
| 28 | 27.0 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 30 | LEFT SIDE CURTAIN | FGR223 | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 31 | 27.2 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 33 | 32.0 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 35 | LEFT SIDE SHEER | FGR223 | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 36 | 32.2 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 38 | 37.0 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 40 | RIGHT SIDE SHEER | FGR223 | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 41 | 37.2 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 43 | 42.0 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 45 | RIGHT SIDE CURTAIN | FGR223 | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 46 | 42.2 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 48 | 47.0 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 50 | BACK SIDE SHEER | FGR223 | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 51 | 47.2 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 53 | 52.0 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 55 | BACK SIDE CURTAIN | FGR223 | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 56 | 52.2 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 241 | 240.0 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 243 | CURTAIN | FGR223 | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 244 | 240.2 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 403 | 287.0 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 405 | CURTAIN | FGR223 | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 406 | 287.2 | rollerShutter | BlindsWithPositioning | DIMMER → **BLIND** | ✅ Correct |
| 60 | 57.0.2 | heatDetector | HeatDetector | GENERIC-SENSOR → **SMOKE-DETECTOR** | ✅ Correct |
| 84 | 81.0.2 | heatDetector | HeatDetector | GENERIC-SENSOR → **SMOKE-DETECTOR** | ✅ Correct |
| *(+26 more heat detectors)* | | | | | |

### Devices that STAY the same (specific mapping matched)

| Type | Role | Current | New | Change? |
|------|------|---------|-----|---------|
| binarySwitch | Light | SWITCH | SWITCH | ❌ No change |
| multilevelSwitch | Light | DIMMER | DIMMER | ❌ No change |

### Devices that NOW GET A DEFAULT CARD (previously skipped)

| Type | Role | Current | New | Impact |
|------|------|---------|-----|--------|
| zwaveDevice | Other | SKIP | **DEFAULT** | ✅ Now visible as "Other" card |
| remoteController | Other | SKIP | **DEFAULT** | ✅ Now visible as "Other" card |
| zigbeeDevice | Other | SKIP | **DEFAULT** | ✅ Now visible as "Other" card |
| iOS_device | — | SKIP | **DEFAULT** | ✅ Now visible as "Other" card |
| niceEngine | Other | SKIP | **DEFAULT** | ✅ Now visible as "Other" card |
| yrWeather | Other | SKIP | **DEFAULT** | ✅ Now visible as "Other" card |

### Devices still correctly SKIPPED (non-physical)

| Type | Reason | Change? |
|------|--------|---------|
| HC_user / VOIP_user | User account, not a device | ❌ Still skipped |
| zwavePrimaryController | Z-Wave controller | ❌ Still skipped |
| zigbeePrimaryController | Zigbee controller | ❌ Still skipped |

---

## Summary of All Changes

| # | File | Action | Description |
|---|------|--------|-------------|
| 1 | `profiles/fibaro-blind.yml` | **NEW** | Window shade profile with `windowShade` + `windowShadeLevel` capabilities |
| 2 | `profiles/fibaro-smoke-detector.yml` | **NEW** | Smoke detector profile with `smokeDetector` capability |
| 3 | `profiles/fibaro-temperature-sensor.yml` | **NEW** | Temperature sensor profile with `temperatureMeasurement` capability |
| 4 | `profiles/fibaro-humidity-sensor.yml` | **NEW** | Humidity sensor profile with `relativeHumidityMeasurement` capability |
| 5 | `profiles/fibaro-illuminance-sensor.yml` | **NEW** | Light sensor profile with `illuminanceMeasurement` capability |
| 6 | `profiles/fibaro-water-sensor.yml` | **NEW** | Water/leak sensor profile with `waterSensor` capability |
| 7 | `profiles/fibaro-default.yml` | **NEW** | Default catch-all profile with `sensor` + `refresh` capabilities — ensures NO device is ever skipped |
| 8 | `src/fibaro/mapper.lua` | **MODIFY** | Replace single-attribute priority chain with multi-attribute MAPPING_RULES table; check type/role/interface BEFORE actions; **default card fallback instead of skip** |
| 8 | `src/handlers/commands.lua` | **MODIFY** | Add `window_shade_open`, `window_shade_close`, `set_shade_level` handlers; register in `capability_handlers` |
| 9 | `src/init.lua` | **MODIFY** | Register `windowShade` and `windowShadeLevel` capability handlers |
| 10 | `src/fibaro/sync.lua` | **MODIFY** | Add state emission logic for blind, smoke-detector, temperature-sensor, humidity-sensor, illuminance-sensor, water-sensor device kinds |

---

## Testing Plan

1. **Deploy updated driver** to SmartThings hub
2. **Verify blind devices** (IDs 28, 30, 31, 33, etc.) appear as "Blinds" in SmartThings app with open/close/setLevel controls
3. **Verify smoke detectors** (IDs 60, 84, 90, etc.) appear as "Smoke Detector" with detected/clear state
4. **Verify existing switches/dimmers** still work correctly (no regression)
5. **Verify skipped devices** still skipped correctly
6. **Test blind commands**: open, close, setShadeLevel via SmartThings app → verify Fibaro API calls
7. **Test state sync**: Change blind position in Fibaro → verify SmartThings state updates
8. **Test smoke detector state**: Trigger/clear alarm in Fibaro → verify SmartThings state updates
