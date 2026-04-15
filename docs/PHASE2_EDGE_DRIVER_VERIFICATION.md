# Phase 2 Edge Driver Verification Guide

Last updated: 2026-04-16

## Purpose

This document captures a repeatable validation flow for the Samsung SmartThings Edge `matter-energy` driver against the Phase 2 electrical simulator built from `connectedhomeip`.

Use this when validating electrical device behavior end-to-end without physical hardware.

## Scope

- Matter simulator repo: `connectedhomeip`
- Edge driver repo: `SmartThingsEdgeDrivers`
- Simulator branch: `virtual-Eclectrical-device`
- Edge driver package: `drivers/SmartThings/matter-energy`

### Device types covered by the simulator setup

- Endpoint 1: Electrical Sensor (`0x0510`)
- Endpoint 2: Device Energy Management (`0x050D`)
- Endpoint 3: Electrical Meter (`0x0514`)
- Endpoint 4: Electrical Utility Meter (`0x0511`)

Note: current `matter-energy` fingerprints include `0x0510`, `0x0514`, and `0x050D` profiles. `0x0511` support may be partial depending on capability mapping scope.

## Preconditions

- Linux or WSL2 environment
- SmartThings Hub on the same LAN as the simulator host
- SmartThings app signed in to the same account as the CLI profile
- SmartThings CLI installed and logged in
- Python 3.11+ for `connectedhomeip` activation/build

## 1) Build and Run the Phase 2 Simulator

Open terminal A:

```bash
cd /home/prabu/Desktop/connectedhomeip
source scripts/activate.sh -p linux
./scripts/build/build_examples.py --target linux-x64-phase2-energy-simulator build
./out/linux-x64-phase2-energy-simulator/chip-phase2-energy-simulator-app \
  --discriminator 3840 \
  --passcode 20202021 \
  --secured-device-port 5540 \
  --KVS /tmp/chip-phase2-kvs \
  --enable-key 000102030405060708090a0b0c0d0e0f
```

Keep terminal A running.

Expected startup indicators:

- `Server initialization complete`
- `Server Listening...`
- `Phase 2 Energy Simulator: Init`
- periodic `Phase 2 Telemetry: tick ...`

## 2) Run Controller Smoke Tests with chip-tool

Open terminal B:

```bash
cd /home/prabu/Desktop/connectedhomeip
source scripts/activate.sh -p linux
./scripts/build/build_examples.py --target linux-x64-chip-tool build
rm -rf /tmp/chip-tool-smoke && mkdir -p /tmp/chip-tool-smoke
./out/linux-x64-chip-tool/chip-tool pairing onnetwork 12344321 20202021 --storage-directory /tmp/chip-tool-smoke
```

Important CLI note:

- For this chip-tool build, `pairing onnetwork` takes only `node-id` and `pin` as positional args.
- Place options like `--storage-directory` after positional args.

Read key attributes:

```bash
./out/linux-x64-chip-tool/chip-tool descriptor read device-type-list 12344321 1 --storage-directory /tmp/chip-tool-smoke
./out/linux-x64-chip-tool/chip-tool descriptor read device-type-list 12344321 2 --storage-directory /tmp/chip-tool-smoke
./out/linux-x64-chip-tool/chip-tool descriptor read device-type-list 12344321 3 --storage-directory /tmp/chip-tool-smoke

./out/linux-x64-chip-tool/chip-tool deviceenergymanagement read esastate 12344321 2 --storage-directory /tmp/chip-tool-smoke
./out/linux-x64-chip-tool/chip-tool deviceenergymanagement read abs-max-power 12344321 2 --storage-directory /tmp/chip-tool-smoke

./out/linux-x64-chip-tool/chip-tool electricalenergymeasurement read cumulative-energy-imported 12344321 1 --storage-directory /tmp/chip-tool-smoke
./out/linux-x64-chip-tool/chip-tool electricalenergymeasurement read cumulative-energy-imported 12344321 3 --storage-directory /tmp/chip-tool-smoke
```

Example values seen during smoke runs:

