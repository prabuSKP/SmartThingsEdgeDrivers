---
name: cloud-api-testing
description: >
  Test and verify SmartThings Edge driver states using the SmartThings Cloud REST API.
  Covers Personal Access Token (PAT) configuration, querying device lists (/v1/devices),
  retrieving device statuses (/v1/devices/{deviceId}/status), and sending commands.
  Use when validating if local driver event emissions successfully propagate to the cloud.
---

# SmartThings Cloud API Testing & Verification

While Edge drivers run locally on the hub, their state updates must propagate to the SmartThings Cloud for users to control them via the mobile app or automation routines.

This skill covers how to query and control your devices via the SmartThings Cloud REST API using `curl` to verify that your local driver is emitting states correctly.

---

## 1. Authentication & Token Setup

All requests to the SmartThings API require a Personal Access Token (PAT):
1. Go to the [SmartThings Personal Access Tokens page](https://account.smartthings.com/tokens).
2. Generate a new token with scopes: `devices`, `capabilities`, `locations`.
3. Save the token as an environment variable in your terminal:
   ```bash
   export ST_TOKEN="your_personal_access_token_here"
   ```

---

## 2. API Reference & Verifications

### A. List All Devices
To find the `deviceId` assigned to your locally-created Edge driver or child devices:

- **Endpoint**: `GET https://api.smartthings.com/v1/devices`
- **Request**:
  ```bash
  curl -H "Authorization: Bearer $ST_TOKEN" \
       https://api.smartthings.com/v1/devices
  ```

- **Verification**: Locate the device with the label or model matching your driver. Copy its `deviceId` (UUID).

---

### B. Retrieve Device Status
Verify if the capability events emitted locally on the hub (e.g. `device:emit_event(capabilities.switch.switch.on())`) have successfully updated the cloud representation.

- **Endpoint**: `GET https://api.smartthings.com/v1/devices/<deviceId>/status`
- **Request**:
  ```bash
  curl -H "Authorization: Bearer $ST_TOKEN" \
       https://api.smartthings.com/v1/devices/YOUR-DEVICE-UUID/status
  ```

- **Verification**: Check if the attributes in the JSON response match the latest physical state:
  ```json
  {
    "components": {
      "main": {
        "switch": {
          "switch": {
            "value": "on",
            "timestamp": "2026-05-27T12:00:00Z"
          }
        }
      }
    }
  }
  ```

---

### C. Send Command to Device
Simulate a command triggered from the SmartThings App to ensure your driver's command handlers (e.g., `handle_switch_on` registered in `init.lua`) are working properly.

- **Endpoint**: `POST https://api.smartthings.com/v1/devices/<deviceId>/commands`
- **Request**:
  ```bash
  curl -X POST \
       -H "Authorization: Bearer $ST_TOKEN" \
       -H "Content-Type: application/json" \
       -d '{
             "commands": [
               {
                 "component": "main",
                 "capability": "switch",
                 "command": "on",
                 "arguments": []
               }
             ]
           }' \
       https://api.smartthings.com/v1/devices/YOUR-DEVICE-UUID/commands
  ```

- **Verification**: Monitor the `logcat` stream. You should immediately see the driver invoke your capability handler for that device command.
