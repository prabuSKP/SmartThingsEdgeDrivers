-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-- Phase 2: Refresh Command Tests (Section 2 of UNIT_TEST_PLAN.md)
-- Tests for the refresh capability on bridge and child devices.

-- Mock fibaro.sync before the driver loads so refresh tests have no real I/O.
local mock_sync = { calls = {} }
function mock_sync.execute_child_action(driver, device, action_name, args)
  table.insert(mock_sync.calls, { fn = "execute_child_action", action_name = action_name, args = args })
  return true, nil
end
function mock_sync.sync_bridge_inventory(driver, bridge)
  table.insert(mock_sync.calls, { fn = "sync_bridge_inventory", id = bridge.id })
  return true, nil
end
function mock_sync.refresh_child(driver, child)
  table.insert(mock_sync.calls, { fn = "refresh_child", id = child.id })
  return true, nil
end
function mock_sync.reschedule_bridge_poll(driver, bridge)
  table.insert(mock_sync.calls, { fn = "reschedule_bridge_poll", id = bridge.id })
end
function mock_sync.apply_pending_child_metadata(driver, device)
  table.insert(mock_sync.calls, { fn = "apply_pending_child_metadata", id = device.id })
end
function mock_sync.on_bridge_removed(driver, bridge)
  table.insert(mock_sync.calls, { fn = "on_bridge_removed", id = bridge.id })
end
function mock_sync.drain_create_queue(driver, max) return 0 end
package.loaded["fibaro.sync"] = mock_sync

local test = require "integration_test"
local t_utils = require "integration_test.utils"
local capabilities = require "st.capabilities"
local fields = require "fields"

local mock_bridge = test.mock_device.build_test_generic_device({
  profile = t_utils.get_profile_definition("hc2-bridge.yml"),
  device_network_id = "fibaro-hc2-bridge-001",
})

local mock_child_switch = test.mock_device.build_test_child_device({
  profile = t_utils.get_profile_definition("fibaro-switch.yml"),
  device_network_id = "fibaro-hc2-bridge-001:device:1",
  parent_device_id = mock_bridge.id,
  parent_assigned_child_key = "device:1",
})

local function test_init()
  test.mock_device.add_test_device(mock_bridge)
  test.mock_device.add_test_device(mock_child_switch)
  mock_sync.calls = {}
end

test.set_test_init_function(test_init)

-- ============================================================
-- Refresh on Bridge
-- ============================================================

test.register_coroutine_test(
  "Refresh - bridge refresh triggers sync_bridge_inventory",
  function()
    test.socket.capability:__queue_receive({
      mock_bridge.id,
      { capability = "refresh", component = "main", command = "refresh", args = {} }
    })
    test.wait_for_events()

    local found = false
    for _, call in ipairs(mock_sync.calls) do
      if call.fn == "sync_bridge_inventory" then
        found = true
        break
      end
    end
    assert(found, "Bridge refresh should trigger sync_bridge_inventory")
  end
)

test.register_coroutine_test(
  "Refresh - bridge refresh does NOT trigger refresh_child",
  function()
    mock_sync.calls = {}
    test.socket.capability:__queue_receive({
      mock_bridge.id,
      { capability = "refresh", component = "main", command = "refresh", args = {} }
    })
    test.wait_for_events()

    local found = false
    for _, call in ipairs(mock_sync.calls) do
      if call.fn == "refresh_child" then
        found = true
        break
      end
    end
    assert(not found, "Bridge refresh should NOT trigger refresh_child")
  end
)

-- ============================================================
-- Refresh on Child Device
-- ============================================================

test.register_coroutine_test(
  "Refresh - child refresh triggers refresh_child",
  function()
    mock_sync.calls = {}
    test.socket.capability:__queue_receive({
      mock_child_switch.id,
      { capability = "refresh", component = "main", command = "refresh", args = {} }
    })
    test.wait_for_events()

    local found = false
    for _, call in ipairs(mock_sync.calls) do
      if call.fn == "refresh_child" and call.id == mock_child_switch.id then
        found = true
        break
      end
    end
    assert(found, "Child refresh should trigger refresh_child")
  end
)

test.register_coroutine_test(
  "Refresh - child refresh does NOT trigger sync_bridge_inventory",
  function()
    mock_sync.calls = {}
    test.socket.capability:__queue_receive({
      mock_child_switch.id,
      { capability = "refresh", component = "main", command = "refresh", args = {} }
    })
    test.wait_for_events()

    local found = false
    for _, call in ipairs(mock_sync.calls) do
      if call.fn == "sync_bridge_inventory" then
        found = true
        break
      end
    end
    assert(not found, "Child refresh should NOT trigger sync_bridge_inventory")
  end
)

-- ============================================================
-- Refresh Error Handling (planned - requires API mock)
-- ============================================================
-- Note: Full error handling tests require API mocking infrastructure
-- to simulate network errors, timeouts, and invalid responses.
-- These will be added when sync module tests are implemented.

test.run_registered_tests()
