---
name: smartthings-c2c-devkit
description: >
  Build cloud-to-cloud (C2C) device integrations for SmartThings using
  SmartThings Schema. Covers OAuth 2.0 auth server setup, Schema App
  registration, AWS Lambda implementation with st-schema Node.js library,
  all interaction types (discovery, state refresh, commands, callbacks),
  device profiles and capabilities, and Works With SmartThings (WWST)
  certification. Use when a developer needs to: (1) create a Schema App
  for a cloud-connected device, (2) implement Lambda functions for
  SmartThings Schema interactions, (3) define device profiles and select
  capabilities, (4) understand OAuth 2.0 requirements for account linking,
  (5) navigate the WWST certification and publishing process, or (6)
  troubleshoot common C2C integration issues.
---

# SmartThings C2C Devkit

Comprehensive guide for building SmartThings Schema (cloud-to-cloud) device integrations and navigating WWST certification.

## Overview

SmartThings Schema allows cloud-connected devices to communicate with the SmartThings platform through a cloud-to-cloud integration. The integration consists of:

1. **Your OAuth 2.0 Authorization Server** — handles account linking
2. **Your Schema App** — a Lambda/webhook endpoint handling SmartThings interactions
3. **Device Profile** — defines capabilities and components for each device type

## Workflow

### Phase 1: Auth Server Setup

Your cloud must support OAuth 2.0 authorization code flow with multiple redirect URIs. See [Auth Server](references/auth-server.md).

### Phase 2: Create & Deploy Schema App

1. Write a Lambda function using the `st-schema` Node.js library
2. Deploy to AWS Lambda (supported regions listed in the docs)
3. Grant SmartThings permission to invoke the Lambda
4. Register the Schema App via SmartThings CLI

See [Schema App](references/schema-app.md).

### Phase 3: Define Device Profiles

Associate your devices with the right Device Profile and Capabilities. See [Device Profiles](references/device-profiles.md).

### Phase 4: Implement Interaction Types

Your Schema App must handle:
- **discoveryRequest** — return device list
- **stateRefreshRequest** — return current device states
- **commandRequest** — execute commands and return updated states
- **Callbacks** — push state changes proactively

See [Interaction Types](references/interaction-types.md).

### Phase 5: Submit for Certification

Test your integration, then submit via SmartThings Console. See [Certification](references/certification.md).

## Quick Start — Lambda Boilerplate

```bash
# Generate a complete Lambda for any device type
bash scripts/generate-lambda.sh --type switch --name "Smart Light" --output ./my-integration
```

See `scripts/generate-lambda.sh --help` for all options.

## Common Device Types & Capabilities

| Device Type | Key Capabilities |
|---|---|
| Switch/Outlet | `st.switch`, `st.switchLevel`, `st.powerMeter`, `st.energyMeter` |
| Light Bulb | `st.switch`, `st.switchLevel`, `st.colorControl`, `st.colorTemperature` |
| Thermostat | `st.thermostat`, `st.thermostatFanMode`, `st.thermostatMode`, `st.temperatureMeasurement` |
| Lock | `st.lock`, `st.battery` |
| Sensor | `st.motionSensor`, `st.contactSensor`, `st.temperatureMeasurement`, `st.battery` |
| Window Covering | `st.windowShade`, `st.switchLevel` |

Full reference: [Capabilities Reference](https://developer.smartthings.com/docs/devices/capabilities/capabilities-reference)

## Key Constraints

- **Always include `st.healthCheck`** in every state response — indicates online/offline
- **No PII in device details** except `friendlyName` and `roomName`
- **Encrypt `deviceCookie`** if it contains PII
- **deviceUniqueId** should match Alexa Skill `customIdentifier` if applicable
- **OAuth 2.0** must support authorization code flow with multiple redirect URIs
- **Self-test thoroughly** before submitting for certification — re-tests cost money

## Troubleshooting

- **Schema App not appearing in Console**: May not be associated with an Organization. Use `smartthings schema --organization [orgUUID]`
- **OAuth redirect loop**: Ensure authorization page requires explicit user tap (no auto-approve)
- **Certification errors**: Run the [SmartThings Test Suite](https://developer.smartthings.com/console/test) before submitting
- **403 on PAT app creation**: Create the app on a normal machine using SmartThings CLI login flow, then set client id/secret manually

## References

- [SmartThings C2C Docs](https://developer.smartthings.com/docs/devices/cloud-connected/get-started)
- [st-schema NPM Package](https://www.npmjs.com/package/st-schema)
- [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli)
- [SmartThings Console](https://developer.smartthings.com/console)
- [Capabilities Reference](https://developer.smartthings.com/docs/devices/capabilities/capabilities-reference)
- [WWST Certification](https://developer.smartthings.com/docs/certification/overview)
