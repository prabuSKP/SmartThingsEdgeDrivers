# Matter Energy Driver - Complete Log Reference

**Driver:** `matter-energy`  
**Version:** 1.0 (Matter 1.5 Electrical Device Support - MVP Tier 1)  
**Last Updated:** April 2026  
**Supported Device Types:** EVSE (0x050C), Solar Power (0x0017), Battery Storage (0x0018), Electrical Sensor (0x0510), Electrical Meter (0x0514), Device Energy Management (0x050D)

---

## Table of Contents

1. [Driver Startup Logs](#1-driver-startup-logs)
2. [Device Lifecycle Logs](#2-device-lifecycle-logs)
3. [Profile Selection Logs by Device Type](#3-profile-selection-logs-by-device-type)
4. [Attribute Handler Logs](#4-attribute-handler-logs)
5. [Capability Handler Logs](#5-capability-handler-logs)
6. [Energy Reporting Logs](#6-energy-reporting-logs)
7. [Error and Warning Logs](#7-error-and-warning-logs)
8. [Multi-Endpoint Aggregation Logs](#8-multi-endpoint-aggregation-logs)
9. [Log Level Guide](#9-log-level-guide)
10. [Troubleshooting with Logs](#10-troubleshooting-with-logs)

---

## 1. Driver Startup Logs

### 1.1 Driver Initialization

**When:** Driver starts on SmartThings Hub

**Log Entry:**
```
[INFO] matter-energy: Starting matter-energy driver, with dispatcher: <dispatcher_address>
```

**Expected Output:**
```
[INFO] matter-energy: Starting matter-energy driver, with dispatcher: 0x7f8a1c002400
```

**What to Verify:**
- Driver name is `matter-energy`
- Dispatcher address is non-null

---

## 2. Device Lifecycle Logs

### 2.1 Device Init (`device_init`)

**When:** Device is first recognized by the driver

**Log Entries:**
```
[INFO] matter-energy: Device init: <device-id>, endpoints: <count>
[DEBUG] matter-energy: Subscription request sent for all attributes
[DEBUG] matter-energy: Endpoint mapping functions configured
[DEBUG] matter-energy: EVSE device detected - emitting default targetEndTime
[INFO] matter-energy: Energy measurement: <n> endpoints found, <m> support cumulative energy
[WARN] matter-energy: Cumulative energy NOT supported - using periodic reporting fallback
```

**Example - EVSE Device:**
```
[INFO] matter-energy: Device init: abc12345-def6-7890, endpoints: 2
[DEBUG] matter-energy: Subscription request sent for all attributes
[DEBUG] matter-energy: Endpoint mapping functions configured
[DEBUG] matter-energy: EVSE device detected - emitting default targetEndTime
[INFO] matter-energy: Energy measurement: 1 endpoints found, 1 support cumulative energy
```

**Example - Electrical Sensor (No Cumulative):**
```
[INFO] matter-energy: Device init: xyz98765-abc1-2345, endpoints: 1
[DEBUG] matter-energy: Subscription request sent for all attributes
[DEBUG] matter-energy: Endpoint mapping functions configured
[INFO] matter-energy: Energy measurement: 1 endpoints found, 0 support cumulative energy
[WARN] matter-energy: Cumulative energy NOT supported - using periodic reporting fallback
```

### 2.2 Device Added (`device_added`)

**When:** Device is added to the hub

**Log Entries:**
```
[DEBUG] matter-energy: Device added: <device-id>, manufacturer: <name>, product: <name>
[DEBUG] matter-energy: EVSE device: setting component map - electricalSensor=EP<n>, deviceEnergyManagement=EP<m>
```

**Example:**
```
[DEBUG] matter-energy: Device added: abc12345-def6-7890, manufacturer: Samsung, product: Matter EVSE
[DEBUG] matter-energy: EVSE device: setting component map - electricalSensor=EP2, deviceEnergyManagement=EP3
```

### 2.3 Do Configure (`do_configure`)

**When:** Device profile is being selected and configured

**Log Entries:**
```
[INFO] matter-energy: doConfigure: Starting profile selection for <device-id>
[DEBUG] matter-energy: Device type detection - EVSE: <n>, Solar: <n>, Battery: <n>, Sensor: <n>, Meter: <n>, DEM: <n>
[DEBUG] matter-energy: EVSE device detected on endpoints: <list>
[DEBUG] matter-energy: Cluster detection - EPM: <n> endpoints, EEM: <n> endpoints, DEMMode: <n> endpoints
[DEBUG] matter-energy: Adding -energy-meas to profile (EEM cluster present)
[DEBUG] matter-energy: Adding -power-meas to profile (EPM cluster present)
[DEBUG] matter-energy: Adding -energy-mgmt-mode to profile (DEMMode cluster present)
[INFO] matter-energy: Updating device profile to <profile-name>
```

**Example - Full EVSE Profile:**
```
[INFO] matter-energy: doConfigure: Starting profile selection for abc12345-def6-7890
[DEBUG] matter-energy: Device type detection - EVSE: 1, Solar: 0, Battery: 0, Sensor: 1, Meter: 0, DEM: 1
[DEBUG] matter-energy: EVSE device detected on endpoints: 1
[DEBUG] matter-energy: Cluster detection - EPM: 1 endpoints, EEM: 1 endpoints, DEMMode: 1 endpoints
[DEBUG] matter-energy: Adding -energy-meas to profile (EEM cluster present)
[DEBUG] matter-energy: Adding -power-meas to profile (EPM cluster present)
[DEBUG] matter-energy: Adding -energy-mgmt-mode to profile (DEMMode cluster present)
[INFO] matter-energy: Updating device profile to evse-energy-meas-power-meas-energy-mgmt-mode
```

### 2.4 Info Changed (`info_changed`)

**When:** Device capabilities or configuration changes

**Log Entries:**
```
(No explicit logs - subscription happens silently)
```

### 2.5 Device Removed (`device_removed`)

**When:** Device is removed from the hub

**Log Entries:**
```
[INFO] matter-energy: device removed
```

**Example:**
```
[INFO] matter-energy: device removed
```

---

## 3. Profile Selection Logs by Device Type

### 3.1 EVSE Device Profiles

#### 3.1.1 Basic EVSE (No EEM, No DEMMode)
```
[DEBUG] matter-energy: Device type detection - EVSE: 1, Solar: 0, Battery: 0, Sensor: 0, Meter: 0, DEM: 0
[DEBUG] matter-energy: EVSE device detected on endpoints: 1
[DEBUG] matter-energy: Cluster detection - EPM: 0 endpoints, EEM: 0 endpoints, DEMMode: 0 endpoints
[INFO] matter-energy: Updating device profile to evse
```

#### 3.1.2 EVSE + Energy Measurement
```
[DEBUG] matter-energy: Cluster detection - EPM: 0 endpoints, EEM: 1 endpoints, DEMMode: 0 endpoints
[DEBUG] matter-energy: Adding -energy-meas to profile (EEM cluster present)
[INFO] matter-energy: Updating device profile to evse-energy-meas
```

#### 3.1.3 EVSE + Power Measurement
```
[DEBUG] matter-energy: Cluster detection - EPM: 1 endpoints, EEM: 0 endpoints, DEMMode: 0 endpoints
[DEBUG] matter-energy: Adding -power-meas to profile (EPM cluster present)
[INFO] matter-energy: Updating device profile to evse-power-meas
```

#### 3.1.4 EVSE + EEM + EPM + DEMMode (Full)
```
[DEBUG] matter-energy: Cluster detection - EPM: 1 endpoints, EEM: 1 endpoints, DEMMode: 1 endpoints
[DEBUG] matter-energy: Adding -energy-meas to profile (EEM cluster present)
[DEBUG] matter-energy: Adding -power-meas to profile (EPM cluster present)
[DEBUG] matter-energy: Adding -energy-mgmt-mode to profile (DEMMode cluster present)
[INFO] matter-energy: Updating device profile to evse-energy-meas-power-meas-energy-mgmt-mode
```

### 3.2 Electrical Sensor Profiles

#### 3.2.1 Electrical Sensor (No Voltage)
```
[INFO] matter-energy: doConfigure: Starting profile selection for <device-id>
[DEBUG] matter-energy: Device type detection - EVSE: 0, Solar: 0, Battery: 0, Sensor: 1, Meter: 0, DEM: 0
[DEBUG] matter-energy: Standalone Electrical Sensor detected on endpoints: 1
[INFO] matter-energy: Updating device profile to electrical-sensor
```

#### 3.2.2 Electrical Sensor + Voltage + Current
```
[INFO] matter-energy: doConfigure: Starting profile selection for <device-id>
[DEBUG] matter-energy: Device type detection - EVSE: 0, Solar: 0, Battery: 0, Sensor: 1, Meter: 0, DEM: 0
[DEBUG] matter-energy: Standalone Electrical Sensor detected on endpoints: 1
[DEBUG] matter-energy: Voltage attribute found on endpoint 1
[DEBUG] matter-energy: Voltage detection result: YES, selecting profile: electrical-sensor-voltage-current
[INFO] matter-energy: Updating device profile to electrical-sensor-voltage-current
```

### 3.3 Electrical Meter Profile

```
[INFO] matter-energy: doConfigure: Starting profile selection for <device-id>
[DEBUG] matter-energy: Device type detection - EVSE: 0, Solar: 0, Battery: 0, Sensor: 0, Meter: 1, DEM: 0
[DEBUG] matter-energy: Standalone Electrical Meter detected on endpoints: 1
[INFO] matter-energy: Updating device profile to electrical-meter
```

### 3.4 DEM Standalone Profile

```
[INFO] matter-energy: doConfigure: Starting profile selection for <device-id>
[DEBUG] matter-energy: Device type detection - EVSE: 0, Solar: 0, Battery: 0, Sensor: 0, Meter: 0, DEM: 1
[DEBUG] matter-energy: Standalone DEM detected on endpoints: 1
[INFO] matter-energy: Updating device profile to dem-standalone
```

### 3.5 Solar Power Profile

```
[INFO] matter-energy: doConfigure: Starting profile selection for <device-id>
[DEBUG] matter-energy: Device type detection - EVSE: 0, Solar: 1, Battery: 0, Sensor: 0, Meter: 0, DEM: 0
[INFO] matter-energy: Updating device profile to solar-power
```

### 3.6 Battery Storage Profile

```
[INFO] matter-energy: doConfigure: Starting profile selection for <device-id>
[DEBUG] matter-energy: Device type detection - EVSE: 0, Solar: 0, Battery: 1, Sensor: 0, Meter: 0, DEM: 0
[INFO] matter-energy: Updating device profile to battery-storage
```

### 3.7 Error - No Matching Device Type

```
[INFO] matter-energy: doConfigure: Starting profile selection for <device-id>
[DEBUG] matter-energy: Device type detection - EVSE: 0, Solar: 0, Battery: 0, Sensor: 0, Meter: 0, DEM: 0
[WARN] matter-energy: doConfigure: No matching device type found - using default profile
```

---

## 4. Attribute Handler Logs

### 4.1 Electrical Power Measurement Cluster (0x0090)

#### 4.1.1 ActivePower Attribute
**Log Entries:**
```
[DEBUG] matter-energy: ActivePower received: EP=<id>, Value=<mW> mW (<W> W)
[WARN] matter-energy: ActivePower: Received nil value, ignoring report
[DEBUG] matter-energy: Power routing: is_aggregation=<bool>, is_standalone=<bool>
[DEBUG] matter-energy: Power aggregation: EP<id>=<W>W, Total=<W>W
```

**Example - Normal Reading:**
```
[DEBUG] matter-energy: ActivePower received: EP=1, Value=1500000 mW (1500.00 W)
[DEBUG] matter-energy: Power routing: is_aggregation=false, is_standalone=true
[DEBUG] matter-energy: Power aggregation: EP1=1500.00W, Total=1500.00W
```

**Example - Nil Value (Error):**
```
[DEBUG] matter-energy: ActivePower received: EP=1, Value=0 mW (0.00 W)
[WARN] matter-energy: ActivePower: Received nil value, ignoring report
```

#### 4.1.2 Voltage Attribute
**Log Entries:**
```
[DEBUG] matter-energy: EPM[EP<id>]: V=<V>V I=0.00A P=0.00W
```

**Example:**
```
[DEBUG] matter-energy: EPM[EP1]: V=230.00V I=0.00A P=0.00W
```

#### 4.1.3 ActiveCurrent Attribute
**Log Entries:**
```
[DEBUG] matter-energy: EPM[EP<id>]: V=0.00V I=<A>A P=0.00W
```

**Example:**
```
[DEBUG] matter-energy: EPM[EP1]: V=0.00V I=6.50A P=0.00W
```

#### 4.1.4 PowerMode Attribute
**No explicit debug logs** - Direct capability emission

**Capability Emitted:**
- AC → `powerSource.powerSource.mains()`
- DC → `powerSource.powerSource.dc()`
- Other → `powerSource.powerSource.unknown()`

### 4.2 Electrical Energy Measurement Cluster (0x0091)

#### 4.2.1 Cumulative Energy Imported
**Log Entries:**
```
[DEBUG] matter-energy: Cumulative Energy Imported: EP=<id>, Raw=<mWh> mWh
[DEBUG] matter-energy: Energy report: Imported=<Wh> Wh, Total=<Wh> Wh, Component=main
```

**Example:**
```
[DEBUG] matter-energy: Cumulative Energy Imported: EP=1, Raw=45000000 mWh
[DEBUG] matter-energy: Energy report: Imported=45000 Wh, Total=45000 Wh, Component=main
```

#### 4.2.2 Cumulative Energy Exported
**Log Entries:**
```
[DEBUG] matter-energy: Cumulative Energy Exported: EP=<id>, Raw=<mWh> mWh
[DEBUG] matter-energy: Energy report: Exported=<Wh> Wh, Total=<Wh> Wh, Component=exportedEnergy
```

**Example:**
```
[DEBUG] matter-energy: Cumulative Energy Exported: EP=1, Raw=12000000 mWh
[DEBUG] matter-energy: Energy report: Exported=12000 Wh, Total=12000 Wh, Component=exportedEnergy
```

#### 4.2.3 Periodic Energy Imported
**Log Entries:**
```
[DEBUG] matter-energy: Periodic Energy Imported: EP=<id>, Raw=<mWh> mWh
[DEBUG] matter-energy: Energy report: Periodic report ignored (cumulative supported)
   OR
[DEBUG] matter-energy: Energy report: Periodic added to cumulative, EP<id> total=<Wh> Wh
[DEBUG] matter-energy: Energy report: Imported=<Wh> Wh, Total=<Wh> Wh, Component=main
```

**Example - Cumulative Supported (Periodic Ignored):**
```
[DEBUG] matter-energy: Periodic Energy Imported: EP=1, Raw=500000 mWh
[DEBUG] matter-energy: Energy report: Periodic report ignored (cumulative supported)
```

**Example - Cumulative NOT Supported (Periodic Used):**
```
[DEBUG] matter-energy: Periodic Energy Imported: EP=1, Raw=500000 mWh
[DEBUG] matter-energy: Energy report: Periodic added to cumulative, EP1 total=500 Wh
[DEBUG] matter-energy: Energy report: Imported=500 Wh, Total=500 Wh, Component=main
```

#### 4.2.4 Periodic Energy Exported
**Log Entries:**
```
[DEBUG] matter-energy: Periodic Energy Exported: EP=<id>, Raw=<mWh> mWh
[DEBUG] matter-energy: Energy report: Periodic report ignored (cumulative supported)
   OR
[DEBUG] matter-energy: Energy report: Periodic added to cumulative, EP<id> total=<Wh> Wh
[DEBUG] matter-energy: Energy report: Exported=<Wh> Wh, Total=<Wh> Wh, Component=exportedEnergy
```

### 4.3 Energy Evse Cluster (0x0099)

#### 4.3.1 State Attribute
**No explicit debug logs** - Direct capability emission

**Capability Emitted:**
- `0x00` → `evseState.state.notPluggedIn()`
- `0x01` → `evseState.state.pluggedInNoDemand()`
- `0x02` → `evseState.state.pluggedInDemand()`
- `0x03` → `evseState.state.pluggedInCharging()`
- `0x04` → `evseState.state.sessionEnding()`
- `0x05` → `evseState.state.fault()`

**Error Log:**
```
[WARN] evse_state_handler invalid EVSE State: <value>
```

#### 4.3.2 SupplyState Attribute
**No explicit debug logs** - Direct capability emission

**Capability Emitted:**
- `0x00` → `evseState.supplyState.disabled()`
- `0x01` → `evseState.supplyState.chargingEnabled()`
- `0x02` → `evseState.supplyState.dischargingEnabled()`
- `0x03` → `evseState.supplyState.disabledError()`
- `0x04` → `evseState.supplyState.disabledDiagnostics()`

**Error Log:**
```
[WARN] evse_supply_state_handler invalid EVSE Supply State: <value>
```

#### 4.3.3 FaultState Attribute
**No explicit debug logs** - Direct capability emission

**Error Log:**
```
[WARN] Invalid EVSE fault state received: <value>
```

#### 4.3.4 ChargingEnabledUntil Attribute
**No explicit debug logs** - Direct capability emission

**Error Log:**
```
[WARN] Charging enabled handler received an invalid target end time, not reporting
```

#### 4.3.5 MinimumChargeCurrent Attribute
**No explicit debug logs** - Direct capability emission

**Error Log:**
```
[WARN] Failed to emit capability for evseChargingSession.minCurrent
```

#### 4.3.6 MaximumChargeCurrent Attribute
**No explicit debug logs** - Direct capability emission

**Error Log:**
```
[WARN] Failed to emit capability for evseChargingSession.maxCurrent
```

#### 4.3.7 SessionDuration Attribute
**No explicit debug logs** - Direct capability emission

**Error Log:**
```
[WARN] evse_session_duration_handler received invalid EVSE Session Duration
```

#### 4.3.8 SessionEnergyCharged Attribute
**No explicit debug logs** - Direct capability emission

**Error Log:**
```
[WARN] evse_session_energy_charged_handler received invalid EVSE Session Energy Charged
```

### 4.4 Energy EvseMode Cluster (0x009D)

#### 4.4.1 SupportedModes Attribute
**No explicit debug logs** - Direct capability emission

**Capabilities Emitted:**
```
[DEBUG] mode.supportedModes: ["Normal", "Eco", "Fast"]
[DEBUG] mode.supportedArguments: ["Normal", "Eco", "Fast"]
```

#### 4.4.2 CurrentMode Attribute
**No explicit debug logs** - Direct capability emission

**Capability Emitted:**
```
[DEBUG] mode.mode: "Eco"
```

### 4.5 DeviceEnergyManagementMode Cluster (0x009F)

#### 4.5.1 SupportedModes Attribute
**No explicit debug logs** - Direct capability emission

#### 4.5.2 CurrentMode Attribute
**No explicit debug logs** - Direct capability emission

### 4.6 PowerSource Cluster (0x0097)

#### 4.6.1 BatPercentRemaining Attribute
**No explicit debug logs** - Direct capability emission

**Capability Emitted:**
```
[DEBUG] battery.battery: <value>
```

#### 4.6.2 BatChargeState Attribute
**No explicit debug logs** - Direct capability emission

**Capability Emitted:**
- `0x00` → `chargingState.chargingState.charging()`
- `0x01` → `chargingState.chargingState.stopped()`
- `0x02` → `chargingState.chargingState.fullyCharged()`
- Other → `chargingState.chargingState.error()`

---

## 5. Capability Handler Logs

### 5.1 EVSE Charging Session Commands

#### 5.1.1 enableCharging Command
**No explicit debug logs** - Direct Matter command send

**Command Sent:**
```
clusters.EnergyEvse.commands.EnableCharging(device, ep, charging_enabled_until_epoch_s, minimum_current, maximum_current)
```

#### 5.1.2 disableCharging Command
**No explicit debug logs** - Direct Matter command send

**Command Sent:**
```
clusters.EnergyEvse.commands.Disable(device, ep)
```

#### 5.1.3 setTargetEndTime Command
**Log Entries:**
```
[INFO] Setting value <time> for evseChargingSession.targetEndTime
```

#### 5.1.4 setMinCurrent Command
**Log Entries:**
```
[INFO] Setting value <current> for evseChargingSession.minCurrent
```

#### 5.1.5 setMaxCurrent Command
**Log Entries:**
```
[INFO] Setting value <current> for evseChargingSession.maxCurrent
[WARN] Clipping Max Current as it cannot be greater than 80A
```

**Example - Normal:**
```
[INFO] Setting value 32000 for evseChargingSession.maxCurrent
```

**Example - Clipped:**
```
[INFO] Setting value 80000 for evseChargingSession.maxCurrent
[WARN] Clipping Max Current as it cannot be greater than 80A
```

### 5.2 Mode Commands

#### 5.2.1 setMode Command (EVSE)
**Log Entries:**
```
[WARN] Received request to set unsupported mode for EnergyEvseMode.
```

**Command Sent:**
```
clusters.EnergyEvseMode.commands.ChangeToMode(device, ep, mode_index)
```

#### 5.2.2 setMode Command (DEM Standalone)
**Log Entries:**
```
[WARN] Received request to set unsupported mode for standalone DeviceEnergyManagementMode.
```

**Command Sent:**
```
clusters.DeviceEnergyManagementMode.commands.ChangeToMode(device, ep, mode_index)
```

---

## 6. Energy Reporting Logs

### 6.1 Cumulative Energy Reporting Flow

**Sequence:**
```
[DEBUG] matter-energy: Cumulative Energy Imported: EP=1, Raw=45000000 mWh
[DEBUG] matter-energy: Energy report: Imported=45000 Wh, Total=45000 Wh, Component=main
[DEBUG] matter-energy: EPM[EP1]: V=230.00V I=6.50A P=1500.00W
[DEBUG] matter-energy: ActivePower received: EP=1, Value=1500000 mW (1500.00 W)
[DEBUG] matter-energy: Power routing: is_aggregation=false, is_standalone=true
[DEBUG] matter-energy: Power aggregation: EP1=1500.00W, Total=1500.00W
```

### 6.2 Periodic Energy Reporting Flow (Cumulative NOT Supported)

**Sequence:**
```
[INFO] matter-energy: Energy measurement: 1 endpoints found, 0 support cumulative energy
[WARN] matter-energy: Cumulative energy NOT supported - using periodic reporting fallback
[DEBUG] matter-energy: Periodic Energy Imported: EP=1, Raw=500000 mWh
[DEBUG] matter-energy: Energy report: Periodic added to cumulative, EP1 total=500 Wh
[DEBUG] matter-energy: Energy report: Imported=500 Wh, Total=500 Wh, Component=main
```

### 6.3 Periodic Energy Reporting Flow (Cumulative Supported - Ignored)

**Sequence:**
```
[INFO] matter-energy: Energy measurement: 1 endpoints found, 1 support cumulative energy
[DEBUG] matter-energy: Periodic Energy Imported: EP=1, Raw=500000 mWh
[DEBUG] matter-energy: Energy report: Periodic report ignored (cumulative supported)
```

### 6.4 Energy Report Throttling

**When:** Energy report received within 15-minute window

**No explicit logs** - Report silently skipped

---

## 7. Error and Warning Logs

### 7.1 Critical Errors (hub_logs = true)

| Log Message | When | Action |
|-------------|------|--------|
| `Cumulative energy NOT supported - using periodic reporting fallback` | Device lacks CUMULATIVE_ENERGY feature | Normal fallback behavior |
| `ActivePower: Received nil value, ignoring report` | ActivePower attribute is nil | Check device firmware |
| `doConfigure: No matching device type found - using default profile` | No recognized device type | Check fingerprints.yml |

### 7.2 Warnings (hub-local)

| Log Message | When | Action |
|-------------|------|--------|
| `evse_state_handler invalid EVSE State: <value>` | Unknown EVSE state enum | Check Matter spec version |
| `evse_supply_state_handler invalid EVSE Supply State: <value>` | Unknown supply state enum | Check Matter spec version |
| `Invalid EVSE fault state received: <value>` | Unknown fault state enum | Check Matter spec version |
| `Charging enabled handler received an invalid target end time, not reporting` | TargetEndTime is nil | Check device behavior |
| `Failed to emit capability for <name>` | Capability emission failed | Check capability definition |
| `evse_session_duration_handler received invalid EVSE Session Duration` | SessionDuration is nil | Check device behavior |
| `evse_session_energy_charged_handler received invalid EVSE Session Energy Charged` | SessionEnergyCharged is nil | Check device behavior |
| `voltage_handler received nil voltage value` | Voltage is nil | Check device behavior |
| `active_current_handler received nil current value` | ActiveCurrent is nil | Check device behavior |
| `Received request to set unsupported mode for EnergyEvseMode.` | setMode for unsupported mode | Check supported modes |
| `Received request to set unsupported mode for standalone DeviceEnergyManagementMode.` | setMode for unsupported DEM mode | Check supported modes |

---

## 8. Multi-Endpoint Aggregation Logs

### 8.1 Solar Power Multi-Endpoint

**Scenario:** Solar panels on multiple endpoints

**Log Sequence:**
```
[DEBUG] matter-energy: ActivePower received: EP=1, Value=3000000 mW (3000.00 W)
[DEBUG] matter-energy: Power routing: is_aggregation=true, is_standalone=false
[DEBUG] matter-energy: Power aggregation: EP1=3000.00W, Total=3000.00W
[DEBUG] matter-energy: ActivePower received: EP=2, Value=2500000 mW (2500.00 W)
[DEBUG] matter-energy: Power routing: is_aggregation=true, is_standalone=false
[DEBUG] matter-energy: Power aggregation: EP2=2500.00W, Total=5500.00W
[DEBUG] matter-energy: ActivePower received: EP=3, Value=2800000 mW (2800.00 W)
[DEBUG] matter-energy: Power routing: is_aggregation=true, is_standalone=false
[DEBUG] matter-energy: Power aggregation: EP3=2800.00W, Total=8300.00W
```

### 8.2 Battery Storage Multi-Endpoint

**Scenario:** Multiple battery units

**Log Sequence:**
```
[DEBUG] matter-energy: ActivePower received: EP=1, Value=-1000000 mW (-1000.00 W)
[DEBUG] matter-energy: Power routing: is_aggregation=true, is_standalone=false
[DEBUG] matter-energy: Power aggregation: EP1=-1000.00W, Total=-1000.00W
[DEBUG] matter-energy: ActivePower received: EP=2, Value=-1500000 mW (-1500.00 W)
[DEBUG] matter-energy: Power routing: is_aggregation=true, is_standalone=false
[DEBUG] matter-energy: Power aggregation: EP2=-1500.00W, Total=-2500.00W
```

### 8.3 Electrical Sensor Standalone

**Scenario:** Single standalone electrical sensor

**Log Sequence:**
```
[DEBUG] matter-energy: ActivePower received: EP=1, Value=1500000 mW (1500.00 W)
[DEBUG] matter-energy: Power routing: is_aggregation=false, is_standalone=true
[DEBUG] matter-energy: Power aggregation: EP1=1500.00W, Total=1500.00W
```

---

## 9. Log Level Guide

### 9.1 Log Levels Used

| Level | Purpose | Visibility | Example |
|-------|---------|------------|---------|
| `log.info_with({ hub_logs = true })` | Critical onboarding flows, profile changes | SmartThings app + Cloud | "Updating device profile to..." |
| `log.warn_with({ hub_logs = true })` | Errors requiring user attention | SmartThings app + Cloud | "Cumulative energy NOT supported..." |
| `log.debug()` | High-frequency attribute reports | Hub-local only | "ActivePower received: EP=1..." |
| `log.info()` | General info (no hub_logs flag) | Hub-local only | "device removed" |
| `log.warn()` | Non-critical warnings | Hub-local only | "evse_state_handler invalid EVSE State" |

### 9.2 Viewing Logs

**SmartThings App (hub_logs = true only):**
```
SmartThings App → Device → Activity
```

**CLI - All Logs (INFO + DEBUG):**
```bash
smartthings edge:drivers:logcat --log-level debug
```

**CLI - Production Logs (INFO + WARN only):**
```bash
smartthings edge:drivers:logcat --log-level info
```

**CLI - Filter by Profile Updates:**
```bash
smartthings edge:drivers:logcat --log-level info | grep "Updating device profile"
```

**CLI - Filter by Power Reports:**
```bash
smartthings edge:drivers:logcat --log-level debug | grep "ActivePower received"
```

**CLI - Filter by Energy Reports:**
```bash
smartthings edge:drivers:logcat --log-level debug | grep "Energy report"
```

**CLI - Filter by Device ID:**
```bash
smartthings edge:drivers:logcat --log-level debug | grep "abc12345"
```

---

## 10. Troubleshooting with Logs

### 10.1 Device Not Onboarding

**Symptoms:** Device appears in hub but shows "Not Working"

**Check Logs For:**
```
[INFO] matter-energy: Device init: <device-id>, endpoints: <count>
[INFO] matter-energy: doConfigure: Starting profile selection for <device-id>
[INFO] matter-energy: Updating device profile to <profile-name>
```

**Missing Logs Indicate:**
- No "Device init" → Device not recognized (check fingerprints.yml)
- No "doConfigure" → Lifecycle handler not triggered (restart hub)
- No "Updating device profile" → Profile selection failed (check device types)

### 10.2 Wrong Profile Selected

**Symptoms:** Device shows incorrect capabilities

**Check Logs For:**
```
[DEBUG] matter-energy: Device type detection - EVSE: <n>, Solar: <n>, Battery: <n>, Sensor: <n>, Meter: <n>, DEM: <n>
[DEBUG] matter-energy: Cluster detection - EPM: <n> endpoints, EEM: <n> endpoints, DEMMode: <n> endpoints
```

**Resolution:**
- Verify device type IDs match expected values
- Check if clusters are present on correct endpoints

### 10.3 No Power/Energy Reports

**Symptoms:** Device shows but values don't update

**Check Logs For:**
```
[DEBUG] matter-energy: ActivePower received: EP=<id>, Value=<mW> mW (<W> W)
[DEBUG] matter-energy: Cumulative Energy Imported: EP=<id>, Raw=<mWh> mWh
```

**Missing Logs Indicate:**
- No "ActivePower received" → Device not sending reports (check Matter subscription)
- No "Energy report" → Capability not supported (check profile)

**Present but No UI Update:**
- Check capability definition in profile
- Verify SmartThings app cache (refresh device)

### 10.4 Energy Reporting Fallback

**Symptoms:** Only periodic energy reports working

**Check Logs For:**
```
[INFO] matter-energy: Energy measurement: <n> endpoints found, <m> support cumulative energy
[WARN] matter-energy: Cumulative energy NOT supported - using periodic reporting fallback
```

**Expected Behavior:**
- Periodic reports used instead of cumulative
- 15-minute throttling still applies

### 10.5 Multi-Endpoint Aggregation Issues

**Symptoms:** Total power doesn't match sum of endpoints

**Check Logs For:**
```
[DEBUG] matter-energy: Power aggregation: EP<id>=<W>W, Total=<W>W
```

**Resolution:**
- Verify all endpoints are being detected
- Check if `is_aggregation_ep` flag is true for solar/battery

---

## Appendix A: Profile Name Reference

| Profile Name | Device Types | Required Clusters |
|--------------|--------------|-------------------|
| `evse` | EVSE (0x050C) | None (base) |
| `evse-energy-meas` | EVSE + EEM | ElectricalEnergyMeasurement |
| `evse-power-meas` | EVSE + EPM | ElectricalPowerMeasurement |
| `evse-energy-meas-power-meas` | EVSE + EEM + EPM | Both |
| `evse-energy-meas-power-meas-energy-mgmt-mode` | EVSE + EEM + EPM + DEMMode | All |
| `electrical-sensor` | Electrical Sensor (0x0510) | EPM or EEM |
| `electrical-sensor-voltage-current` | Electrical Sensor + Voltage | EPM + Voltage |
| `electrical-meter` | Electrical Meter (0x0514) | EPM + EEM |
| `dem-standalone` | DEM (0x050D) | DeviceEnergyManagementMode |
| `solar-power` | Solar Power (0x0017) | EPM + EEM |
| `battery-storage` | Battery Storage (0x0018) | EPM + EEM + PowerSource |

---

## Appendix B: Device Type ID Reference

| Device Type | ID (Hex) | ID (Decimal) |
|-------------|----------|--------------|
| RootNode | 0x0016 | 22 |
| Solar Power | 0x0017 | 23 |
| Battery Storage | 0x0018 | 24 |
| Heat Pump | 0x0309 | 777 |
| Energy EVSE | 0x050C | 1292 |
| Device Energy Management | 0x050D | 1293 |
| Water Heater | 0x050F | 1295 |
| Electrical Sensor | 0x0510 | 1296 |
| Electrical Utility Meter | 0x0511 | 1297 |
| Meter Reference Point | 0x0512 | 1298 |
| Electrical Energy Tariff | 0x0513 | 1299 |
| Electrical Meter | 0x0514 | 1300 |

---

## Appendix C: Cluster ID Reference

| Cluster | ID (Hex) | ID (Decimal) |
|---------|----------|--------------|
| ElectricalPowerMeasurement | 0x0090 | 144 |
| ElectricalEnergyMeasurement | 0x0091 | 145 |
| DeviceEnergyManagement | 0x0098 | 152 |
| DeviceEnergyManagementMode | 0x009F | 159 |
| EnergyEvse | 0x0099 | 153 |
| EnergyEvseMode | 0x009D | 157 |
| PowerSource | 0x0097 | 151 |
| PowerTopology | 0x009C | 156 |
| MeterIdentification | 0x0B06 | 2822 |
| CommodityMetering | 0x0B07 | 2823 |
| CommodityPrice | 0x0095 | 149 |
| CommodityTariff | 0x0700 | 1792 |

---

*Document Version: 1.0*  
*Generated: April 2026*  
*Driver: matter-energy (SmartThings Edge)*
