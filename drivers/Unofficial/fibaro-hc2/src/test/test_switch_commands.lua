-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-- Mock fibaro.sync BEFORE integration_test loads the driver (init.lua → commands.lua
-- → require "fibaro.sync"). This keeps socket/API calls out of command unit tests.
local mock_sync = { calls = {} }
function mock_sync.execute_child_action(driver, device, action_name, args)
  table.insert(mock_sync.calls, { action_name = action_name, args = args })
  return true, nil
end
function mock_sync.sync_bridge_inventory(driver, bridge) return true, nil end
function mock_sync.refresh_child(driver, child) return true, nil end
function mock_sync.reschedule_bridge_poll(driver, bridge) end
function mock_sync.apply_pending_child_metadata(driver, device) end
function mock_sync.on_bridge_removed(driver, bridge) end
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
  -- Set kind AFTER add_test_device so the optimistic-event guard in switch_on / switch_off fires.
  mock_child_switch:set_field(fields.HC2_DEVICE_KIND, "switch", { persist = true })
  mock_sync.calls = {}
end

test.set_test_init_function(test_init)

-- ============================================================
-- switch.on
-- ============================================================

test.register_coroutine_test(
  "Switch - switch.on emits optimistic on event",
  function()
    test.socket.capability:__queue_receive({
      mock_child_switch.id,
      { capability = "switch", component = "main", command = "on", args = {} }
    })

    test.socket.capability:__expect_send(
      mock_child_switch:generate_test_message("main", capabilities.switch.switch.on())
    )
  end
)

test.register_coroutine_test(
  "Switch - switch.on calls execute_child_action with turnOn",
  function()
    test.socket.capability:__queue_receive({
      mock_child_switch.id,
      { capability = "switch", component = "main", command = "on", args = {} }
    })

    test.socket.capability:__expect_send(
      mock_child_switch:generate_test_message("main", capabilities.switch.switch.on())
    )

    test.wait_for_events()

    assert(#mock_sync.calls >= 1,
      "Expected at least one sync call, got: " .. tostring(#mock_sync.calls))
    local last = mock_sync.calls[#mock_sync.calls]
    assert(last.action_name == "turnOn",
      "Expected turnOn action, got: " .. tostring(last.action_name))
  end
)

-- ============================================================
-- switch.off
-- ============================================================

test.register_coroutine_test(
  "Switch - switch.off emits optimistic off event",
  function()
    test.socket.capability:__queue_receive({
      mock_child_switch.id,
      { capability = "switch", component = "main", command = "off", args = {} }
    })

    test.socket.capability:__expect_send(
      mock_child_switch:generate_test_message("main", capabilities.switch.switch.off())
    )
  end
)

test.register_coroutine_test(
  "Switch - switch.off calls execute_child_action with turnOff",
  function()
    test.socket.capability:__queue_receive({
      mock_child_switch.id,
      { capability = "switch", component = "main", command = "off", args = {} }
    })

    test.socket.capability:__expect_send(
      mock_child_switch:generate_test_message("main", capabilities.switch.switch.off())
    )

    test.wait_for_events()

    assert(#mock_sync.calls >= 1,
      "Expected at least one sync call, got: " .. tostring(#mock_sync.calls))
    local last = mock_sync.calls[#mock_sync.calls]
    assert(last.action_name == "turnOff",
      "Expected turnOff action, got: " .. tostring(last.action_name))
  end
)

-- ============================================================
-- No optimistic event for bridge devices
-- ============================================================

test.register_coroutine_test(
  "Switch - switch.on with unknown HC2_DEVICE_KIND does NOT emit optimistic event",
  function()
    -- Set kind to something that doesn't match "switch" or "dimmer" to verify
    -- the optimistic-event guard is skipped, while execute_child_action still fires.
    mock_child_switch:set_field(fields.HC2_DEVICE_KIND, "unknown", { persist = true })

    test.socket.capability:__queue_receive({
      mock_child_switch.id,
      { capability = "switch", component = "main", command = "on", args = {} }
    })

    -- No __expect_send: unknown kind skips the optimistic event.
    test.wait_for_events()

    local found_turnOn = false
    for _, call in ipairs(mock_sync.calls) do
      if call.action_name == "turnOn" then
        found_turnOn = true
      end
    end
    assert(found_turnOn, "execute_child_action should still dispatch turnOn for unknown kind")
  end
)

test.run_registered_tests()
