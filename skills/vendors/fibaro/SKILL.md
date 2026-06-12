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
| Switch (metered — exposes `power`/`energy` interface) | `fibaro-switch-metered` |
| Dimmer | `fibaro-dimmer` |
| Dimmer (metered — exposes `power`/`energy` interface) | `fibaro-dimmer-metered` |
| Blind/window shade | `fibaro-blind` |
| Blind/shade (metered — exposes `power`/`energy` interface) | `fibaro-blind-metered` |
| Contact sensor | `fibaro-contact` |
| Motion sensor | `fibaro-motion` |
| Temperature sensor | `fibaro-temperature-sensor` |
| Humidity sensor | `fibaro-humidity-sensor` |
| Illuminance sensor | `fibaro-illuminance-sensor` |
| Water/flood sensor | `fibaro-water-sensor` |
| Smoke detector | `fibaro-smoke-detector` |
| Generic fallback | `fibaro-default` (full integrations only) |

Every Fibaro mapper rule that returns one of these profile names must have a matching `name:` in `profiles/*.yml` — **and** every generated profile must have a mapper rule that uses it. Do not generate a profile (or a rule) for a kind that is out of the requested scope.

**Energy/power metering (production requirement).** Many Fibaro relays and dimmers meter consumption: they expose the `power` and/or `energy` **interface** and carry `properties.power` (W) and `properties.energy` (kWh). When a device maps to `switch` or `dimmer` **and** `has_interface(interfaces, "energy")` or `has_interface(interfaces, "power")`, emit the **`-metered` profile variant** (`fibaro-switch-metered` / `fibaro-dimmer-metered`, which add `powerMeter` + `energyMeter`) — never discard the metering data. Implement it as a **post-match upgrade** in `mapper.map_device` (after a rule matches, swap `profile = rule.profile .. "-metered"`), so every switch/dimmer rule benefits without duplicating the rule table. Then: (1) the adapter normalizes `power = utils.safe_tonumber(props.power)` / `energy = utils.safe_tonumber(props.energy)`; (2) `emit_child_state` emits `capabilities.powerMeter.power({value, unit="W"})` and `capabilities.energyMeter.energy({value, unit="kWh"})` for the `switch`/`dimmer` kinds; (3) `init.lua` `supported_capabilities` includes `capabilities.powerMeter` and `capabilities.energyMeter`. Plain (non-metered) devices normalize `power`/`energy` to `nil`, so they emit nothing and **stay on the plain profile** — never add metering capabilities to a non-metered switch (it shows misleading empty 0 W / 0 kWh tiles). Detection is **interface-driven**, not name-driven. Roller shutters / `FGR223` curtain controllers are metered too and use **`fibaro-blind-metered`** (windowShade + windowShadeLevel + powerMeter + energyMeter); the same interface-driven post-match upgrade covers the `blind` kind, and `emit_child_state` emits the meters for `blind` as well.

For Add device discovery:

- **Auto-discovery is the Fibaro "find server" UDP broadcast — NOT mDNS or SSDP.** Fibaro HC2/HC3 advertise no SSDP/UPnP root device, and their mDNS (Avahi) is hostname-resolution only (no browsable service). The official app locates the hub via a proprietary **UDP broadcast on port 44444** ("Fibaro find server"). Generate this finder as Tier 1 (`discovery_provider.discover_via_finder` → `fibaro_finder.scan`) and treat **any responder on 44444 as the HC3**, building the candidate from the datagram's source IP. **Do NOT generate an `st.mdns` browse for discovery** — the hub never answers it. Full pattern: `smartthings/lan-driver/discovery/find-server-udp`.
- **mDNS survives only as serial→host *resolution*, never as a discovery scan.** When the user enters a Fibaro serial on the manual bridge, `sync.lua` resolves `hc3-<serial>.local` via `mdns_resolver.lua` (an A-record lookup). That is the only mDNS in the driver. Do not confuse it with browsing for the hub.
- **The Fibaro hub must appear as exactly one bridge, visible during the scan.** Run the finder inside the `should_continue()` loop. If the finder returns nothing and no Fibaro bridge exists yet, create the **manual-entry fallback bridge INSIDE the scan window** (`discovery_provider.build_manual_bridge()`, stable DNI `fibaro-hc3:manual`) so the user always has a card to enter the IP/serial into — a `try_create_device` issued after the window closes is not reliably honored. Guard with `found_controller` / `manual_created` flags so only one placeholder is ever made.
- **Reconcile by identity, then clean up.** Match existing bridges by DNI (or serial/host) and update in place rather than minting a duplicate. Once the finder discovers the real HC3, delete the **unconfigured** manual placeholder (only when it has no host/username — never delete a manual bridge the user already configured). See `discovery_provider` + `discovery.lua` in the reference driver, and `smartthings/lan-driver/discovery/hub-discovery` → "Single-Bridge Reconciliation".
- Do not generate broad SSDP matching (`upnp:rootdevice`) for Fibaro — SSDP was removed; it produced false matches and HC3 does not advertise it.
- Cache discovered host, port, scheme, serial, and platform (`discovery.cache_bridge_metadata` → `pending_bridge_data`) before `try_create_device()`, then apply them during bridge lifecycle init via `discovery.apply_pending_bridge_metadata`. Use `set_field_if_present` so a re-scan of the empty manual placeholder never wipes identity that `sync.lua` learned from the live hub.
- **HTTPS / TLS (HC3 on port 443).** HC3 serves the local API over HTTPS/443 with a certificate chain anchored by a **Fibaro CA**; HC2 is HTTP-only. Support both via the `scheme` preference (`http` default; HTTPS only when explicitly set, never auto-enabled by discovery). The Edge sandbox **cannot write a `cafile` to disk at runtime** and does not expose `luasec.loadcertificate`, so validation is enforced at the **application layer**: keep the luasec transport `verify="none"` and, after the handshake, compare the hub's presented cert against a **pinned SHA-256 fingerprint** computed in pure Lua (`fibaro/cert.lua`, wired via the `pin_verify` hook on `utils.labeled_socket_builder`). The `tlsVerify` preference selects the trust model — **`none`** (encrypt-only, default), **`auto`** (fetch the CA from `GET /api/settings/certificates/ca` on first contact, fingerprint-pin it, validate every later connection), or **`bundled`** (validate against `src/fibaro_server.crt`). See `smartthings/lan-driver/bridge/secure-transport` → "Edge sandbox: app-layer fingerprint pinning".

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
-- The SmartThings Edge `Driver` object has NO `get_device_by_dni` method. Resolve a
-- child by its device_network_id by iterating the driver's device list.
local function find_device_by_dni(driver, dni)
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == dni then return device end
  end
  return nil
end

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
      local child_device = find_device_by_dni(driver, tostring(change.id))
      if child_device then
        -- Update child device status based on changed properties
        sync_properties_to_st(child_device, change.properties)
      end
    end
  end
end
```
