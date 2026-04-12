# Phase 2 ConnectedHomeIP Notes

## Current Branch Reality

The checkout at [connectedhomeip](C:\Prabu\Application\SmartThingsEdgeDrivers\connectedhomeip) does **not** contain the older `examples/energy-management-app` path referenced in [VIRTUAL_DEVICE_TESTING_PLAN.md](C:\Prabu\Application\SmartThingsEdgeDrivers\docs\VIRTUAL_DEVICE_TESTING_PLAN.md).

Relevant apps in this branch are:

- Linux-capable EVSE energy app: [examples/evse-app](C:\Prabu\Application\SmartThingsEdgeDrivers\connectedhomeip\examples\evse-app)
- Linux-capable gateway/meter app: [examples/energy-gateway-app](C:\Prabu\Application\SmartThingsEdgeDrivers\connectedhomeip\examples\energy-gateway-app)
- Android-only virtual device app: [examples/virtual-device-app](C:\Prabu\Application\SmartThingsEdgeDrivers\connectedhomeip\examples\virtual-device-app)

For Phase 2 on Linux/WSL, `virtual-device-app` is not the runtime target in this branch.

## Generated Phase 2 ZAP

Use the generator script:

- [tools/generate_phase2_energy_zap.py](C:\Prabu\Application\SmartThingsEdgeDrivers\tools\generate_phase2_energy_zap.py)

It writes the composed Phase 2 simulator topology here by default:

- [phase2-energy-simulator.zap](C:\Prabu\Application\SmartThingsEdgeDrivers\connectedhomeip\examples\evse-app\evse-common\phase2-energy-simulator.zap)

The generated `.zap` defines:

- Endpoint 0: Root Node
- Endpoint 1: Electrical Sensor (`0x0510`)
- Endpoint 2: Device Energy Management (`0x050D`)
- Endpoint 3: Electrical Meter (`0x0514`)
- Endpoint 4: Electrical Utility Meter (`0x0511`)

## Linux Runtime Target

This workspace now has a dedicated Linux simulator target wired to the generated
Phase 2 `.zap`:

```bash
./scripts/build/build_examples.py --target linux-x64-phase2-energy-simulator build
```

It produces:

```bash
./out/linux-x64-phase2-energy-simulator/chip-phase2-energy-simulator-app
```

The runtime is implemented in:

- [Phase2EnergySimulatorMain.cpp](C:\Prabu\Application\SmartThingsEdgeDrivers\connectedhomeip\examples\evse-app\evse-common\src\Phase2EnergySimulatorMain.cpp)
- [phase2_main.cpp](C:\Prabu\Application\SmartThingsEdgeDrivers\connectedhomeip\examples\evse-app\linux\phase2_main.cpp)

## Current Scope

The Phase 2 host simulator now:

- Initializes standalone Electrical Sensor behavior on endpoint 1
- Initializes standalone DEM behavior on endpoint 2
- Initializes Electrical Meter + Commodity Metering on endpoint 3
- Allows Meter Identification to bind on the Utility Meter endpoint instead of assuming endpoint 1
- Seeds static EPM/EEM values so the SmartThings driver can commission, read, and subscribe against all modeled endpoints

## Remaining Work

- The simulator currently seeds fixed readings; it is not yet a timer-driven telemetry simulator.
- Linux/WSL build and commissioning verification still needs to be run in the actual Linux environment.
