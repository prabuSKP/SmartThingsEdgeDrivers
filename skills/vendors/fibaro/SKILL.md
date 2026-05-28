---
name: fibaro
description: >
  Integrate Fibaro Home Center 2/3 (HC2/HC3) hubs with SmartThings Edge drivers.
  Covers the Fibaro local REST API, sending device control actions (/api/callAction),
  and handling state synchronization using long-polling (/api/refreshStates) with
  event cursors. Use when building or debugging Fibaro-to-SmartThings bridge integrations.
---

# Fibaro Home Center Integration Guide

This skill covers the integration of Fibaro Home Center 2 (HC2) and Home Center 3 (HC3) local REST APIs with SmartThings Edge drivers. It leverages patterns extracted from the reference Fibaro Edge driver.

---

## 1. Fibaro Local REST API Reference

### A. Authentication
Fibaro requires HTTP Basic Authentication for all local API requests. Make sure to encode credentials using `st.base64` and add them to the `Authorization` header.

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

## 2. Device Control: `/api/callAction`

Commands are sent by calling actions on specific devices:
- **Endpoint**: `POST /api/callAction`
- **Payload**: JSON containing the device ID, action name, and optional arguments.

### Example Actions

#### Turn a Switch On
```http
POST /api/callAction
Content-Type: application/json

{
  "deviceID": 124,
  "name": "turnOn",
  "arguments": []
}
```

#### Turn a Switch Off
```http
POST /api/callAction
Content-Type: application/json

{
  "deviceID": 124,
  "name": "turnOff",
  "arguments": []
}
```

#### Set a Dimmer/Level (0-100)
```http
POST /api/callAction
Content-Type: application/json

{
  "deviceID": 130,
  "name": "setValue",
  "arguments": [75]
}
```

---

## 3. Real-Time State Sync: `/api/refreshStates`

Instead of polling `/api/devices` repeatedly (which is resource intensive), Fibaro supports a long-polling change feed via `/api/refreshStates`.

### Long-Polling Request
- **Endpoint**: `GET /api/refreshStates?lastStructureId=<struct_id>&lastEventId=<event_id>`
- **Response**: Returns only the modifications since the provided structure/event cursors.

#### Response Structure:
```json
{
  "lastStructureId": 140023,
  "lastEventId": 450912,
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
Store the cursors persistently in the parent bridge device's datastore:

```lua
local function poll_fibaro_changes(driver, bridge_device)
  local client = bridge_device:get_field("api_client")
  
  -- Retrieve cursors
  local last_struct = bridge_device:get_field("last_structure_id") or 0
  local last_event = bridge_device:get_field("last_event_id") or 0
  
  local url = string.format(
    "%s/refreshStates?lastStructureId=%d&lastEventId=%d",
    client.base_url, last_struct, last_event
  )
  
  local body, code = client:http_get(url)
  if code == 200 and body then
    local data = json.decode(body)
    
    -- 1. Save new cursors
    bridge_device:set_field("last_structure_id", data.lastStructureId, {persist = true})
    bridge_device:set_field("last_event_id", data.lastEventId, {persist = true})
    
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
