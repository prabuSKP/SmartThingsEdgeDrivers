---
name: hub-profile-mapping
description: >
  Map 3rd-party hub device types to SmartThings device profiles using a multi-attribute
  matching engine. Covers the 4-group priority system (Interfaces → Multi-endpoint →
  Type/Role → Actions), helper functions for attribute matching, multi-channel Z-Wave
  endpoint filtering, room name prefixing, default card fallback, and complete mapping
  rule table structure. Use when building the mapper.lua module for a hub bridge driver.
---

# Hub Device → SmartThings Profile Mapping

The mapper is the brain of a hub bridge driver. It examines each device from the 3rd-party
hub and decides: (1) should this device become a SmartThings child device? (2) which
SmartThings profile should it use?

## Mapping Design Principles

1. **Use ALL available attributes** — `type`, `baseType`, `deviceRole`, `actions`, `interfaces`, `properties`
2. **Most specific match wins** — check interfaces first, then type/role, then actions
3. **Never skip a device silently** — use a default card fallback for unrecognized types
4. **Role-aware mapping** — differentiate devices of same type but different roles
5. **Multi-channel awareness** — filter duplicate Z-Wave endpoints
6. **Profile names must exist** — every `profile` returned by `mapper.map_device()` must match a `name:` in `profiles/*.yml`

## Profile Name Contract

Pick one prefix per generated driver, usually the vendor or package key, and use it everywhere. Replace `vendor` in these examples with the actual integration prefix, such as `fibaro`, `hubitat`, `homeassistant`, or `openhab`.

| Kind | Profile name |
|---|---|
| Bridge | `vendor-bridge` |
| Switch | `vendor-switch` |
| Dimmer | `vendor-dimmer` |
| Blind | `vendor-blind` |
| Contact | `vendor-contact` |
| Motion | `vendor-motion` |
| Temperature | `vendor-temperature-sensor` |
| Humidity | `vendor-humidity-sensor` |
| Illuminance | `vendor-illuminance-sensor` |
| Water | `vendor-water-sensor` |
| Smoke | `vendor-smoke-detector` |
| Default | `vendor-default` |

Do not mix placeholder names like `my-switch`, generic names like `switch`, and prefixed names like `vendor-switch` in the same generated driver. If the mapper returns `vendor-switch`, the generated profile must contain `name: vendor-switch`.

## 4-Group Priority System

```
GROUP 1: Interface-based matching     (highest priority)
    ↓ no match
GROUP 2: Multi-endpoint matching
    ↓ no match
GROUP 3: Type/Role-based matching
    ↓ no match
GROUP 4: Action-based matching        (lowest priority — fallback)
    ↓ no match
DEFAULT: Catch-all card
```

## Helper Functions

```lua
local function has_action(actions, action_name)
  return type(actions) == "table" and actions[action_name] ~= nil
end

local function has_interface(interfaces, needle)
  if type(interfaces) ~= "table" then return false end
  for _, value in ipairs(interfaces) do
    if tostring(value) == needle then return true end
  end
  return false
end

local function has_value(device)
  return type(device) == "table" and device.value ~= nil
end

local function contains(haystack, needle)
  return tostring(haystack or ""):find(needle, 1, true) ~= nil
end
```

## Mapping Rules Table

Each rule is a table with `match`, `kind`, `profile`, and `reason` fields.
Rules are checked in order; first match wins.

```lua
local MAPPING_RULES = {
  -- =========================================================================
  -- GROUP 1: INTERFACE-BASED MATCHING (Highest Priority)
  -- =========================================================================

  {
    match = function(d)
      return has_interface(d.interfaces, "windowCovering")
    end,
    kind = "blind",
    profile = "vendor-blind",
    reason = "BLIND (interface: windowCovering)"
  },
  {
    match = function(d)
      return has_interface(d.interfaces, "smokeDetector")
    end,
    kind = "smoke-detector",
    profile = "vendor-smoke-detector",
    reason = "SMOKE-DETECTOR (interface: smokeDetector)"
  },
  {
    match = function(d)
      return has_interface(d.interfaces, "motionSensor")
    end,
    kind = "motion",
    profile = "vendor-motion",
    reason = "MOTION (interface: motionSensor)"
  },
  {
    match = function(d)
      return has_interface(d.interfaces, "contactSensor")
        or has_interface(d.interfaces, "doorWindowSensor")
    end,
    kind = "contact",
    profile = "vendor-contact",
    reason = "CONTACT (interface: contactSensor)"
  },
  {
    match = function(d)
      return has_interface(d.interfaces, "temperatureSensor")
    end,
    kind = "temperature-sensor",
    profile = "vendor-temperature-sensor",
    reason = "TEMPERATURE-SENSOR (interface)"
  },
  {
    match = function(d)
      return has_interface(d.interfaces, "humiditySensor")
    end,
    kind = "humidity-sensor",
    profile = "vendor-humidity-sensor",
    reason = "HUMIDITY-SENSOR (interface)"
  },
  {
    match = function(d)
      return has_interface(d.interfaces, "lightSensor")
    end,
    kind = "illuminance-sensor",
    profile = "vendor-illuminance-sensor",
    reason = "ILLUMINANCE-SENSOR (interface)"
  },
  {
    match = function(d)
      return has_interface(d.interfaces, "waterSensor")
        or has_interface(d.interfaces, "floodSensor")
    end,
    kind = "water-sensor",
    profile = "vendor-water-sensor",
    reason = "WATER-SENSOR (interface)"
  },

  -- =========================================================================
  -- GROUP 2: MULTI-ENDPOINT MATCHING
  -- =========================================================================

  -- Double switch (2 relay endpoints)
  {
    match = function(d)
      return d.is_multi_endpoint and #d.endpoints == 3
    end,
    kind = "double-switch",
    profile = "vendor-double-switch",
    reason = "DOUBLE-SWITCH (multi-endpoint: 2 relays)"
  },

  -- =========================================================================
  -- GROUP 3: TYPE/ROLE-BASED MATCHING
  -- =========================================================================

  {
    match = function(d)
      return contains(d.type, "rollerShutter")
        or contains(d.type, "FGR")
        or contains(d.base_type, "baseShutter")
        or contains(d.role, "BlindsWithPositioning")
    end,
    kind = "blind",
    profile = "vendor-blind",
    reason = "BLIND (type/role match)"
  },
  -- Add more type/role rules as needed...

  -- =========================================================================
  -- GROUP 4: ACTION-BASED MATCHING (Fallback)
  -- =========================================================================

  {
    match = function(d)
      return has_action(d.actions, "setValue")
    end,
    kind = "dimmer",
    profile = "vendor-dimmer",
    reason = "DIMMER (action: setValue)"
  },
  {
    match = function(d)
      return has_action(d.actions, "turnOn")
        and has_action(d.actions, "turnOff")
    end,
    kind = "switch",
    profile = "vendor-switch",
    reason = "SWITCH (actions: turnOn/turnOff)"
  },
  {
    match = function(d)
      return has_value(d)
    end,
    kind = "generic-sensor",
    profile = "vendor-default",
    reason = "GENERIC-SENSOR (has value property)"
  },
}
```

