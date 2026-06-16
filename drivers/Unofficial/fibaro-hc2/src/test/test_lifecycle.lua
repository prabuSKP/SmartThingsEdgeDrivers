-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-- Mock fibaro.sync before the driver loads so lifecycle tests have no real I/O.
-- sync_bridge_inventory, reschedule_bridge_poll etc. are called from lifecycle.init/added.
local mock_sync = { calls = {} }
function mock_sync.execute_child_action(driver, device, action_name, args)
  table.insert(mock_sync.calls, { fn = "execute_child_action", action_name = action_name })
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
-- Bridge lifecycle: added
-- ============================================================

test.register_coroutine_test(
  "Lifecycle - bridge added triggers sync_bridge_inventory",
  function()
    test.socket.device_lifecycle:__queue_receive({ mock_bridge.id, "added" })
    test.wait_for_events()

    local found = false
    for _, call in ipairs(mock_sync.calls) do
      if call.fn == "sync_bridge_inventory" then
        found = true
        break
      end
    end
    assert(found, "Bridge added should trigger sync_bridge_inventory")
  end
)

test.register_coroutine_test(
  "Lifecycle - bridge added triggers reschedule_bridge_poll",
  function()
    test.socket.device_lifecycle:__queue_receive({ mock_bridge.id, "added" })
    test.wait_for_events()

    local found = false
    for _, call in ipairs(mock_sync.calls) do
      if call.fn == "reschedule_bridge_poll" then
        found = true
        break
      end
    end
    assert(found, "Bridge added should trigger reschedule_bridge_poll")
  end
)

-- ============================================================
-- Child lifecycle: added
-- ============================================================

test.register_coroutine_test(
  "Lifecycle - child device added triggers apply_pending_child_metadata",
  function()
    test.socket.device_lifecycle:__queue_receive({ mock_child_switch.id, "added" })
    test.wait_for_events()

    local found = false
    for _, call in ipairs(mock_sync.calls) do
      if call.fn == "apply_pending_child_metadata" then
        found = true
        break
      end
    end
    assert(found, "Child added should trigger apply_pending_child_metadata")
  end
)

test.register_coroutine_test(
  "Lifecycle - child device added does NOT trigger sync_bridge_inventory",
  function()
    -- Init events (bridge init → sync_bridge_inventory) fire before the coroutine
    -- body runs. Reset here so we only see calls from THIS event.
    mock_sync.calls = {}
    test.socket.device_lifecycle:__queue_receive({ mock_child_switch.id, "added" })
    test.wait_for_events()

    local found = false
    for _, call in ipairs(mock_sync.calls) do
      if call.fn == "sync_bridge_inventory" then
        found = true
        break
      end
    end
    assert(not found, "Child added should NOT trigger sync_bridge_inventory")
  end
)

-- ============================================================
-- Bridge lifecycle: removed
-- ============================================================

test.register_coroutine_test(
  "Lifecycle - bridge removed triggers on_bridge_removed",
  function()
    test.socket.device_lifecycle:__queue_receive({ mock_bridge.id, "removed" })
    test.wait_for_events()

    local found = false
    for _, call in ipairs(mock_sync.calls) do
      if call.fn == "on_bridge_removed" then
        found = true
        break
      end
    end
    assert(found, "Bridge removed should trigger on_bridge_removed")
  end
)

-- ============================================================
-- infoChanged: bridge vs child
-- ============================================================

test.register_coroutine_test(
  "Lifecycle - infoChanged on bridge triggers reschedule_bridge_poll and sync",
  function()
    test.socket.device_lifecycle:__queue_receive(
      mock_bridge:generate_info_changed({
        preferences = {
          ["fibaro.host"] = "192.168.1.100",
          ["fibaro.username"] = "admin",
          ["fibaro.password"] = "secret",
        }
      })
    )
    test.wait_for_events()

    local found_poll = false
    local found_sync = false
    for _, call in ipairs(mock_sync.calls) do
      if call.fn == "reschedule_bridge_poll" then found_poll = true end
      if call.fn == "sync_bridge_inventory" then found_sync = true end
    end
    assert(found_poll, "infoChanged on bridge should trigger reschedule_bridge_poll")
    assert(found_sync, "infoChanged on bridge should trigger sync_bridge_inventory")
  end
)

test.register_coroutine_test(
  "Lifecycle - infoChanged on child device is skipped (no sync triggered)",
  function()
    -- Clear init-phase calls (bridge init fires sync_bridge_inventory before
    -- the coroutine body runs) so we only assert on this specific event.
    mock_sync.calls = {}
    test.socket.device_lifecycle:__queue_receive(
      mock_child_switch:generate_info_changed({
        preferences = { somePref = "value" }
      })
    )
    test.wait_for_events()

    -- child infoChanged is a no-op: lifecycle.info_changed returns early for non-bridge
    local found_poll = false
    local found_sync = false
    for _, call in ipairs(mock_sync.calls) do
      if call.fn == "reschedule_bridge_poll" then found_poll = true end
      if call.fn == "sync_bridge_inventory" then found_sync = true end
    end
    assert(not found_poll, "infoChanged on child should NOT trigger reschedule_bridge_poll")
    assert(not found_sync, "infoChanged on child should NOT trigger sync_bridge_inventory")
  end
)

test.run_registered_tests()
