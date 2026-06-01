---
name: smartthings-child-devices
description: >
  Create and manage child devices in SmartThings Edge drivers. Covers the complete
  child device lifecycle: metadata caching in driver datastore, try_create_device
  with EDGE_CHILD type, pending metadata application in lifecycle handlers, child
  key generation, parent-child navigation, stale child cleanup, structured
  vendor_provided_label encoding for downstream tools, and child device field
  persistence. Use when building the child device management layer of a hub bridge
  Edge driver.
---

# SmartThings Child Device Management

Child devices are created by a bridge/gateway driver to represent individual devices
from a 3rd-party hub. They appear as separate devices in the SmartThings app but
are managed by the same Edge driver instance.

## Child Device Creation Flow

```
sync_bridge_inventory()
  │
  ├─ mapper.map_device(normalized) → mapped { key, kind, profile, label, ... }
  │
  ├─ Check: child already exists for key?
  │   ├── YES → update state via emit_child_state()
  │   └── NO  → 1. Cache metadata in datastore
  │             2. Call driver:try_create_device(metadata)
  │                    ↓
  │             SmartThings platform creates device
  │                    ↓
  │             lifecycle.added() fires
  │                    ↓
  │             lifecycle.init() fires
  │                    ↓
  │             3. Apply pending metadata from cache
```

## Child Key Generation

Each child device needs a unique key within its parent bridge. Use the hub device ID:

```lua
local function child_key_for_id(hub_device_id)
  return "fibaro-" .. tostring(hub_device_id)
end

local function device_id_from_child_key(child_key)
  local id = child_key:match("^fibaro%-(%d+)$")
  return id and tonumber(id) or nil
end
```

## Metadata Caching

Before calling `try_create_device`, cache the metadata so it can be applied in the
lifecycle handler:

```lua
local function cache_child_metadata(driver, bridge, mapped)
  driver.datastore.pending_child_data = driver.datastore.pending_child_data or {}

  local cache_key = bridge.device_network_id .. "|" .. mapped.key
  driver.datastore.pending_child_data[cache_key] = {
    bridge_dni = bridge.device_network_id,
    hc2_device_id = mapped.id,
    hc2_device_type = mapped.type,
    hc2_device_kind = mapped.kind,
    hc2_room_id = mapped.room_id or 0,
    hc2_room_name = mapped.room_name or "",
  }
end
```

## Creating a Child Device

```lua
local function ensure_child_device(driver, bridge, mapped, existing_child)
  -- If child already exists, just update its state
  if existing_child then
    emit_child_state(existing_child, mapped.raw, mapped.kind)
    return existing_child
  end

  -- Cache metadata for lifecycle handler
  cache_child_metadata(driver, bridge, mapped)

  -- Build structured vendor_provided_label
  local raw_label = type(mapped.raw) == "table"
    and tostring(mapped.raw.label or "")
    or ""

  local structured_vpl = string.format(
    "fibaro|roomId:%s|roomName:%s|label:%s",
    tostring(mapped.room_id or 0),
    tostring(mapped.room_name or ""),
    raw_label
  )

  -- Create the child device
  local metadata = {
    type = "EDGE_CHILD",
    label = mapped.label,
    profile = mapped.profile,
    manufacturer = "Fibaro",
    model = mapped.type ~= "" and mapped.type or "hub-device",
    vendor_provided_label = structured_vpl,
    parent_device_id = bridge.id,
    parent_assigned_child_key = mapped.key,
  }

  local success, err = driver:try_create_device(metadata)
  if not success then
    log.error_with({ hub_logs = true },
      "[Driver] Failed to create child " .. mapped.key .. ": " .. tostring(err))
  end

  return nil  -- Device will be available after lifecycle fires
end
```

> **Scale warning:** the inline create above is fine for a handful of devices, but a hub
> with 100s of devices will exceed the SmartThings cloud creation rate limit if you call
> `try_create_device` for all of them in one inventory pass — failed creates are dropped
> and those devices silently never appear. For any bridge that can have many children,
> **enqueue creates and drain them in paced batches with retry/backoff** instead. See
> `smartthings/lan-driver/bridge/hub-event-sync` §8 (Rate-Limit-Safe Bulk Child Creation).
> `cache_child_metadata` then runs at *drain* time (just before the actual
> `try_create_device`), not at enqueue time.

### Metadata Fields Reference

| Field | Required | Description |
|---|---|---|
| `type` | Yes | Always `"EDGE_CHILD"` |
| `label` | Yes | Display name in SmartThings app |
| `profile` | Yes | Profile YAML filename (without `.yml`) |
| `manufacturer` | No | Manufacturer string |
| `model` | No | Model identifier |
| `vendor_provided_label` | No | Structured metadata for scripts |
| `parent_device_id` | Yes | `bridge.id` — the parent bridge device UUID |
| `parent_assigned_child_key` | Yes | Unique key within this bridge |

