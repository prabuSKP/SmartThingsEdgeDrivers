# Matter 1.5 Electrical Device Types — Full Mapping Table

> **Related document:** [ELECTRICAL_DEVICE_TYPES_MATTER_1_5_SUMMARY.md](./ELECTRICAL_DEVICE_TYPES_MATTER_1_5_SUMMARY.md) (high-level summary)
>
> **This document:** Detailed attribute-level cross-reference of all 11 Matter Electrical Device Types → Clusters → Attributes → SmartThings Capabilities, with capability availability and Edge Driver implementation status.
>
> **Last Updated:** April 12, 2026

---

## Column Definitions

| Column | Meaning |
|---|---|
| **Matter Cluster** | The Matter spec cluster required/optional for the device type |
| **M/O** | **M** = Mandatory, **O** = Optional (per Matter spec) |
| **Matter Attribute** | The specific attribute within the cluster |
| **Attr ID** | The Matter attribute ID (hex) |
| **SmartThings Capability** | The SmartThings capability this attribute should map to |
| **ST Cap Defined?** | ✅ = Capability exists in SmartThings platform (Production or Proposed). ❌ = Does NOT exist, would need a Custom Capability |
| **Cap Type** | 🟢 Production / 🟡 Proposed / 🔴 Custom Needed |
| **Edge Driver Implemented?** | ✅ = Handler already exists in an Edge Driver in this repo. ❌ = No handler exists yet |
| **Which Edge Driver?** | The specific driver that has the handler (e.g., `matter-energy`, `matter-thermostat`, `zigbee-power-meter`) |

---

## SmartThings Capability Reference — All Capabilities Relevant to Electrical Device Types

> This table answers: **Does the SmartThings platform have this capability defined?**

| SmartThings Capability ID | ST Cap Defined? | Cap Type | Key Attributes | Key Commands |
|---|---|---|---|---|
| `powerMeter` | ✅ Yes | 🟢 Production | `power` (W) | — |
| `energyMeter` | ✅ Yes | 🟢 Production | `energy` (Wh) | `resetEnergyMeter` |
| `powerConsumptionReport` | ✅ Yes | 🟢 Production | `powerConsumption` (object: start, end, deltaEnergy, energy) | — |
| `powerSource` | ✅ Yes | 🟢 Production | `powerSource` (enum: battery, dc, mains, unknown) | — |
| `voltageMeasurement` | ✅ Yes | 🟢 Production | `voltage` (V) | — |
| `currentMeasurement` | ✅ Yes | 🟢 Production | `current` (A) | — |
| `temperatureMeasurement` | ✅ Yes | 🟢 Production | `temperature` (°C/°F) | — |
| `thermostatMode` | ✅ Yes | 🟢 Production | `thermostatMode` (enum) | `setThermostatMode` |
| `thermostatHeatingSetpoint` | ✅ Yes | 🟢 Production | `heatingSetpoint` (°C/°F) | `setHeatingSetpoint` |
| `thermostatCoolingSetpoint` | ✅ Yes | 🟢 Production | `coolingSetpoint` (°C/°F) | `setCoolingSetpoint` |
| `mode` | ✅ Yes | 🟢 Production | `mode`, `supportedModes`, `supportedArguments` | `setMode` |
| `battery` | ✅ Yes | 🟢 Production | `battery` (%) | — |
| `chargingState` | ✅ Yes | 🟡 Proposed | `chargingState` (enum: charging, stopped, fullyCharged, error) | — |
| `evseState` | ✅ Yes | 🟡 Proposed | `state`, `supplyState`, `faultState` | — |
| `evseChargingSession` | ✅ Yes | 🟡 Proposed | `chargingState`, `energyDelivered`, `sessionTime`, `minCurrent`, `maxCurrent`, `targetEndTime` | `enableCharging`, `disableCharging`, `setMinCurrent`, `setMaxCurrent`, `setTargetEndTime` |
| `firmwareUpdate` | ✅ Yes | 🟢 Production | `availableVersion`, `currentVersion` | — |
| `refresh` | ✅ Yes | 🟢 Production | — | `refresh` |
| ~~`deviceEnergyManagement`~~ | ❌ No | 🔴 Custom Needed | *(would need: esaState, esaType, optOutState, forecast)* | — |
| ~~`meterIdentification`~~ | ❌ No | 🔴 Custom Needed | *(would need: meterType, pointOfDelivery, utilityName)* | — |
| ~~`energyPrice`~~ | ❌ No | 🔴 Custom Needed | *(would need: currentPrice, currency, priceForecast)* | — |
| ~~`energyTariff`~~ | ❌ No | 🔴 Custom Needed | *(would need: currentTariff, tariffSchedules)* | — |
| ~~`waterHeaterOperationalState`~~ | ❌ No | 🔴 Custom Needed | *(would need: boostState, tankPercentage, heatDemand)* | — |
| ~~`frequencyMeasurement`~~ | ❌ No | 🔴 Custom Needed | *(would need: frequency in Hz)* | — |
| ~~`powerFactorMeasurement`~~ | ❌ No | 🔴 Custom Needed | *(would need: powerFactor)* | — |

