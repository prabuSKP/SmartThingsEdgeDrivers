# Matter 1.5 Electrical Device Types — Implementation Summary
## SmartThings Edge Drivers (focused on `matter-energy` scope)

---

## 1) Device Types: What needs to be added?

| Device Type | ID (Hex) | Matter Since | Current SmartThings Status | Need to Add in `matter-energy`? | Already handled in which driver/device class? |
|---|---:|---:|---|---|---|
| Solar Power | `0x0017` | 1.4 | ✅ Supported | No | `matter-energy` (solar profile) |
| Battery Storage | `0x0018` | 1.4 | ✅ Supported | No | `matter-energy` (battery profile) |
| Energy EVSE | `0x050C` | 1.3 | ✅ Supported | No | `matter-energy` (EVSE profiles) |
| Device Energy Management (standalone) | `0x050D` | 1.3 | ⚠️ Partial (Mode cluster only) | **Yes** (full DEM cluster) | Partial in `matter-energy` |
| Electrical Sensor (standalone) | `0x0510` | 1.3 | ⚠️ Partial (as co-located companion) | **Yes** (standalone path) | Partial in `matter-energy`; also used in `matter-switch`/`matter-thermostat` combos |
| Electrical Utility Meter | `0x0511` | 1.5 | ❌ Not supported | **Yes** | Not yet handled |
| Meter Reference Point | `0x0512` | 1.5 | ❌ Not supported | **Yes** | Not yet handled |
| Electrical Energy Tariff | `0x0513` | 1.5 | ❌ Not supported | **Yes** | Not yet handled |
| Electrical Meter | `0x0514` | 1.5 | ❌ Not supported | **Yes** | Not yet handled |
| Water Heater | `0x050F` | 1.4 | ✅ Supported | No | `matter-thermostat` (water-heater device class) |
| Heat Pump | `0x0309` | 1.4 | ✅ Supported | No | `matter-thermostat` (heat-pump device class) |

> **Scope note:** For this implementation stream, the actual additions in `matter-energy` are primarily: `0x050D`, standalone `0x0510`, and `0x0511`–`0x0514`.

---

## 2) Cluster support needed per Electrical Device Type

Legend: **M** = Mandatory, **O** = Optional  
Status terms: ✅ Done, ⚠️ Partial, ❌ Missing

| Device Type | Required / Relevant Clusters | Support Status Today | Action Needed |
|---|---|---|---|
| **Device Energy Management** (`0x050D`) | `DeviceEnergyManagement (0x0098)` **M**, `DeviceEnergyManagementMode (0x009F)` O | DEMMode ✅, full DEM ❌ | Add full `DeviceEnergyManagement` cluster support |
| **Electrical Sensor** (`0x0510`) | `ElectricalPowerMeasurement (0x0090)` **M***, `ElectricalEnergyMeasurement (0x0091)` **M***, `PowerTopology (0x009C)` O | EPM/EEM ✅, PowerTopology ❌ | Add standalone flow + optional `PowerTopology` |
| **Electrical Utility Meter** (`0x0511`) | `MeterIdentification (0x0B06)` **M**, `ElectricalPowerMeasurement (0x0090)` O, `ElectricalEnergyMeasurement (0x0091)` O | ❌ | Add meter identification + optional EPM/EEM mapping |
| **Meter Reference Point** (`0x0512`) | `PowerTopology (0x009C)` **M** | ❌ | Add `PowerTopology` support |
| **Electrical Energy Tariff** (`0x0513`) | `CommodityPrice (0x0095)` **M**, `CommodityTariff (0x0700)` O | ❌ | Add pricing/tariff cluster support |
| **Electrical Meter** (`0x0514`) | `CommodityMetering (0x0B07)` **M**, `MeterIdentification (0x0B06)` O | ❌ | Add commodity metering + optional meter identification |

\* Matter rule for Electrical Sensor requires at least one of EPM/EEM capabilities depending on endpoint composition; current SmartThings implementation already supports EPM/EEM paths in specific co-located scenarios.

---

## 3) SmartThings Capability Mapping to Clusters (Electrical Device Types)

This table includes all clusters used by the electrical device types above and indicates whether SmartThings drivers already cover them.

