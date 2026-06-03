---
name: smartthings-edge-packaging
description: >
  Package and install custom SmartThings Edge drivers onto the SmartThings Hub using SmartThings CLI.
  Covers the full command lifecycle: package, channel creation, channel assignment, hub enrollment,
  and driver installation. Provides clear recovery steps for common validation and API errors (e.g. 422 Unprocessable Entity).
---

# SmartThings Edge Driver Packaging & Installation

This skill covers the complete lifecycle of packaging, enrolling, and installing a SmartThings Edge driver onto a hub using the SmartThings CLI. Use this when the user requests packaging, deployment, channel enrollment, or installation of the Edge driver on a SmartThings hub.

## 1. Authentication Check

Before running any deployment commands, verify the CLI authentication status and configuration:

```bash
# Check if CLI is logged in
smartthings config
```

If the credentials are not set, warn the user. The CLI usually automatically authenticates using `config.yaml` or browser-based login flow.

## 2. Driver Packaging & Deployment Workflow

Always follow these steps sequentially to package and deploy:

### Step 1: Package the Driver
This builds the package and uploads it to the SmartThings Developer Console. It performs validation on the driver's layout, profiles, metadata, and Lua syntax.

```bash
smartthings edge:drivers:package <driver-directory-path>
```
**Example output:**
```
Driver Id:   89df0b6a-93f5-46fa-9a57-1ccb7a695b28
Name:        Fibaro HC2/HC3 Bridge
Package Key: fibaro-bridge-driver
Version:     2026-06-03T10:30:15.123Z
```

### Step 2: Retrieve Available Channels
Drivers must be assigned to a Channel before they can be installed on a Hub. Check for existing channels:

```bash
smartthings edge:channels --json
```

If no channel exists, create one:
```bash
smartthings edge:channels:create --json <<'EOF'
{
  "name": "Custom Edge Drivers",
  "description": "Channel for local custom Edge drivers",
  "termsOfServiceUrl": "https://samsung.com"
}
EOF
```

### Step 3: Assign Driver to Channel
Assign the newly packaged driver (using its `Driver Id` from Step 1) to the chosen channel (using `Channel Id` from Step 2):

```bash
smartthings edge:channels:assign <driver-id> --channel <channel-id>
```

### Step 4: Retrieve Available Hubs
Identify the Target Hub where the driver should be installed:

```bash
smartthings devices --json | jq '[.[] | select(.type == "HUB") | {deviceId, label}]'
```

### Step 5: Enroll Hub in Channel
Ensure the target hub is enrolled in the driver channel. This is a one-time operation per channel/hub pair:

```bash
smartthings edge:channels:enroll <hub-device-id> --channel <channel-id>
```

### Step 6: Install the Driver
Finally, install the driver onto the hub:

```bash
smartthings edge:drivers:install <driver-id> --hub <hub-device-id> --channel <channel-id>
```

### Step 7: Verify Installation
Verify that the driver was successfully installed and is active on the hub:

```bash
smartthings edge:drivers:installed --hub <hub-device-id> --json
```

---

## 3. Resolving 422 (Unprocessable Entity) Errors

A `422 Unprocessable Entity` response from `smartthings edge:drivers:package` indicates API validation failure. Common causes and fixes are:

### A. Invalid Profile Categories
The `categories:` section in any profile `profiles/*.yml` file contains an invalid or non-standard category.
- **Fix**: Cross-reference the Category Reference table in the `smartthings-profile-generation` skill. Only use verified category names:
  - Use `TempSensor` (NOT `TemperatureSensor`)
  - Use `LeakSensor` (NOT `WaterSensor`)
  - Use `Blind` (NOT `Blinds` or `BlindController`)
  - Use `Bridges` (NOT `Bridge`)
  - Use `SmartLock` (NOT `Lock`)
  - Use `Light` (NOT `Dimmer`)
  - Use `GenericSensor` (NOT `Sensor` or `Other`)

### B. Missing Profile Fields
The profile YAML lacks a top-level `name:` field, or the component IDs are duplicate.
- **Fix**: Check `profiles/*.yml` for `name: vendor-profile-name` at the top level and ensure component IDs are unique (e.g. `main`, `switch2`).

### C. Profile Naming Mismatch in Lua code
A Lua file attempts to instantiate a profile name that is not present in the `profiles/` directory, or is mismatched by case.
- **Fix**: Run `grep -rn "profile =" src/` and verify that each profile name matches the `name:` field in a profile YAML file exactly.

### D. Lua Syntax Errors
If a Lua file has a syntax error, packaging might fail.
- **Fix**: Validate syntax locally using `luac` before packaging:
  ```bash
  luac -p src/**/*.lua
  ```