---

## Device Type 1: Solar Power (0x0017) — ✅ DONE

| | |
|---|---|
| **Matter Device Type ID** | `0x0017` (23) |
| **Matter Spec Since** | 1.4 |

| Matter Cluster | M/O | Matter Attribute | Attr ID | SmartThings Capability | ST Cap Defined? | Cap Type | Edge Driver Implemented? | Which Edge Driver? |
|---|---|---|---|---|---|---|---|---|
| ElectricalPowerMeasurement (`0x0090`) | **M** | `PowerMode` | `0x0000` | `powerSource` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `ActivePower` | `0x0008` | `powerMeter` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `Voltage` | `0x0004` | `voltageMeasurement` | ✅ Yes | 🟢 Production | ❌ No | — |
| | | `ActiveCurrent` | `0x0005` | `currentMeasurement` | ✅ Yes | 🟢 Production | ❌ No | — |
| | | `Frequency` | `0x0007` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `PowerFactor` | `0x000C` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| ElectricalEnergyMeasurement (`0x0091`) | **M** | `CumulativeEnergyImported` | `0x0001` | `energyMeter` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `CumulativeEnergyExported` | `0x0002` | `energyMeter` (export component) | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `PeriodicEnergyImported` | `0x0003` | `powerConsumptionReport` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `PeriodicEnergyExported` | `0x0004` | `powerConsumptionReport` (export) | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| PowerTopology (`0x009C`) | O | `AvailableEndpoints` | `0x0000` | *(internal — no user-facing cap)* | ❌ No | 🔴 Internal | ❌ No | — |
| | | `ActiveEndpoints` | `0x0001` | *(internal — no user-facing cap)* | ❌ No | 🔴 Internal | ❌ No | — |

---

## Device Type 2: Battery Storage (0x0018) — ✅ DONE

| | |
|---|---|
| **Matter Device Type ID** | `0x0018` (24) |
| **Matter Spec Since** | 1.4 |

| Matter Cluster | M/O | Matter Attribute | Attr ID | SmartThings Capability | ST Cap Defined? | Cap Type | Edge Driver Implemented? | Which Edge Driver? |
|---|---|---|---|---|---|---|---|---|
| PowerSource (`0x002F`) | **M** | `BatPercentRemaining` | `0x000C` | `battery` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `BatChargeState` | `0x001A` | `chargingState` | ✅ Yes | 🟡 Proposed | ✅ Yes | `matter-energy` |
| ElectricalPowerMeasurement (`0x0090`) | **M** | `PowerMode` | `0x0000` | `powerSource` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `ActivePower` | `0x0008` | `powerMeter` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `Voltage` | `0x0004` | `voltageMeasurement` | ✅ Yes | 🟢 Production | ❌ No | — |
| | | `ActiveCurrent` | `0x0005` | `currentMeasurement` | ✅ Yes | 🟢 Production | ❌ No | — |
| ElectricalEnergyMeasurement (`0x0091`) | **M** | `CumulativeEnergyImported` | `0x0001` | `energyMeter` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `CumulativeEnergyExported` | `0x0002` | `energyMeter` (export) | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `PeriodicEnergyImported` | `0x0003` | `powerConsumptionReport` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `PeriodicEnergyExported` | `0x0004` | `powerConsumptionReport` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| PowerTopology (`0x009C`) | O | `AvailableEndpoints` | `0x0000` | *(internal)* | ❌ No | 🔴 Internal | ❌ No | — |