| Matter Cluster | Cluster ID | Typical SmartThings Capability Mapping | In Scope Device Types | Already taken care in SmartThings? | Which driver / device class currently handles it? | Gap / Needed Work |
|---|---:|---|---|---|---|---|
| ElectricalPowerMeasurement | `0x0090` | `powerMeter.power`, `powerSource.powerSource` | `0x0510`, `0x0511`(O), EVSE/solar/battery co-located | ✅ | `matter-energy` (EVSE/solar/battery), `matter-thermostat` (heat-pump/water-heater combos), `matter-switch` (switch-energy variants) | Add standalone sensor + utility meter path integration |
| ElectricalEnergyMeasurement | `0x0091` | `energyMeter.energy`, `powerConsumptionReport.powerConsumption` | `0x0510`, `0x0511`(O), EVSE/solar/battery co-located | ✅ | `matter-energy`, `matter-thermostat`, `matter-switch` | Add standalone sensor + utility meter path integration |
| DeviceEnergyManagementMode | `0x009F` | `mode.mode` | `0x050D` (optional), EVSE companion | ✅ | `matter-energy` | Keep as-is |
| DeviceEnergyManagement | `0x0098` | custom `deviceEnergyManagement` capability (ESA state/type/forecast/opt-out) | `0x050D` | ❌ (full cluster) | Not fully handled in current drivers | Implement full DEM cluster handling |
| PowerTopology | `0x009C` | Internal topology mapping (and optional custom exposure if needed) | `0x0510`(O), `0x0512`(M), co-located patterns | ⚠️ Partial | Present in some drivers (e.g., `matter-switch` embedded usage), not implemented for `matter-energy` electrical roadmap | Implement in `matter-energy` for reference-point and sensor-topology scenarios |
| MeterIdentification | `0x0B06` | custom `meterIdentification` capability (`meterType`, `pointOfDelivery`) | `0x0511`(M), `0x0514`(O) | ❌ | Not handled today | Add embedded cluster + capability mapping |
| CommodityMetering | `0x0B07` | `energyMeter.energy`, `powerMeter.power` | `0x0514`(M) | ❌ | Not handled today | Add cluster handlers and profile support |
| CommodityPrice | `0x0095` | custom `energyPrice.currentPrice` | `0x0513`(M) | ❌ | Not handled today | Add pricing handler + capability |
| CommodityTariff | `0x0700` | custom `energyTariff.currentTariff` | `0x0513`(O) | ❌ | Not handled today | Add tariff handler + capability |
| EnergyEvse | `0x0099` | `evseState`, `evseChargingSession` | `0x050C` | ✅ | `matter-energy` EVSE class | No new work for this cluster |
| EnergyEvseMode | `0x009D` | `mode.mode` | `0x050C` | ✅ | `matter-energy` EVSE class | No new work for this cluster |
| WaterHeaterMode | `0x009E` | `mode.mode` | `0x050F` | ✅ | `matter-thermostat` water-heater class | Out of `matter-energy` scope |
| Thermostat | `0x0201` | `thermostatMode`, `thermostatHeatingSetpoint`, `temperatureMeasurement` | `0x0309`, optional `0x050F` | ✅ | `matter-thermostat` heat-pump/water-heater classes | Out of `matter-energy` scope |

---

## Practical takeaway (short)

For Matter 1.5 electrical device expansion in `matter-energy`, the main missing cluster work is:

1. `DeviceEnergyManagement (0x0098)`
2. `PowerTopology (0x009C)` (for electrical reference/sensor topology paths)
3. `MeterIdentification (0x0B06)`
4. `CommodityMetering (0x0B07)`
5. `CommodityPrice (0x0095)`
6. `CommodityTariff (0x0700)`

Existing EPM/EEM/EVSE foundations are already reusable.

## 4) Key Attributes Coverage & SmartThings Handling

The following table evaluates the key attributes for the core Matter 1.5 electrical clusters and highlights if they are actively evaluated/handled in the `matter-energy` SmartThings driver base.

| Cluster | Key Attribute | M/O | SmartThings Driver Handling (`matter-energy`) | Capability Mapping & Implementation Notes |
|---|---|:---:|---|---|
| **ElectricalPowerMeasurement (`0x0090`)** | `ActivePower` | M | ✅ Yes | Maps to `powerMeter.power`. Extensively used. |
| | `ActivePowerMeasurementRange` | O | ⚠️ Partial | Internal bounds / profile evaluation. |
| | `Voltage` | O | ✅ Yes | Maps to `voltageMeasurement.voltage`. |
| | `ActiveCurrent` | O | ⚠️ Partial | Can map to custom capabilities if present. |
| **ElectricalEnergyMeasurement (`0x0091`)** | `CumulativeEnergyImported` | M | ✅ Yes | Maps to `energyMeter.energy` via periodic polling/reports. |
| | `CumulativeEnergyExported` | O | ⚠️ Partial | Can be mapped if solar/generation is configured. |
| | `PeriodicEnergyImported` | O | ✅ Yes | Maps to `powerConsumptionReport.powerConsumption`. |
| | `PeriodicEnergyExported` | O | ❌ No | Generative reporting not yet fully bridged. |
| **DeviceEnergyManagement (`0x0098`)** | `ESAType` | M | ❌ No | Will require a custom `deviceEnergyManagement` capability. |
| | `ESAAcceptedCommandList` | M | ❌ No | Needed to expose which DEM modes are active. |
| | `ESAState` | M | ❌ No | Needs binding to custom capabilities for "Online/Offline/Optimizing". |
| | `PowerForecastReporting` | O | ❌ No | Required for solar/EVSE advanced prediction. |
| | `OptOutState` | O | ❌ No | Local user override detection. |
| **PowerTopology (`0x009C`)** | `AvailableEndpoints` | M | ❌ No | Structural mapping only; needs driver internal topology mapper. |
| | `ActiveEndpoints` | M | ❌ No | For nested `MeterReferencePoint` topologies. |
| **MeterIdentification (`0x0B06`)** | `MeterType` | M | ❌ No | Standard ST capabilities lack this; requires `meterIdentification`. |
| | `UtilityName` | O | ❌ No | Typically exposed as a custom string attribute. |
| | `PointOfDelivery` | O | ❌ No | Specific to v1.5 Utility/Energy Provider use cases. |
| **CommodityMetering (`0x0B07`)** | `MeteringDeviceType` | M | ❌ No | Needs ST integration for utility metering contexts. |
| | `TotalConsumedVolume` | M | ❌ No | Needs ST integration, potentially mapped to standard `energyMeter` if electrical. |
| **EnergyEvse (`0x0099`)** | `State` | M | ✅ Yes | Mapped to EVSE State capabilities. |
| | `ChargingEnabledUntil` | O | ✅ Yes | Tracked in EVSE session. |
| | `SessionDuration` | M | ✅ Yes | Exposed to `evseChargingSession`. |

---
