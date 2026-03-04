# Design Plan v2.0: Matter 1.5 Electrical Device Class Support
## SmartThings Edge Driver — `matter-energy`

---

> **v2.0 Changelog (vs v1.0):**
> - **CRITICAL FIX:** Water Heater (0x050F) and Heat Pump (0x0309) are **already implemented** in the `matter-thermostat` driver — removed from `matter-energy` scope
> - **Clarification:** "Cluster handler registry" recommendation assessed — the `matter_handlers.attr` table IS the registry; all drivers already use it
> - Corrected `capabilities/` directory location to match repo convention
> - Added `version.api` gating enforcement requirements with exact thresholds
> - Revised implementation phases based on actual remaining work
> - Added cross-driver analysis section
> - Added feedback resolution appendix

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current State Analysis — Updated](#2-current-state-analysis--updated)
3. [Cross-Driver Analysis — NEW](#3-cross-driver-analysis--new)
4. [Matter 1.5 Electrical Device Types — Scope Revision](#4-matter-15-electrical-device-types--scope-revision)
5. [Cluster-to-Capability Mapping](#5-cluster-to-capability-mapping)
6. [Architecture & File Structure](#6-architecture--file-structure)
7. [Handler Design (Detailed)](#7-handler-design-detailed)
8. [Cluster Handler Registration Pattern — Analysis](#8-cluster-handler-registration-pattern--analysis)
9. [Profile Design](#9-profile-design)
10. [Lifecycle & Discovery Flow](#10-lifecycle--discovery-flow)
11. [Feature-Gated Logic](#11-feature-gated-logic)
12. [Implementation Phases — Revised](#12-implementation-phases--revised)
13. [Testing Strategy](#13-testing-strategy)
14. [Glossary](#14-glossary)
15. [Appendix A: Co-location Patterns](#appendix-a-co-location-patterns)
16. [Appendix B: Updated fingerprints.yml](#appendix-b-updated-fingerprintsyml)
17. [Appendix C: Key Decisions & Trade-offs](#appendix-c-key-decisions--trade-offs)
18. [Appendix D: Feedback Resolution](#appendix-d-feedback-resolution)

---

## 1. Executive Summary

### Goal
Extend the existing `matter-energy` SmartThings Edge driver to support the **remaining unsupported** electrical device types defined in the Matter 1.5 specification.

### Critical Finding (v2.0)

During cross-driver codebase review, we discovered that **Water Heater (0x050F) and Heat Pump (0x0309) are already implemented** in the `matter-thermostat` driver:

| Already Implemented (in `matter-thermostat`) | Evidence |
|---|---|
| Water Heater (0x050F) | `fingerprints.yml` line 178, profiles: `water-heater.yml`, `water-heater-power-energy-powerConsumption.yml`, test: `test_matter_water_heater.lua` (422 lines), `WaterHeaterMode` embedded cluster, `thermostat_handlers/attribute_handlers.lua` with water heater mode handlers |
| Heat Pump (0x0309) | `fingerprints.yml` line 183, profiles: `heat-pump.yml`, `heat-pump-thermostat.yml` + 5 variants, test: `test_matter_heat_pump.lua`, `fields.HEAT_PUMP_DEVICE_TYPE_ID = 0x0309` |

**The `matter-energy` driver should NOT duplicate Water Heater or Heat Pump support.** The SmartThings architecture deliberately splits these across drivers:
- **`matter-thermostat`** → Thermostat-centric devices (thermostats, water heaters, heat pumps, air purifiers, fans)
- **`matter-energy`** → Energy management devices (EVSE, solar, battery, electrical sensors, metering)

### Revised Scope

| Aspect | Current (v1) | Proposed (v2) |
|--------|-------------|---------------|
| Device Types Supported | 3 (EVSE, Solar Power, Battery Storage) | **7** (+ Electrical Sensor standalone, DEM standalone, Electrical Utility Meter, Meter Reference Point, Electrical Energy Tariff, Electrical Meter) |
| Clusters Handled | 5 + 1 (EnergyEvse, EnergyEvseMode, ElectricalPowerMeasurement, ElectricalEnergyMeasurement, DeviceEnergyManagementMode, PowerSource) | **12** (+ DeviceEnergyManagement full, PowerTopology, MeterIdentification, CommodityMetering, CommodityPrice, CommodityTariff) |
| Profiles | 8 | **15+** |
| Sub-drivers | 0 | **2** (metering, dem-standalone) |

### Why This Is Different from v1.0
- **v1.0** proposed 11 device types, 15 clusters, 4 sub-drivers — this included Water Heater and Heat Pump
- **v2.0** correctly scopes to 7 device types, 12 clusters, 2 sub-drivers — avoids duplicating existing functionality

---

## 2. Current State Analysis — Updated

### 2.1 Existing `matter-energy` Driver Architecture

```
matter-energy/
├── config.yml                 ← Driver metadata
├── fingerprints.yml           ← 3 fingerprints (EVSE, Solar, Battery)
├── profiles/                  ← 8 YAML capability profiles
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

### 2.2 Current Fingerprints

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

### 2.4 Current Handler Registration Pattern

The `matter-energy` driver uses the **standard `matter_handlers.attr` table** — the same pattern used by every Matter driver in the repository:

```lua
matter_driver_template = {
  matter_handlers = {
    attr = {
      [clusters.EnergyEvse.ID] = {
        [clusters.EnergyEvse.attributes.State.ID] = evse_state_handler,
        [clusters.EnergyEvse.attributes.SupplyState.ID] = evse_supply_state_handler,
        -- ...
      },
      [clusters.ElectricalPowerMeasurement.ID] = {
        [clusters.ElectricalPowerMeasurement.attributes.ActivePower.ID] = active_power_handler,
        -- ...
      },
      -- ... more clusters
    },
  },
}
```

This IS the cluster handler registry. See Section 8 for detailed analysis.

### 2.5 What's Missing (Revised)

| Device Type | ID | Status | Owner Driver |
|---|---|---|---|
| Electrical Sensor (standalone) | 0x0510 | ⚠️ Only as EVSE companion | `matter-energy` (extend) |
| Device Energy Management (standalone) | 0x050D | ⚠️ Only mode cluster | `matter-energy` (extend) |
| Electrical Utility Meter | 0x0511 | ❌ Not supported (new in 1.5) | `matter-energy` (new) |
| Meter Reference Point | 0x0512 | ❌ Not supported (new in 1.5) | `matter-energy` (new) |
| Electrical Energy Tariff | 0x0513 | ❌ Not supported (new in 1.5) | `matter-energy` (new) |
| Electrical Meter | 0x0514 | ❌ Not supported (new in 1.5) | `matter-energy` (new) |
| ~~Water Heater~~ | ~~0x050F~~ | ✅ Already done | `matter-thermostat` |
| ~~Heat Pump~~ | ~~0x0309~~ | ✅ Already done | `matter-thermostat` |

---

## 3. Cross-Driver Analysis — NEW

### 3.1 How Electrical Device Types Are Split Across Drivers

The SmartThings Edge Driver repository follows a **domain-driven driver split**:

| Driver | Domain | Electrical Device Types Handled |
|---|---|---|
| `matter-energy` | Energy management, EV charging, solar, battery | EVSE (0x050C), Solar Power (0x0017), Battery Storage (0x0018), Electrical Sensor (0x0510 as EVSE companion) |
| `matter-thermostat` | Climate control, heating, hot water | Thermostat (0x0301), Water Heater (0x050F), Heat Pump (0x0309), Air Purifier (0x002D), Room AC (0x0072), Fan (0x002B) |
| `matter-switch` | Switching, lighting, plugs, valves | Electrical Sensor (0x0510 as Eve Energy companion via sub-driver) |

### 3.2 Shared Clusters Across Drivers

Several clusters appear in multiple drivers. This is by design — each driver has its own copy of the handler logic tailored to its device types:

| Cluster | `matter-energy` | `matter-thermostat` | `matter-switch` |
|---|:---:|:---:|:---:|
| ElectricalPowerMeasurement | ✅ | ✅ | ✅ |
| ElectricalEnergyMeasurement | ✅ | ✅ | ✅ |
| PowerSource | ✅ | ✅ | ✅ |
| WaterHeaterMode | — | ✅ | — |
| Thermostat | — | ✅ | — |
| EnergyEvse | ✅ | — | — |
| PowerTopology | — | — | ✅ |

### 3.3 What This Means for the Design

1. **DO NOT** add Water Heater or Heat Pump to `matter-energy` — they are in `matter-thermostat`
2. **DO NOT** add Thermostat cluster handling to `matter-energy` — reuse from `matter-thermostat` if needed
3. **DO** add standalone Electrical Sensor support (not tied to EVSE)
4. **DO** add full DEM cluster support (currently only DEMMode)
5. **DO** add all Matter 1.5 metering device types (0x0511–0x0514) — these are genuinely new

### 3.4 matter-thermostat Water Heater Implementation Details

For reference, here's what the `matter-thermostat` driver already covers:

**Fingerprints:**
```yaml
- id: "matter/water-heater"
  deviceLabel: Matter Water Heater
  deviceTypes:
    - id: 0x050F
  deviceProfileName: water-heater
```

**Profiles:**
- `water-heater.yml` — temperatureMeasurement, thermostatMode, thermostatHeatingSetpoint, mode (WaterHeaterMode)
- `water-heater-power-energy-powerConsumption.yml` — adds powerMeter, energyMeter, powerConsumptionReport

**Clusters handled:** Thermostat, TemperatureMeasurement, WaterHeaterMode, ElectricalPowerMeasurement, ElectricalEnergyMeasurement

**Embedded cluster:** `WaterHeaterMode` (gated by `version.api < 13`)

**Tests:** `test_matter_water_heater.lua` (422 lines, comprehensive)

### 3.5 matter-thermostat Heat Pump Implementation Details

**Fingerprints:**
```yaml
- id: "matter/heat-pump"
  deviceLabel: Matter Heat Pump
  deviceTypes:
    - id: 0x0309
    - id: 0x0510
  deviceProfileName: heat-pump
- id: "matter/heat-pump/thermostat"
  deviceLabel: Matter Heat Pump
  deviceTypes:
    - id: 0x0309
    - id: 0x0510
    - id: 0x0301
  deviceProfileName: heat-pump-thermostat
```

**Profiles:** 7 variants — `heat-pump.yml`, `heat-pump-thermostat.yml`, `heat-pump-thermostat-humidity.yml`, etc.

**Tests:** `test_matter_heat_pump.lua`

---

## 4. Matter 1.5 Electrical Device Types — Scope Revision

### 4.1 Device Type Master Table

| # | Device Type | ID (Hex) | ID (Dec) | Spec Since | Driver Owner | Status |
|---|---|---|---|---|---|---|
| 1 | Solar Power | 0x0017 | 23 | 1.4 | `matter-energy` | ✅ Done |
| 2 | Battery Storage | 0x0018 | 24 | 1.4 | `matter-energy` | ✅ Done |
| 3 | Heat Pump | 0x0309 | 777 | 1.4 | `matter-thermostat` | ✅ Done |
| 4 | Energy EVSE | 0x050C | 1292 | 1.3 | `matter-energy` | ✅ Done |
| 5 | Device Energy Management | 0x050D | 1293 | 1.3 | `matter-energy` | ⚠️ Partial |
| 6 | Water Heater | 0x050F | 1295 | 1.4 | `matter-thermostat` | ✅ Done |
| 7 | Electrical Sensor | 0x0510 | 1296 | 1.3 | `matter-energy` | ⚠️ Partial |
| 8 | **Electrical Utility Meter** | 0x0511 | 1297 | **1.5** | `matter-energy` | ❌ New |
| 9 | **Meter Reference Point** | 0x0512 | 1298 | **1.5** | `matter-energy` | ❌ New |
| 10 | **Electrical Energy Tariff** | 0x0513 | 1299 | **1.5** | `matter-energy` | ❌ New |
| 11 | **Electrical Meter** | 0x0514 | 1300 | **1.5** | `matter-energy` | ❌ New |

### 4.2 Remaining Device Type → Required Cluster Mapping

```
Legend:  M = Mandatory    O = Optional
```

**Device Energy Management (0x050D)** — Energy management controller (standalone)
| Cluster | ID | Requirement | Current Status |
|---|---|---|---|
| DeviceEnergyManagement | 0x0098 | **M** | ❌ Not implemented (only DEMMode exists) |
| DeviceEnergyManagementMode | 0x009F | O | ✅ Done |

**Electrical Sensor (0x0510)** — Standalone power/energy measurement point
| Cluster | ID | Requirement | Current Status |
|---|---|---|---|
| ElectricalPowerMeasurement | 0x0090 | **M** (at least one of EPM/EEM) | ✅ Done |
| ElectricalEnergyMeasurement | 0x0091 | **M** (at least one of EPM/EEM) | ✅ Done |
| PowerTopology | 0x009C | O | ❌ Not implemented |

**Electrical Utility Meter (0x0511)** — Utility smart meter
| Cluster | ID | Requirement |
|---|---|---|
| MeterIdentification | 0x0B06 | **M** |
| ElectricalPowerMeasurement | 0x0090 | O |
| ElectricalEnergyMeasurement | 0x0091 | O |

**Meter Reference Point (0x0512)** — Measurement reference topology
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

### 4.3 New Clusters Required (6 clusters)

| # | Cluster | ID | Type | Key Attributes |
|---|---------|-----|------|----------------|
| 1 | DeviceEnergyManagement (full) | 0x0098 | Commands | ESAType, ESAState, Forecast, PowerAdjustmentCapability, OptOutState |
| 2 | PowerTopology | 0x009C | Read-only | AvailableEndpoints, ActiveEndpoints |
| 3 | MeterIdentification | 0x0B06 | Read-only | MeterType, PointOfDelivery |
| 4 | CommodityMetering | 0x0B07 | Read-only | CumulativeEnergy, InstantaneousDemand |
| 5 | CommodityPrice | 0x0095 | Read-only | CurrentPrice, ForecastPrices |
| 6 | CommodityTariff | 0x0700 | Read-only | TariffSchedules, CurrentTariff |

---

## 5. Cluster-to-Capability Mapping

### 5.1 Mapping Design Principles

1. **One SmartThings capability per user-visible concept** (e.g., power measurement, energy consumption)
2. **Reuse existing capabilities** where possible (`powerMeter`, `energyMeter`)
3. **Create custom capabilities** only when no standard one fits (e.g., `meterIdentification`, `energyPrice`)
4. **Components** separate multi-function endpoints

### 5.2 Complete Mapping Table (Revised — `matter-energy` scope only)

| Matter Cluster | Matter Attribute(s) | SmartThings Capability | Capability Attribute | Notes |
|---|---|---|---|---|
| **ElectricalPowerMeasurement** | ActivePower | `powerMeter` | `power` (W) | Convert mW → W. ✅ Exists |
| | PowerMode | `powerSource` | `powerSource` | AC/DC mapping. ✅ Exists |
| | Voltage | `voltageMeasurement` | `voltage` (V) | Custom cap needed |
| | ActiveCurrent | `currentMeasurement` | `current` (A) | Custom cap needed |
| | Frequency | `frequencyMeasurement` | `frequency` (Hz) | Custom cap needed |
| | PowerFactor | `powerFactor` | `powerFactor` | Custom cap needed |
| **ElectricalEnergyMeasurement** | CumulativeEnergyImported | `energyMeter` | `energy` (Wh) | ✅ Exists |
| | PeriodicEnergyImported | `powerConsumptionReport` | `powerConsumption` | ✅ Exists |
| | CumulativeEnergyExported | `energyMeter` (export comp) | `energy` (Wh) | ✅ Exists |
| **DeviceEnergyManagement** | ESAState | `deviceEnergyManagement` | `esaState` | Custom cap |
| | ESAType | `deviceEnergyManagement` | `esaType` | |
| | Forecast | `deviceEnergyManagement` | `forecast` | Complex struct |
| | OptOutState | `deviceEnergyManagement` | `optOutState` | |
| **DeviceEnergyManagementMode** | SupportedModes/CurrentMode | `mode` | `mode` | ✅ Exists |
| **PowerTopology** | AvailableEndpoints | (internal use) | | Topology mapping |
| **MeterIdentification** | MeterType | `meterIdentification` | `meterType` | Custom cap |
| | PointOfDelivery | `meterIdentification` | `pointOfDelivery` | |
| **CommodityMetering** | CumulativeEnergy | `energyMeter` | `energy` | Reuse existing |
| | InstantaneousDemand | `powerMeter` | `power` | Reuse existing |
| **CommodityPrice** | CurrentPrice | `energyPrice` | `currentPrice` | Custom cap |
| **CommodityTariff** | CurrentTariff | `energyTariff` | `currentTariff` | Custom cap |

### 5.3 Custom Capabilities Required (Revised — 5 capabilities)

| Custom Capability ID | Purpose | Attributes | Commands |
|---|---|---|---|
| `deviceEnergyManagement` | DEM ESA state & forecast | esaState, esaType, optOutState | — |
| `meterIdentification` | Utility meter metadata | meterType, pointOfDelivery | — |
| `energyPrice` | Live commodity pricing | currentPrice, currency, unit | — |
| `energyTariff` | Tariff schedule info | currentTariff, description | — |
| `voltageMeasurement` | AC/DC voltage | voltage (V) | — |

> **Note (v2.0):** `waterHeaterOperationalState` custom capability from v1.0 has been removed — the `matter-thermostat` driver uses standard `thermostatMode`, `thermostatHeatingSetpoint`, and `mode` capabilities for Water Heater, which is already implemented and tested.

---

## 6. Architecture & File Structure

### 6.1 Proposed Directory Structure (Revised)

```
matter-energy/
├── config.yml
├── fingerprints.yml                     ← Updated with remaining device types
├── capabilities/                        ← Custom capability definitions
│   ├── deviceEnergyManagement.yml       ← (under driver root, per repo convention)
│   ├── meterIdentification.yml
│   ├── energyPrice.yml
│   ├── energyTariff.yml
│   └── voltageMeasurement.yml
├── profiles/                            ← Expanded from 8 → 15+ profiles
│   ├── evse.yml                         ← Existing (unchanged)
│   ├── evse-energy-meas.yml             ← Existing
│   ├── evse-energy-meas-energy-mgmt-mode.yml
│   ├── evse-energy-meas-power-meas-energy-mgmt-mode.yml
│   ├── evse-power-meas.yml
│   ├── evse-power-meas-energy-mgmt-mode.yml
│   ├── solar-power.yml                  ← Existing (unchanged)
│   ├── battery-storage.yml              ← Existing (unchanged)
│   ├── electrical-sensor.yml            ← NEW (standalone)
│   ├── electrical-sensor-topology.yml   ← NEW (with PowerTopology)
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
    │   ├── energy_measurement_handlers.lua  ← EPM + EEM handlers (extracted)
    │   ├── mode_handlers.lua            ← All mode cluster handlers (extracted)
    │   ├── dem_handlers.lua             ← NEW: full DEM cluster support
    │   ├── metering_handlers.lua        ← NEW: MeterIdentification, CommodityMetering
    │   ├── pricing_handlers.lua         ← NEW: CommodityPrice, CommodityTariff
    │   └── power_topology_handlers.lua  ← NEW
    ├── sub_drivers/                     ← NEW: device-type-specific sub-drivers
    │   ├── metering/                    ← Covers Utility Meter, Reference Point, Tariff, Meter
    │   │   ├── init.lua
    │   │   └── can_handle.lua
    │   └── dem_standalone/
    │       ├── init.lua
    │       └── can_handle.lua
    ├── DeviceEnergyManagement/          ← NEW: full embedded cluster def
    ├── PowerTopology/                   ← NEW: embedded cluster def
    ├── MeterIdentification/             ← NEW: embedded cluster def
    ├── CommodityMetering/               ← NEW: embedded cluster def
    ├── CommodityPrice/                  ← NEW: embedded cluster def
    ├── CommodityTariff/                 ← NEW: embedded cluster def
    ├── DeviceEnergyManagementMode/      ← Existing
    ├── ElectricalEnergyMeasurement/     ← Existing
    ├── ElectricalPowerMeasurement/      ← Existing
    ├── EnergyEvse/                      ← Existing
    ├── EnergyEvseMode/                  ← Existing
    └── test/
        ├── test_evse.lua                ← Existing
        ├── test_electrical_sensor.lua   ← NEW
        ├── test_dem_standalone.lua       ← NEW
        ├── test_metering.lua            ← NEW
        └── test_pricing.lua             ← NEW
```

### 6.2 Design Rationale (Revised)

| Decision | Why |
|---|---|
| **No Water Heater / Heat Pump** | Already implemented in `matter-thermostat` with full profiles, handlers, fingerprints, and tests |
| **Sub-drivers** for Metering and DEM standalone only | These have unique cluster combinations distinct from EVSE/Solar/Battery. Only 2 sub-drivers needed (not 4 as in v1.0) |
| **Handler modules** extracted from init.lua | The current init.lua is 758 lines and monolithic. Splitting into handler modules improves maintainability |
| **Shared `constants.lua`** | Device type IDs, field names, and enum maps are used everywhere. Centralizing avoids duplication |
| **`capabilities/` under driver root** | Matches repo convention. Other drivers like `aqara-lock` and `aqara-cube` put custom capabilities here |
| **Separate `can_handle.lua` files** | Matches the repo pattern (e.g., `eve_energy/can_handle.lua` uses lazy loading) |

---

## 7. Handler Design (Detailed)

### 7.1 DEM Handlers (`handlers/dem_handlers.lua`)

The full DeviceEnergyManagement cluster expands beyond just the Mode cluster already implemented:

```lua
-- handlers/dem_handlers.lua
local capabilities = require "st.capabilities"
local clusters = require "st.matter.clusters"
local log = require "log"

local DemHandlers = {}

-- ESA State Maps
local ESA_STATE_MAP = {
  [0x00] = "offline",
  [0x01] = "online",
  [0x02] = "fault",
  [0x03] = "userOptOut",
  [0x04] = "powerAdjustActive",
  [0x05] = "paused",
}

local ESA_TYPE_MAP = {
  [0x00] = "evse",
  [0x01] = "spaceHeating",
  [0x02] = "waterHeating",
  [0x03] = "spaceCooling",
  [0x04] = "spaceHeatingCooling",
  [0x05] = "batteryStorage",
  [0x06] = "solarPV",
  [0x07] = "fridgeFreezer",
  [0x08] = "washingMachine",
  [0x09] = "dishwasher",
  [0x0A] = "cooking",
  [0x0B] = "homeWaterHeater",
  [0x0C] = "clothesDryer",
  [0xFF] = "other",
}

-- ESAState → deviceEnergyManagement.esaState
function DemHandlers.esa_state_handler(driver, device, ib, response)
  local state = ESA_STATE_MAP[ib.data.value]
  if state then
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.deviceEnergyManagement.esaState(state))
  end
end

-- ESAType → deviceEnergyManagement.esaType
function DemHandlers.esa_type_handler(driver, device, ib, response)
  local esa_type = ESA_TYPE_MAP[ib.data.value]
  if esa_type then
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.deviceEnergyManagement.esaType(esa_type))
  end
end

-- OptOutState → deviceEnergyManagement.optOutState
function DemHandlers.opt_out_state_handler(driver, device, ib, response)
  local opt_out_map = {
    [0x00] = "noOptOut",
    [0x01] = "localOptOut",
    [0x02] = "gridOptOut",
    [0x03] = "optOut",
  }
  local state = opt_out_map[ib.data.value]
  if state then
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.deviceEnergyManagement.optOutState(state))
  end
end

return DemHandlers
```

### 7.2 Metering Handlers (`handlers/metering_handlers.lua`)

```lua
-- handlers/metering_handlers.lua
local capabilities = require "st.capabilities"
local clusters = require "st.matter.clusters"

local MeteringHandlers = {}

-- MeterIdentification.MeterType → meterIdentification.meterType
function MeteringHandlers.meter_type_handler(driver, device, ib, response)
  local meter_type_map = {
    [0x00] = "utility",
    [0x01] = "private",
    [0x02] = "industrial",
  }
  local meter_type = meter_type_map[ib.data.value]
  if meter_type then
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.meterIdentification.meterType(meter_type))
  end
end

-- MeterIdentification.PointOfDelivery → meterIdentification.pointOfDelivery
function MeteringHandlers.point_of_delivery_handler(driver, device, ib, response)
  if ib.data.value then
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.meterIdentification.pointOfDelivery(ib.data.value))
  end
end

-- CommodityMetering.CumulativeEnergy → energyMeter.energy
function MeteringHandlers.commodity_cumulative_energy_handler(driver, device, ib, response)
  if ib.data.value then
    local energy_wh = ib.data.value / 1000  -- mWh → Wh
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.energyMeter.energy({value = energy_wh, unit = "Wh"}))
  end
end

-- CommodityMetering.InstantaneousDemand → powerMeter.power
function MeteringHandlers.commodity_instantaneous_demand_handler(driver, device, ib, response)
  if ib.data.value then
    local power_w = ib.data.value / 1000  -- mW → W
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.powerMeter.power({value = power_w, unit = "W"}))
  end
end

return MeteringHandlers
```

### 7.3 Pricing Handlers (`handlers/pricing_handlers.lua`)

```lua
-- handlers/pricing_handlers.lua
local capabilities = require "st.capabilities"
local clusters = require "st.matter.clusters"

local PricingHandlers = {}

-- CommodityPrice.CurrentPrice → energyPrice.currentPrice
function PricingHandlers.current_price_handler(driver, device, ib, response)
  if ib.data then
    -- CommodityPrice struct contains price, currency, trailing digits
    device:emit_event_for_endpoint(ib.endpoint_id,
      capabilities.energyPrice.currentPrice({
        value = ib.data.elements.price.value,
        unit = ib.data.elements.currency.value
      }))
  end
end

return PricingHandlers
```

### 7.4 Energy Measurement Handlers (Refactored from init.lua)

The existing `energy_report_handler_factory`, `active_power_handler`, `power_mode_handler` are extracted **unchanged** into `handlers/energy_measurement_handlers.lua`. They become a module that can be required by both the main driver and sub-drivers.

### 7.5 EVSE Handlers (Refactored from init.lua)

All EVSE-specific handlers (`evse_state_handler`, `evse_supply_state_handler`, `evse_fault_state_handler`, `evse_charging_enabled_until_handler`, `evse_current_limit_handler`, `evse_session_duration_handler`, `evse_session_energy_charged_handler`) are extracted into `handlers/evse_handlers.lua`.

### 7.6 Mode Handlers (Refactored from init.lua)

`energy_evse_supported_modes_attr_handler`, `energy_evse_mode_attr_handler`, `device_energy_mgmt_supported_modes_attr_handler`, `device_energy_mgmt_mode_attr_handler` are extracted into `handlers/mode_handlers.lua`.

---

## 8. Cluster Handler Registration Pattern — Analysis

### 8.1 The Recommendation Under Review

The feedback recommended adding a "cluster handler registry pattern":

```lua
-- Recommended pattern:
matter_handlers = {
   attr = {
      [clusters.ElectricalPowerMeasurement.ID] = power_handlers,
      [clusters.ElectricalEnergyMeasurement.ID] = energy_handlers
   }
}
```

### 8.2 Cross-Codebase Evidence

After examining **every Matter driver** in the repository, here is how each one registers handlers:

| Driver | `matter_handlers.attr` pattern | Uses separate handler modules? |
|---|---|---|
| `matter-switch` (365 lines) | `[clusters.X.ID] = { [clusters.X.attributes.Y.ID] = handler_fn }` | Yes: `switch_handlers/attribute_handlers.lua` |
| `matter-sensor` (303 lines) | `[clusters.X.ID] = { [clusters.X.attributes.Y.ID] = handler_fn }` | Yes: `sensor_handlers/attribute_handlers.lua` |
| `matter-thermostat` (519 lines) | `[clusters.X.ID] = { [clusters.X.attributes.Y.ID] = handler_fn }` | Yes: `thermostat_handlers/attribute_handlers.lua` |
| `matter-lock` (724 lines) | `[clusters.X.ID] = { [clusters.X.attributes.Y.ID] = handler_fn }` | No: all inline in init.lua |
| `matter-energy` (758 lines) | `[clusters.X.ID] = { [clusters.X.attributes.Y.ID] = handler_fn }` | No: all inline in init.lua |

### 8.3 Key Insight: The Registry IS the Pattern

**The `matter_handlers.attr` table is already a cluster handler registry.** Every driver in the repo uses exactly this pattern. There is no separate "registry" abstraction — the driver template table IS the dispatch registry.

The MatterDriver framework uses this table to:
1. Match incoming attribute reports by cluster ID
2. Match by attribute ID within the cluster
3. Call the registered handler function

### 8.4 What the Recommendation Actually Means

The feedback's example was slightly misleading. It suggested:

```lua
[clusters.ElectricalPowerMeasurement.ID] = power_handlers,  -- module reference
```

But in reality, every driver in the repo registers **individual attribute handlers**, not entire modules:

```lua
[clusters.ElectricalPowerMeasurement.ID] = {
  [clusters.ElectricalPowerMeasurement.attributes.ActivePower.ID] = attribute_handlers.active_power_handler,
  [clusters.ElectricalPowerMeasurement.attributes.PowerMode.ID] = attribute_handlers.power_mode_handler,
},
```

### 8.5 Assessment: Is This Helpful?

| Aspect | Assessment |
|---|---|
| Already in use? | **YES** — all 5 Matter drivers use this exact pattern |
| Changes needed? | **NO** — the existing `matter-energy` init.lua already uses it correctly |
| Any improvement possible? | **YES, but not the registry itself** — the improvement is extracting handler functions into separate modules (like `matter-switch` and `matter-thermostat` do) |

### 8.6 Design Decision

✅ **Keep the standard `matter_handlers.attr` table** as-is — it's the correct pattern  
✅ **Extract handler functions into modules** (as proposed in Section 6)  
❌ **Do NOT add a separate registry abstraction** — it would deviate from the repo pattern  

The actual improvement is the **handler module extraction** (e.g., `handlers/evse_handlers.lua`), not a different dispatch mechanism. The init.lua registers handlers from modules like this:

```lua
-- init.lua (refactored)
local evse_handlers = require "handlers.evse_handlers"
local energy_handlers = require "handlers.energy_measurement_handlers"
local mode_handlers = require "handlers.mode_handlers"
local dem_handlers = require "handlers.dem_handlers"
local metering_handlers = require "handlers.metering_handlers"
local pricing_handlers = require "handlers.pricing_handlers"

matter_driver_template = {
  matter_handlers = {
    attr = {
      [clusters.EnergyEvse.ID] = {
        [clusters.EnergyEvse.attributes.State.ID] = evse_handlers.state_handler,
        [clusters.EnergyEvse.attributes.SupplyState.ID] = evse_handlers.supply_state_handler,
        -- ...
      },
      [clusters.ElectricalPowerMeasurement.ID] = {
        [clusters.ElectricalPowerMeasurement.attributes.ActivePower.ID] = energy_handlers.active_power_handler,
        [clusters.ElectricalPowerMeasurement.attributes.PowerMode.ID] = energy_handlers.power_mode_handler,
      },
      [clusters.DeviceEnergyManagement.ID] = {
        [clusters.DeviceEnergyManagement.attributes.ESAState.ID] = dem_handlers.esa_state_handler,
        [clusters.DeviceEnergyManagement.attributes.ESAType.ID] = dem_handlers.esa_type_handler,
        [clusters.DeviceEnergyManagement.attributes.OptOutState.ID] = dem_handlers.opt_out_state_handler,
      },
      [clusters.MeterIdentification.ID] = {
        [clusters.MeterIdentification.attributes.MeterType.ID] = metering_handlers.meter_type_handler,
        [clusters.MeterIdentification.attributes.PointOfDelivery.ID] = metering_handlers.point_of_delivery_handler,
      },
      -- ... etc
    },
  },
}
```

This is the **exact same pattern** used by `matter-switch`, `matter-sensor`, and `matter-thermostat`.

---

## 9. Profile Design

### 9.1 Profile Naming Convention

Following the repo pattern:
```
<primary-device-type>[-optional-cluster-1][-optional-cluster-2].yml
```

### 9.2 New Profile Definitions

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

#### `dem-standalone.yml`
```yaml
name: dem-standalone
components:
- id: main
  capabilities:
  - id: deviceEnergyManagement    # Custom: ESA state, type
    version: 1
  - id: firmwareUpdate
    version: 1
  - id: refresh
    version: 1
  categories:
  - name: SmartPlug
```

#### `dem-standalone-mode.yml`
```yaml
name: dem-standalone-mode
components:
- id: main
  capabilities:
  - id: deviceEnergyManagement
    version: 1
  - id: mode                      # DeviceEnergyManagementMode
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
  - id: meterIdentification       # Custom: meter type, PoD
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
  - id: energyMeter               # From CommodityMetering
    version: 1
  - id: powerMeter                # From CommodityMetering
    version: 1
  - id: firmwareUpdate
    version: 1
  - id: refresh
    version: 1
  categories:
  - name: SmartPlug
```

#### `electrical-energy-tariff.yml`
```yaml
name: electrical-energy-tariff
components:
- id: main
  capabilities:
  - id: energyPrice               # Custom: current price
    version: 1
  - id: energyTariff              # Custom: tariff schedule
    version: 1
  - id: firmwareUpdate
    version: 1
  - id: refresh
    version: 1
  categories:
  - name: SmartPlug
```

### 9.3 Dynamic Profile Selection

Profile selection happens in `doConfigure` lifecycle. The logic remains:

```
FOR each device:
  1. Identify the PRIMARY device type (highest priority)
  2. Check which OPTIONAL clusters are present
  3. Build profile name string: <base>[-optional1][-optional2]
  4. Call device:try_update_metadata({ profile = profile_name })
```

Priority order (revised — excludes Water Heater and Heat Pump):
1. EVSE (0x050C) — highest, most specific
2. Electrical Utility Meter (0x0511)
3. Electrical Meter (0x0514)
4. Electrical Energy Tariff (0x0513)
5. Solar Power (0x0017)
6. Battery Storage (0x0018)
7. Device Energy Management (0x050D)
8. Electrical Sensor (0x0510)
9. Meter Reference Point (0x0512)

---

## 10. Lifecycle & Discovery Flow

### 10.1 Complete Device Discovery Sequence

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
│     - Has EPM? Has EEM? Has PowerTopology?                   │
│     - Has DEM Mode? Has MeterIdentification?                 │
│  3. Build profile name string                                │
│  4. Switch to correct profile:                               │
│     device:try_update_metadata({ profile = profile_name })   │
│                                                              │
│  5. Check FeatureMap for conditional attributes:             │
│     - EEM: Cumulative vs Periodic energy support             │
│     - EPM: AC vs DC, Polyphase, Harmonics                   │
│     - DEM: PowerAdjustment, Forecast, Pausable              │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    device_init (lifecycle)                    │
│                                                              │
│  1. Set endpoint_to_component / component_to_endpoint fns    │
│  2. Subscribe to all relevant attributes                     │
│  3. Read FeatureMap for conditional logic                    │
│  4. Set CUMULATIVE_REPORTS_NOT_SUPPORTED field if needed     │
└──────────────────────────────────────────────────────────────┘
```

### 10.2 Sub-Driver `can_handle` Pattern

Following the `eve_energy/can_handle.lua` pattern with lazy loading:

```lua
-- sub_drivers/metering/can_handle.lua
local device_lib = require "st.device"
local constants = require "constants"

return function(opts, driver, device)
  if device.network_type ~= device_lib.NETWORK_TYPE_MATTER then
    return false
  end
  for _, ep in ipairs(device.endpoints) do
    for _, dt in ipairs(ep.device_types) do
      if dt.device_type_id == constants.ELECTRICAL_UTILITY_METER_DT_ID
        or dt.device_type_id == constants.ELECTRICAL_METER_DT_ID
        or dt.device_type_id == constants.ELECTRICAL_ENERGY_TARIFF_DT_ID
        or dt.device_type_id == constants.METER_REFERENCE_POINT_DT_ID then
        return true, require("sub_drivers.metering")
      end
    end
  end
  return false
end
```

---

## 11. Feature-Gated Logic

### 11.1 `version.api` Gating Requirements

The repo enforces embedded cluster loading behind `version.api` checks. Based on current codebase evidence:

| API Version | What It Gates | Evidence |
|---|---|---|
| `< 10` | AirQuality, Concentration clusters, SmokeCoAlarm | `matter-sensor`, `matter-thermostat` |
| `< 11` | ElectricalEnergyMeasurement, ElectricalPowerMeasurement, PowerTopology, BooleanStateConfiguration, ValveConfigurationAndControl | `matter-switch`, `matter-energy`, `matter-thermostat` |
| `< 12` | (varies) | `matter-energy` checks |
| `< 13` | WaterHeaterMode | `matter-thermostat` |
| `< 16` | Descriptor | `matter-switch` |

**For new clusters**, we must determine the correct API version threshold. Since Matter 1.5 metering clusters are new, they will likely need:

```lua
-- In init.lua:
if version.api < 17 then  -- TBD: check actual SDK version when released
  clusters.MeterIdentification = require "MeterIdentification"
  clusters.CommodityMetering = require "CommodityMetering"
  clusters.CommodityPrice = require "CommodityPrice"
  clusters.CommodityTariff = require "CommodityTariff"
end

if version.api < 14 then  -- TBD
  clusters.DeviceEnergyManagement = require "DeviceEnergyManagement"
  clusters.PowerTopology = require "PowerTopology"
end
```

> **⚠️ Important:** The exact `version.api` thresholds must be confirmed against the SmartThings Lua SDK release that adds native support for each cluster. Use conservative (high) thresholds until confirmed.

### 11.2 FeatureMap Checks Required

| Cluster | Feature | Bit | What It Gates |
|---|---|---|---|
| **ElectricalEnergyMeasurement** | CUMULATIVE_ENERGY | 0x04 | CumulativeEnergyImported/Exported attributes |
| | PERIODIC_ENERGY | 0x08 | PeriodicEnergyImported/Exported attributes |
| | IMPORTED_ENERGY | 0x01 | *Imported attributes |
| | EXPORTED_ENERGY | 0x02 | *Exported attributes |
| **ElectricalPowerMeasurement** | ALTERNATING_CURRENT | 0x02 | Voltage, Frequency, PowerFactor |
| | DIRECT_CURRENT | 0x01 | DC measurement attributes |
| | POLYPHASE_POWER | 0x04 | Multi-phase measurement |
| **DeviceEnergyManagement** | POWER_ADJUSTMENT | 0x01 | PowerAdjustmentCapability, commands |
| | FORECAST_ADJUSTMENT | 0x04 | Forecast attribute |
| | CONSTRAINT_BASED_ADJUSTMENT | 0x08 | RequestConstraintBasedForecast command |
| | PAUSABLE | 0x02 | OptOutState, Pause/Resume commands |

### 11.3 Implementation Pattern (from existing codebase)

```lua
-- Existing pattern in matter-energy init.lua (device_init):
if #embedded_cluster_utils.get_endpoints(device,
  clusters.ElectricalEnergyMeasurement.ID,
  {feature_bitmap = clusters.ElectricalEnergyMeasurement.types.Feature.CUMULATIVE_ENERGY}
) == 0 then
  device:set_field(CUMULATIVE_REPORTS_NOT_SUPPORTED, true, {persist = false})
end

-- Same pattern used in matter-switch and matter-thermostat:
-- matter-switch/init.lua line 126:
if #embedded_cluster_utils.get_endpoints(device,
  clusters.ElectricalEnergyMeasurement.ID,
  {feature_bitmap = clusters.ElectricalEnergyMeasurement.types.Feature.CUMULATIVE_ENERGY}
) > 0 then
  device:set_field(fields.CUMULATIVE_REPORTS_SUPPORTED, true, {persist = false})
end
```

---

## 12. Implementation Phases — Revised

### Phase 1: Refactor & Foundation (Week 1-2)

**Goal:** Clean up the existing 758-line init.lua without changing behavior.

| Task | Description | Files |
|---|---|---|
| 1.1 | Create `constants.lua` — extract device type IDs, field names, enum maps | New file |
| 1.2 | Create `handlers/evse_handlers.lua` — extract 8 EVSE attribute handlers + command handlers | New file (extract from init.lua) |
| 1.3 | Create `handlers/energy_measurement_handlers.lua` — extract `energy_report_handler_factory`, `active_power_handler`, `power_mode_handler` | New file (extract from init.lua) |
| 1.4 | Create `handlers/mode_handlers.lua` — extract 4 mode-related handlers | New file (extract from init.lua) |
| 1.5 | Slim down `init.lua` to ~200 lines: lifecycle orchestration + handler registration | Modify init.lua |
| 1.6 | Update `embedded_cluster_utils.lua` to register new cluster definitions | Modify |
| 1.7 | Run existing tests to confirm zero regressions | Run tests |

**Success criteria:** All existing tests pass. init.lua < 250 lines.

### Phase 2: Standalone Electrical Sensor & DEM (Week 3-4)

**Goal:** Support Electrical Sensor without EVSE, and full DEM device type.

| Task | Description | Files |
|---|---|---|
| 2.1 | Create `DeviceEnergyManagement` full embedded cluster definition | New |
| 2.2 | Create `PowerTopology` embedded cluster definition | New |
| 2.3 | Define `deviceEnergyManagement` custom capability | New YAML |
| 2.4 | Create `handlers/dem_handlers.lua` | New |
| 2.5 | Create `handlers/power_topology_handlers.lua` | New |
| 2.6 | Create profiles: `electrical-sensor.yml`, `dem-standalone.yml`, `dem-standalone-mode.yml` | New |
| 2.7 | Create `sub_drivers/dem_standalone/` | New |
| 2.8 | Add fingerprints for standalone Electrical Sensor (0x0510) and DEM (0x050D) | Modify fingerprints.yml |
| 2.9 | Write tests: `test_electrical_sensor.lua`, `test_dem_standalone.lua` | New |

### Phase 3: Metering Ecosystem (Week 5-7)

**Goal:** All Matter 1.5 metering device types.

| Task | Description | Files |
|---|---|---|
| 3.1 | Create embedded cluster defs: MeterIdentification, CommodityMetering, CommodityPrice, CommodityTariff | New |
| 3.2 | Define custom capabilities: meterIdentification, energyPrice, energyTariff | New YAML |
| 3.3 | Create `handlers/metering_handlers.lua` | New |
| 3.4 | Create `handlers/pricing_handlers.lua` | New |
| 3.5 | Create profiles: `electrical-utility-meter.yml`, `electrical-meter.yml`, `electrical-energy-tariff.yml`, `meter-reference-point.yml` | New |
| 3.6 | Create `sub_drivers/metering/` | New |
| 3.7 | Add fingerprints for 0x0511, 0x0512, 0x0513, 0x0514 | Modify fingerprints.yml |
| 3.8 | Write tests: `test_metering.lua`, `test_pricing.lua` | New |

### Phase 4: Integration Testing & Polish (Week 8-9)

| Task | Description |
|---|---|
| 4.1 | End-to-end testing with virtual/real devices |
| 4.2 | Multi-endpoint co-location testing (e.g., Utility Meter + Reference Point + Tariff + Meter on same physical device) |
| 4.3 | Profile switching edge cases |
| 4.4 | FeatureMap edge cases (missing features, unknown enum values) |
| 4.5 | Cross-driver testing: verify no conflicts with `matter-thermostat` for shared device types |
| 4.6 | Documentation and README update |

### Timeline Comparison v1.0 vs v2.0

| | v1.0 | v2.0 |
|---|---|---|
| Phases | 6 (12 weeks) | 4 (9 weeks) |
| Sub-drivers to build | 4 | 2 |
| Profiles to create | 12+ | 7 |
| Handler modules | 8 | 7 |
| Reason for reduction | Water Heater + Heat Pump already exist in `matter-thermostat` | N/A |

---

## 13. Testing Strategy

### 13.1 Unit Test Structure

Following the existing `integration_test` framework pattern:

```lua
-- test/test_electrical_sensor.lua
local test = require "integration_test"
local capabilities = require "st.capabilities"
local clusters = require "st.matter.clusters"
local t_utils = require "integration_test.utils"

local mock_device = test.mock_device.build_test_matter_device({
  profile = t_utils.get_profile_definition("electrical-sensor.yml"),
  manufacturer_info = { vendor_id = 0x0000, product_id = 0x0000 },
  endpoints = {
    {
      endpoint_id = 1,
      clusters = {
        { cluster_id = clusters.ElectricalPowerMeasurement.ID, cluster_type = "SERVER" },
        { cluster_id = clusters.ElectricalEnergyMeasurement.ID, cluster_type = "SERVER",
          feature_map = 13 }, -- IMPE, CUME, PERE
      },
      device_types = {
        { device_type_id = 0x0510, device_type_revision = 1 },  -- Electrical Sensor
      }
    }
  }
})

-- Test: ActivePower → powerMeter.power
test.register_coroutine_test("Standalone electrical sensor power reading", function()
  test.socket.matter:__queue_receive({
    mock_device.id,
    clusters.ElectricalPowerMeasurement.attributes.ActivePower:build_test_report_data(
      mock_device, 1, 150000  -- 150W in mW
    )
  })
  test.socket.capability:__expect_send(
    mock_device:generate_test_message("main",
      capabilities.powerMeter.power({ value = 150.0, unit = "W" }))
  )
end)
```

### 13.2 Test Coverage Matrix (Revised)

| Device Type | Attribute Handlers | Command Handlers | Profile Switch | Feature Gating | Co-location |
|---|:---:|:---:|:---:|:---:|:---:|
| EVSE | ✅ Existing | ✅ Existing | ✅ Existing | ✅ | ✅ |
| Solar Power | ✅ Existing | N/A | ✅ | ✅ | — |
| Battery Storage | ✅ Existing | N/A | ✅ | ✅ | — |
| ~~Water Heater~~ | ~~✅ Already in matter-thermostat~~ | — | — | — | — |
| ~~Heat Pump~~ | ~~✅ Already in matter-thermostat~~ | — | — | — | — |
| Electrical Sensor (standalone) | 🆕 | N/A | 🆕 | ✅ | — |
| DEM Standalone | 🆕 | 🆕 | 🆕 | 🆕 | — |
| Utility Meter | 🆕 | N/A | 🆕 | — | 🆕 |
| Meter Ref Point | 🆕 | N/A | 🆕 | — | 🆕 |
| Energy Tariff | 🆕 | N/A | 🆕 | — | 🆕 |
| Electrical Meter | 🆕 | N/A | 🆕 | — | 🆕 |

---

## 14. Glossary

| Term | Definition |
|---|---|
| **Device Type** | A Matter specification concept defining what a physical device is (e.g., "Electrical Meter"). Identified by a hex ID (e.g., 0x0514). Determines which clusters are mandatory. |
| **Cluster** | A Matter concept grouping related attributes, commands, and events (e.g., "CommodityMetering" cluster handles cumulative energy and demand readings). |
| **Endpoint** | A logical sub-device within a physical Matter device. A single physical device can expose multiple endpoints, each with different device types. |
| **Attribute** | A named, typed data point within a cluster that can be read and/or subscribed to. E.g., `CumulativeEnergy` in CommodityMetering. |
| **Command** | An action that can be sent to a cluster. E.g., `ChangeToMode` on DeviceEnergyManagementMode. |
| **FeatureMap** | A 32-bit bitmask (attribute 0xFFFC) on every cluster indicating which optional features the device supports. |
| **Profile** | A SmartThings YAML file defining which capabilities a device exposes in the app UI. Selected dynamically at `doConfigure`. |
| **Capability** | A SmartThings concept representing a user-visible function (e.g., `powerMeter`, `energyMeter`). Maps to UI controls. |
| **Component** | A named section within a SmartThings profile that groups capabilities (e.g., `main`, `electricalSensor`). Maps to endpoints. |
| **Sub-driver** | A Lua module within an Edge driver that handles a specific subset of devices. Selected via `can_handle()` function. |
| **Embedded Cluster** | A cluster definition included directly in the driver (in `src/`) when the SmartThings Lua library doesn't yet include it natively. Gated by `version.api < X` checks. |
| **Co-location** | When multiple device types share the same endpoint. E.g., Utility Meter + Meter Reference Point on the same physical device. |
| **ESA** | Energy Smart Appliance — the DEM cluster's term for any energy-managed device. ESAType tells you what kind (EVSE, water heater, battery, etc.). |
| **mW / mWh** | Matter reports power in milliwatts and energy in milliwatt-hours. SmartThings expects Watts and Watt-hours. Always divide by 1000. |
| **`matter_handlers.attr`** | The standard Lua table in every SmartThings MatterDriver template that maps cluster IDs → attribute IDs → handler functions. This IS the cluster handler dispatch registry. |

---

## Appendix A: Co-location Patterns

### Pattern 1: EVSE Device (existing)
```
Endpoint 0: Root Node
Endpoint 1: Energy EVSE (0x050C) + Electrical Sensor (0x0510) + DEM (0x050D)
  Clusters: EnergyEvse, EnergyEvseMode, EPM, EEM, DEM, DEMMode, PowerTopology
```

### Pattern 2: Full Metering Ecosystem (new in 1.5)
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

### Pattern 3: Water Heater Device (handled by `matter-thermostat`)
```
Endpoint 0: Root Node
Endpoint 1: Water Heater (0x050F) + Electrical Sensor (0x0510) + DEM (0x050D)
  Clusters: WaterHeaterManagement, WaterHeaterMode, Thermostat(opt), EPM, EEM, DEM, DEMMode
```

### Pattern 4: Heat Pump Device (handled by `matter-thermostat`)
```
Endpoint 0: Root Node
Endpoint 1: Heat Pump (0x0309) + Electrical Sensor (0x0510) + DEM (0x050D)
  Clusters: Thermostat, EPM, EEM, DEM, DEMMode, PowerTopology
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

  # Extended existing device types
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

  # New Matter 1.5 device types
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

> **Note:** Water Heater (0x050F) and Heat Pump (0x0309) fingerprints are NOT added here — they already exist in `matter-thermostat/fingerprints.yml`.

---

## Appendix C: Key Decisions & Trade-offs

| Decision | Alternatives Considered | Rationale |
|---|---|---|
| **Remove Water Heater + Heat Pump from scope** | Duplicate support in `matter-energy` | These device types are already fully implemented in `matter-thermostat` with profiles, handlers, fingerprints, embedded clusters, and comprehensive tests. Duplicating would create maintenance burden and potential fingerprint conflicts. |
| **Keep standard `matter_handlers.attr` table** | Add separate "cluster handler registry" abstraction | Every driver in the repo (5/5 examined) uses the same `matter_handlers.attr` pattern. Adding an abstraction would deviate from established patterns. |
| **Extract handler modules** | Keep monolithic init.lua | Current init.lua is 758 lines. Drivers like `matter-switch` and `matter-thermostat` already use `attribute_handlers.lua` / `capability_handlers.lua` modules. Follow this proven pattern. |
| **Only 2 sub-drivers** (metering, dem-standalone) | 4 sub-drivers as in v1.0 | With Water Heater and Heat Pump removed, only metering (4 device types) and DEM standalone need sub-driver isolation. Electrical Sensor standalone can be handled in the main driver. |
| **Separate `can_handle.lua` files** | Inline `can_handle` in sub-driver init | Matches `eve_energy/can_handle.lua` pattern that supports lazy loading. |
| **Phase 5 metering clusters prioritized after DEM** | Metering first | DEM has partially existing support (DEMMode) and higher device availability than 1.5 metering devices. |

---

## Appendix D: Feedback Resolution

### D.1 Feedback Item Analysis

Each feedback item from the v1.0 review has been assessed against the actual codebase:

| # | Feedback Item | Assessment | Action in v2.0 |
|---|---|---|---|
| 1 | Driver structure alignment | ✅ Confirmed: structure matches repo | No change needed |
| 2 | Existing driver patterns | ✅ Confirmed: handler modules + sub-drivers are standard | No change needed |
| 3 | Capability integration | ✅ Confirmed: standard `capabilities.X.y(value)` pattern | No change needed |
| 4 | Matter cluster integration | ✅ Confirmed: `st.matter.clusters` + embedded clusters | No change needed |
| 5 | Dynamic profile selection | ✅ Confirmed: `try_update_metadata` in doConfigure | No change needed |
| 6 | Fingerprints compatibility | ✅ Confirmed: `matterGeneric` pattern | No change needed |
| 7 | Unit conversion (mW→W, mWh→Wh) | ✅ Confirmed: existing handlers divide by 1000 | No change needed |
| 8 | Event handler model | ✅ Confirmed: attr → handler → capability event | No change needed |
| 9 | Custom capabilities location | ⚠️ **Adjusted**: moved to `capabilities/` under driver root | Updated in Section 6 |
| 10 | Embedded clusters version gating | ⚠️ **Enforced**: added explicit `version.api` thresholds | Updated in Section 11 |
| 11 | Testing framework | ✅ Confirmed: `integration_test` framework | No change needed |
| 12 | Implementation priority | 🔄 **Revised**: removed WH/HP, reordered phases | Updated in Section 12 |
| 13 | Cluster handler registry | ❌ **Rejected**: it's not a separate pattern, it IS the existing `matter_handlers.attr` table | Full analysis in Section 8 |

### D.2 Critical Discovery: Water Heater + Heat Pump Already Exist

**Evidence path:**
1. `matter-thermostat/fingerprints.yml` lines 178-195: fingerprints for `0x050F` and `0x0309`
2. `matter-thermostat/profiles/`: `water-heater.yml`, `water-heater-power-energy-powerConsumption.yml`, 7 heat-pump variants
3. `matter-thermostat/src/thermostat_utils/fields.lua` line 35: `WATER_HEATER_DEVICE_TYPE_ID = 0x050F`
4. `matter-thermostat/src/init.lua` line 38: `clusters.WaterHeaterMode = require "embedded_clusters.WaterHeaterMode"`
5. `matter-thermostat/src/embedded_clusters/WaterHeaterMode/`: full embedded cluster definition
6. `matter-thermostat/src/thermostat_handlers/attribute_handlers.lua`: `water_heater_supported_modes_handler`, `water_heater_current_mode_handler`
7. `matter-thermostat/src/test/test_matter_water_heater.lua`: 422-line comprehensive test file
8. `matter-thermostat/src/test/test_matter_heat_pump.lua`: test file exists

### D.3 Cluster Handler Registry — Detailed Analysis

The feedback recommended:
```lua
matter_handlers = {
   attr = {
      [clusters.ElectricalPowerMeasurement.ID] = power_handlers,
      [clusters.ElectricalEnergyMeasurement.ID] = energy_handlers
   }
}
```

**Actual repo usage (all 5 Matter drivers):**
```lua
matter_handlers = {
   attr = {
      [clusters.ElectricalPowerMeasurement.ID] = {
         [clusters.ElectricalPowerMeasurement.attributes.ActivePower.ID] = handler_fn,
      },
   }
}
```

The `matter_handlers.attr` table **IS** the dispatch registry. The MatterDriver framework reads this table to route incoming attribute reports to the correct handler. Every driver uses it identically. There is no separate registry layer to add.

The **real improvement** is extracting handler functions into modules (which our design already does in Section 6), not changing the dispatch mechanism.

---

*Document Version: 2.0*
*Last Updated: March 4, 2026*
*Previous Version: [v1.0](./DESIGN_PLAN_ELECTRICAL_DEVICE_CLASS.md)*
*Author: SmartThings Edge Driver Team*
