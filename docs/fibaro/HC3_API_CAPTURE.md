# Fibaro HC3 API Capture

This document records what we can currently verify about Fibaro Home Center 3 API behavior for the SmartThings Edge integration work.

It intentionally separates:

- confirmed information taken from official Fibaro sources,
- inferred behavior that is likely but not fully verified from public docs in this environment,
- items that still require capture from a live HC3 controller or the built-in HC3 Swagger UI.

## Scope

Target endpoints for the first HC3 comparison pass:

- `GET /api/devices`
- `GET /api/devices/:id`
- `POST /api/devices/:id/action/:actionName`
- `GET /api/scenes`

## Summary

Current conclusion:

- The current mock server is still an HC2-style mock.
- HC3 appears to keep the `/api/devices/:id/action/:actionName` pattern.
- HC3 scene execution appears to use `POST /api/scenes/:id/execute`.
- Public Fibaro pages available from this environment do not expose enough machine-readable HC3 response schema detail to safely claim exact request and response payload parity for `GET /api/devices`, `GET /api/devices/:id`, or `GET /api/scenes`.

## Capture Matrix

### 1. `GET /api/devices`

Status: `probable, not yet payload-verified`

What we know:

- HC3 clearly has a device inventory model in the web UI and automation model.
- HC3 manuals describe device-centric concepts, controller-side device management, and device reporting.
- The HC3 documentation entry point exists at the official HC3 REST API page.

What we do not yet have from public docs in this environment:

- exact example response body,
- exact top-level array or object shape,
- exact field names for HC3 controller entries,
- whether HC3 returns Quick Apps, plugins, child devices, and controller records in exactly the same shape as HC2.

Working assumption for implementation planning:

- The endpoint likely still exists and returns a device inventory list.
- The payload is likely similar enough in concept to HC2 that an adapter layer can normalize it.
- We should not assume the HC2 fields are identical until we capture a real HC3 response.

Required live capture:

- one full `GET /api/devices` response from a real HC3,
- one inventory snapshot that includes at least:
  - a binary switch,
  - a dimmer,
  - a contact sensor,
  - a motion sensor,
  - one Quick App or child device if present.

### 2. `GET /api/devices/:id`

Status: `probable, not yet payload-verified`

What we know:

- Fibaro HC2 and HC3 both use device IDs extensively in UI and action APIs.
- HC3 command examples publicly discussed by Fibaro users target `/api/devices/:id/action/:actionName`, which strongly implies device-by-ID reads also exist.

What we do not yet have from public docs in this environment:

- exact response body for a single HC3 device,
- whether the single-device response is identical to an element from `GET /api/devices`,
- exact action list representation,
- whether HC3 uses additional metadata fields that the current mock does not model.

Working assumption for implementation planning:

- The endpoint likely exists and returns one device object.
- The SmartThings driver should treat the device response as controller-specific and normalize it through an HC3 adapter instead of reusing HC2 mapping blindly.

Required live capture:

- one `GET /api/devices/:id` for each representative device type used by the driver,
- at minimum one controllable actuator and one read-only sensor.

### 3. `POST /api/devices/:id/action/:actionName`

Status: `route pattern highly likely, response semantics not fully verified`

What we know:

- Official HC3 REST API documentation exists on the Fibaro HC3 developer site.
- HC3 community examples consistently use:

```http
POST /api/devices/:id/action/:actionName
Content-Type: application/json

{"args":[]}
```

- Public HC3 discussion on the official Fibaro forum shows this route being used for actions such as `turnOn`.

What we do not yet have fully verified from official docs in this environment:

- whether the success response is always `202 Accepted`,
- exact response body shape on success,
- whether `delay` is optional or supported,
- whether all actions use `args` only or some use additional fields.

Known HC3 risk relative to the current mock:

- The current mock returns `200` with an empty body.
- HC3 examples discussed publicly indicate asynchronous acceptance semantics may return a job-style body, for example an `id` and `timestamp`.

Implementation implication:

- The Edge driver should not depend on an empty-body `200` contract.
- The mock server should gain an HC3 mode that can return HC3-style async acceptance if live capture confirms it.

Required live capture:

- one successful `turnOn`,
- one successful `turnOff`,
- one successful `setValue`,
- one unsupported action,
- one malformed payload case.

### 4. `GET /api/scenes`

Status: `probable, not yet payload-verified`

What we know:

- HC3 manuals show scenes as a first-class controller object with run, enable, disable, and configuration behavior.
- HC3 scene execution is publicly described as `POST /api/scenes/:id/execute`.
- This strongly implies a list/read API for scenes still exists.

What we do not yet have from public docs in this environment:

- exact `GET /api/scenes` response body,
- exact scene fields,
- whether HC3 still uses fields such as `runningInstances`, `isLua`, `autostart`, and `roomID` in the same form as HC2,
- whether manual scenes, block scenes, Lua scenes, and Quick App related scenes share one schema.

Implementation implication:

- We should not reuse HC2 `scenes.json` as an HC3 contract.
- Scene support should remain behind an HC3 adapter until live payloads are captured.

Required live capture:

- one `GET /api/scenes` response from a real HC3,
- one scene detail example if HC3 exposes a separate scene-by-ID read endpoint,
- one execute response from `POST /api/scenes/:id/execute`.

## Gap Against Current Mock

Current mock behavior in this repository:

- models HC2 controller and HC2-shaped device inventory,
- returns `200` empty body for device actions,
- exposes HC2-style scene objects,
- does not implement HC3 scene execute flow,
- does not model Quick Apps as an HC3-first concept.

Therefore:

- keep the current mock as `hc2`,
- add a separate `hc3` mode or a second mock profile,
- do not relabel the current mock as HC3-compatible.

## What Can Be Treated As Confirmed Today

Confirmed from official/public Fibaro material:

- HC3 has an official REST API surface.
- HC3 is device-centric and scene-centric.
- HC3 scenes are executable from the controller interface.

Confirmed enough for planning, but still needing live payload capture before code contract hardening:

- `POST /api/devices/:id/action/:actionName`
- `POST /api/scenes/:id/execute`

Not confirmed enough yet to freeze response contracts:

- exact `GET /api/devices` payload shape,
- exact `GET /api/devices/:id` payload shape,
- exact `GET /api/scenes` payload shape,
- exact success and error body format for device actions.

## Recommended Next Capture Step

Use a real HC3 and collect:

1. `GET /api/devices`
2. `GET /api/devices/:id`
3. `POST /api/devices/:id/action/:actionName`
4. `GET /api/scenes`
5. `POST /api/scenes/:id/execute`

For each call, record:

- method,
- URL,
- request headers,
- request body,
- status code,
- raw JSON response body,
- notes about whether the response is synchronous or asynchronous.

## Sources

- Official HC3 API landing page: <https://www.fibaro.com/dev/specs/hc3/>
- Official HC3 manual: <https://manuals.fibaro.com/home-center-3/>
- Official HC3 scenes manual: <https://manuals.fibaro.com/document/hc3-scenes/>

Note:

- The HC3 API landing page is Swagger-style and the public crawler available in this environment does not expose the full interactive schema content.
- Because of that limitation, exact response examples still need to be captured from a live HC3 controller or a direct Swagger export.
