---
name: fibaro
description: >
  Integrate Fibaro Home Center 2/3 (HC2/HC3) hubs with SmartThings Edge drivers.
  Covers the Fibaro local REST API, sending device control actions (/api/devices/{id}/action/{action}),
  and handling state synchronization using long-polling (/api/refreshStates) with
  the `last` cursor. Use when building or debugging Fibaro-to-SmartThings bridge integrations.
---

# Fibaro Home Center Integration Guide

This skill covers the integration of Fibaro Home Center 2 (HC2) and Home Center 3 (HC3) local REST APIs with SmartThings Edge drivers. It leverages patterns extracted from the reference Fibaro Edge driver.

---

## 1. Fibaro Local REST API Reference

### A. Authentication
Fibaro requires HTTP Basic Authentication for all local API requests. Make sure to encode credentials using `st.base64` and add them to the `Authorization` header.

### A1. SmartThings Driver Generation Requirements

When generating a Fibaro bridge Edge driver, combine this vendor skill with the generic LAN bridge skills and enforce these Fibaro-specific choices:

- Use `fibaro` as the profile and child-key prefix unless the user explicitly asks for another package prefix.
- Bridge profile: `fibaro-bridge` (always generated).
- **Generate child profiles only for the device kinds the user requested — not the whole catalog.** The table below is the full set of Fibaro profile *names to use when a kind is in scope*; it is not a list to emit every time. A request for "a light on the HC3" yields `fibaro-bridge` + `fibaro-switch`/`fibaro-dimmer` only, with the Fibaro mapper scoped to skip every other device type (no `fibaro-default`). Generate the full catalog only when the user asks for all devices / a complete integration. See `smartthings/lan-driver/mapping/hub-profile-mapping` → "Scope: Generate Only Requested Device Types".

| Kind | Profile name |
|---|---|
| Switch | `fibaro-switch` |
| Dimmer | `fibaro-dimmer` |
| Blind/window shade | `fibaro-blind` |
| Contact sensor | `fibaro-contact` |
| Motion sensor | `fibaro-motion` |
| Temperature sensor | `fibaro-temperature-sensor` |
| Humidity sensor | `fibaro-humidity-sensor` |
| Illuminance sensor | `fibaro-illuminance-sensor` |
| Water/flood sensor | `fibaro-water-sensor` |
| Smoke detector | `fibaro-smoke-detector` |
| Generic fallback | `fibaro-default` (full integrations only) |

Every Fibaro mapper rule that returns one of these profile names must have a matching `name:` in `profiles/*.yml` — **and** every generated profile must have a mapper rule that uses it. Do not generate a profile (or a rule) for a kind that is out of the requested scope.

For Add device discovery:

- **The Fibaro hub must appear as exactly one bridge — and it must be visible during the scan.** Fibaro HC2/HC3 hubs generally do **not** advertise over mDNS, so create the manual/fixed-IP placeholder **up front**, at the start of `discover()` (idempotent, gated on `any_bridge_exists`), so the user always has a bridge to configure during the scan window. **Do not defer it to after the loop** — that leaves the scan empty and is why the hub "never shows up." Singleness comes from **reconciliation, not deferral**: see the next bullet. See `smartthings/lan-driver/discovery/hub-discovery` → "Single-Bridge Reconciliation".
- **Reconcile by identity before creating.** Match existing bridges by DNI, `serialNumber`, OR host and update in place, so the mDNS path adopts a manually configured bridge (and vice-versa) instead of duplicating it. Once a real hub is discovered, delete a leftover unconfigured manual placeholder.
- Do not rely on broad SSDP matches like `upnp:rootdevice` without validating the candidate as Fibaro. Many unrelated LAN devices match that term.
- Prefer `st.mdns` for HC3-style flows, and validate candidates using service name, TXT fields such as `platform` / `serialNumber`, or `/api/settings/info`.
- If auto discovery is requested, generate the `st.mdns` scan and Fibaro candidate normalization code; do not generate only a sleeping placeholder loop.
- Cache discovered host, port, scheme, serial, and platform before `try_create_device()`, then persist them during bridge lifecycle init.

### B. Device Discovery & Inventory Sync
To fetch all devices paired to the Fibaro hub:
- **Endpoint**: `GET /api/devices`
- **Response**: A JSON array of device objects.

Key fields in device objects:
- `id`: Unique integer identifier.
- `name`: Friendly name.
- `type`: Fibaro device type (e.g. `com.fibaro.binarySwitch`, `com.fibaro.multilevelSwitch`, `com.fibaro.FGRGBW441M`).
- `properties`: Table containing active states (e.g. `value`, `power`, `energy`, `batteryLevel`).
- `interfaces`: List of supported interfaces (e.g., `["quickApp", "light"]`).
- `parentId`: Identifies multi-endpoint sub-devices.

---

## 2. Device Control: `/api/devices/{id}/action/{action}`

Commands are sent by calling actions on specific devices:
- **Endpoint**: `POST /api/devices/{device_id}/action/{action_name}`
- **Payload**: JSON containing an `args` array, generated through the HC2/HC3 adapter.
- Do not generate Fibaro command clients that only use `POST /api/callAction`; the reference Edge driver uses the per-device action endpoint above.

### Example Actions

#### Turn a Switch On
```http
POST /api/devices/124/action/turnOn
Content-Type: application/json

{
  "args": []
}
```

#### Turn a Switch Off
```http
POST /api/devices/124/action/turnOff
Content-Type: application/json

{
  "args": []
}
```

#### Set a Dimmer/Level (0-100)
```http
POST /api/devices/130/action/setValue
Content-Type: application/json

{
  "args": [75]
}
```

---

## 3. Real-Time State Sync: `/api/refreshStates`

Instead of polling `/api/devices` repeatedly (which is resource intensive), Fibaro supports a long-polling change feed via `/api/refreshStates`.

### Long-Polling Request
- **Endpoint**: `GET /api/refreshStates` for initial cursor priming.
- **Endpoint**: `GET /api/refreshStates?last=<last>` for incremental polling.
- **Response**: Returns only the modifications since the provided `last` cursor.
- Store `payload.last` in a persistent bridge field and use it on the next poll.
- Do not generate Fibaro polling that only stores `lastStructureId` / `lastEventId`; align with the reference Edge driver's `last` cursor flow unless a specific target API proves otherwise.

#### Response Structure:
```json
{
  "last": 140023,
  "changes": [
    {
      "id": 124,
      "log": "",
      "properties": {
        "value": true
      }
    }
  ],
  "events": []
}
```

### Implementing in Lua
Store the cursor persistently in the parent bridge device's datastore:

```lua
local function poll_fibaro_changes(driver, bridge_device)
  local client = bridge_device:get_field("api_client")
  
  -- Retrieve cursor
  local last = bridge_device:get_field("last_refresh_states")
  
  local data, err, code = client:get_refresh_states(last)
  if code == 200 and type(data) == "table" then
    
    -- 1. Save new cursor
    bridge_device:set_field("last_refresh_states", data.last, {persist = true})
    
    -- 2. Process changes
    for _, change in ipairs(data.changes or {}) do
      local child_device = driver:get_device_by_dni(tostring(change.id))
      if child_device then
        -- Update child device status based on changed properties
        sync_properties_to_st(child_device, change.properties)
      end
    end
  end
end
```
