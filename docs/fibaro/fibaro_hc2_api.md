# Fibaro HC2 Mock API Reference for Edge Driver Testing

## Overview

This document gives you a practical HC2 API subset for local mock-server development and SmartThings Edge Driver testing.

It includes:
- Core API list
- Correct JSON response examples (HC2-style)
- API usage in driver workflow
- Notes for generic/unknown device handling

---

## Core API List (Recommended for Mock Server)

| # | API | Method | Sample Response (summary) | Usage in Edge Driver |
|---|---|---|---|---|
| 1 | `/api/devices` | GET | Array of devices with `id`, `name`, `type`, `properties`, `actions` | Discovery, initial sync, device mapping |
| 2 | `/api/devices/{id}` | GET | Single device object | Polling and state refresh |
| 3 | `/api/devices/45/action/turnOn` | POST | `200 OK` with empty body | Switch ON command |
| 4 | `/api/devices/45/action/turnOff` | POST | `200 OK` with empty body | Switch OFF command |
| 5 | `/api/devices/46/action/setValue` | POST | `200 OK` with empty body | Dimmer level command |
| 6 | `/api/rooms` | GET | Array of rooms | Optional room mapping |
| 7 | `/api/scenes` | GET | Array of scenes | Optional scene discovery |

---

## Correct JSON Response Examples

### 1) Get all devices

**Endpoint:** `GET /api/devices`

```json
[
  {
    "id": 45,
    "name": "Living Room Light",
    "type": "com.fibaro.binarySwitch",
    "roomID": 1,
    "properties": {
      "value": 1,
      "dead": false
    },
    "actions": {
      "turnOn": 0,
      "turnOff": 0
    }
  },
  {
    "id": 46,
    "name": "Hall Dimmer",
    "type": "com.fibaro.multilevelSwitch",
    "roomID": 1,
    "properties": {
      "value": 50,
      "dead": false
    },
    "actions": {
      "turnOn": 0,
      "turnOff": 0,
      "setValue": 0
    }
  },
  {
    "id": 47,
    "name": "Front Door Sensor",
    "type": "com.fibaro.doorSensor",
    "roomID": 2,
    "properties": {
      "value": 0,
      "dead": false
    },
    "actions": {}
  },
  {
    "id": 48,
    "name": "Generic Relay",
    "type": "com.fibaro.device",
    "roomID": 3,
    "properties": {
      "value": 1,
      "dead": false
    },
    "actions": {
      "turnOn": 0,
      "turnOff": 0
    }
  }
]
```

### 2) Get a single device

**Endpoint:** `GET /api/devices/{id}`

```json
{
  "id": 45,
  "name": "Living Room Light",
  "type": "com.fibaro.binarySwitch",
  "roomID": 1,
  "properties": {
    "value": 0,
    "dead": false
  },
  "actions": {
    "turnOn": 0,
    "turnOff": 0
  }
}
```

### 3) Call action (turnOn / turnOff / setValue)

**Endpoints:**
- `POST /api/devices/45/action/turnOn`
- `POST /api/devices/45/action/turnOff`
- `POST /api/devices/46/action/setValue`

**Request body for `setValue`:**

```json
{
  "args": [75]
}
```

**Typical response:** `200 OK` with an empty body

### 4) Rooms (optional)

**Endpoint:** `GET /api/rooms`

```json
[
  { "id": 1, "name": "Living Room" },
  { "id": 2, "name": "Bedroom" },
  { "id": 3, "name": "Kitchen" }
]
```

### 5) Scenes (optional)

**Endpoint:** `GET /api/scenes`

```json
[
  { "id": 10, "name": "Movie Mode" },
  { "id": 11, "name": "Night Mode" }
]
```

---

## API Usage in Edge Driver (Tabular)

| Phase | API | Purpose | Driver Behavior |
|---|---|---|---|
| Discovery | `/api/devices` | Get all devices in HC2 | Parse device list and create/map SmartThings devices |
| Polling | `/api/devices/{id}` | Fetch latest state | Read `properties.value` and emit capability events |
| Control | `/api/devices/{id}/action/{actionName}` | Execute command | Send `turnOn`, `turnOff`, `setValue` based on capability command |
| Optional Metadata | `/api/rooms` | Room mapping | Add location context if needed |
| Optional Automations | `/api/scenes` | Scene discovery | Expose scene metadata as optional feature |

---

## JSON Fields You Should Use

| Field | Meaning | How to Use |
|---|---|---|
| `id` | Unique device identifier | Use as stable key between HC2 and Edge device |
| `name` | Device display name | Device label in SmartThings |
| `type` | Fibaro device type string | Initial classification only (do not trust blindly) |
| `properties.value` | Current state value | Switch state, dim level, sensor value |
| `actions` | Supported commands | Detect actual capabilities (`turnOn`, `turnOff`, `setValue`) |
| `properties.dead` | Reachability status | Optional health/offline handling |

---

## Minimal Mandatory Endpoints for Mock Server

| API | Required | Why |
|---|---|---|
| `/api/devices` | Yes | Discovery |
| `/api/devices/{id}` | Yes | Polling |
| `/api/devices/{id}/action/{actionName}` | Yes | Device control |
| `/api/rooms` | Optional | Metadata |
| `/api/scenes` | Optional | Scene features |

---

## Handling Generic / Unknown Devices (`com.fibaro.device`)

Use **capability detection** instead of strict type matching:

1. If `actions.turnOn` and `actions.turnOff` exist -> treat as switch.
2. If `actions.setValue` exists -> treat as dimmer.
3. If only `properties.value` exists and no control actions -> treat as sensor-like.

This makes your driver robust across firmware and vendor variations.

---

## Important HC2 Behavior Notes

- HC2 device actions use **POST** on `/api/devices/{id}/action/{actionName}`.
- Action payloads are sent as JSON using an `args` array when parameters are needed.
- API access is typically protected with **Basic Auth**.
- No native push stream for many use cases -> periodic polling is common.
- Responses are usually flat JSON objects/arrays.

## Important Correction

- Older mock notes sometimes showed `GET /api/callAction?...`.
- For this project, the correct Fibaro HC2/Lite-compatible command path is `POST /api/devices/{id}/action/{actionName}`.
- SmartThings Edge Driver development should use the POST action route, not the legacy GET form.

---

## End-to-End Flow

1. Driver starts and authenticates.
2. Call `/api/devices` to discover all devices.
3. Create/map SmartThings devices by capability.
4. Poll `/api/devices/{id}` at interval for state sync.
5. Send commands through `POST /api/devices/{id}/action/{actionName}`.
6. Continue polling to confirm and reflect state updates.