## Applying Pending Metadata

In the lifecycle `added` or `init` handler, apply the cached metadata:

```lua
function sync.apply_pending_child_metadata(driver, device)
  if is_bridge(device) then return end

  driver.datastore.pending_child_data = driver.datastore.pending_child_data or {}

  local bridge = find_parent_bridge(driver, device)
  local bridge_dni = bridge and bridge.device_network_id
    or device:get_field(fields.PARENT_BRIDGE_DNI)
  local child_key = device.parent_assigned_child_key

  if not bridge_dni or not child_key then return end

  local cache_key = bridge_dni .. "|" .. child_key
  local pending = driver.datastore.pending_child_data[cache_key]
  if pending == nil then return end

  -- Apply all fields with persistence
  device:set_field(fields.PARENT_BRIDGE_DNI, pending.bridge_dni, { persist = true })
  device:set_field(fields.HC2_DEVICE_ID, pending.hc2_device_id, { persist = true })
  device:set_field(fields.HC2_DEVICE_TYPE, pending.hc2_device_type, { persist = true })
  device:set_field(fields.HC2_DEVICE_KIND, pending.hc2_device_kind, { persist = true })
  device:set_field(fields.HC2_ROOM_ID, pending.hc2_room_id, { persist = true })
  device:set_field(fields.HC2_ROOM_NAME, pending.hc2_room_name, { persist = true })

  -- Remove from cache
  driver.datastore.pending_child_data[cache_key] = nil
end
```

## Parent-Child Navigation

### Finding children for a bridge

```lua
local function child_devices_for_bridge(driver, bridge)
  local children = {}
  for _, device in ipairs(driver:get_devices()) do
    if device.parent_device_id == bridge.id
      and device.parent_assigned_child_key ~= nil then
      children[device.parent_assigned_child_key] = device
    end
  end
  return children
end
```

### Finding a specific child by hub device ID

```lua
local function child_for_bridge_and_device_id(driver, bridge, device_id)
  local key = child_key_for_id(device_id)
  return child_devices_for_bridge(driver, bridge)[key]
end
```

### Finding the parent bridge for a child

```lua
local function find_parent_bridge(driver, child)
  -- Direct parent lookup
  if child.parent_device_id then
    for _, device in ipairs(driver:get_devices()) do
      if device.id == child.parent_device_id then
        return device
      end
    end
  end

  -- Fallback: use stored bridge DNI
  local bridge_dni = child:get_field(fields.PARENT_BRIDGE_DNI)
  if bridge_dni then
    for _, device in ipairs(driver:get_devices()) do
      if device.device_network_id == bridge_dni then
        return device
      end
    end
  end

  return nil
end
```

## Stale Child Cleanup

Remove child devices that no longer exist on the hub:

```lua
local function delete_child(driver, child)
  if type(driver.try_delete_device) == "function" then
    driver:try_delete_device(child.id)
  else
    -- Fallback: mark offline if delete not supported
    child:offline()
  end
end

-- In sync_bridge_inventory:
local seen = {}
for _, mapped in ipairs(mapped_devices) do
  seen[mapped.key] = true
  ensure_child_device(driver, bridge, mapped, children_by_key[mapped.key])
end

for child_key, child in pairs(children_by_key) do
  if not seen[child_key] then
    log.info("[Driver] Deleting stale child: " .. child_key)
    delete_child(driver, child)
  end
end
```

## Structured vendor_provided_label

The `vendor_provided_label` field encodes metadata for downstream Python tools:

```
Format: "fibaro|roomId:<id>|roomName:<name>|label:<raw_label>"

Example: "fibaro|roomId:221|roomName:Living Room|label:Main Light"
```

**Important**: SmartThings does NOT preserve `vendor_provided_label` for `EDGE_CHILD` devices.
Therefore, the room info must also be encoded in the device `label` as `[RoomName:roomId]`:

```lua
label = string.format("[%s:%s] %s", room_name, tostring(room_id), raw_label)
-- Result: "[Living Room:221] Main Light"
```

## Datastore Initialization

Initialize the datastore in `init.lua` before the driver starts:

```lua
if driver.datastore.pending_child_data == nil then
  driver.datastore.pending_child_data = {}
end

if driver.datastore.pending_bridge_data == nil then
  driver.datastore.pending_bridge_data = {}
end
```

## Multi-Channel / Multi-Endpoint Devices

A multi-gang module (dual/triple relay, multi-channel dimmer) can be represented two ways.
**Inspect the real hub API payload before choosing** — do not assume.

### Pattern 1 — Hub exposes each channel as its own device (most common)

