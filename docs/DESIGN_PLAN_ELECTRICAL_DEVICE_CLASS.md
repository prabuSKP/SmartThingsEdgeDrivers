# Design Plan: Matter 1.5 Electrical Device Class Support
## SmartThings Edge Driver — `matter-energy`

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current State Analysis](#2-current-state-analysis)
3. [Matter 1.5 Electrical Device Types — Complete Reference](#3-matter-15-electrical-device-types--complete-reference)
4. [Cluster-to-Capability Mapping](#4-cluster-to-capability-mapping)
5. [Architecture & File Structure](#5-architecture--file-structure)
6. [Profile Design](#6-profile-design)
7. [Handler Design (Detailed)](#7-handler-design-detailed)
8. [Lifecycle & Discovery Flow](#8-lifecycle--discovery-flow)
9. [Feature-Gated Logic](#9-feature-gated-logic)
10. [Implementation Phases](#10-implementation-phases)
11. [Testing Strategy](#11-testing-strategy)
12. [Glossary](#12-glossary)

---

## 1. Executive Summary

### Goal
Extend the existing `matter-energy` SmartThings Edge driver to support **all 11 electrical device types** defined in the Matter 1.5 specification, covering **15 application-level clusters**.

### What's Changing
| Aspect | Current (v1) | Proposed (v2) |
|--------|-------------|---------------|
| Device Types Supported | 3 (EVSE, Solar Power, Battery Storage) | **11** (+ Water Heater, Heat Pump, Electrical Sensor standalone, DEM standalone, Electrical Utility Meter, Meter Reference Point, Electrical Energy Tariff, Electrical Meter) |
| Clusters Handled | 5 (EnergyEvse, EnergyEvseMode, ElectricalPowerMeasurement, ElectricalEnergyMeasurement, DeviceEnergyManagementMode) | **15** (+ WaterHeaterManagement, WaterHeaterMode, DeviceEnergyManagement, PowerTopology, Thermostat, MeterIdentification, CommodityMetering, CommodityPrice, CommodityTariff, TimeSynchronization) |
| Profiles | 8 | **20+** |
| Sub-drivers | 0 | **4** (water-heater, heat-pump, metering, dem-standalone) |

### Why This Matters
The Matter 1.5 spec adds a complete electrical ecosystem: smart water heaters, heat pumps, solar inverters, battery systems, and utility meters can all be controlled through a single SmartThings driver. This design ensures we handle every device type the spec defines, with proper cluster-to-capability mapping.

---

## 2. Current State Analysis

### 2.1 Existing Driver Architecture

```
matter-energy/
├── config.yml                 ← Driver metadata
├── fingerprints.yml           ← Device type matching rules
├── profiles/                  ← YAML capability profiles (8 files)
│   ├── evse.yml
│   ├── evse-energy-meas.yml
│   ├── evse-energy-meas-energy-mgmt-mode.yml
│   ├── evse-energy-meas-power-meas-energy-mgmt-mode.yml
│   ├── evse-power-meas.yml
│   ├── evse-power-meas-energy-mgmt-mode.yml
│   ├── solar-power.yml
│   └── battery-storage.yml
└── src/
    ├── init.lua               ← Main driver (758 lines, monolithic)
    ├── embedded_cluster_utils.lua
    ├── DeviceEnergyManagementMode/  ← Embedded cluster def
    ├── ElectricalEnergyMeasurement/ ← Embedded cluster def
    ├── ElectricalPowerMeasurement/  ← Embedded cluster def
    ├── EnergyEvse/                  ← Embedded cluster def
    ├── EnergyEvseMode/              ← Embedded cluster def
    └── test/
```

### 2.2 Current Fingerprints (Device Type → Profile matching)

```yaml
matterGeneric:
  - id: "matter/evse"             # 0x0510 + 0x050C
    deviceTypes: [0x0510, 0x050C]
    deviceProfileName: evse
  - id: "matter/solar-power"      # 0x0017
    deviceTypes: [0x0017]
    deviceProfileName: solar-power
  - id: "matter/battery-storage"  # 0x0018
    deviceTypes: [0x0018]
    deviceProfileName: battery-storage
```

### 2.3 Current Capability Coverage

| SmartThings Capability | Matter Cluster | Status |
|----------------------|---------------|--------|
| `evseState` | EnergyEvse (State, SupplyState, FaultState) | ✅ Done |
| `evseChargingSession` | EnergyEvse (ChargingEnabledUntil, MinCurrent, MaxCurrent, SessionDuration, SessionEnergyCharged) | ✅ Done |
| `mode` | EnergyEvseMode + DeviceEnergyManagementMode | ✅ Done |
| `powerSource` | ElectricalPowerMeasurement (PowerMode) | ✅ Done |
| `powerMeter` | ElectricalPowerMeasurement (ActivePower) | ✅ Done |
| `energyMeter` | ElectricalEnergyMeasurement (CumulativeEnergy) | ✅ Done |
| `powerConsumptionReport` | ElectricalEnergyMeasurement (Periodic/Cumulative) | ✅ Done |
| `battery` | PowerSource (BatPercentRemaining) | ✅ Done |
| `chargingState` | PowerSource (BatChargeState) | ✅ Done |

### 2.4 What's Missing

| Device Type | ID | Status |
|---|---|---|
| Water Heater | 0x050F | ❌ Not supported |
| Heat Pump | 0x0309 | ❌ Not supported |
| Device Energy Management (standalone) | 0x050D | ⚠️ Partial (only mode cluster) |
| Electrical Sensor (standalone) | 0x0510 | ⚠️ Only as EVSE companion |
| Electrical Utility Meter | 0x0511 | ❌ Not supported (new in 1.5) |
| Meter Reference Point | 0x0512 | ❌ Not supported (new in 1.5) |
| Electrical Energy Tariff | 0x0513 | ❌ Not supported (new in 1.5) |
| Electrical Meter | 0x0514 | ❌ Not supported (new in 1.5) |

---

## 3. Matter 1.5 Electrical Device Types — Complete Reference

### 3.1 Device Type Master Table

| # | Device Type | ID (Hex) | ID (Dec) | Class | Spec Since |
|---|---|---|---|---|---|
| 1 | **Solar Power** | 0x0017 | 23 | Simple | 1.4 |
| 2 | **Battery Storage** | 0x0018 | 24 | Simple | 1.4 |
| 3 | **Heat Pump** | 0x0309 | 777 | Simple | 1.4 |
| 4 | **Energy EVSE** | 0x050C | 1292 | Simple | 1.3 |
| 5 | **Device Energy Management** | 0x050D | 1293 | Utility | 1.3 |
| 6 | **Water Heater** | 0x050F | 1295 | Simple | 1.4 |
| 7 | **Electrical Sensor** | 0x0510 | 1296 | Utility | 1.3 |
| 8 | **Electrical Utility Meter** | 0x0511 | 1297 | Simple | **1.5** |
| 9 | **Meter Reference Point** | 0x0512 | 1298 | Simple | **1.5** |
| 10 | **Electrical Energy Tariff** | 0x0513 | 1299 | Simple | **1.5** |
| 11 | **Electrical Meter** | 0x0514 | 1300 | Simple | **1.5** |

### 3.2 Device Type → Required Cluster Mapping

```
Legend:  M = Mandatory    O = Optional    Co-located = shares endpoint with another DT
```

#### Tier 1: Existing Device Types (already partially implemented)

**Energy EVSE (0x050C)** — Electric vehicle charger
| Cluster | ID | Requirement |
|---|---|---|
| EnergyEvse | 0x0099 | **M** |
| EnergyEvseMode | 0x009D | **M** |

> Co-located with: Electrical Sensor (0x0510) mandatory, DEM (0x050D) optional

**Solar Power (0x0017)** — Solar panel/inverter
| Cluster | ID | Requirement |
|---|---|---|
| ElectricalPowerMeasurement | 0x0090 | **M** |
| ElectricalEnergyMeasurement | 0x0091 | **M** |
| PowerTopology | 0x009C | O |

**Battery Storage (0x0018)** — Home battery
| Cluster | ID | Requirement |
|---|---|---|
| PowerSource | 0x002F | **M** (Battery feature) |
| ElectricalPowerMeasurement | 0x0090 | **M** |
| ElectricalEnergyMeasurement | 0x0091 | **M** |
| PowerTopology | 0x009C | O |

#### Tier 2: New Device Types (need implementation)

**Water Heater (0x050F)** — Smart water heater
| Cluster | ID | Requirement |
|---|---|---|
| WaterHeaterManagement | 0x0094 | **M** |
| WaterHeaterMode | 0x009E | **M** |
| Thermostat | 0x0201 | O |

> Co-located with: Electrical Sensor (0x0510), DEM (0x050D)

**Heat Pump (0x0309)** — Heat pump unit
| Cluster | ID | Requirement |
|---|---|---|
| Thermostat | 0x0201 | **M** |
| ElectricalPowerMeasurement | 0x0090 | O |
| ElectricalEnergyMeasurement | 0x0091 | O |

> Co-located with: Electrical Sensor (0x0510), DEM (0x050D)

**Device Energy Management (0x050D)** — Energy management controller
| Cluster | ID | Requirement |
|---|---|---|
| DeviceEnergyManagement | 0x0098 | **M** |
| DeviceEnergyManagementMode | 0x009F | O |

**Electrical Sensor (0x0510)** — Power/energy measurement point
| Cluster | ID | Requirement |
|---|---|---|
| ElectricalPowerMeasurement | 0x0090 | **M** (at least one of EPM/EEM) |
| ElectricalEnergyMeasurement | 0x0091 | **M** (at least one of EPM/EEM) |
| PowerTopology | 0x009C | O |

#### Tier 3: New in Matter 1.5 (metering ecosystem)

**Electrical Utility Meter (0x0511)** — Utility smart meter
| Cluster | ID | Requirement |
|---|---|---|
| MeterIdentification | 0x0B06 | **M** |
| ElectricalPowerMeasurement | 0x0090 | O |
| ElectricalEnergyMeasurement | 0x0091 | O |

**Meter Reference Point (0x0512)** — Measurement reference
| Cluster | ID | Requirement |
|---|---|---|
| PowerTopology | 0x009C | **M** |

**Electrical Energy Tariff (0x0513)** — Pricing information
| Cluster | ID | Requirement |
|---|---|---|
| CommodityPrice | 0x0095 | **M** |
| CommodityTariff | 0x0700 | O |

**Electrical Meter (0x0514)** — General electrical meter
| Cluster | ID | Requirement |
|---|---|---|
| CommodityMetering | 0x0B07 | **M** |
| MeterIdentification | 0x0B06 | O |

### 3.3 Cluster Summary (All 15)

| # | Cluster | ID | Type | Key Attributes |
|---|---------|-----|------|----------------|
| 1 | ElectricalPowerMeasurement | 0x0090 | Read-only | PowerMode, ActivePower, Voltage, ActiveCurrent, Frequency, PowerFactor |
| 2 | ElectricalEnergyMeasurement | 0x0091 | Read-only + Events | CumulativeEnergyImported/Exported, PeriodicEnergyImported/Exported |
| 3 | WaterHeaterManagement | 0x0094 | Commands | HeaterTypes, HeatDemand, TankVolume, TankPercentage, BoostState |
| 4 | CommodityPrice | 0x0095 | Read-only | CurrentPrice, ForecastPrices |
| 5 | DeviceEnergyManagement | 0x0098 | Commands | ESAType, ESAState, Forecast, PowerAdjustmentCapability |
| 6 | EnergyEvse | 0x0099 | Commands | State, SupplyState, FaultState, SessionDuration, SessionEnergyCharged |
| 7 | PowerTopology | 0x009C | Read-only | AvailableEndpoints, ActiveEndpoints |
| 8 | EnergyEvseMode | 0x009D | Commands | SupportedModes, CurrentMode |
| 9 | WaterHeaterMode | 0x009E | Commands | SupportedModes, CurrentMode |
| 10 | DeviceEnergyManagementMode | 0x009F | Commands | SupportedModes, CurrentMode |
| 11 | Thermostat | 0x0201 | Commands | LocalTemperature, OccupiedHeatingSetpoint, SystemMode |
| 12 | CommodityTariff | 0x0700 | Read-only | TariffSchedules, CurrentTariff |
| 13 | MeterIdentification | 0x0B06 | Read-only | MeterType, PointOfDelivery |
| 14 | CommodityMetering | 0x0B07 | Read-only | CumulativeEnergy, InstantaneousDemand |
| 15 | TimeSynchronization | 0x0038 | Utility | UTCTime, Granularity |

---

## 4. Cluster-to-Capability Mapping

### 4.1 Mapping Design Principles

1. **One SmartThings capability per user-visible concept** (e.g., power measurement, energy consumption, water heater control)
2. **Reuse existing capabilities** where possible (`powerMeter`, `energyMeter`, `thermostatHeatingSetpoint`, etc.)
3. **Create custom capabilities** only when no standard one fits (e.g., `waterHeaterControl`, `meterIdentification`)
4. **Components** separate multi-function endpoints (e.g., EVSE main + electricalSensor + deviceEnergyManagement)

### 4.2 Complete Mapping Table

| Matter Cluster | Matter Attribute(s) | SmartThings Capability | Capability Attribute | Notes |
|---|---|---|---|---|
| **ElectricalPowerMeasurement** | ActivePower | `powerMeter` | `power` (W) | Convert mW → W |
| | PowerMode | `powerSource` | `powerSource` | AC/DC mapping |
| | Voltage | `voltageMeasurement` | `voltage` (V) | New cap needed |
| | ActiveCurrent | `currentMeasurement` | `current` (A) | New cap needed |
| | Frequency | `frequencyMeasurement` | `frequency` (Hz) | New cap needed |
| | PowerFactor | `powerFactor` | `powerFactor` | New cap needed |
| **ElectricalEnergyMeasurement** | CumulativeEnergyImported | `energyMeter` | `energy` (Wh) | Convert mWh → Wh |
| | PeriodicEnergyImported | `powerConsumptionReport` | `powerConsumption` | Existing handler |
| | CumulativeEnergyExported | `energyMeter` (export comp) | `energy` (Wh) | Export component |
| **WaterHeaterManagement** | BoostState | `waterHeaterOperationalState` | `operationalState` | Custom cap |
| | TankPercentage | `waterHeaterOperationalState` | `tankPercentage` | % tank heated |
| | TankVolume | `waterHeaterOperationalState` | `tankVolume` (L) | |
| | HeaterTypes | (informational) | | Stored, not displayed |
| | HeatDemand | `waterHeaterOperationalState` | `heatDemand` | Bitmap |
| **WaterHeaterMode** | SupportedModes/CurrentMode | `mode` | `mode` | Off/Manual/Timed |
| **DeviceEnergyManagement** | ESAState | `deviceEnergyManagement` | `esaState` | Custom cap |
| | ESAType | `deviceEnergyManagement` | `esaType` | |
| | Forecast | `deviceEnergyManagement` | `forecast` | Complex struct |
| | OptOutState | `deviceEnergyManagement` | `optOutState` | |
| **DeviceEnergyManagementMode** | SupportedModes/CurrentMode | `mode` | `mode` | Component-scoped |
| **EnergyEvse** | State/SupplyState/FaultState | `evseState` | `state`/`supplyState`/`faultState` | Existing |
| | Session attributes | `evseChargingSession` | various | Existing |
| **EnergyEvseMode** | SupportedModes/CurrentMode | `mode` | `mode` | Existing |
| **Thermostat** | LocalTemperature | `temperatureMeasurement` | `temperature` | |
| | OccupiedHeatingSetpoint | `thermostatHeatingSetpoint` | `heatingSetpoint` | |
| | SystemMode | `thermostatMode` | `thermostatMode` | |
| **PowerTopology** | AvailableEndpoints | (internal use) | | Topology mapping |
| **MeterIdentification** | MeterType | `meterIdentification` | `meterType` | Custom cap |
| **CommodityMetering** | CumulativeEnergy | `energyMeter` | `energy` | Reuse existing |
| **CommodityPrice** | CurrentPrice | `energyPrice` | `currentPrice` | Custom cap |
| **CommodityTariff** | CurrentTariff | `energyTariff` | `currentTariff` | Custom cap |
| **PowerSource** | BatPercentRemaining | `battery` | `battery` | Existing |
| | BatChargeState | `chargingState` | `chargingState` | Existing |

### 4.3 Custom Capabilities Required

These capabilities don't exist in the standard SmartThings library and need to be defined:

| Custom Capability ID | Purpose | Attributes | Commands |
|---|---|---|---|
| `waterHeaterOperationalState` | Water heater tank & boost status | operationalState, tankPercentage, tankVolume, heatDemand | boost, cancelBoost |
| `voltageMeasurement` | AC/DC voltage | voltage (V) | — |
| `currentMeasurement` | Current draw | current (A) | — |
| `deviceEnergyManagement` | DEM ESA state & forecast | esaState, esaType, optOutState | — |
| `meterIdentification` | Utility meter metadata | meterType, pointOfDelivery | — |
| `energyPrice` | Live commodity pricing | currentPrice, currency, unit | — |
| `energyTariff` | Tariff schedule info | currentTariff, description | — |

---

## 5. Architecture & File Structure

### 5.1 Proposed Directory Structure

```
matter-energy/
├── config.yml
├── fingerprints.yml                     ← Updated with all 11 device types
├── capabilities/                        ← NEW: Custom capability definitions
│   ├── waterHeaterOperationalState.yml
│   ├── voltageMeasurement.yml
│   ├── currentMeasurement.yml
│   ├── deviceEnergyManagement.yml
│   ├── meterIdentification.yml
│   ├── energyPrice.yml
│   └── energyTariff.yml
├── profiles/                            ← Expanded from 8 → 20+ profiles
│   ├── evse.yml                         ← Existing (unchanged)
│   ├── evse-energy-meas.yml             ← Existing
│   ├── evse-energy-meas-energy-mgmt-mode.yml
│   ├── evse-energy-meas-power-meas-energy-mgmt-mode.yml
│   ├── evse-power-meas.yml
│   ├── evse-power-meas-energy-mgmt-mode.yml
│   ├── solar-power.yml                  ← Existing (unchanged)
│   ├── battery-storage.yml              ← Existing (unchanged)
│   ├── water-heater.yml                 ← NEW
│   ├── water-heater-thermostat.yml      ← NEW
│   ├── heat-pump.yml                    ← NEW
│   ├── heat-pump-energy.yml             ← NEW
│   ├── electrical-sensor.yml            ← NEW (standalone)
│   ├── dem-standalone.yml               ← NEW
│   ├── dem-standalone-mode.yml          ← NEW
│   ├── electrical-utility-meter.yml     ← NEW
│   ├── meter-reference-point.yml        ← NEW
│   ├── electrical-energy-tariff.yml     ← NEW
│   └── electrical-meter.yml             ← NEW
└── src/
    ├── init.lua                         ← REFACTORED: slimmer, delegates to modules
    ├── embedded_cluster_utils.lua       ← Updated with new clusters
    ├── constants.lua                    ← NEW: shared constants & device type IDs
    ├── utils.lua                        ← NEW: shared utility functions
    ├── handlers/                        ← NEW: organized handler modules
    │   ├── evse_handlers.lua            ← Extracted from init.lua
    │   ├── energy_measurement_handlers.lua  ← EPM + EEM handlers
    │   ├── water_heater_handlers.lua    ← NEW
    │   ├── thermostat_handlers.lua      ← NEW
    │   ├── dem_handlers.lua             ← NEW
    │   ├── mode_handlers.lua            ← All mode cluster handlers
    │   ├── metering_handlers.lua        ← NEW (Meter ID, Commodity)
    │   └── power_topology_handlers.lua  ← NEW
    ├── sub_drivers/                     ← NEW: device-type-specific sub-drivers
    │   ├── water_heater/
    │   │   └── init.lua
    │   ├── heat_pump/
    │   │   └── init.lua
    │   ├── metering/                    ← Covers Utility Meter, Reference Point, Tariff, Meter
    │   │   └── init.lua
    │   └── dem_standalone/
    │       └── init.lua
    ├── WaterHeaterManagement/           ← NEW: embedded cluster def
    ├── WaterHeaterMode/                 ← NEW: embedded cluster def
    ├── DeviceEnergyManagement/          ← NEW: embedded cluster def (full)
    ├── PowerTopology/                   ← NEW: embedded cluster def
    ├── DeviceEnergyManagementMode/      ← Existing
    ├── ElectricalEnergyMeasurement/     ← Existing
    ├── ElectricalPowerMeasurement/      ← Existing
    ├── EnergyEvse/                      ← Existing
    ├── EnergyEvseMode/                  ← Existing
    └── test/
        ├── test_evse.lua
        ├── test_water_heater.lua        ← NEW
        ├── test_heat_pump.lua           ← NEW
        ├── test_electrical_sensor.lua   ← NEW
        ├── test_metering.lua            ← NEW
        └── test_dem.lua                 ← NEW
```

### 5.2 Design Rationale

| Decision | Why |
|---|---|
| **Sub-drivers** for Water Heater, Heat Pump, Metering, DEM | Each has unique clusters and commands. Sub-drivers provide clean `can_handle` filtering by device type. |
| **Handler modules** extracted from init.lua | The current init.lua is 758 lines and monolithic. Splitting into handler modules improves maintainability. |
| **Shared `constants.lua`** | Device type IDs, field names, and enum maps are used everywhere. Centralizing avoids duplication. |
| **No sub-driver for EVSE** | EVSE is already well-handled in the main driver. Moving it would break existing code with no benefit. |

---

## 6. Profile Design

### 6.1 Profile Naming Convention

```
<primary-device-type>[-optional-cluster-1][-optional-cluster-2].yml
```

Examples:
- `water-heater.yml` — base Water Heater
- `water-heater-thermostat.yml` — Water Heater with optional Thermostat cluster
- `heat-pump-energy.yml` — Heat Pump with energy measurement clusters

### 6.2 New Profile Definitions

#### `water-heater.yml`
```yaml
name: water-heater
components:
- id: main
  capabilities:
  - id: waterHeaterOperationalState  # Custom: tank %, boost state
    version: 1
  - id: mode                          # WaterHeaterMode
    version: 1
  - id: energyMeter                   # From co-located Electrical Sensor
    version: 1
  - id: powerMeter                    # From co-located Electrical Sensor
    version: 1
  - id: powerConsumptionReport
    version: 1
  - id: firmwareUpdate
    version: 1
  - id: refresh
    version: 1
  categories:
  - name: WaterHeater
- id: deviceEnergyManagement
  label: Energy Manager
  capabilities:
  - id: mode                          # DeviceEnergyManagementMode
    version: 1
```

#### `heat-pump.yml`
```yaml
name: heat-pump
components:
- id: main
  capabilities:
  - id: thermostatMode
    version: 1
  - id: thermostatHeatingSetpoint
    version: 1
  - id: temperatureMeasurement
    version: 1
  - id: firmwareUpdate
    version: 1
  - id: refresh
    version: 1
  categories:
  - name: HeatPump
```

#### `electrical-sensor.yml` (standalone)
```yaml
name: electrical-sensor
components:
- id: main
  capabilities:
  - id: powerMeter
    version: 1
  - id: energyMeter
    version: 1
  - id: powerConsumptionReport
    version: 1
  - id: powerSource
    version: 1
  - id: firmwareUpdate
    version: 1
  - id: refresh
    version: 1
  categories:
  - name: SmartPlug
```

#### `electrical-utility-meter.yml`
```yaml
name: electrical-utility-meter
components:
- id: main
  capabilities:
  - id: meterIdentification     # Custom
    version: 1
  - id: energyMeter
    version: 1
  - id: powerMeter
    version: 1
  - id: firmwareUpdate
    version: 1
  - id: refresh
    version: 1
  categories:
  - name: SmartPlug
```

#### `electrical-meter.yml`
```yaml
name: electrical-meter
components:
- id: main
  capabilities:
  - id: energyMeter             # From CommodityMetering
    version: 1
  - id: powerMeter
    version: 1
  - id: firmwareUpdate
    version: 1
  - id: refresh
    version: 1
  categories:
  - name: SmartPlug
```

### 6.3 Dynamic Profile Selection

Profile selection happens in `doConfigure` lifecycle. The logic is:

```
FOR each device:
  1. Identify the PRIMARY device type (highest priority)
  2. Check which OPTIONAL clusters are present
  3. Build profile name string: <base>[-optional1][-optional2]
  4. Call device:try_update_metadata({ profile = profile_name })
```

Priority order for primary device type detection:
1. EVSE (0x050C) — highest, it's the most specific
2. Water Heater (0x050F)
3. Heat Pump (0x0309)
4. Electrical Utility Meter (0x0511)
5. Electrical Meter (0x0514)
6. Electrical Energy Tariff (0x0513)
7. Solar Power (0x0017)
8. Battery Storage (0x0018)
9. Device Energy Management (0x050D)
10. Electrical Sensor (0x0510)
11. Meter Reference Point (0x0512)

---

## 7. Handler Design (Detailed)

### 7.1 Water Heater Handlers (`handlers/water_heater_handlers.lua`)

```
┌────────────────────────────────────┐
│     WaterHeaterManagement (0x0094) │
│                                    │
│  Attributes (read/subscribe):      │
│  ┌──────────────┬────────────────┐ │
│  │ HeaterTypes  │ bitmap → store │ │
│  │ HeatDemand   │ bitmap → emit │ │
│  │ TankVolume   │ uint16 → emit │ │
│  │ TankPercentage│ percent→ emit│ │
│  │ BoostState   │ enum → emit   │ │
│  │ EstimatedHeat│ energy→ emit  │ │
│  └──────────────┴────────────────┘ │
│                                    │
│  Commands (send):                  │
│  ┌──────────────┬────────────────┐ │
│  │ Boost        │ duration,      │ │
│  │              │ oneShot,       │ │
│  │              │ emergencyBoost,│ │
│  │              │ targetTemp,    │ │
│  │              │ targetPercent, │ │
│  │              │ targetReheat   │ │
│  │ CancelBoost  │ (no params)   │ │
│  └──────────────┴────────────────┘ │
└────────────────────────────────────┘
```

**Handler pseudocode:**

```lua
-- Attribute: BoostState → waterHeaterOperationalState.operationalState
local function boost_state_handler(driver, device, ib, response)
  local boost_state = ib.data.value
  local event_map = {
    [BoostStateEnum.INACTIVE] = "inactive",
    [BoostStateEnum.ACTIVE]   = "active",
  }
  local state = event_map[boost_state]
  if state then
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.waterHeaterOperationalState.operationalState(state))
  end
end

-- Attribute: TankPercentage → waterHeaterOperationalState.tankPercentage
local function tank_percentage_handler(driver, device, ib, response)
  if ib.data.value then
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.waterHeaterOperationalState.tankPercentage(ib.data.value))
  end
end

-- Command: Boost
local function handle_boost(driver, device, cmd)
  local ep = component_to_endpoint(device, cmd.component)
  local boost_info = {
    duration = cmd.args.duration or 3600,  -- default 1 hour
  }
  if cmd.args.targetTemperature then
    boost_info.temporarySetpoint = cmd.args.targetTemperature * 100  -- °C → 0.01°C
  end
  if cmd.args.targetPercentage then
    boost_info.targetPercentage = cmd.args.targetPercentage
  end
  device:send(clusters.WaterHeaterManagement.commands.Boost(device, ep, boost_info))
end

-- Command: CancelBoost
local function handle_cancel_boost(driver, device, cmd)
  local ep = component_to_endpoint(device, cmd.component)
  device:send(clusters.WaterHeaterManagement.commands.CancelBoost(device, ep))
end
```

### 7.2 Thermostat Handlers (`handlers/thermostat_handlers.lua`)

Used by: **Heat Pump** (mandatory), **Water Heater** (optional)

```lua
-- LocalTemperature → temperatureMeasurement.temperature
local function local_temp_handler(driver, device, ib, response)
  local temp = ib.data.value
  if temp ~= nil then
    -- Matter Thermostat reports in 0.01°C units
    local temp_c = temp / 100.0
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.temperatureMeasurement.temperature({value = temp_c, unit = "C"}))
  end
end

-- OccupiedHeatingSetpoint → thermostatHeatingSetpoint.heatingSetpoint
local function heating_setpoint_handler(driver, device, ib, response)
  if ib.data.value then
    local setpoint_c = ib.data.value / 100.0
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.thermostatHeatingSetpoint.heatingSetpoint({value = setpoint_c, unit = "C"}))
  end
end

-- SystemMode → thermostatMode.thermostatMode
local THERMOSTAT_MODE_MAP = {
  [0x00] = "off",
  [0x01] = "auto",
  [0x03] = "cool",
  [0x04] = "heat",
  [0x05] = "emergency heat",
}
```

### 7.3 DEM Handlers (`handlers/dem_handlers.lua`)

```lua
-- ESAState → deviceEnergyManagement.esaState
local ESA_STATE_MAP = {
  [0x00] = "offline",
  [0x01] = "online",
  [0x02] = "fault",
  [0x03] = "userOptOut",
  [0x04] = "powerAdjustActive",
  [0x05] = "paused",
}

-- ESAType → deviceEnergyManagement.esaType
local ESA_TYPE_MAP = {
  [0x00] = "evse",
  [0x01] = "spaceHeating",
  [0x02] = "waterHeating",
  [0x03] = "spaceCooling",
  [0x05] = "batteryStorage",
  [0x06] = "solarPV",
  [0xFF] = "other",
}
```

### 7.4 Energy Measurement Handlers (refactored from init.lua)

The existing `energy_report_handler_factory` and `active_power_handler` are extracted unchanged into `handlers/energy_measurement_handlers.lua`. The only change is they become a module that can be required by both the main driver and sub-drivers.

---

## 8. Lifecycle & Discovery Flow

### 8.1 Complete Device Discovery Sequence

```
┌─────────────────────────────────────────────────────────────┐
│                    MATTER DEVICE JOINS                       │
│                                                              │
│  Hub discovers endpoints → reads Descriptor cluster          │
│  → gets DeviceTypeList for each endpoint                     │
│  → SmartThings platform matches fingerprints.yml             │
│  → Creates device with default profile                       │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    device_added (lifecycle)                   │
│                                                              │
│  1. Scan all endpoints for device types                      │
│  2. Build component-to-endpoint map:                         │
│     {                                                        │
│       "main" → primary endpoint,                             │
│       "electricalSensor" → sensor endpoint,                  │
│       "deviceEnergyManagement" → DEM endpoint,               │
│       "importedEnergy" → import endpoint,                    │
│       "exportedEnergy" → export endpoint                     │
│     }                                                        │
│  3. Persist the map                                          │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    doConfigure (lifecycle)                    │
│                                                              │
│  1. Identify primary device type (priority order)            │
│  2. Check which optional clusters are present:               │
│     - Has EPM? Has EEM? Has Thermostat?                      │
│     - Has DEM Mode? Has PowerTopology?                       │
│  3. Build profile name string                                │
│  4. Switch to correct profile:                               │
│     device:try_update_metadata({ profile = profile_name })   │
│                                                              │
│  5. Check FeatureMap for conditional attributes:             │
│     - EEM: Cumulative vs Periodic energy support             │
│     - EPM: AC vs DC, Polyphase, Harmonics                   │
│     - WHM: EnergyManagement feature, TankPercent feature     │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    device_init (lifecycle)                    │
│                                                              │
│  1. Set endpoint_to_component / component_to_endpoint fns    │
│  2. Subscribe to all relevant attributes                     │
│  3. Read FeatureMap for conditional logic                    │
│  4. Emit default states for capabilities                     │
└──────────────────────────────────────────────────────────────┘
```

### 8.2 Sub-Driver `can_handle` Pattern

Each sub-driver declares which device types it handles:

```lua
-- sub_drivers/water_heater/init.lua
local WATER_HEATER_DT_ID = 0x050F

local function can_handle(opts, driver, device, ...)
  for _, ep in ipairs(device.endpoints) do
    for _, dt in ipairs(ep.device_types) do
      if dt.device_type_id == WATER_HEATER_DT_ID then
        return true
      end
    end
  end
  return false
end
```

Sub-driver priority: the **first matching sub-driver** handles the device. The main driver acts as fallback for any unmatched device type.

---

## 9. Feature-Gated Logic

### 9.1 Why Feature Checking Matters

Not all devices supporting a cluster implement all its attributes. The Matter FeatureMap (attribute 0xFFFC) tells us which optional features are active.

### 9.2 Feature Checks Required

| Cluster | Feature | Bit | What It Gates |
|---|---|---|---|
| **ElectricalEnergyMeasurement** | CUMULATIVE_ENERGY | 0x04 | CumulativeEnergyImported/Exported attributes |
| | PERIODIC_ENERGY | 0x08 | PeriodicEnergyImported/Exported attributes |
| | IMPORTED_ENERGY | 0x01 | *Imported attributes |
| | EXPORTED_ENERGY | 0x02 | *Exported attributes |
| **ElectricalPowerMeasurement** | ALTERNATING_CURRENT | 0x02 | Voltage, Frequency, PowerFactor, RMS attributes |
| | DIRECT_CURRENT | 0x01 | DC measurement attributes |
| | POLYPHASE_POWER | 0x04 | Multi-phase measurement |
| | HARMONICS | 0x08 | HarmonicCurrents attribute |
| | POWER_QUALITY | 0x10 | HarmonicPhases attribute |
| **WaterHeaterManagement** | ENERGY_MANAGEMENT | 0x01 | EstimatedHeatRequired attribute |
| | TANK_PERCENT | 0x02 | TankPercentage attribute, targetPercentage/targetReheat in Boost |
| **DeviceEnergyManagement** | POWER_ADJUSTMENT | 0x01 | PowerAdjustmentCapability, PowerAdjustRequest/Cancel commands |
| | FORECAST_ADJUSTMENT | 0x04 | Forecast attribute, StartTimeAdjust command |
| | CONSTRAINT_BASED_ADJUSTMENT | 0x08 | RequestConstraintBasedForecast command |
| | PAUSABLE | 0x02 | OptOutState, Pause/Resume commands |

### 9.3 Implementation Pattern

```lua
-- In device_init:
local function check_eem_features(device)
  local eem_eps = embedded_cluster_utils.get_endpoints(device, clusters.ElectricalEnergyMeasurement.ID)
  if #eem_eps > 0 then
    -- Check if cumulative energy is supported
    local cumulative_eps = embedded_cluster_utils.get_endpoints(device,
      clusters.ElectricalEnergyMeasurement.ID,
      { feature_bitmap = clusters.ElectricalEnergyMeasurement.types.Feature.CUMULATIVE_ENERGY })

    if #cumulative_eps == 0 then
      device:set_field(CUMULATIVE_REPORTS_NOT_SUPPORTED, true, {persist = false})
      -- Will rely on periodic reports only
    end
  end
end

-- In water_heater_handlers:
local function check_whm_features(device)
  local whm_eps = embedded_cluster_utils.get_endpoints(device,
    clusters.WaterHeaterManagement.ID)
  if #whm_eps > 0 then
    local tank_percent_eps = embedded_cluster_utils.get_endpoints(device,
      clusters.WaterHeaterManagement.ID,
      { feature_bitmap = clusters.WaterHeaterManagement.types.Feature.TANK_PERCENT })

    if #tank_percent_eps > 0 then
      device:set_field("__whm_has_tank_percent", true, {persist = false})
      -- Subscribe to TankPercentage attribute
    end
  end
end
```

---

## 10. Implementation Phases

### Phase 1: Refactor & Foundation (Week 1-2)

**Goal:** Clean up the existing code without changing behavior.

| Task | Description | Files |
|---|---|---|
| 1.1 | Extract constants into `constants.lua` | New file |
| 1.2 | Extract EVSE handlers into `handlers/evse_handlers.lua` | Extract from init.lua |
| 1.3 | Extract energy measurement handlers | Extract from init.lua |
| 1.4 | Extract mode handlers | Extract from init.lua |
| 1.5 | Slim down init.lua to orchestration only | Modify init.lua |
| 1.6 | Update `embedded_cluster_utils.lua` to register new clusters | Modify |
| 1.7 | Add all new device type IDs to fingerprints.yml | Modify |
| 1.8 | Run existing tests to confirm no regressions | Run tests |

### Phase 2: Water Heater Support (Week 3-4)

**Goal:** Full Water Heater device type support.

| Task | Description | Files |
|---|---|---|
| 2.1 | Create `WaterHeaterManagement` embedded cluster definition | New |
| 2.2 | Create `WaterHeaterMode` embedded cluster definition | New |
| 2.3 | Define `waterHeaterOperationalState` custom capability | New YAML |
| 2.4 | Create `water-heater.yml` and `water-heater-thermostat.yml` profiles | New YAML |
| 2.5 | Implement `handlers/water_heater_handlers.lua` | New |
| 2.6 | Create `sub_drivers/water_heater/init.lua` | New |
| 2.7 | Add Water Heater fingerprint | Modify |
| 2.8 | Write `test_water_heater.lua` | New |

### Phase 3: Heat Pump & Thermostat (Week 5-6)

**Goal:** Heat Pump device type + shared Thermostat cluster support.

| Task | Description | Files |
|---|---|---|
| 3.1 | Implement `handlers/thermostat_handlers.lua` | New |
| 3.2 | Create `heat-pump.yml` and `heat-pump-energy.yml` profiles | New YAML |
| 3.3 | Create `sub_drivers/heat_pump/init.lua` | New |
| 3.4 | Add Heat Pump fingerprint | Modify |
| 3.5 | Write `test_heat_pump.lua` | New |

### Phase 4: Standalone Device Types (Week 7-8)

**Goal:** Standalone Electrical Sensor + DEM + PowerTopology.

| Task | Description | Files |
|---|---|---|
| 4.1 | Create `DeviceEnergyManagement` full embedded cluster | New |
| 4.2 | Create `PowerTopology` embedded cluster | New |
| 4.3 | Implement `handlers/dem_handlers.lua` | New |
| 4.4 | Implement `handlers/power_topology_handlers.lua` | New |
| 4.5 | Create `electrical-sensor.yml`, `dem-standalone.yml` profiles | New |
| 4.6 | Create `sub_drivers/dem_standalone/init.lua` | New |
| 4.7 | Write tests | New |

### Phase 5: Metering Ecosystem (Week 9-10)

**Goal:** All Matter 1.5 metering device types.

| Task | Description | Files |
|---|---|---|
| 5.1 | Create embedded cluster defs for MeterIdentification, CommodityMetering, CommodityPrice, CommodityTariff | New |
| 5.2 | Define custom capabilities (meterIdentification, energyPrice, energyTariff) | New |
| 5.3 | Create profiles for all 4 metering device types | New |
| 5.4 | Implement `handlers/metering_handlers.lua` | New |
| 5.5 | Create `sub_drivers/metering/init.lua` | New |
| 5.6 | Write tests | New |

### Phase 6: Integration Testing & Polish (Week 11-12)

| Task | Description |
|---|---|
| 6.1 | End-to-end testing with virtual/real devices |
| 6.2 | Multi-endpoint co-location testing (e.g., Water Heater + Electrical Sensor + DEM on same device) |
| 6.3 | Profile switching edge cases |
| 6.4 | FeatureMap edge cases (missing features, unknown enum values) |
| 6.5 | Documentation and README update |

---

## 11. Testing Strategy

### 11.1 Unit Test Structure

Each test file follows the existing pattern in the `test/` directory:

```lua
-- test/test_water_heater.lua
local test = require "integration_test"
local capabilities = require "st.capabilities"
local clusters = require "st.matter.clusters"
local t_utils = require "integration_test.utils"

local mock_device = test.mock_device.build_test_matter_device({
  profile = t_utils.get_profile_definition("water-heater.yml"),
  manufacturer_info = { vendor_id = 0x0000, product_id = 0x0000 },
  endpoints = {
    { -- endpoint 1: Water Heater + Electrical Sensor + DEM
      endpoint_id = 1,
      clusters = {
        { cluster_id = clusters.WaterHeaterManagement.ID, cluster_type = "SERVER" },
        { cluster_id = clusters.WaterHeaterMode.ID, cluster_type = "SERVER" },
        { cluster_id = clusters.ElectricalPowerMeasurement.ID, cluster_type = "SERVER" },
        { cluster_id = clusters.ElectricalEnergyMeasurement.ID, cluster_type = "SERVER" },
        { cluster_id = clusters.DeviceEnergyManagement.ID, cluster_type = "SERVER" },
      },
      device_types = {
        { device_type_id = 0x050F, device_type_revision = 1 },  -- Water Heater
        { device_type_id = 0x0510, device_type_revision = 1 },  -- Electrical Sensor
        { device_type_id = 0x050D, device_type_revision = 2 },  -- DEM
      }
    }
  }
})

-- Test: BoostState attribute → waterHeaterOperationalState event
test.register_coroutine_test("Water heater boost active", function()
  test.socket.matter:__queue_receive({
    mock_device.id,
    clusters.WaterHeaterManagement.attributes.BoostState:build_test_report_data(
      mock_device, 1, clusters.WaterHeaterManagement.types.BoostStateEnum.ACTIVE
    )
  })
  test.socket.capability:__expect_send(
    mock_device:generate_test_message("main",
      capabilities.waterHeaterOperationalState.operationalState("active"))
  )
end)
```

### 11.2 Test Coverage Matrix

| Device Type | Attribute Handlers | Command Handlers | Profile Switch | Feature Gating | Co-location |
|---|:---:|:---:|:---:|:---:|:---:|
| EVSE | ✅ Existing | ✅ Existing | ✅ Existing | ✅ | ✅ |
| Solar Power | ✅ Existing | N/A | ✅ | ✅ | - |
| Battery Storage | ✅ Existing | N/A | ✅ | ✅ | - |
| Water Heater | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 |
| Heat Pump | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 |
| DEM Standalone | 🆕 | 🆕 | 🆕 | 🆕 | - |
| Electrical Sensor | 🆕 | N/A | 🆕 | ✅ | - |
| Utility Meter | 🆕 | N/A | 🆕 | - | - |
| Meter Ref Point | 🆕 | N/A | 🆕 | - | - |
| Energy Tariff | 🆕 | N/A | 🆕 | - | - |
| Electrical Meter | 🆕 | N/A | 🆕 | - | - |

---

## 12. Glossary

| Term | Definition |
|---|---|
| **Device Type** | A Matter specification concept defining what a physical device is (e.g., "Water Heater"). Identified by a hex ID (e.g., 0x050F). Determines which clusters are mandatory. |
| **Cluster** | A Matter concept grouping related attributes, commands, and events (e.g., "WaterHeaterManagement" cluster handles tank monitoring and boost commands). |
| **Endpoint** | A logical sub-device within a physical Matter device. A single physical device can expose multiple endpoints, each with different device types. E.g., a Water Heater might have endpoint 1 (Water Heater DT + Electrical Sensor DT + DEM DT). |
| **Attribute** | A named, typed data point within a cluster that can be read and/or subscribed to. E.g., `BoostState` in WaterHeaterManagement. |
| **Command** | An action that can be sent to a cluster. E.g., `Boost` command to start heating. |
| **FeatureMap** | A 32-bit bitmask (attribute 0xFFFC) on every cluster indicating which optional features the device supports. |
| **Profile** | A SmartThings YAML file defining which capabilities a device exposes in the app UI. Selected dynamically at `doConfigure`. |
| **Capability** | A SmartThings concept representing a user-visible function (e.g., `powerMeter`, `thermostatMode`). Maps to UI controls. |
| **Component** | A named section within a SmartThings profile that groups capabilities (e.g., `main`, `electricalSensor`). Maps to endpoints via the component-to-endpoint map. |
| **Sub-driver** | A Lua module within an Edge driver that handles a specific subset of devices. Selected via `can_handle()` function. |
| **Embedded Cluster** | A cluster definition included directly in the driver (in `src/`) when the SmartThings Lua library doesn't yet include it natively. Gated by `version.api < X` checks. |
| **Co-location** | When multiple device types share the same endpoint. E.g., Water Heater (0x050F) + Electrical Sensor (0x0510) + DEM (0x050D) on endpoint 1. |
| **ESA** | Energy Smart Appliance — the DEM cluster's term for any energy-managed device. ESAType tells you what kind (EVSE, water heater, battery, etc.). |
| **mW / mWh** | Matter reports power in milliwatts and energy in milliwatt-hours. SmartThings expects Watts and Watt-hours. Always divide by 1000. |

---

## Appendix A: Co-location Patterns (from Matter spec examples)

### Pattern 1: EVSE Device
```
Endpoint 0: Root Node
Endpoint 1: Energy EVSE (0x050C) + Electrical Sensor (0x0510) + DEM (0x050D)
  Clusters: EnergyEvse, EnergyEvseMode, EPM, EEM, DEM, DEMMode, PowerTopology
```

### Pattern 2: Water Heater Device
```
Endpoint 0: Root Node
Endpoint 1: Water Heater (0x050F) + Electrical Sensor (0x0510) + DEM (0x050D)
  Clusters: WaterHeaterManagement, WaterHeaterMode, Thermostat(opt), EPM, EEM, DEM, DEMMode, PowerTopology
```

### Pattern 3: Heat Pump Device
```
Endpoint 0: Root Node
Endpoint 1: Heat Pump (0x0309) + Power Source (0x0011) + Electrical Sensor (0x0510) + DEM (0x050D)
  Clusters: Thermostat, PowerSource, EPM, EEM, DEM, DEMMode, PowerTopology
```

### Pattern 4: Full Metering Ecosystem
```
Endpoint 0: Root Node
Endpoint 1: Electrical Utility Meter (0x0511)
  Clusters: MeterIdentification, EPM, EEM
Endpoint 2: Meter Reference Point (0x0512)
  Clusters: PowerTopology
Endpoint 3: Electrical Energy Tariff (0x0513)
  Clusters: CommodityPrice, CommodityTariff
Endpoint 4: Electrical Meter (0x0514)
  Clusters: CommodityMetering, MeterIdentification
```

---

## Appendix B: Updated fingerprints.yml

```yaml
matterGeneric:
  # Existing (unchanged)
  - id: "matter/evse"
    deviceLabel: Matter EVSE
    deviceTypes:
      - id: 0x0510
      - id: 0x050C
    deviceProfileName: evse
  - id: "matter/solar-power"
    deviceLabel: Matter Solar Power
    deviceTypes:
      - id: 0x0017
    deviceProfileName: solar-power
  - id: "matter/battery-storage"
    deviceLabel: Matter Battery Storage
    deviceTypes:
      - id: 0x0018
    deviceProfileName: battery-storage

  # New device types
  - id: "matter/water-heater"
    deviceLabel: Matter Water Heater
    deviceTypes:
      - id: 0x050F
    deviceProfileName: water-heater
  - id: "matter/heat-pump"
    deviceLabel: Matter Heat Pump
    deviceTypes:
      - id: 0x0309
    deviceProfileName: heat-pump
  - id: "matter/dem"
    deviceLabel: Matter Energy Manager
    deviceTypes:
      - id: 0x050D
    deviceProfileName: dem-standalone
  - id: "matter/electrical-sensor"
    deviceLabel: Matter Electrical Sensor
    deviceTypes:
      - id: 0x0510
    deviceProfileName: electrical-sensor
  - id: "matter/electrical-utility-meter"
    deviceLabel: Matter Utility Meter
    deviceTypes:
      - id: 0x0511
    deviceProfileName: electrical-utility-meter
  - id: "matter/meter-reference-point"
    deviceLabel: Matter Meter Reference
    deviceTypes:
      - id: 0x0512
    deviceProfileName: meter-reference-point
  - id: "matter/electrical-energy-tariff"
    deviceLabel: Matter Energy Tariff
    deviceTypes:
      - id: 0x0513
    deviceProfileName: electrical-energy-tariff
  - id: "matter/electrical-meter"
    deviceLabel: Matter Electrical Meter
    deviceTypes:
      - id: 0x0514
    deviceProfileName: electrical-meter
```

---

## Appendix C: Key Decisions & Trade-offs

| Decision | Alternatives Considered | Rationale |
|---|---|---|
| **Single driver for all electrical types** | Separate drivers per device type | Matter energy devices share many clusters (EPM, EEM, DEM). A single driver avoids code duplication and handles co-located device types naturally. |
| **Sub-drivers for new device types** | Everything in init.lua | The current 758-line monolith is already hard to maintain. Sub-drivers provide clean separation. |
| **Custom capabilities for Water Heater** | Reuse generic `switch` + `thermostat` | Water Heater has unique concepts (boost, tank percentage) that don't map well to generic caps. |
| **Phase 5 for metering (1.5 clusters)** | Implement everything at once | The 1.5 metering clusters (CommodityMetering, CommodityPrice, CommodityTariff, MeterIdentification) have few real devices today. Prioritize Water Heater and Heat Pump first. |
| **Dynamic profile selection in doConfigure** | Static profiles per fingerprint | Devices with the same primary type can have different optional clusters. Dynamic selection ensures the correct UI. |

---

*Document Version: 1.0*
*Last Updated: March 4, 2026*
*Author: SmartThings Edge Driver Team*
