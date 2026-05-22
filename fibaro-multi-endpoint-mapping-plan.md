# Fibaro Multi-Endpoint and Parent Container Mapping Implementation Plan

This document details the plan and logic used to filter out parent container devices and duplicate unnamed child endpoints from Fibaro Home Center integration.

## Problem Statement

The Fibaro Home Center represents Z-Wave and Zigbee multi-channel/multi-endpoint devices as a hierarchy consisting of a parent container and multiple child endpoints:

```
Device 37 (com.fibaro.zwaveDevice, parentId=1)     ← Parent container, NO controls
  ├── Device 38 (com.fibaro.rollerShutter, name="37.0")    ← Endpoint 0, unnamed duplicate
  ├── Device 39 (com.fibaro.remoteController, name="37.0.1") ← Skipped (handled separately)
  ├── Device 40 (com.fibaro.FGR223, name="RIGHT SIDE SHEER") ← Named, controllable device
  └── Device 41 (com.fibaro.rollerShutter, name="37.2")     ← Endpoint 2, unnamed duplicate
```

### Current Behavior
Previously, the SmartThings Edge Driver created separate device cards for:
1. **Parent Containers** (types matching `zwaveDevice` or `zigbeeDevice`), which have no physical values or controllable actions, causing empty cards mapped as `DEFAULT`.
2. **Unnamed Duplicate Endpoints** (names matching `<parentId>.<endpoint>` or `<parentId>.<endpoint>.<sub-endpoint>`), which duplicate physical controls already handled by named child devices.

### Desired Behavior
Only create SmartThings device cards for:
1. **Named controllable child devices** (e.g. `"RIGHT SIDE SHEER"`, `"LIGHT SWITCH 1"`).
2. **Unnamed child endpoints ONLY IF no named sibling exists** under the same parent (Option A). This ensures single-control parent devices (e.g., parent `287` with only child `287.0`) are not skipped.

---

## Log Analysis & Target Patterns

### Category A: Multi-channel Blinds/Rollers (e.g. FGR223)
* Parent `37` (type `zwaveDevice`, parentId `1`) → **SKIP**
* Child `38` (name `"37.0"`, parentId `37`) → **SKIP** (named sibling exists)
* Child `40` (name `"RIGHT SIDE SHEER"`, parentId `37`) → **KEEP**
* Child `41` (name `"37.2"`, parentId `37`) → **SKIP** (named sibling exists)

### Category B: Multi-switch Modules
* Parent `21` (type `zwaveDevice`, parentId `1`) → **SKIP**
* Child `22` (name `"21.0"`, parentId `21`) → **SKIP** (named siblings exist)
* Child `23` (name `"LIGHT SWICH 1"`, parentId `21`) → **KEEP**
* Child `24` (name `"LIGHT SWICH 2"`, parentId `21`) → **KEEP**
* Child `25` (name `"FAN SWICH"`, parentId `21`) → **KEEP**
* Child `26` (name `"CURTAIN SWICH"`, parentId `21`) → **KEEP**

### Category C: Unnamed Devices with No Named Sibling (Single-control)
* Parent `287` (type `zwaveDevice`, parentId `1`) → **SKIP**
* Child `403` (name `"287.0"`, parentId `287`) → **KEEP** (no named siblings exist under parent 287)

---

## Implementation Details

The filtering logic is divided between `sync.lua` (pre-calculating named sibling relationships) and `mapper.lua` (making individual device mapping decisions).

### 1. [mapper.lua](file:///home/test/EdgeClient/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/fibaro/mapper.lua)

#### Parent Container Skipping
Skip all devices where the type contains `zwaveDevice` or `zigbeeDevice`:
```lua
-- Skip Z-Wave/Zigbee parent container devices (they don't control anything)
if contains(device.type, "zwaveDevice") or contains(device.type, "zigbeeDevice") then
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Device %s is a Z-Wave/Zigbee container device, skipping", tostring(device.id)))
  return nil, "zwave/zigbee container device"
end
```

#### Unnamed Endpoint Filtering
Unnamed endpoint names are matched using regex pattern matches for `<parentId>.<endpoint>` (`^%d+%.%d+$`) or `<parentId>.<endpoint>.<sub-endpoint>` (`^%d+%.%d+%.%d+$`). If the parent has a named sibling, we skip:
```lua
-- Skip unnamed multi-channel endpoints (e.g. "37.0", "37.2", "81.0.2")
-- These are Z-Wave multi-channel endpoints that duplicate named sibling devices.
-- Only skip if the device has a named sibling under the same parent.
local raw_label = device.label or ""
local parent_id = device.parent_id or 0
if parent_id > 1 and parent_has_named_sibling then
  if raw_label:match("^%d+%.%d+$") or raw_label:match("^%d+%.%d+%.%d+$") then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Device %s ('%s') is an unnamed multi-channel endpoint (parentId=%s) with a named sibling, skipping",
      tostring(device.id), raw_label, tostring(parent_id)))
    return nil, "unnamed multi-channel endpoint"
  end
end
```

### 2. [sync.lua](file:///home/test/EdgeClient/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/fibaro/sync.lua)

#### Named Sibling Detection & Single-Pass Optimization
Instead of normalizing each device twice (which is computationally expensive and floods the hub logs with duplicated trace logs), the device list `discovered` is traversed once to build both the cached list of `normalized_devices` and the map of `parents_with_named_siblings`:

```lua
  local parents_with_named_siblings = {}
  local normalized_devices = {}
  for _, raw_device in ipairs(discovered) do
    local normalized_device = adapter.normalize_device(raw_device)
    table.insert(normalized_devices, normalized_device)
    local parent_id = normalized_device.parent_id or 0
    local raw_label = normalized_device.label or ""
    if parent_id > 1 then
      local is_unnamed = raw_label:match("^%d+%.%d+$") ~= nil or raw_label:match("^%d+%.%d+%.%d+$") ~= nil
      if not is_unnamed then
        parents_with_named_siblings[parent_id] = true
      end
    end
  end
```

Then, the second loop iterates over the pre-cached `normalized_devices`, checking `parents_with_named_siblings` and calling `mapper.map_device`:
```lua
  for _, normalized_device in ipairs(normalized_devices) do
    ...
    local parent_id = normalized_device.parent_id or 0
    local parent_has_named_sibling = parent_id > 1 and parents_with_named_siblings[parent_id] == true
    local mapped, map_err = mapper.map_device(normalized_device, rooms, parent_has_named_sibling)
    ...
  end
```

---

## Verification & Mapping Statistics

The logic was simulated against a complete list of 368 devices:
* **Total devices processed**: 368
* **Total kept**: 189
* **Total skipped**: 179
  * **Z-Wave / Zigbee parent containers skipped**: 69
  * **Unnamed duplicate endpoints skipped**: 68
  * **Remote controllers skipped**: 36
  * **User devices skipped**: 4
  * **Controller devices skipped**: 2

Single unnamed endpoints (like child device `403` under parent `287`) are correctly preserved since they do not have any named siblings.