## Skip Filters (Before Mapping)

Filter out non-physical-device types before applying mapping rules:

```lua
function mapper.map_device(device, rooms, parent_has_named_sibling)
  -- Skip non-device types
  if device.is_gateway then return nil, "controller device" end
  if device.is_user then return nil, "user device" end
  if device.is_plugin then return nil, "plugin/virtual device" end
  if device.enabled == false then return nil, "disabled device" end

  -- Skip system device types
  if contains(device.type, "iOS_device") then return nil, "mobile device" end
  if contains(device.type, "remoteController") then return nil, "remote controller" end

  -- Skip Z-Wave/Zigbee parent containers (they have no controls)
  if contains(device.type, "zwaveDevice")
    or contains(device.type, "zigbeeDevice") then
    return nil, "container device"
  end

  -- Skip unnamed multi-channel endpoints when named siblings exist
  local label = device.label or ""
  if device.parent_id > 1 and parent_has_named_sibling then
    if label:match("^%d+%.%d+$") or label:match("^%d+%.%d+%.%d+$") then
      return nil, "unnamed endpoint with named sibling"
    end
  end

  -- ... proceed to mapping rules
end
```

## Multi-Channel Endpoint Filtering

Z-Wave multi-channel devices create a hierarchy:

```
Parent 37 (zwaveDevice, parentId=1)           → SKIP (container)
  ├── Child 38 (rollerShutter, name="37.0")   → SKIP (unnamed, has named sibling)
  ├── Child 39 (remoteController, name="37.0.1") → SKIP (remote controller)
  ├── Child 40 (FGR223, name="RIGHT SIDE SHEER")  → KEEP (named, controllable)
  └── Child 41 (rollerShutter, name="37.2")   → SKIP (unnamed, has named sibling)
```

**Pre-calculate named sibling sets** in the sync layer (single pass):

```lua
local parents_with_named_siblings = {}
for _, nd in ipairs(normalized_devices) do
  local parent_id = nd.parent_id or 0
  if parent_id > 1 then
    local is_unnamed = (nd.label or ""):match("^%d+%.%d+$")
      or (nd.label or ""):match("^%d+%.%d+%.%d+$")
    if not is_unnamed then
      parents_with_named_siblings[parent_id] = true
    end
  end
end
```

## Room Name Enrichment

Prefix device labels with room names for downstream tools:

```lua
local room_name = rooms[device.room_id] or ""
local label = device.label
if room_name ~= "" then
  -- Encode room_id in label for Python room assignment script
  label = string.format("[%s:%s] %s", room_name, tostring(device.room_id), device.label)
end
```

## Default Card Fallback

**Never skip a device.** If no mapping rule matches, create a default card:

```lua
-- After all MAPPING_RULES checked with no match:
return {
  id = device.id,
  key = child_key_for_id(device.id),
  kind = "default",
  profile = "vendor-default",
  label = label,
  type = device_type,
  raw = device,
}
```

## Return Value Structure

Each mapped device returns:

```lua
{
  id = 45,                          -- Hub device ID
  key = "vendor-45",                -- SmartThings child key (unique per bridge)
  kind = "switch",                  -- Device kind for command routing
  profile = "vendor-switch",        -- Must match a `name:` in profiles/*.yml
  label = "[Living Room:1] Light",  -- Display label
  type = "com.fibaro.binarySwitch", -- Original hub device type
  parent_id = 0,                    -- Hub parent device ID
  room_id = 1,                      -- Hub room ID
  room_name = "Living Room",        -- Hub room name
  raw = { ... },                    -- Full normalized device for state emission
}
```

## Adding New Device Types

To add support for a new device type:

1. **Create a new profile YAML** in `profiles/`
2. **Add a mapping rule** to `MAPPING_RULES` in the appropriate priority group
3. **Add state emission** in `emit_child_state()` (in `hub-event-sync` skill)
4. **Add command handlers** if the device is controllable (in `commands.lua`)
5. **Register capability handlers** in `init.lua`

## Required Mapper/Profile Self-Check

Before finalizing generated code, compare mapper outputs to profile names:

```bash
rg -n 'profile = "' src/vendor/mapper.lua
rg -n '^name:' profiles
```

Every profile name in mapper output must appear exactly once in `profiles/*.yml`. If a rule returns a profile that is not generated, either generate that profile or remove/disable the rule.