---

## Device Type 3: Energy EVSE (0x050C) — ✅ DONE

| | |
|---|---|
| **Matter Device Type ID** | `0x050C` (1292) |
| **Matter Spec Since** | 1.3 |

| Matter Cluster | M/O | Matter Attribute | Attr ID | SmartThings Capability | ST Cap Defined? | Cap Type | Edge Driver Implemented? | Which Edge Driver? |
|---|---|---|---|---|---|---|---|---|
| EnergyEvse (`0x0099`) | **M** | `State` | `0x0000` | `evseState.state` | ✅ Yes | 🟡 Proposed | ✅ Yes | `matter-energy` |
| | | `SupplyState` | `0x0001` | `evseState.supplyState` | ✅ Yes | 🟡 Proposed | ✅ Yes | `matter-energy` |
| | | `FaultState` | `0x0002` | `evseState.faultState` | ✅ Yes | 🟡 Proposed | ✅ Yes | `matter-energy` |
| | | `ChargingEnabledUntil` | `0x0003` | `evseChargingSession.targetEndTime` | ✅ Yes | 🟡 Proposed | ✅ Yes | `matter-energy` |
| | | `MinimumChargeCurrent` | `0x0006` | `evseChargingSession.minCurrent` | ✅ Yes | 🟡 Proposed | ✅ Yes | `matter-energy` |
| | | `MaximumChargeCurrent` | `0x0007` | `evseChargingSession.maxCurrent` | ✅ Yes | 🟡 Proposed | ✅ Yes | `matter-energy` |
| | | `SessionDuration` | `0x0040` | `evseChargingSession.sessionTime` | ✅ Yes | 🟡 Proposed | ✅ Yes | `matter-energy` |
| | | `SessionEnergyCharged` | `0x0041` | `evseChargingSession.energyDelivered` | ✅ Yes | 🟡 Proposed | ✅ Yes | `matter-energy` |
| EnergyEvseMode (`0x009D`) | **M** | `SupportedModes` | `0x0000` | `mode.supportedModes` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `CurrentMode` | `0x0001` | `mode.mode` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |

> Co-located with: Electrical Sensor (0x0510) mandatory, DEM (0x050D) optional

---

## Device Type 4: Water Heater (0x050F) — ✅ DONE (in `matter-thermostat`)

| | |
|---|---|
| **Matter Device Type ID** | `0x050F` (1295) |
| **Matter Spec Since** | 1.4 |

| Matter Cluster | M/O | Matter Attribute | Attr ID | SmartThings Capability | ST Cap Defined? | Cap Type | Edge Driver Implemented? | Which Edge Driver? |
|---|---|---|---|---|---|---|---|---|
| Thermostat (`0x0201`) | **M** | `LocalTemperature` | `0x0000` | `temperatureMeasurement` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |
| | | `OccupiedHeatingSetpoint` | `0x0012` | `thermostatHeatingSetpoint` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |
| | | `SystemMode` | `0x001C` | `thermostatMode` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |
| WaterHeaterMode (`0x009E`) | **M** | `SupportedModes` | `0x0000` | `mode.supportedModes` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |
| | | `CurrentMode` | `0x0001` | `mode.mode` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |
| WaterHeaterManagement (`0x0094`) | O | `HeaterTypes` | `0x0000` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `HeatDemand` | `0x0001` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `TankVolume` | `0x0002` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `TankPercentage` | `0x000D` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `BoostState` | `0x0005` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |

---

## Device Type 5: Heat Pump (0x0309) — ✅ DONE (in `matter-thermostat`)

