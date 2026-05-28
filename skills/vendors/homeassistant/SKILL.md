---
name: homeassistant
description: >
  Integrate Home Assistant local instances with SmartThings Edge drivers.
  Covers token authorization (Bearer), REST service control (/api/services), WebSocket
  real-time state change subscription (state_changed events), and mapping HA domains
  (light, switch, binary_sensor, sensor) to SmartThings capabilities. Use when building
  or maintaining Home Assistant-to-SmartThings bridge integrations.
---

# Home Assistant Local Integration Guide

This skill details how to connect, command, and synchronize Home Assistant (HA) instances with a SmartThings Edge bridge driver using local REST and WebSocket APIs.

---

## 1. REST API & Authentication

Home Assistant local APIs require authorization using a Long-Lived Access Token (created in the HA user profile).

- **Header format**: `Authorization: Bearer <ACCESS_TOKEN>`

### Fetching Current Inventory & States
- **Endpoint**: `GET /api/states`
- **Response**: An array of entity state objects. Use this during discovery/bootstrap to inventory all items.

#### Key State Object Fields:
- `entity_id`: Entity identifier (e.g., `light.living_room_light`, `binary_sensor.front_door`).
- `state`: String representation of the state (e.g., `on`, `off`, `unavailable`, `15.4`).
- `attributes`: JSON map of properties (e.g., `brightness`, `device_class`, `unit_of_measurement`).

---

## 2. Device Control via Services

Control actions are performed by making a `POST` request to the appropriate HA domain service.

- **Endpoint**: `POST /api/services/<domain>/<service>`
- **Payload**: JSON containing the `entity_id` and optional configuration variables.

### Example REST Service Calls

#### Turn On a Light/Switch
- **Endpoint**: `POST /api/services/light/turn_on`
- **Payload**:
  ```json
  {
    "entity_id": "light.living_room_light"
  }
  ```

#### Set Brightness (0-255 in HA, mapped from 0-100 in ST)
- **Endpoint**: `POST /api/services/light/turn_on`
- **Payload**:
  ```json
  {
    "entity_id": "light.living_room_light",
    "brightness": 192
  }
  ```

#### Turn Off a Light/Switch
- **Endpoint**: `POST /api/services/switch/turn_off`
- **Payload**:
  ```json
  {
    "entity_id": "switch.coffee_maker"
  }
  ```

---

## 3. Real-Time Push Events via WebSocket

Using the WebSocket API is highly recommended to receive instantaneous state changes from Home Assistant.

### Connection Protocol
1. Open a WebSocket connection to: `ws://<HA_IP>:8123/api/websocket`
2. The server responds with an authentication request:
   ```json
   { "type": "auth_required", "ha_version": "2026.x" }
   ```
3. Send the auth token:
   ```json
   { "type": "auth", "access_token": "<ACCESS_TOKEN>" }
   ```
4. Confirm auth success:
   ```json
   { "type": "auth_ok", "ha_version": "2026.x" }
   ```

### Subscribing to State Changes
Once authenticated, send a subscription frame to listen for all state changes:
```json
{
  "id": 1,
  "type": "subscribe_events",
  "event_type": "state_changed"
}
```

### Parsing State Change Events
The server will push messages matching this pattern:
```json
{
  "id": 1,
  "type": "event",
  "event": {
    "event_type": "state_changed",
    "data": {
      "entity_id": "light.living_room_light",
      "new_state": {
        "entity_id": "light.living_room_light",
        "state": "on",
        "attributes": {
          "brightness": 255
        }
      }
    }
  }
}
```

Map this event in Lua by checking `entity_id` and extracting `new_state.state` and attributes.

---

## 4. Mapping Home Assistant Domains to SmartThings Capabilities

| HA Domain | `device_class` / Attribute | SmartThings Capability | ST Value / Event |
|---|---|---|---|
| **`switch`** | - | `switch` | `on()` / `off()` |
| **`light`** | `brightness` | `switch` & `switchLevel` | `on()`/`off()`, `level(0-100)` |
| **`binary_sensor`**| `motion` | `motionSensor` | `active` / `inactive` |
| | `door` or `window` | `contactSensor` | `open` / `closed` |
| | `moisture` | `waterSensor` | `dry` / `wet` |
| **`sensor`** | temperature class | `temperatureMeasurement` | `temperature(value)` |
| | humidity class | `relativeHumidityMeasurement` | `humidity(value)` |
| **`cover`** | - | `windowShade` | `open` / `closed` / `partially open` |
