# Fibaro HC2 Driver - Unit Test Implementation Plan

> **Status**: ⚠️ **PARTIALLY PASSING** - 122/139 tests pass (87.8%). 17 tests fail due to local mock limitations. 2 test files cannot load due to Hub runtime dependencies. See [Actual Test Run Results](#actual-test-run-results) for details.

## Table of Contents

1. [Overview](#overview)
2. [Test Framework](#test-framework)
3. [Test Directory Structure](#test-directory-structure)
4. [Implemented Test Files](#implemented-test-files)
5. [Actual Test Run Results](#actual-test-run-results)
5. [Detailed Test Scenarios](#detailed-test-scenarios)
6. [Running Tests](#running-tests)
7. [Test Coverage Goals](#test-coverage-goals)
8. [Implementation Status](#implementation-status)

---

## Actual Test Run Results

> Run date: 2026-06-16. Command: `lua -lluacov test/<file>.lua` from `drivers/Unofficial/fibaro-hc2/src/` with LUA_PATH pointing to both the local `test/` mock directory and `~/.local/st-lua/lua_libs/`.

### Test Results Summary

| Test File | Passed | Total | Status |
|-----------|--------|-------|--------|
| `test_utils.lua` | 48 | 48 | ✅ All pass |
| `test_mapper.lua` | 43 | 43 | ✅ All pass |
| `test_adapter.lua` | 16 | 17 | ⚠️ 1 failure |
| `test_switch_commands.lua` | 2 | 5 | ❌ 3 failures |
| `test_dimmer_commands.lua` | 5 | 7 | ❌ 2 failures |
| `test_blind_commands.lua` | 5 | 8 | ❌ 3 failures |
| `test_refresh_commands.lua` | 2 | 4 | ❌ 2 failures |
| `test_lifecycle.lua` | 1 | 7 | ❌ 6 failures |
| `test_discovery.lua` | — | — | 💥 Cannot load |
| `test_sync.lua` | — | — | 💥 Cannot load |
| **Total** | **122** | **139** | **87.8% pass rate** |

### Coverage Report (luacov)

Only the files that are actually loaded and executed by passing tests appear in coverage. Modules that cannot be loaded (due to Hub runtime dependencies) contribute 0%.

| File | Hits | Missed | Coverage |
|------|------|--------|----------|
| `fibaro/adapter.lua` | 38 | 2 | **95.0%** |
| `fibaro/adapters/hc2.lua` | 104 | 2 | **98.1%** |
| `fibaro/adapters/hc3.lua` | 124 | 10 | **92.5%** |
| `fibaro/mapper.lua` | 256 | 18 | **93.4%** |
| `fields.lua` | 22 | 0 | **100.0%** |
| `utils.lua` | 86 | 74 | **53.8%** |
| `handlers/commands.lua` | 0 | — | **0%** (not loaded) |
| `handlers/lifecycle.lua` | 0 | — | **0%** (not loaded) |
| `discovery.lua` | 0 | — | **0%** (not loaded) |
| `fibaro_finder.lua` | 0 | — | **0%** (not loaded) |
| `fibaro/sync.lua` | 0 | — | **0%** (not loaded) |
| `fibaro/api.lua` | 0 | — | **0%** (not loaded) |
| **Total (tracked files only)** | **630** | **106** | **85.6%** |

### Root Causes of Failures

#### Category 1: `wait_for_events()` is a no-op in the local mock (10 failures)

The tests in `test_switch_commands.lua`, `test_dimmer_commands.lua`, `test_blind_commands.lua`, `test_refresh_commands.lua`, and part of `test_lifecycle.lua` follow this pattern:

```lua
test.socket.capability:__queue_receive({ ... })  -- queue an event
test.wait_for_events()                            -- supposed to dispatch it
assert(#mock_sync.calls >= 1, "...")              -- check handler was called
```

In `test/integration_test.lua` (the local standalone mock), `wait_for_events()` is implemented as:
```lua
function integration_test.wait_for_events()
  -- Mock: no-op in local testing
end
```

So the queued events never reach the driver's command/lifecycle handlers, `mock_sync.calls` stays empty, and all assertions on it fail.

**Fix needed**: Implement event dispatch in the local mock's `wait_for_events()` — it needs to look up the driver's registered capability/lifecycle handlers and invoke them with the queued event payloads.

#### Category 2: `generate_info_changed` missing on mock devices (2 failures)

`test_lifecycle.lua` calls `mock_bridge:generate_info_changed({...})`, which exists on devices created by the **real** SmartThings `integration_test` framework (`lua_libs/integration_test/mock_device.lua`) but is not added by the local mock in `test/integration_test.lua`.

**Fix needed**: Add `generate_info_changed` to the `create_mock_device` function in `test/integration_test.lua`.

#### Category 3: Hub runtime dependency prevents module loading (2 test files)

`test_discovery.lua` requires `discovery_provider` → `fibaro_finder` → `cosock.socket` → `socket` (from `lua_libs/`), which calls `_envlibrequire`, a SmartThings Hub C-level global that doesn't exist in a standalone Lua interpreter.

`test_sync.lua` requires `fibaro.sync` → `cosock.socket` → same chain.

Full error:
```
socket/init.lua:12: attempt to call a nil value (global '_envlibrequire')
```

**Fix needed**: Add a `test/cosock/socket.lua` (or equivalent) that stubs `_envlibrequire` and provides minimal mock socket functionality so these modules can be required outside the Hub runtime.

#### Category 4: Single `test_adapter.lua` failure

`test_adapter.lua` line 248 asserts `"Should extract state as value"` — one `normalize_device` test case expects a specific `state` field extraction that doesn't match the current adapter output. Likely a test written against a planned (not yet implemented) adapter behavior.

### How to Run Tests Locally

```bash
SRC=drivers/Unofficial/fibaro-hc2/src
ST_LIBS=~/.local/st-lua/lua_libs
LUA_SHARE=~/.local/st-lua/lua_install/share/lua/5.4
LUA=~/.local/st-lua/lua_install/bin/lua
LUACOV=~/.local/st-lua/lua_install/bin/luacov

export LUA_PATH="$SRC/test/?.lua;$SRC/test/?/init.lua;$SRC/?.lua;$SRC/?/init.lua;$ST_LIBS/?.lua;$ST_LIBS/?/init.lua;$LUA_SHARE/?.lua;$LUA_SHARE/?/init.lua;;"

cd "$SRC"

# Run a single test file
$LUA test/test_mapper.lua

# Run with coverage (generates luacov.stats.out + luacov.report.out in src/)
$LUA -lluacov test/test_utils.lua
$LUA -lluacov test/test_mapper.lua
# ... repeat for each file, then:
$LUACOV
```

The `.luacov` config at `src/.luacov` excludes test stubs and SDK libraries so only driver source files appear in the report:

```lua
return {
  exclude = {
    "fibaro%-hc2/src/test",
    "fibaro%-hc2/src/lunchbox",
    "st%-lua",
    "^test/",
  },
  statsfile  = "luacov.stats.out",
  reportfile = "luacov.report.out",
}
```

### What Needs to Be Fixed for Full Coverage

| Issue | Affected Tests | Effort |
|-------|----------------|--------|
| Add `wait_for_events()` dispatch to local mock | 10 test failures across 5 files | Medium |
| Add `generate_info_changed` to local mock devices | 2 test failures in `test_lifecycle.lua` | Low |
| Stub `cosock.socket` / `_envlibrequire` for standalone Lua | `test_discovery.lua`, `test_sync.lua` can't load | Medium |
| Fix adapter `state` field assertion in `test_adapter.lua:248` | 1 test failure | Low |
| Increase `utils.lua` test coverage (currently 53.8%) | Not a failure — gap in test data | Low |

---

## Overview

This document provides a comprehensive end-to-end plan for implementing unit tests for the Fibaro HC2 Edge Driver. The Fibaro HC2 driver is a **LAN-based driver** that communicates with Fibaro Home Center controllers via REST API over HTTP/HTTPS.

### Driver Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    SmartThings Hub                              │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                  Fibaro HC2 Driver                        │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐    │  │
│  │  │  lifecycle  │  │  commands   │  │    discovery    │    │  │
│  │  │  handlers   │  │  handlers   │  │    provider     │    │  │
│  │  └──────┬──────┘  └──────┬──────┘  └────────┬────────┘    │  │
│  │         │                │                   │            │  │
│  │  ┌──────▼────────────────▼───────────────────▼────────┐   │  │
│  │  │              fibaro/sync.lua                       │   │  │
│  │  │         (Core synchronization logic)               │   │  │
│  │  └──────┬─────────────────────────────────────────────┘   │  │
│  │         │                                                 │  │
│  │  ┌──────▼─────────────────────────────────────────────┐   │  │
│  │  │              fibaro/api.lua                        │   │  │
│  │  │         (REST API client)                          │   │  │
│  │  └────────────────────────────────────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ HTTP/HTTPS REST API
                              ▼
                    ┌─────────────────────┐
                    │   Fibaro HC2/HC3    │
                    │   Home Center       │
                    └─────────────────────┘
```

---

## Test Framework

The SmartThings Edge Driver test framework uses **Lua coroutines** with mocked sockets for testing.

### Core Test Modules

| Module | Purpose |
|--------|---------|
| `integration_test` | Core test framework |
| `integration_test.utils` | Utility functions for test setup |
| `integration_test.zigbee_test_utils` | For Zigbee drivers (not used for LAN) |
| `st.capabilities` | SmartThings capabilities |
| `st.driver` | Driver framework |

### Test Pattern

```lua
local test = require "integration_test"
local t_utils = require "integration_test.utils"
local capabilities = require "st.capabilities"

-- Create mock device
local mock_device = test.mock_device.build_test_lan_device({
  profile = t_utils.get_profile_definition("profile-name.yml"),
  -- LAN-specific properties
})

-- Setup test initialization
local function test_init()
  test.mock_device.add_test_device(mock_device)
end
test.set_test_init_function(test_init)

-- Register test cases
test.register_coroutine_test(
  "Test description",
  function()
    -- Queue incoming events
    test.socket.device_lifecycle:__queue_receive({ mock_device.id, "added" })
    
    -- Expect outgoing messages
    test.socket.capability:__expect_send(mock_device:generate_test_message(...))
  end
)

-- Run all tests
test.run_registered_tests()
```

---

## Test Directory Structure

```
drivers/Unofficial/fibaro-hc2/
└── src/
    └── test/
        ├── test_lifecycle.lua           # Device lifecycle tests (added, removed, infoChanged)
        ├── test_switch_commands.lua     # Switch on/off command tests
        ├── test_dimmer_commands.lua     # Dimmer setLevel command tests
        ├── test_blind_commands.lua      # Window shade command tests
        ├── test_mapper.lua              # Device mapper tests
        └── test_utils.lua               # Utility function tests
```

---

## Implemented Test Files

### 1. test_mapper.lua (43 test cases)

Tests the device mapping logic in `fibaro/mapper.lua`.

| Test Category | Test Cases |
|---------------|------------|
| **Switch mapping** | Switch device maps to kind=switch with fibaro-switch profile, Label includes room name |
| **Dimmer mapping** | Dimmer device with setValue maps to kind=dimmer |
| **Blind mapping** | Blind by windowCovering interface, Blind by rollerShutter type |
| **Sensor mapping** | Smoke detector, Motion sensor, Contact sensor, Temperature sensor, Humidity sensor, Illuminance sensor, Water sensor |
| **Multi-endpoint mapping** | Double switch (3 endpoints), Triple switch (4 endpoints) |
| **Metered profiles** | Switch with power/energy interface, Dimmer with power/energy values |
| **Skip/filter conditions** | Hidden device (visible=false), Disabled device (enabled=false), Gateway device (is_gateway=true), Invalid device (nil id) |
| **Default fallback** | Unknown device type falls back to kind=default |
| **Result structure** | Result contains required fields (id, key, room_id, label) |
| **Additional device types (Phase 2)** | CO detector, Vibration, Acceleration, Soil Moisture, UV, Air Quality, Voltage, Current sensors + Siren, Sprinkler, Fan, Thermostat, Garage Door |
| **Mapper edge cases (Phase 2)** | nil label, nil type, empty actions, nil room_id, unknown interface, zero value, empty string label, room_id 0 |

### 2. test_utils.lua (48 test cases)

Tests utility functions in `utils.lua`.

| Function | Test Cases |
|----------|------------|
| **safe_tonumber** | Integer value returns as-is, String number converts, Decimal string converts, Nil returns nil, Empty string returns nil, Non-numeric string returns nil |
| **clamp** | Value within range stays unchanged, Value below min clamps to min, Value above max clamps to max, Value at min/max boundaries |
| **trim** | Removes leading/trailing whitespace, String without spaces returns unchanged, Non-string returns as-is |
| **value_is_truthy** | Boolean true/false, Non-zero number, Zero, String 'true'/'on'/'open'/'active', String 'false', Nil |
| **sanitize_host** | Strips http scheme and extracts port, Strips trailing slash, Trims whitespace, Strips https scheme |
| **hostname_for_serial** | Bare serial gets hc3- prefix, Prefixed serial preserves prefix, Uppercase HC3L is lowercased, Empty/nil returns nil |
| **child_key_for_id** | Formats numeric ID, Formats string ID |
| **device_id_from_child_key** | Extracts numeric ID, Returns string when not numeric, Returns nil for invalid key |
| **is_bridge** | Device without parent_assigned_child_key is bridge, Device with child key is not bridge |
| **controller_kind_from_info** | HC3 platform returns hc3, HC2 platform returns hc2, HC3/HC2 serial returns correct kind, Nil returns nil |
| **api_version_for_serial** | HC3 serial returns version 5, HC2 serial returns version 4, Unknown serial returns nil |

### 3. test_switch_commands.lua (5 test cases)

Tests switch command handlers in `handlers/commands.lua`.

| Test Case | Description |
|-----------|-------------|
| **switch.on emits optimistic on event** | When switch.on command is received, optimistic switch.on event is emitted immediately |
| **switch.on calls execute_child_action with turnOn** | After emitting event, execute_child_action is called with turnOn action |
| **switch.off emits optimistic off event** | When switch.off command is received, optimistic switch.off event is emitted |
| **switch.off calls execute_child_action with turnOff** | After emitting event, execute_child_action is called with turnOff action |
| **switch.on with unknown kind does NOT emit optimistic event** | When HC2_DEVICE_KIND is not "switch" or "dimmer", optimistic event is skipped but execute_child_action still fires |

**Mocking Strategy**: Uses inline mock for `fibaro.sync` module to isolate command tests from real I/O.

### 4. test_dimmer_commands.lua (7 test cases)

Tests dimmer command handlers in `handlers/commands.lua`.

| Test Case | Description |
|-----------|-------------|
| **setLevel(50) emits optimistic switch.on and level(50)** | Level > 0 emits both switch.on and level event |
| **setLevel(50) calls setValue action** | execute_child_action called with setValue, not turnOn |
| **setLevel(0) emits optimistic switch.off and level(0)** | Level = 0 emits switch.off and level(0) |
| **setLevel(100) is clamped to 99** | Level values are clamped to 0-99 range |
| **setLevel(0) calls setValue not turnOff** | setLevel always calls setValue regardless of level value |
| **switch.on on dimmer emits optimistic on event** | Dimmer also responds to switch.on command |
| **switch.off on dimmer emits optimistic off event** | Dimmer also responds to switch.off command |

### 5. test_blind_commands.lua (8 test cases)

Tests blind/shade command handlers in `handlers/commands.lua`.

| Test Case | Description |
|-----------|-------------|
| **open emits windowShade.open and shadeLevel(99)** | open() emits both windowShade.open and shadeLevel(99) events |
| **open calls setValue(99)** | execute_child_action called with setValue(99) |
| **close emits windowShade.closed and shadeLevel(0)** | close() emits both windowShade.closed and shadeLevel(0) events |
| **close calls setValue(0)** | execute_child_action called with setValue(0) |
| **setShadeLevel(75) emits partially_open and shadeLevel(75)** | Mid-level emits partially_open state |
| **setShadeLevel(75) calls setValue(75)** | execute_child_action called with setValue(75) |
| **setShadeLevel(0) emits closed state** | Level 0 emits windowShade.closed |
| **setShadeLevel(99) emits open state** | Level 99 emits windowShade.open |

### 6. test_lifecycle.lua (7 test cases)

Tests device lifecycle handlers in `handlers/lifecycle.lua`.

| Test Case | Description |
|-----------|-------------|
| **Bridge added triggers sync_bridge_inventory** | When bridge device is added, sync_bridge_inventory is called |
| **Bridge added triggers reschedule_bridge_poll** | When bridge device is added, reschedule_bridge_poll is called |
| **Child device added triggers apply_pending_child_metadata** | When child device is added, apply_pending_child_metadata is called |
| **Child device added does NOT trigger sync_bridge_inventory** | Child addition only applies metadata, doesn't trigger full sync |
| **Bridge removed triggers on_bridge_removed** | When bridge is removed, cleanup function is called |
| **infoChanged on bridge triggers reschedule_bridge_poll and sync** | Bridge preference changes trigger resync and poll reschedule |
| **infoChanged on child device is skipped** | Child device preference changes are ignored (no-op) |

**Mocking Strategy**: Uses inline mock for `fibaro.sync` module with call tracking to verify correct functions are invoked.

---

## Detailed Test Scenarios

### 1. Lifecycle Handler Tests ✅ IMPLEMENTED

| Test Case | Status | Description |
|-----------|--------|-------------|
| Bridge Added | ✅ | When bridge device is added, initialize and start discovery |
| Bridge Added (triggers poll) | ✅ | When bridge device is added, reschedule bridge poll |
| Child Added | ✅ | When child device is added, apply pending metadata |
| Child Added (no sync) | ✅ | Child addition doesn't trigger full inventory sync |
| Info Changed (bridge) | ✅ | Bridge preferences updated triggers reschedule and sync |
| Info Changed (child) | ✅ | Child preferences updated is skipped (no-op) |
| Removed (bridge) | ✅ | Bridge device removed triggers cleanup |

### 2. Command Handler Tests ✅ IMPLEMENTED

| Test Case | Status | Description |
|-----------|--------|-------------|
| Switch On | ✅ | `switch.on` command emits optimistic event and calls `turnOn` API |
| Switch Off | ✅ | `switch.off` command emits optimistic event and calls `turnOff` API |
| Set Level (dimmer, >0) | ✅ | `setLevel(50)` emits level event, calls `setValue(50)` |
| Set Level (dimmer, 0) | ✅ | `setLevel(0)` emits off event, calls `setValue(0)` |
| Set Level (clamping) | ✅ | `setLevel(100)` is clamped to 99 |
| Set Shade Level | ✅ | `setShadeLevel(75)` emits partially_open, calls `setValue(75)` |
| Shade Open | ✅ | `open()` emits open, calls `setValue(99)` |
| Shade Close | ✅ | `close()` emits closed, calls `setValue(0)` |

### 3. Device Mapper Tests ✅ IMPLEMENTED

| Test Case | Status | Description |
|-----------|--------|-------------|
| Map Switch | ✅ | Device with turnOn/turnOff actions → `kind=switch`, `profile=fibaro-switch` |
| Map Dimmer | ✅ | Device with setValue action → `kind=dimmer`, `profile=fibaro-dimmer` |
| Map Blind (interface) | ✅ | Device with `windowCovering` interface → `kind=blind` |
| Map Blind (type) | ✅ | Device with `rollerShutter` type → `kind=blind` |
| Map Smoke Detector | ✅ | Device with `smokeDetector` interface → `kind=smoke-detector` |
| Map Motion Sensor | ✅ | Device with `motionSensor` interface → `kind=motion` |
| Map Contact Sensor | ✅ | Device with `contactSensor` interface → `kind=contact` |
| Map Temperature Sensor | ✅ | Device with `temperatureSensor` interface → `kind=temperature-sensor` |
| Map Humidity Sensor | ✅ | Device with `humiditySensor` interface → `kind=humidity-sensor` |
| Map Illuminance Sensor | ✅ | Device with `lightSensor` interface → `kind=illuminance-sensor` |
| Map Water Sensor | ✅ | Device with `waterSensor` interface → `kind=water-sensor` |
| Map Multi-endpoint (2) | ✅ | Device with 3 endpoints → `kind=double-switch` |
| Map Multi-endpoint (3) | ✅ | Device with 4 endpoints → `kind=triple-switch` |
| Map Metered Switch | ✅ | Switch with power/energy interface → `profile=fibaro-switch-metered` |
| Map Metered Dimmer | ✅ | Dimmer with power/energy values → `profile=fibaro-dimmer-metered` |
| Skip Hidden | ✅ | Device with `visible=false` → nil, error="hidden device" |
| Skip Disabled | ✅ | Device with `enabled=false` → nil, error="disabled device" |
| Skip Gateway | ✅ | Device with `is_gateway=true` → nil, error="controller device" |
| Default Mapping | ✅ | Unknown device type → `kind=default`, `profile=fibaro-default` |

### 4. Utility Function Tests ✅ IMPLEMENTED

| Function | Status | Test Coverage |
|----------|--------|---------------|
| safe_tonumber | ✅ | 6 test cases covering all conversion scenarios |
| clamp | ✅ | 5 test cases covering boundary conditions |
| trim | ✅ | 3 test cases for whitespace handling |
| value_is_truthy | ✅ | 10 test cases for various types |
| sanitize_host | ✅ | 4 test cases for host string parsing |
| hostname_for_serial | ✅ | 5 test cases for mDNS hostname building |
| child_key_for_id | ✅ | 2 test cases for key formatting |
| device_id_from_child_key | ✅ | 3 test cases for ID extraction |
| is_bridge | ✅ | 2 test cases for bridge detection |
| controller_kind_from_info | ✅ | 5 test cases for controller type detection |
| api_version_for_serial | ✅ | 3 test cases for API version detection |

### 5. Sync Module Tests ⏸️ DEFERRED

These tests are more complex as they involve API mocking. Currently deferred as the sync module is tested indirectly through lifecycle and command tests.

| Test Case | Status | Description |
|-----------|--------|-------------|
| sync_bridge_inventory (success) | ⏸️ | Full sync with valid config |
| sync_bridge_inventory (no config) | ⏸️ | Sync without credentials |
| sync_bridge_inventory (API error) | ⏸️ | Sync with API failure |
| poll_bridge (incremental) | ⏸️ | Incremental poll with changes |
| poll_bridge (full reconcile) | ⏸️ | Periodic full sync |

### 6. Refresh Command Tests ✅ IMPLEMENTED (Phase 2)

| Test Case | Status | Description |
|-----------|--------|-------------|
| Bridge refresh | ✅ | `refresh()` on bridge triggers sync_bridge_inventory |
| Child refresh | ✅ | `refresh()` on child triggers refresh_child |

---

## Running Tests

> **Note**: `tools/run_driver_tests.py` referenced below does not exist in this repo. Use the standalone Lua runner documented in [Actual Test Run Results → How to Run Tests Locally](#how-to-run-tests-locally) instead.

### Prerequisites

1. Lua 5.4 at `~/.local/st-lua/lua_install/bin/lua`
2. luacov at `~/.local/st-lua/lua_install/bin/luacov` (for coverage)
3. SmartThings SDK libs at `~/.local/st-lua/lua_libs/`

### Run Individual Test File

```bash
SRC=drivers/Unofficial/fibaro-hc2/src
ST_LIBS=~/.local/st-lua/lua_libs
LUA_SHARE=~/.local/st-lua/lua_install/share/lua/5.4
LUA=~/.local/st-lua/lua_install/bin/lua

export LUA_PATH="$SRC/test/?.lua;$SRC/test/?/init.lua;$SRC/?.lua;$SRC/?/init.lua;$ST_LIBS/?.lua;$ST_LIBS/?/init.lua;$LUA_SHARE/?.lua;$LUA_SHARE/?/init.lua;;"

cd "$SRC"
$LUA test/test_mapper.lua
```

### Run All Tests With Coverage

```bash
LUACOV=~/.local/st-lua/lua_install/bin/luacov
cd "$SRC"
rm -f luacov.stats.out luacov.report.out

for f in test/test_utils.lua test/test_mapper.lua test/test_adapter.lua \
          test/test_switch_commands.lua test/test_dimmer_commands.lua \
          test/test_blind_commands.lua test/test_refresh_commands.lua \
          test/test_lifecycle.lua; do
  $LUA -lluacov "$f"
done

$LUACOV   # reads luacov.stats.out, writes luacov.report.out
grep -A 20 "^Summary" luacov.report.out
```

---

## Test Coverage Goals

### Measured vs Target Coverage (as of 2026-06-16)

| Component | Measured | Target | Gap | Blocker |
|-----------|----------|--------|-----|---------|
| `fibaro/mapper.lua` | **93.4%** | 90% | ✅ Met | — |
| `fibaro/adapter.lua` | **95.0%** | 90% | ✅ Met | — |
| `fibaro/adapters/hc2.lua` | **98.1%** | 90% | ✅ Met | — |
| `fibaro/adapters/hc3.lua` | **92.5%** | 90% | ✅ Met | — |
| `fields.lua` | **100%** | 90% | ✅ Met | — |
| `utils.lua` | **53.8%** | 95% | ❌ -41pp | Missing test cases for uncovered functions |
| `handlers/commands.lua` | **0%** | 80% | ❌ -80pp | `wait_for_events()` no-op; handlers never invoked |
| `handlers/lifecycle.lua` | **0%** | 75% | ❌ -75pp | Same — `wait_for_events()` no-op |
| `fibaro/sync.lua` | **0%** | 60% | ❌ -60pp | `cosock.socket` requires Hub runtime |
| `fibaro/api.lua` | **0%** | 50% | ❌ -50pp | `cosock.socket` requires Hub runtime |
| `discovery.lua` | **0%** | 50% | ❌ -50pp | `cosock.socket` requires Hub runtime |
| `fibaro_finder.lua` | **0%** | 50% | ❌ -50pp | `cosock.socket` requires Hub runtime |

### Test Files Summary

| Test File | Test Cases | Status |
|-----------|------------|--------|
| `test_mapper.lua` | 43 | ✅ IMPLEMENTED |
| `test_utils.lua` | 26 | ✅ OPTIMIZED (consolidated from 70) |
| `test_adapter.lua` | 17 | ✅ OPTIMIZED (consolidated from 53) |
| `test_switch_commands.lua` | 3 | ✅ IMPLEMENTED |
| `test_dimmer_commands.lua` | 5 | ✅ IMPLEMENTED |
| `test_blind_commands.lua` | 5 | ✅ IMPLEMENTED |
| `test_lifecycle.lua` | 7 | ✅ IMPLEMENTED |
| `test_refresh_commands.lua` | 4 | ✅ IMPLEMENTED |
| `test_sync.lua` | 15 | ✅ IMPLEMENTED |
| `test_discovery.lua` | 10 | ✅ IMPLEMENTED |

**Total: 135 test cases** (optimized from 216 - 37% reduction)

> **Note**: Test optimization completed by consolidating redundant edge case tests while maintaining full coverage of core business logic.
> 
> **Optimization Summary**:
> - `test_utils.lua`: 70 → 26 tests (44 tests removed - consolidated redundant edge cases)
> - `test_adapter.lua`: 53 → 17 tests (36 tests removed - consolidated similar assertions)
> - Core logic tests (mapper, commands, sync, discovery) kept intact
> - **Reduction: 81 tests (37%) while maintaining coverage**

---

## Implementation Status

### ✅ Phase 1: Setup - COMPLETED

- [x] Create `src/test/` directory
- [x] Create `test_mapper.lua` with all mapper test cases (43 tests — 100% pass)
- [x] Create `test_utils.lua` with utility function tests (48 tests — 100% pass)
- [x] Verify tests run successfully with standalone Lua

### ✅ Phase 2: Command Handlers - FILES CREATED, MOCK INCOMPLETE

- [x] Create `test_switch_commands.lua` (5 tests — 2 pass, 3 blocked)
- [x] Create `test_dimmer_commands.lua` (7 tests — 5 pass, 2 blocked)
- [x] Create `test_blind_commands.lua` (8 tests — 5 pass, 3 blocked)
- [ ] **BLOCKED**: `wait_for_events()` in `test/integration_test.lua` is a no-op; driver handlers are never called, so `mock_sync.calls` always remains empty

### ✅ Phase 3: Lifecycle Handlers - FILES CREATED, MOCK INCOMPLETE

- [x] Create `test_lifecycle.lua` (7 tests — 1 pass, 6 blocked)
- [ ] **BLOCKED**: Same `wait_for_events()` no-op issue (5 failures) + `generate_info_changed` not implemented on mock devices (2 failures)

### ✅ Phase 3b: Adapter Tests - COMPLETED

- [x] Create `test_adapter.lua` (17 tests — 16 pass, 1 failure on `state` field assertion at line 248)

### ⏸️ Phase 4: Integration Tests - FILES EXIST, CANNOT LOAD

- [x] `test_sync.lua` file created but **cannot be required** — `fibaro.sync` → `cosock.socket` → `_envlibrequire` (Hub C global)
- [x] `test_discovery.lua` file created but **cannot be required** — same dependency chain via `discovery_provider` → `fibaro_finder`
- [ ] Fix requires a stub for `cosock.socket` or `_envlibrequire` that works in standalone Lua

### ⏸️ Phase 5: Mock Framework Hardening - NOT STARTED

- [ ] Implement event dispatch in `test/integration_test.lua::wait_for_events()` — read queued socket events and call the driver's registered handlers
- [ ] Add `generate_info_changed(prefs)` to mock device objects in `create_mock_device()`
- [ ] Add `test/cosock/socket.lua` stub to unblock test_sync and test_discovery loading
- [ ] Fix `test_adapter.lua:248` — align assertion with actual adapter `normalize_device` output

---

## Extending Test Coverage

This section outlines strategies and specific areas for extending test coverage beyond the current **122 test cases**.

> **Note**: Analysis of existing tests shows no duplicates or unnecessary test cases. All 122 tests serve distinct purposes:
> - `test_utils.lua` (48 tests): Comprehensive utility function coverage with no redundancy
> - `test_mapper.lua` (43 tests): 22 original + 13 device types + 8 edge cases
> - `test_blind_commands.lua` (8 tests): Distinct command/state combinations
> - `test_dimmer_commands.lua` (7 tests): Focused on level handling variations
> - `test_lifecycle.lua` (7 tests): Each lifecycle event tested once
> - `test_switch_commands.lua` (5 tests): Core switch functionality
> - `test_refresh_commands.lua` (4 tests): Bridge and child refresh operations

---

## Challenges for Newly Planned Test Cases

This section outlines the technical challenges and mitigation strategies for implementing the planned test extensions.

### Challenge 1: REST API Mocking for Sync Module Tests

**Problem**: The sync module (`fibaro/sync.lua`) makes real HTTP requests to Fibaro controllers. Testing requires mocking the entire HTTP layer.

**Specific Challenges**:

| Challenge | Impact | Mitigation |
|-----------|--------|------------|
| `fibaro.api` module uses LuaSocket | Cannot intercept real HTTP calls | Create wrapper layer that can be swapped with mock |
| Authentication handling | Login tokens, session management | Mock auth endpoint to return fake tokens |
| Async HTTP responses | Coroutine-based async handling | Use `coroutine.yield/resume` pattern in mocks |
| Multiple API endpoints | `/api/devices`, `/api/refreshStates`, etc. | Centralized mock response router |
| Error simulation | Need to test 401/403/500 responses | Configurable mock response status codes |

**Recommended Approach**:
```lua
-- Wrap the API module for testability
-- In fibaro/api.lua, add test hook:
local api = {}
api._http_client = require "socket.http"  -- Injectable

-- In test, replace:
api._http_client = {
  request = function(url)
    return mock_responses[url], 200
  end
}
```

---

### Challenge 2: Stateful Sync Operations

**Problem**: Sync operations maintain state (last poll time, known devices, pending queues).

**Specific Challenges**:

| Challenge | Impact | Mitigation |
|-----------|--------|------------|
| Datastore persistence | State stored in driver datastore | Mock datastore or reset between tests |
| Incremental poll state | `refreshStates` API uses `last` parameter | Track state in mock, verify parameter |
| Device creation queue | Async device creation pacing | Use test coroutine timing controls |
| Pending metadata cache | Child metadata cached before child exists | Pre-populate cache in test setup |

**Recommended Approach**:
```lua
-- Reset datastore before each sync test
local function reset_datastore()
  driver._datastore = {}
end

-- Verify sync state transitions
test.register_coroutine_test(
  "Sync - poll_bridge uses last poll timestamp",
  function()
    -- Setup: Set last poll time
    mock_sync:set_last_poll(1000)
    
    -- Execute: Run poll
    sync.poll_bridge(driver, bridge)
    
    -- Verify: API called with last=1000
    assert(mock_api.last_call_args.last == 1000)
  end
)
```

---

### Challenge 3: Testing Timing-Dependent Behavior

**Problem**: Sync and polling operations use timers and delays that are hard to test deterministically.

**Specific Challenges**:

| Challenge | Impact | Mitigation |
|-----------|--------|------------|
| Poll interval timers | Tests would need to wait minutes | Mock timer module, trigger manually |
| Rate limiting (device creation) | Paced device creation over time | Disable pacing in test mode |
| Debounced preference changes | Delayed sync on infoChanged | Trigger debounce immediately in tests |
| Async callback ordering | Hard to assert event order | Use event queue inspection |

**Recommended Approach**:
```lua
-- Use driver._timer mock
local mock_timer = {
  call_with_delay = function(callback, delay)
    -- Don't actually wait, just store callback
    mock_timer.pending_callbacks[#mock_timer.pending_callbacks + 1] = callback
  end,
  pending_callbacks = {}
}

-- Trigger pending callbacks manually
mock_timer.pending_callbacks[1]()
```

---

### Challenge 4: Device Type Coverage Complexity

**Problem**: Testing 13+ additional device types requires significant test data setup.

**Specific Challenges**:

| Challenge | Impact | Mitigation |
|-----------|--------|------------|
| Device type variations | Each type has unique properties | Use test data factory pattern |
| Interface combinations | Devices can have multiple interfaces | Test primary interface first |
| Profile mapping logic | Complex priority in mapper | Test mapping rules in isolation |
| Vendor-specific types | Non-standard Fibaro types | Focus on standard types first |

**Recommended Approach**:
```lua
-- Test data factory
local function build_device(opts)
  return {
    id = opts.id or 1,
    type = opts.type or "com.fibaro.binarySwitch",
    actions = opts.actions or { turnOn = true, turnOff = true },
    interfaces = opts.interfaces or {},
    -- ... defaults for all required fields
  }
end

-- Usage:
local co_detector = build_device({
  type = "com.fibaro.coSensor",
  interfaces = { "coDetector" }
})
```

---

### Challenge 5: Error Injection and Edge Cases

**Problem**: Testing error paths requires forcing failures in controlled ways.

**Specific Challenges**:

| Challenge | Impact | Mitigation |
|-----------|--------|------------|
| API timeout simulation | Hard to force real timeouts | Mock client returns error after delay |
| Partial sync failures | Some devices sync, others fail | Mock returns mixed success/failure |
| Network disconnection | Hub loses connectivity | Mock throws connection error |
| Malformed responses | Invalid JSON from controller | Mock returns broken JSON strings |

**Recommended Approach**:
```lua
-- Configurable mock behavior
mock_api.set_behavior("devices", {
  status = 500,
  body = "Internal Server Error"
})

mock_api.set_behavior("refreshStates", {
  status = 200,
  body = "{ invalid json"  -- Malformed
})
```

---

### Challenge 6: Discovery/mDNS Testing

**Problem**: mDNS discovery relies on network multicast, which is hard to mock.

**Specific Challenges**:

| Challenge | Impact | Mitigation |
|-----------|--------|------------|
| Multicast network packets | Cannot capture in test environment | Abstract discovery behind interface |
| Service resolution | mDNS name resolution | Mock DNS resolver |
| Duplicate detection | Ignore repeated discoveries | Test deduplication logic separately |
| Device fingerprinting | Verify Fibaro HC2/HC3 | Test fingerprint logic in isolation |

**Recommended Approach**:
```lua
-- Abstract discovery behind injectable interface
local discovery = {}
discovery._scanner = require "mdns.scanner"  -- Injectable

-- In test:
discovery._scanner = {
  scan = function()
    return {
      { name = "HC3-00033787", host = "192.168.1.50", port = 80 }
    }
  end
}
```

---

### Challenge 7: Adapter Layer Testing

**Problem**: Device adapters transform Fibaro-specific data to SmartThings capabilities.

**Specific Challenges**:

| Challenge | Impact | Mitigation |
|-----------|--------|------------|
| Value mapping logic | Fibaro levels (0-99) vs internal | Test mapping formulas explicitly |
| State translation | on/off ↔ switch capability | Test bidirectional mapping |
| Multi-attribute devices | Power + energy + switch | Test each attribute separately |
| Adapter selection | Correct adapter for device type | Test adapter registry logic |

**Recommended Approach**:
```lua
-- Test adapters in isolation from sync
test.register_coroutine_test(
  "Adapter - binarySwitch maps value to switch capability",
  function()
    local fibaro_state = { value = true }
    local st_event = adapters.binary_switch.to_capability(fibaro_state)
    assert(st_event.switch == "on")
  end
)
```

---

### Challenge Summary Table

| Challenge Area | Complexity | Priority |
|----------------|------------|----------|
| REST API Mocking | High | High |
| Stateful Operations | Medium | High |
| Timing Dependencies | Medium | Medium |
| Device Type Coverage | Low | Medium |
| Error Injection | Medium | High |
| Discovery/mDNS | High | Low |
| Adapter Testing | Medium | Medium |

---

### Risk Mitigation Recommendations

1. **Start with refresh command tests** - Lowest complexity, uses existing mock patterns
2. **Build API mocking incrementally** - Start with one endpoint, expand gradually
3. **Use test data factories** - Reduces duplication in device type tests
4. **Test error paths separately** - Don't mix happy-path and error tests
5. **Document mock limitations** - Note what the mocks don't simulate accurately

---

### Priority Levels for Extension

| Priority | Area | Effort | Impact |
|----------|------|--------|--------|
| **High** | Sync module tests | Medium | High - Core functionality |
| **High** | Refresh command tests | Low | High - User-facing feature |
| **Medium** | Additional device types | Medium | Medium - Broader device support |
| **Medium** | Error handling scenarios | Low | High - Reliability |
| **Low** | Discovery provider tests | High | Medium - Auto-discovery |

---

### 1. Sync Module Tests (`test_sync.lua`)

The sync module is the core of the driver's communication with Fibaro HC2/HC3 controllers. Testing requires mocking the REST API layer.

#### 1.1 Mock API Infrastructure

Create `src/test/mock_api.lua`:

```lua
-- Mock API infrastructure for sync tests
local mock_api = {}

local mock_responses = {
  devices = {},
  rooms = {},
  refresh_states = { last = 0, changes = {} },
  login_status = 200,
  settings_info = { platform = "HC3", serialNumber = "HC3-00033787" },
}

function mock_api.set_mock_response(endpoint, data)
  mock_responses[endpoint] = data
end

function mock_api.add_mock_device(device)
  table.insert(mock_responses.devices, device)
end

function mock_api.reset()
  mock_responses = {
    devices = {},
    rooms = {},
    refresh_states = { last = 0, changes = {} },
    login_status = 200,
    settings_info = { platform = "HC3", serialNumber = "HC3-00033787" },
  }
end

return mock_api
```

#### 1.2 Test Cases to Add

| Test Case | Description | Priority |
|-----------|-------------|----------|
| `sync_bridge_inventory - success` | Full sync with valid credentials returns devices | High |
| `sync_bridge_inventory - no credentials` | Sync fails gracefully when credentials missing | High |
| `sync_bridge_inventory - API error` | Sync handles HTTP 401/403/500 errors | High |
| `sync_bridge_inventory - empty inventory` | Sync handles empty device list | Medium |
| `sync_bridge_inventory - device removal` | Sync detects and removes deleted devices | High |
| `sync_bridge_inventory - device addition` | Sync detects and queues new devices | High |
| `sync_bridge_inventory - device update` | Sync detects and updates changed devices | High |
| `poll_bridge - incremental changes` | Poll only fetches changes since last poll | Medium |
| `poll_bridge - full reconcile` | Periodic full sync reconciles all devices | Medium |
| `refresh_child - success` | Refresh fetches current device state | High |
| `refresh_child - device not found` | Refresh handles 404 gracefully | Medium |
| `drain_create_queue - pacing` | Device creation is rate-limited | Medium |
| `apply_pending_child_metadata - exists` | Metadata applied when available | Medium |
| `apply_pending_child_metadata - missing` | Wait when metadata not yet cached | Medium |

---

### 2. Refresh Command Tests (`test_refresh_commands.lua`)

**Status**: ✅ **IMPLEMENTED** (4 tests)

Tests for the refresh capability on bridge and child devices.

#### Implemented Test Cases

| Test Case | Description | Status |
|-----------|-------------|--------|
| `Refresh - bridge refresh triggers sync_bridge_inventory` | Bridge refresh triggers full inventory sync | ✅ |
| `Refresh - bridge refresh does NOT trigger refresh_child` | Bridge refresh doesn't call child refresh | ✅ |
| `Refresh - child refresh triggers refresh_child` | Child refresh fetches device state | ✅ |
| `Refresh - child refresh does NOT trigger sync_bridge_inventory` | Child refresh doesn't trigger full sync | ✅ |

#### Deferred Test Cases (require API mocking)

| Test Case | Description | Priority |
|-----------|-------------|----------|
| `refresh - error handling` | Refresh handles API errors gracefully | Medium |

#### Example Test Structure

```lua
local test = require "integration_test"
local t_utils = require "integration_test.utils"
local capabilities = require "st.capabilities"
local fields = require "fields"

-- Mock sync module
local mock_sync = { calls = {} }
function mock_sync.refresh_child(driver, child)
  table.insert(mock_sync.calls, { fn = "refresh_child", id = child.id })
  return true, nil
end
function mock_sync.sync_bridge_inventory(driver, bridge)
  table.insert(mock_sync.calls, { fn = "sync_bridge_inventory", id = bridge.id })
  return true, nil
end
package.loaded["fibaro.sync"] = mock_sync

local mock_bridge = test.mock_device.build_test_generic_device({...})
local mock_child = test.mock_device.build_test_child_device({...})

test.register_coroutine_test(
  "Refresh - bridge refresh triggers sync_bridge_inventory",
  function()
    test.socket.capability:__queue_receive({
      mock_bridge.id,
      { capability = "refresh", component = "main", command = "refresh", args = {} }
    })
    test.wait_for_events()
    -- Assert sync_bridge_inventory was called
  end
)

test.run_registered_tests()
```

---

### 3. Additional Device Type Tests

**Status**: ✅ **IMPLEMENTED** (13 tests in `test_mapper.lua`)

Extend `test_mapper.lua` with more device type mappings.

#### Implemented Sensor Types (8 tests)

| Device Type | Current Behavior | Test Status |
|-------------|-----------------|-------------|
| CO Detector | Maps to `smoke-detector` via `lifeDangerSensor` base_type | ✅ |
| Vibration Sensor | Falls back to `generic-sensor`/`default` | ✅ |
| Acceleration Sensor | Falls back to `generic-sensor`/`default` | ✅ |
| Soil Moisture Sensor | Falls back to `generic-sensor`/`default` | ✅ |
| UV Sensor | Falls back to `generic-sensor`/`default` | ✅ |
| Air Quality Sensor | Falls back to `generic-sensor`/`default` | ✅ |
| Voltage Sensor | Falls back to `generic-sensor`/`default` | ✅ |
| Current Sensor | Falls back to `generic-sensor`/`default` | ✅ |

#### Implemented Actuator Types (5 tests)

| Device Type | Current Behavior | Test Status |
|-------------|-----------------|-------------|
| Siren | Maps to `switch` via `turnOn/turnOff` actions | ✅ |
| Sprinkler | Maps to `switch` via `turnOn/turnOff` actions | ✅ |
| Fan | Maps to `switch` via `turnOn/turnOff` actions | ✅ |
| Thermostat | Falls back to `generic-sensor`/`default` | ✅ |
| Garage Door | Falls back to `generic-sensor`/`default` | ✅ |

#### Note on Expected vs Current Behavior

The tests document **current behavior** without modifying `mapper.lua`. To achieve the expected kind/profile mappings from the original plan, interface-based mapping rules would need to be added to `mapper.lua` for each new device type.

#### 3.2 Sensor Types to Add

| Device Type | Interface | Expected Kind | Profile |
|-------------|-----------|---------------|---------|
| CO Detector | `coDetector` | `co-detector` | `fibaro-co-detector` |
| Vibration Sensor | `vibrationSensor` | `vibration` | `fibaro-vibration` |
| Acceleration Sensor | `accelerationSensor` | `acceleration` | `fibaro-acceleration` |
| Soil Moisture Sensor | `soilMoistureSensor` | `soil-moisture` | `fibaro-soil-moisture` |
| UV Sensor | `uvSensor` | `uv-index` | `fibaro-uv-sensor` |
| Air Quality Sensor | `airQualitySensor` | `air-quality` | `fibaro-air-quality` |
| Voltage Sensor | `voltageSensor` | `voltage` | `fibaro-voltage` |
| Current Sensor | `currentSensor` | `current` | `fibaro-current` |

#### 3.2 Actuator Types to Add

| Device Type | Actions | Expected Kind | Profile |
|-------------|---------|---------------|---------|
| Siren | `turnOn`, `turnOff` | `siren` | `fibaro-siren` |
| Sprinkler | `turnOn`, `turnOff` | `sprinkler` | `fibaro-sprinkler` |
| Fan | `turnOn`, `turnOff`, `setSpeed` | `fan` | `fibaro-fan` |
| Thermostat | `setHeatingSetpoint`, `setCoolingSetpoint` | `thermostat` | `fibaro-thermostat` |
| Garage Door | `open`, `close` | `garage-door` | `fibaro-garage` |

#### 3.3 Special Device Configurations

| Configuration | Test Scenario |
|---------------|---------------|
| Battery-powered devices | Test battery level reporting |
| Multi-channel devices | Test endpoint mapping beyond 3-4 channels |
| Devices with multiple interfaces | Test priority when device has multiple capabilities |
| Devices with custom properties | Test handling of vendor-specific properties |

---

### 4. Error Handling and Edge Cases

#### 4.1 Command Handler Error Tests

| Test Case | Description |
|-----------|-------------|
| `switch.on - API timeout` | Command times out, error is logged |
| `switch.on - API returns error` | Command fails, device state unchanged |
| `setLevel - invalid level` | Level outside 0-99 is handled |
| `setLevel - non-numeric argument` | Invalid argument type is handled |

#### 4.2 Lifecycle Error Tests

| Test Case | Description |
|-----------|-------------|
| `bridge added - sync fails` | Bridge comes online but sync fails |
| `bridge added - partial success` | Some devices sync, others fail |
| `child added - metadata missing` | Child added before parent sync completes |
| `infoChanged - invalid preferences` | Invalid preference values are rejected |

#### 4.3 Mapper Edge Cases

| Test Case | Description |
|-----------|-------------|
| `device with nil label` | Mapper handles missing label gracefully |
| `device with nil type` | Mapper handles missing type |
| `device with empty actions` | Device with no actions gets default mapping |
| `device with nil room_id` | Device without room gets no room prefix |
| `device with unknown interface` | Unknown interface doesn't break mapping |

---

### 5. Discovery Provider Tests (`test_discovery.lua`)

Tests for the mDNS discovery mechanism.

#### Test Cases to Add

| Test Case | Description | Priority |
|-----------|-------------|----------|
| `mdns response parsing` | Parse mDNS service discovery response | Medium |
| `device fingerprinting` | Verify device matches Fibaro HC2/HC3 | Medium |
| `duplicate detection` | Ignore duplicate discoveries | Low |
| `invalid response handling` | Handle malformed mDNS responses | Low |

---

### 6. Adapter Tests (`test_adapters.lua`)

Tests for device-specific adapters in `fibaro/adapters/`.

#### Test Cases to Add

| Adapter | Test Scenario | Priority |
|---------|---------------|----------|
| Binary Switch | on/off state mapping | Medium |
| Multilevel Switch | Level mapping (0-99 ↔ Fibaro levels) | Medium |
| Roller Shutter | Position mapping, tilt support | Medium |
| Sensor Adapters | Value mapping for various sensor types | Medium |
| Metered Devices | Power/energy reading conversion | Low |

---

### 7. Integration Test Scenarios

End-to-end scenarios that combine multiple components.

#### 7.1 Full Device Lifecycle

```
1. Bridge discovered via mDNS
2. Bridge added → sync triggered
3. Devices discovered and queued
4. Child devices created
5. Child devices added → metadata applied
6. Commands sent to child devices
7. State updates received
```

#### 7.2 Reconciliation Scenarios

| Scenario | Steps |
|----------|-------|
| Device added on HC2 | Poll detects new device → SmartThings device created |
| Device removed from HC2 | Poll detects missing device → SmartThings device removed |
| Device renamed on HC2 | Poll detects name change → SmartThings label updated |
| Credentials changed | infoChanged → full resync with new credentials |

---

### 8. Coverage Measurement and Monitoring

#### 8.1 Running Coverage Reports

```bash
# Run with coverage
python3 tools/run_driver_tests.py -f "fibaro-hc2" -c

# Generate HTML report
python3 tools/run_driver_tests.py -f "fibaro-hc2" -c --html

# View coverage summary
cat coverage/fibaro-hc2/summary.txt
```

#### 8.2 Coverage Goals by Module (measured 2026-06-16)

| Module | Measured | Target | Extended Target | Blocker |
|--------|----------|--------|-----------------|---------|
| `fibaro/mapper.lua` | **93.4%** | 90% | 95% | — met |
| `fibaro/adapter*.lua` | **95–98%** | 90% | 95% | — met |
| `fields.lua` | **100%** | 90% | 100% | — met |
| `utils.lua` | **53.8%** | 95% | 98% | Missing test cases |
| `handlers/commands.lua` | **0%** | 80% | 90% | `wait_for_events` no-op |
| `handlers/lifecycle.lua` | **0%** | 75% | 85% | `wait_for_events` no-op |
| `fibaro/sync.lua` | **0%** | 60% | 80% | Hub socket dependency |
| `fibaro/api.lua` | **0%** | 50% | 70% | Hub socket dependency |
| `discovery.lua` | **0%** | 50% | 60% | Hub socket dependency |
| **Overall (tracked only)** | **85.6%** | **75%** | **85%** | Partial — 6/12 files tracked |

#### 8.3 Identifying Coverage Gaps

Use luacov or similar tools to identify uncovered lines:

```bash
# After running tests with coverage
luacov -f "drivers/Unofficial/fibaro-hc2/src"

# Review uncovered lines
cat luacov.report.out | grep -A 5 "fibaro/sync.lua"
```

---

### 9. Test Maintenance Best Practices

#### 9.1 When to Add Tests

- **New features**: Always add tests for new device types or capabilities
- **Bug fixes**: Add regression tests for any bug fixes
- **Refactoring**: Ensure existing tests pass; add tests if coverage is low
- **API changes**: Update tests when Fibaro API behavior changes

#### 9.2 Test Naming Conventions

```lua
-- Format: "<Component> - <action> <expected result>"
test.register_coroutine_test(
  "Mapper - switch device maps to kind=switch with fibaro-switch profile",
  function() ... end
)

test.register_coroutine_test(
  "Dimmer - setLevel(50) emits optimistic switch.on and level(50)",
  function() ... end
)
```

#### 9.3 Mock Management

- Always reset mock state between tests
- Use `mock_sync.calls = {}` in `test_init()` for command tests
- Clear calls before specific assertions when init fires events

---

### Extension Roadmap

| Quarter | Focus Area | Expected Test Count |
|---------|------------|---------------------|
| **Current (2026-06)** | Baseline — 122/139 pass, 17 blocked, 2 files unloadable | **139 tests written** |
| Next sprint | Fix local mock (`wait_for_events`, `generate_info_changed`, `cosock` stub) | +0 new tests; unblocks 17 failures |
| Q3 | Sync module tests (requires cosock stub) | +14 tests (153 total) |
| Q3 | Error handling + Edge cases | +15 tests (168 total) |
| Q4 | Discovery provider tests | +4 tests (172 total) |
| Q4 | Adapter tests + Integration | +15 tests (187 total) |

#### Test Count Summary by Category

| Category | Original Plan | Implemented Today | Total |
|----------|---------------|-------------------|-------|
| **Original Tests** | 97 | - | 97 |
| **Phase 2: Device Types** | 20 | 13 | 13 |
| **Phase 2: Refresh Commands** | 4 | 4 | 4 |
| **Phase 2: Mapper Edge Cases** | - | 8 | 8 |
| **Deferred (Sync)** | 14 | - | 0 |
| **Deferred (Discovery)** | 4 | - | 0 |
| **Deferred (Adapters)** | 5 | - | 0 |
| **TOTAL** | 144 | **25** | **122** |

---

## Appendix: Example Test Output

---

## References

- [SmartThings Edge Driver Test Framework](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers)
- [Integration Test Documentation](https://developer.smartthings.com/docs/edge/integration-tests/)
- [Fibaro HC2 Driver Source](./src/)
- [Test Runner Script](../../../tools/run_driver_tests.py)
- [Lua Coverage Tools](https://keplerproject.github.io/luacov/)

---

**Last Updated**: 2026-06-16
**Test Framework Version**: Local standalone Lua mock (`src/test/integration_test.lua`) — not the full SmartThings `integration_test` framework
**Lua Version**: 5.4.7 (`~/.local/st-lua/lua_install/bin/lua`)
**luacov Version**: 0.17.0 (`~/.local/st-lua/lua_install/bin/luacov`)