| | |
|---|---|
| **Matter Device Type ID** | `0x0309` (777) |
| **Matter Spec Since** | 1.4 |

| Matter Cluster | M/O | Matter Attribute | Attr ID | SmartThings Capability | ST Cap Defined? | Cap Type | Edge Driver Implemented? | Which Edge Driver? |
|---|---|---|---|---|---|---|---|---|
| Thermostat (`0x0201`) | **M** | `LocalTemperature` | `0x0000` | `temperatureMeasurement` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |
| | | `OccupiedHeatingSetpoint` | `0x0012` | `thermostatHeatingSetpoint` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |
| | | `OccupiedCoolingSetpoint` | `0x0011` | `thermostatCoolingSetpoint` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |
| | | `SystemMode` | `0x001C` | `thermostatMode` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |
| ElectricalPowerMeasurement (`0x0090`) | O | `ActivePower` | `0x0008` | `powerMeter` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |
| ElectricalEnergyMeasurement (`0x0091`) | O | `CumulativeEnergyImported` | `0x0001` | `energyMeter` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |
| | | `PeriodicEnergyImported` | `0x0003` | `powerConsumptionReport` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-thermostat` |

---

## Device Type 6: Device Energy Management (0x050D) — ⚠️ PARTIAL

| | |
|---|---|
| **Matter Device Type ID** | `0x050D` (1293) |
| **Matter Spec Since** | 1.3 |

| Matter Cluster | M/O | Matter Attribute | Attr ID | SmartThings Capability | ST Cap Defined? | Cap Type | Edge Driver Implemented? | Which Edge Driver? |
|---|---|---|---|---|---|---|---|---|
| DeviceEnergyManagement (`0x0098`) | **M** | `ESAType` | `0x0000` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `ESACanGenerate` | `0x0001` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `ESAState` | `0x0002` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `AbsMinPower` | `0x0003` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `AbsMaxPower` | `0x0004` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `PowerAdjustmentCapability` | `0x0005` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `Forecast` | `0x0006` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `OptOutState` | `0x0007` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| DeviceEnergyManagementMode (`0x009F`) | O | `SupportedModes` | `0x0000` | `mode.supportedModes` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `CurrentMode` | `0x0001` | `mode.mode` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |

---

## Device Type 7: Electrical Sensor (0x0510) — ⚠️ PARTIAL

| | |
|---|---|
| **Matter Device Type ID** | `0x0510` (1296) |
| **Matter Spec Since** | 1.3 |

> Matter spec requires at least one of ElectricalPowerMeasurement or ElectricalEnergyMeasurement.

| Matter Cluster | M/O | Matter Attribute | Attr ID | SmartThings Capability | ST Cap Defined? | Cap Type | Edge Driver Implemented? | Which Edge Driver? |
|---|---|---|---|---|---|---|---|---|
| ElectricalPowerMeasurement (`0x0090`) | **M*** | `PowerMode` | `0x0000` | `powerSource` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `ActivePower` | `0x0008` | `powerMeter` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `Voltage` | `0x0004` | `voltageMeasurement` | ✅ Yes | 🟢 Production | ❌ No | — |
| | | `ActiveCurrent` | `0x0005` | `currentMeasurement` | ✅ Yes | 🟢 Production | ❌ No | — |
| | | `Frequency` | `0x0007` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `PowerFactor` | `0x000C` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `ApparentPower` | `0x000E` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `ReactivePower` | `0x000F` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| ElectricalEnergyMeasurement (`0x0091`) | **M*** | `CumulativeEnergyImported` | `0x0001` | `energyMeter` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `CumulativeEnergyExported` | `0x0002` | `energyMeter` (export) | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `PeriodicEnergyImported` | `0x0003` | `powerConsumptionReport` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `PeriodicEnergyExported` | `0x0004` | `powerConsumptionReport` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| PowerTopology (`0x009C`) | O | `AvailableEndpoints` | `0x0000` | *(internal — no user-facing cap)* | ❌ No | 🔴 Internal | ❌ No | — |
| | | `ActiveEndpoints` | `0x0001` | *(internal — no user-facing cap)* | ❌ No | 🔴 Internal | ❌ No | — |

> \*At least one of EPM or EEM is mandatory per Matter spec.

---

## Device Type 8: Electrical Utility Meter (0x0511) — ❌ NOT SUPPORTED (New in 1.5)

| | |
|---|---|
| **Matter Device Type ID** | `0x0511` (1297) |
| **Matter Spec Since** | **1.5** |

| Matter Cluster | M/O | Matter Attribute | Attr ID | SmartThings Capability | ST Cap Defined? | Cap Type | Edge Driver Implemented? | Which Edge Driver? |
|---|---|---|---|---|---|---|---|---|
| MeterIdentification (`0x0B06`) | **M** | `MeterType` | `0x0000` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `UtilityName` | `0x0001` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `MeterSerialNumber` | `0x0007` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `PointOfDelivery` | `0x000D` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| ElectricalPowerMeasurement (`0x0090`) | O | `ActivePower` | `0x0008` | `powerMeter` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `Voltage` | `0x0004` | `voltageMeasurement` | ✅ Yes | 🟢 Production | ❌ No | — |
| | | `ActiveCurrent` | `0x0005` | `currentMeasurement` | ✅ Yes | 🟢 Production | ❌ No | — |
| ElectricalEnergyMeasurement (`0x0091`) | O | `CumulativeEnergyImported` | `0x0001` | `energyMeter` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |
| | | `PeriodicEnergyImported` | `0x0003` | `powerConsumptionReport` | ✅ Yes | 🟢 Production | ✅ Yes | `matter-energy` |

---

## Device Type 9: Meter Reference Point (0x0512) — ❌ NOT SUPPORTED (New in 1.5)

| | |
|---|---|
| **Matter Device Type ID** | `0x0512` (1298) |
| **Matter Spec Since** | **1.5** |

| Matter Cluster | M/O | Matter Attribute | Attr ID | SmartThings Capability | ST Cap Defined? | Cap Type | Edge Driver Implemented? | Which Edge Driver? |
|---|---|---|---|---|---|---|---|---|
| PowerTopology (`0x009C`) | **M** | `AvailableEndpoints` | `0x0000` | *(internal — no user-facing cap)* | ❌ No | 🔴 Internal | ❌ No | — |
| | | `ActiveEndpoints` | `0x0001` | *(internal — no user-facing cap)* | ❌ No | 🔴 Internal | ❌ No | — |

---

## Device Type 10: Electrical Energy Tariff (0x0513) — ❌ NOT SUPPORTED (New in 1.5)

| | |
|---|---|
| **Matter Device Type ID** | `0x0513` (1299) |
| **Matter Spec Since** | **1.5** |

| Matter Cluster | M/O | Matter Attribute | Attr ID | SmartThings Capability | ST Cap Defined? | Cap Type | Edge Driver Implemented? | Which Edge Driver? |
|---|---|---|---|---|---|---|---|---|
| CommodityPrice (`0x0095`) | **M** | `CurrentPrice` | `0x0000` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `PriceForecast` | `0x0001` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `Currency` | `0x0002` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| CommodityTariff (`0x0700`) | O | `TariffSchedules` | `0x0000` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `CurrentTariff` | `0x0001` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `ActiveTariffIndex` | `0x0002` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |

---

## Device Type 11: Electrical Meter (0x0514) — ❌ NOT SUPPORTED (New in 1.5)

| | |
|---|---|
| **Matter Device Type ID** | `0x0514` (1300) |
| **Matter Spec Since** | **1.5** |

| Matter Cluster | M/O | Matter Attribute | Attr ID | SmartThings Capability | ST Cap Defined? | Cap Type | Edge Driver Implemented? | Which Edge Driver? |
|---|---|---|---|---|---|---|---|---|
| CommodityMetering (`0x0B07`) | **M** | `CumulativeEnergy` | `0x0000` | `energyMeter` | ✅ Yes | 🟢 Production | ❌ No | — |
| | | `InstantaneousDemand` | `0x0001` | `powerMeter` | ✅ Yes | 🟢 Production | ❌ No | — |
| | | `MeteringDeviceType` | `0x0002` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| MeterIdentification (`0x0B06`) | O | `MeterType` | `0x0000` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |
| | | `PointOfDelivery` | `0x000D` | *(no ST capability)* | ❌ No | 🔴 Custom Needed | ❌ No | — |

---

## MVP Decision Matrix — Summary View

> This table rolls up all 11 device types. Read it top-to-bottom to pick your MVP scope.

| # | Device Type | ID | Status | Mandatory Attrs with ST Cap ✅ | Mandatory Attrs needing Custom ❌ | % Covered by Existing ST Caps | Edge Driver Handler Coverage | **MVP Verdict** |
|---|---|---|---|---|---|---|---|---|
| 1 | Solar Power | `0x0017` | ✅ Done | 6/6 core | 0 | 100% | 4/6 (Voltage/Current not mapped) | ✅ SHIPPED |
| 2 | Battery Storage | `0x0018` | ✅ Done | 6/6 core | 0 | 100% | 6/6 | ✅ SHIPPED |
| 3 | Energy EVSE | `0x050C` | ✅ Done | 10/10 | 0 | 100% | 10/10 | ✅ SHIPPED |
| 4 | Water Heater | `0x050F` | ✅ Done | 5/5 core | 5 (WHM optional cluster) | 100% core | 5/5 core | ✅ SHIPPED (matter-thermostat) |
| 5 | Heat Pump | `0x0309` | ✅ Done | 7/7 | 0 | 100% | 7/7 | ✅ SHIPPED (matter-thermostat) |
| **6** | **Electrical Sensor** | **`0x0510`** | ⚠️ Partial | **6/6 core** | **0** | **100%** | **4/6** (Voltage/Current missing) | **🟢 MVP TIER 1** |
| **7** | **DEM (mode-only)** | **`0x050D`** | ⚠️ Partial | **2/2** (mode) | **8** (full DEM cluster) | **100% for mode** | **2/2** (mode handlers exist) | **🟢 MVP TIER 1** |
| **8** | **Electrical Meter** | **`0x0514`** | ❌ None | **2/3** | **1** (MeteringDeviceType) | **67%** | **0/3** | **🟡 MVP TIER 2** |
| **9** | **Utility Meter** | **`0x0511`** | ❌ None | **0/4** mandatory + **3/3** optional | **4** (MeterIdentification) | **0% mandatory, 100% optional** | **3/7** (EPM/EEM reused) | **🟡 MVP TIER 2** |
| **10** | **Meter Ref Point** | **`0x0512`** | ❌ None | **0/2** | **2** (internal) | **0%** | **0/2** | **🟡 MVP TIER 2** |
| **11** | **Energy Tariff** | **`0x0513`** | ❌ None | **0/6** | **6** | **0%** | **0/6** | **🔴 DEFERRED** |

### How to read the MVP Verdict:

- **🟢 MVP TIER 1** = All mandatory attributes map to **existing** SmartThings capabilities (`ST Cap Defined?` = ✅). Only needs new fingerprint + profile + minor handler additions in Edge Driver. **Start here.**
- **🟡 MVP TIER 2** = Some mandatory attributes map to existing caps, but others have **no ST capability** (`ST Cap Defined?` = ❌). Needs new embedded cluster definitions + possibly custom capability definitions.
- **🔴 DEFERRED** = Zero mandatory attributes have existing ST capabilities. Every attribute needs a custom capability definition. **Do last.**

---

*Document Version: 1.0*
*Last Updated: April 12, 2026*
*Related: [ELECTRICAL_DEVICE_TYPES_MATTER_1_5_SUMMARY.md](./ELECTRICAL_DEVICE_TYPES_MATTER_1_5_SUMMARY.md) | [DESIGN_PLAN_ELECTRICAL_DEVICE_CLASS_v2.md](./DESIGN_PLAN_ELECTRICAL_DEVICE_CLASS_v2.md)*
