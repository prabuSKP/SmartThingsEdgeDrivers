# Fibaro HC2 and HC3 Driver Notes

This document summarizes the contract the SmartThings Fibaro Edge driver now targets after the HC3 discovery and bootstrap work.

## Current Driver Behavior

The driver supports both controller families in one package:

- HC2 uses a manual bridge placeholder with user-entered host and credentials.
- HC3 requires mDNS discovery and creates bridge devices from the discovered controller identity.

## Bootstrap Contract

Before inventory sync, the driver now treats these endpoints as the controller bootstrap contract:

- `GET /api/loginStatus`
- `GET /api/settings/info`

The bridge uses `settings/info` as the source of truth for:

- controller family
- API generation
- `platform`
- `serialNumber`

Only after bootstrap does the driver move on to inventory and runtime state sync.

## Discovery Model

### HC2

- Manual placeholder bridge
- User enters host, protocol, username, and password
- Driver bootstraps with `loginStatus` and `settings/info`

### HC3

- mDNS discovery is required
- The driver scans `_http._tcp.local`
- It parses TXT values such as `platform`, `serialNumber`, `apiVersion`, and `path`
- Bridge identity is persisted by discovered serial number
- Discovered host, port, and scheme are stored on the bridge and used for runtime calls

Manual host entry remains in the profile only as an operator override or recovery path. It is not the primary HC3 onboarding path.

## Runtime Contract Used By The Driver

### Bootstrap

- `GET /api/loginStatus`
- `GET /api/settings/info`

### Inventory And Child State

- `GET /api/devices`
- `GET /api/devices/:id`

### Device Commands

- `POST /api/devices/:id/action/:actionName`

### Incremental State Feed

- `GET /api/refreshStates`
- `GET /api/refreshStates?last=<cursor>`

The driver still uses full inventory sync for startup and reconciliation, but it now stores a `refreshStates` cursor on the bridge and uses incremental change polling for normal bridge polls.

## Current Mapping Rules

The driver creates SmartThings child devices for:

- switch
- dimmer
- contact sensor
- motion sensor
- generic value-only sensor

The driver now explicitly filters out infrastructure-style inventory entries such as:

- controller devices
- user devices such as `HC_user`
- plugin and virtual-device style records
- disabled devices

This matters because the updated mock returns controller, user, plugin, and virtual-device records in `/api/devices`, not only end devices.

## Scene Status

The HTTP client now includes the route family needed to support both scene models:

- HC2: `POST /api/scenes/:id/action/start|stop`
- HC3: `POST /api/scenes/:id/execute|kill`

Scene devices are still not surfaced into SmartThings device models in this implementation pass.

## Mock Alignment Notes

The updated mock at `C:\Prabu\Application\Fibaro_lua` now aligns more closely with pyfibaro expectations:

- bootstrap reads happen through `loginStatus` and `settings/info`
- HC3 mDNS records can advertise `platform`, `serialNumber`, `apiVersion`, and `path`
- `/api/refreshStates` returns cursor-based incremental changes
- HC3 payloads use more native booleans and numbers

The SmartThings driver implementation now follows that model.

## Remaining Gaps

- No SmartThings scene device exposure yet
- No virtual-device or plugin support yet
- No verified real-HC3 mDNS parity capture beyond the mock contract
- HTTPS still uses relaxed certificate verification for local controller access

## Validation Focus

Use `API_PROFILE=hc2` and `API_PROFILE=hc3` separately during validation.

HC3 validation should confirm:

1. mDNS discovery creates the bridge without manual host entry
2. bridge bootstrap resolves controller family from `settings/info`
3. inventory excludes controller and plugin noise
4. `refreshStates` polling updates child devices after changes

HC2 validation should confirm:

1. manual bridge bootstrap still works
2. inventory and commands remain stable
3. full inventory sync still reconciles child creation and deletion
