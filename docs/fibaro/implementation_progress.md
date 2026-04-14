# Implementation Progress

## Fibaro HC2 and HC3 Edge Driver

The Fibaro Edge driver under [drivers/Unofficial/fibaro-hc2](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2) now supports a combined HC2 and HC3 runtime model.

### Package Shape

- Bridge profile: [hc2-bridge.yml](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/profiles/hc2-bridge.yml)
- Child profiles:
  - [fibaro-switch.yml](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/profiles/fibaro-switch.yml)
  - [fibaro-dimmer.yml](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/profiles/fibaro-dimmer.yml)
  - [fibaro-contact.yml](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/profiles/fibaro-contact.yml)
  - [fibaro-motion.yml](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/profiles/fibaro-motion.yml)
  - [fibaro-generic-sensor.yml](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/profiles/fibaro-generic-sensor.yml)
- Runtime entry point: [init.lua](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/init.lua)

### Implemented Discovery And Bootstrap

- [discovery.lua](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/discovery.lua) now keeps one manual HC2 bridge placeholder and performs required HC3 mDNS scans on `_http._tcp.local`.
- HC3 bridges are created from discovered serial number, host, port, and TXT metadata rather than from a fixed placeholder.
- [init.lua](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/init.lua) schedules HC3 mDNS scans at startup and on a recurring timer.
- [lifecycle.lua](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/handlers/lifecycle.lua) applies pending bridge identity metadata before bridge sync starts.
- [api.lua](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/fibaro/api.lua) now exposes:
  - `GET /api/loginStatus`
  - `GET /api/settings/info`
  - `GET /api/refreshStates`
  - `GET /api/devices`
  - `GET /api/devices/:id`
  - `POST /api/devices/:id/action/:actionName`
  - scene route helpers for both HC2 and HC3 route families

### Implemented Runtime Flow

- Bridge bootstrap now happens through `loginStatus` and `settings/info` before inventory sync.
- Controller family is derived from `platform` and `serialNumber`, then stored on the bridge through [fields.lua](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/fields.lua).
- [adapter.lua](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/fibaro/adapter.lua) selects HC2 or HC3 adapters from bootstrap info instead of relying only on `/devices` heuristics.
- [sync.lua](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/fibaro/sync.lua) now:
  - uses discovered HC3 endpoint data stored on the bridge
  - performs full inventory sync on startup and reconciliation
  - stores a `refreshStates` cursor on the bridge
  - uses incremental `refreshStates` polling during scheduled bridge polls
  - falls back to full inventory sync when incremental polling is not sufficient

### Implemented Mapping Changes

- [mapper.lua](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/fibaro/mapper.lua) still maps switch, dimmer, motion, contact, and generic sensor devices.
- The mapper now filters controller records, user records, disabled devices, and plugin or virtual-device style entries so `/api/devices` noise does not become SmartThings child devices.
- [hc2.lua](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/fibaro/adapters/hc2.lua) and [hc3.lua](C:/Prabu/Application/SmartThingsEdgeDrivers/drivers/Unofficial/fibaro-hc2/src/fibaro/adapters/hc3.lua) normalize booleans, device-role metadata, plugin markers, and controller-like records more consistently.

### Current Limits

- Scene HTTP route support exists in the client layer, but SmartThings scene devices are still not surfaced.
- Virtual devices and plugin devices are intentionally filtered out in this pass.
- Rooms, sections, plugins, and home metadata are not yet modeled as SmartThings entities.
- HC3 mDNS support is implemented against the mock contract, but real-controller DNS-SD parity still needs validation.
- HTTPS still uses relaxed certificate verification for local controller access.
- A real SmartThings package validation was not run here because the SmartThings CLI is not available in this environment.

### Next Practical Validation

1. Package and install the updated driver on a hub.
2. Validate HC2 through the manual bridge flow.
3. Validate HC3 through mDNS discovery with the updated mock server in `C:\Prabu\Application\Fibaro_lua`.
4. Confirm that controller and plugin records are not surfaced as SmartThings child devices.
5. Confirm that `refreshStates` updates child state without a full inventory refresh on every poll.
