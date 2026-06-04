---
name: ota-analysis
description: >
  Understand and manage Over-the-Air (OTA) driver deployments and device firmware updates
  in SmartThings Edge. Covers driver packaging lifecycle updates, checking firmware
  versions, hub beta/production channels, and OTA updates for Zigbee/Z-Wave/Matter devices.
  Use when: (1) planning automated driver release processes, (2) diagnosing device firmware
  compatibility, or (3) troubleshooting state loss during hot driver updates.
---

# Over-the-Air (OTA) Updates & Driver Deployments

This skill explains how the SmartThings Hub applies Over-the-Air (OTA) updates to driver packages and how to manage and troubleshoot connected device firmware updates.

---

## 1. Driver Package OTA Updates

When you package and publish an updated Edge driver, the hub pulls it down and restarts the local driver runtime.

### The Deployment Lifecycle
1. **Package**: You execute `smartthings edge:drivers:package` which compiles files and uploads the bundle to the SmartThings Cloud.
2. **Assign**: The driver is assigned to a hub channel (`smartthings edge:channels:assign`).
3. **Pull**: The hub automatically checks for updates on the channel (usually within 12–24 hours, or immediately if triggered manually).
4. **Hot Reload**:
   - The hub spawns the new driver version in parallel.
   - The hub shuts down the old driver, calling `removed` or cleaning up active threads.
   - The hub starts the new driver, triggering the `init` lifecycle callback for every device.

### Preventing State Loss During Driver Upgrades
To ensure that device configurations, IP addresses, and state cursors survive driver updates, **always** write critical metadata fields to the persistent datastore using the `{persist = true}` option:

```lua
-- Will survive driver reloads and hub power cycles
device:set_field("last_event_id", 450912, {persist = true})
```

---

## 2. Connected Device Firmware Updates (OTA)

SmartThings Hub v2 and v3 support OTA firmware updates for paired Zigbee and Z-Wave devices.

### A. Zigbee OTA Updates
Zigbee devices check for OTA files by sending Query Next Image requests to the hub. The hub downloads matching firmwares from the SmartThings Cloud.

- **Requirements**: The device must report its manufacturer and model matching an approved firmware catalog.
- **Enabling OTA**: Ensure "Secure join" and "Device firmware updates" are enabled in the Hub utilities menu inside the SmartThings App.

### B. Z-Wave OTA Updates
Z-Wave OTA utilizes the `FirmwareUpdateMd` (Firmware Update Meta Data) Command Class.
- Devices must support Z-Wave OTA.
- Firmware updates must be initiated by the hub using target hex binaries.

---

## 3. Querying Firmware Versions

Use the SmartThings CLI to check active firmware versions on the hub or connected devices:

### Get Hub Info
There is **no `smartthings hubs` command** (it prints the full CLI help). List hubs by filtering the device list, then read the hub's detail:
```bash
smartthings devices --json | jq '[.[] | select(.type=="HUB") | {deviceId, label}]'
smartthings devices <hub-device-id> --json
```
*Verification*: Check the `firmwareVersion` attribute to confirm the Hub is running the minimum firmware required for your driver features.

### Get Device Firmware
Query specific device details to view the `firmware` or `hardware` version reported by the device description:
```bash
smartthings devices YOUR-DEVICE-UUID -j
```
*Verification*: Inspect the `firmwareVersion` field in the JSON output.