Fibaro, and most Z-Wave/Zigbee bridges, expose each physical relay as a **separate
device** with its own `id`, `parentId`, `name`, `value`, and `actions`. A single multi-gang
module therefore appears as **several devices plus internal/auxiliary endpoints**:

```
container  "145"      type=zwaveDevice    visible=false   <- skip (container)
endpoint-0 "145.0"    type=binarySwitch   visible=false   <- skip (root aggregation node)
phantom    "145.0.2"  type=heatDetector   visible=false   <- skip (phantom sub-endpoint!)
channel    "COVE LIGHT"   type=binarySwitch  visible=true  <- KEEP (real load)
channel    "WALL PROFILE" type=binarySwitch  visible=true  <- KEEP (real load)
```

The correct model is **one SmartThings child per *real* controllable channel**, using your
normal single-capability profiles (`switch`, `dimmer`). The hard part is **not** creating a
device for every endpoint — multi-channel modules emit phantom sub-endpoints (e.g. a fake
`heatDetector` per switch) and root aggregation nodes that would become duplicate or
nonsense cards. **Two filters, in this order:**

**(1) Respect the hub's own visibility flag — this is the authoritative signal.**
Hubs hide their internal endpoints. Skipping `visible == false` removes phantom sensor
sub-endpoints, hidden root nodes, and secondary channels the user has hidden in one line —
far more reliable than pattern-matching names. (Devices from APIs that omit the flag should
normalize to `visible = true` so they are unaffected.)

```lua
if device.visible == false then
  return nil, "hidden device"        -- phantoms, hidden roots, hidden secondaries
end
```

**(2) Skip the endpoint-0 root even when it is left visible**, but only when the module
genuinely has more than one controllable channel (a single-channel module's only load may
legitimately be named `"<id>.0"`):

```lua
-- Pre-pass in sync: count controllable channels per parent
local parent_channel_counts = {}
for _, nd in ipairs(normalized_devices) do
  local pid = nd.parent_id or 0
  local controllable = (nd.actions or {}).turnOn ~= nil or (nd.actions or {}).setValue ~= nil
  if pid > 1 and controllable then
    parent_channel_counts[pid] = (parent_channel_counts[pid] or 0) + 1
  end
end

-- In mapper:
local parent_is_multichannel = parent_id > 1 and (parent_channel_counts[parent_id] or 0) > 1
local is_numeric_endpoint = label:match("^%d+%.%d+$") or label:match("^%d+%.%d+%.%d+$")
if parent_is_multichannel and is_numeric_endpoint and label:match("%.0$") then
  return nil, "multi-channel root endpoint"
end
```

> **Verify against a real device dump before trusting any name heuristic.** On one real
> 368-device Fibaro hub, naïvely accepting every controllable/typed endpoint produced **197
> devices including 28 phantom `heatDetector` cards and 11 duplicate root switches**;
> applying the visibility flag + root filter reduced it to the correct **155 real loads**.
> Do **not** decide what to surface from the device `name` pattern alone (e.g. "skip numeric
> endpoints", or the inverse "keep every numeric endpoint") — both mis-handle real installs.
> The hub's `visible`/hidden flag is the signal that actually matches user intent.

### Pattern 2 — Hub exposes one device with multiple endpoints/components

If the hub returns a *single* device carrying per-endpoint state (e.g. an `endpoints`
array with a value each), model it as one child with a **multi-component profile**
(`main`, `switch1`, `switch2`) and route by component:

```lua
-- Emit to a specific component
device:emit_component_event(device.profile.components["switch2"],
  capabilities.switch.switch.on())

-- Route a command to the right endpoint
local function handle_switch_on(driver, device, command)
  local endpoint = component_to_endpoint(command.component)  -- "main" → 0, "switch2" → 2
  send_action(device, endpoint, "turnOn")
end
```

Choose Pattern 1 when the hub gives each channel its own name/room (you would lose that by
collapsing into components). Choose Pattern 2 only when state is delivered per-endpoint
inside one device object.

## Key Design Principles

1. **Cache-before-create** — always cache metadata before `try_create_device`
2. **Apply in lifecycle** — apply cached metadata in `added`/`init` handlers
3. **Cleanup cache** — remove pending entries after successful application
4. **Persist all fields** — use `{persist = true}` for hub restart recovery
5. **Dual encoding** — encode room info in both VPL and label as safety net
6. **Stale cleanup** — always reconcile children on full inventory sync
7. **Pace bulk creates** — enqueue + drain with backoff for large hubs (see `hub-event-sync` §8); never fire 100s of `try_create_device` calls at once
8. **One child per *real* channel** — filter on the hub's `visible`/hidden flag first (drops phantom sub-endpoints, hidden roots, hidden secondaries), then drop the `.0` aggregation node of multi-channel modules. Never decide what to surface from the device-name pattern alone — verify against a real device dump.