- `ESAState: 1`
- `AbsMaxPower: 7200000`
- endpoint 1 `CumulativeEnergyImported.Energy` around `45,000,000+`
- endpoint 3 `CumulativeEnergyImported.Energy` around `52,000,000+`

## 3) Package and Install the SmartThings Edge Driver

Open terminal C:

```bash
cd /home/prabu/Desktop/SmartThingsEdgeDrivers/drivers/SmartThings/matter-energy
```

### Fast path (recommended)

```bash
smartthings edge:drivers:package . --install
```

This flow packages, uploads, assigns, and installs interactively.

### Explicit path (if you want full control)

Get IDs first:

```bash
smartthings devices --type HUB -j
smartthings edge:channels -j
smartthings edge:drivers -j
```

Then run:

```bash
smartthings edge:drivers:package .
smartthings edge:channels:assign <driver-id> --channel <channel-id>
smartthings edge:channels:enroll <hub-id> --channel <channel-id>
smartthings edge:drivers:install <driver-id> --hub <hub-id> --channel <channel-id>
```

Verify installation:

```bash
smartthings edge:drivers:installed
smartthings edge:drivers:devices --driver <driver-id>
```

## 4) Commission the Simulator in SmartThings App

- Open SmartThings app
- Add device -> Matter
- Scan QR from simulator output or enter manual code
- Complete commissioning

Network requirement:

- phone, hub, and simulator host must be on the same LAN

## 5) Verify Fingerprint Match and Profile Selection

Stream Edge logs:

```bash
smartthings edge:drivers:logcat --log-level info
```

Look for profile update lines from `matter-energy` driver logic, for example:

- `Updating device profile to electrical-sensor`
- `Updating device profile to electrical-meter`
- `Updating device profile to dem-standalone`

Fingerprint source:

- `drivers/SmartThings/matter-energy/fingerprints.yml`

Profile selection logic source:

- `drivers/SmartThings/matter-energy/src/init.lua`

## 6) Validate Capability Behavior in SmartThings

Cross-check SmartThings app values with chip-tool reads:

- `powerMeter.power` vs EPM `active-power`
- `energyMeter.energy` vs EEM `cumulative-energy-imported`
- DEM mode/state related UI vs DEM cluster values
- For meter profile, verify voltage/current when exposed

Suggested quick reads:

```bash
./out/linux-x64-chip-tool/chip-tool electricalpowermeasurement read active-power 12344321 1 --storage-directory /tmp/chip-tool-smoke
./out/linux-x64-chip-tool/chip-tool electricalpowermeasurement read voltage 12344321 3 --storage-directory /tmp/chip-tool-smoke
./out/linux-x64-chip-tool/chip-tool electricalpowermeasurement read active-current 12344321 3 --storage-directory /tmp/chip-tool-smoke
```

## 7) Pass Criteria

A verification run is considered good when:

1. Simulator stays running without assertion crash.
2. chip-tool commissioning and key reads succeed.
3. Device is onboarded in SmartThings.
4. Installed driver is `matter-energy`.
5. Logcat shows expected profile selection.
6. Capability values in SmartThings are consistent with chip-tool reads.

## 8) Troubleshooting

### Simulator not discoverable by SmartThings

- Verify LAN reachability and mDNS visibility
- Ensure phone/hub/host are on same network

### chip-tool pairing command fails by args

- Use:
  `pairing onnetwork <node-id> <pin> --storage-directory <dir>`
- Do not pass discriminator as a positional arg for `onnetwork`

### Stale commissioning state

```bash
rm -f /tmp/chip-phase2-kvs /tmp/chip-phase2-kvs-smoke
rm -rf /tmp/chip-tool-smoke
```

### Driver is installed but wrong profile selected

- Confirm device type exposure with `descriptor read device-type-list`
- Check `fingerprints.yml` entries and `init.lua` profile logic

## 9) Cleanup

```bash
pkill -f chip-phase2-energy-simulator-app || true
```

Optional unpair:

```bash
./out/linux-x64-chip-tool/chip-tool pairing unpair 12344321 --storage-directory /tmp/chip-tool-smoke
```
