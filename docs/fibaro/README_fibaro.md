# Fibaro HC2 Mock API

Local Node.js + Express mock server that exposes an HC2-style API for SmartThings Edge Driver testing.

## Quick Start

1. Install dependencies:

   ```bash
   npm install
   ```

2. Start the mock server:

   ```bash
   npm start
   ```

3. Run the automated tests:

   ```bash
   npm test
   ```

Server base URL:

```text
http://localhost:3000/api
```

Default Basic Auth credentials come from `.env`:

```text
admin / admin
```

## Contract

- Base URL: `http://<host>:<port>/api`
- Auth: Basic Auth using `MOCK_USER` / `MOCK_PASS`
- Content-Type: `application/json`
- Dimmer `setValue` range: `0-99`
- State model: static seed data plus mutable in-memory runtime state
- Concurrency model: last write wins
- Action route: `POST /api/devices/:id/action/:actionName` with body `{"args":[...]}`
- Error shape: HC2-like `404` / `405` routes return no content

## Endpoints

### Core API

- `GET /api/devices`
- `GET /api/devices/:id`
- `POST /api/devices/:id/action/:actionName`
- `GET|POST|PUT|DELETE /api/devices`
- `GET|POST|PUT|DELETE /api/sections`
- `GET|POST|PUT|DELETE /api/rooms`
- `GET|POST|PUT|DELETE /api/scenes`
- `GET|POST|PUT|DELETE /api/virtualDevices`
- `GET /api/rooms`
- `GET /api/scenes`
- `GET /api/plugins/installed`
- `GET|PUT /api/loginStatus`
- `GET /api/refreshStates`

### Mock Controls

- `POST /__mock/device/:id/state`
- `POST /__mock/simulate/motion/start`
- `POST /__mock/simulate/motion/stop`
- `POST /__mock/faults/latency`
- `POST /__mock/faults/offline`
- `GET /__mock/state`

## Supported Actions

| Behavior | Detection Rule | Supported Actions | State Change |
| --- | --- | --- | --- |
| Switch | `turnOn` + `turnOff`, no `setValue` | `turnOn`, `turnOff` | `value = 1` or `0` |
| Dimmer | `setValue` exists | `turnOn`, `turnOff`, `setValue` | `turnOn => 99`, `turnOff => 0`, `setValue => clamp(0-99)` |
| Sensor-like | no control actions, `properties.value` exists | none | read-only state |
| Virtual device | `/api/virtualDevices` | `pressButton`, `setSlider`, `setProperty` | virtual-device specific |

## API Examples

Get all devices:

```bash
curl -u admin:admin http://localhost:3000/api/devices
```

Get one device:

```bash
curl -u admin:admin http://localhost:3000/api/devices/45
```

Turn on a switch:

```bash
curl -u admin:admin -H "Content-Type: application/json" -X POST -d "{\"args\":[]}" http://localhost:3000/api/devices/45/action/turnOn
```

Set a dimmer to 75:

```bash
curl -u admin:admin -H "Content-Type: application/json" -X POST -d "{\"args\":[75]}" http://localhost:3000/api/devices/46/action/setValue
```

Mark a device offline:

```bash
curl -u admin:admin -H "Content-Type: application/json" -d "{\"deviceID\":45,\"dead\":true}" http://localhost:3000/__mock/faults/offline
```

Add 500ms latency:

```bash
curl -u admin:admin -H "Content-Type: application/json" -d "{\"latencyMs\":500}" http://localhost:3000/__mock/faults/latency
```

Get one scene through the HC2-style query-id form:

```bash
curl -u admin:admin "http://localhost:3000/api/scenes?id=10"
```

Create a room:

```bash
curl -u admin:admin -H "Content-Type: application/json" -X POST -d "{\"name\":\"Office\",\"sectionID\":2,\"icon\":\"room_office\",\"defaultSensors\":{\"temperature\":0,\"humidity\":0,\"light\":0},\"defaultThermostat\":0,\"sortOrder\":20}" http://localhost:3000/api/rooms
```

## Known Differences Vs Real HC2

- State is in-memory only and resets on restart.
- The action subset is intentionally narrow: `turnOn`, `turnOff`, `setValue`, and a minimal virtual-device subset.
- Fault injection is available under `/__mock/*`, which is not part of the real HC2 API.
- Device, room, scene, and virtual-device payloads are HC2-shaped seed data, not raw captures exported from a live controller.
- The mock includes a controller, normal devices, one virtual device, and one plugin-style device so discovery logic is closer to a real HC2 inventory.

## Integration Notes

- Discovery: use `GET /api/devices`
- Polling: use `GET /api/devices/:id`
- Commands: use `POST /api/devices/:id/action/:actionName` with `{"args":[...]}`
- If your driver queries collections with `?id=<n>`, the mock returns the single object form that HC2 examples use.
- Generic `com.fibaro.device` handling should inspect `actions` first, not just `type`
- Offline simulation is exposed through `properties.dead`; timeout behavior should be tested with `/__mock/faults/latency`
