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

## Verified Linux/WSL Setup (April 2026)

The following setup/build path has been validated on Linux for
`origin/virtual-Eclectrical-device`:

1. Install required host tools:

```bash
sudo apt-get update
sudo apt-get install -y cmake libdbus-1-dev libavahi-client-dev ninja-build \
  libgirepository1.0-dev libcairo2-dev libreadline-dev libevent-dev default-jre
```

2. Use Python 3.11+ (`python3 --version` must report 3.11 or newer).

If your default `python3` is older, prepend a 3.11 shim path before activation:

```bash
export PATH=/home/$USER/.local/py311-shim:$PATH
```

3. Check out required submodules:

```bash
git submodule update --init --depth 1 \
	third_party/pigweed/repo \
	third_party/openthread/repo \
	third_party/editline/repo

python3 scripts/checkout_submodules.py --shallow --platform linux
```

4. Bootstrap and activate:

```bash
source scripts/bootstrap.sh -p linux
source scripts/activate.sh -p linux
```

5. Build the simulator:

```bash
./scripts/build/build_examples.py --target linux-x64-phase2-energy-simulator build
```

6. Optional but recommended: run one clean build from scratch:

```bash
rm -rf out/linux-x64-phase2-energy-simulator
./scripts/build/build_examples.py --target linux-x64-phase2-energy-simulator build
```

Expected binary:

```bash
./out/linux-x64-phase2-energy-simulator/chip-phase2-energy-simulator-app
```

Notes:

- `source/activate.sh` is not a valid path in `connectedhomeip`.
- The Phase 2 flow requires `phase2-energy-simulator.matter` next to
	`phase2-energy-simulator.zap` in `examples/evse-app/evse-common`.

## Current Scope

The Phase 2 host simulator now:

- Initializes standalone Electrical Sensor behavior on endpoint 1
- Initializes standalone DEM behavior on endpoint 2
- Initializes Electrical Meter + Commodity Metering on endpoint 3
- Allows Meter Identification to bind on the Utility Meter endpoint instead of assuming endpoint 1
- Implements timer-driven telemetry (10s intervals) for dynamic voltage, current, and active power reporting, along with continuous energy accumulation.

## Validation Status

- **Linux/WSL Build Execution**: Verified with a clean rebuild on 2026-04-15 for `linux-x64-phase2-energy-simulator`.

## Remaining Work

- Electrical Utility Meter (`0x0511`) driver fingerprint/profile is not yet implemented (Meter Identification has no standard SmartThings capability mapping).
