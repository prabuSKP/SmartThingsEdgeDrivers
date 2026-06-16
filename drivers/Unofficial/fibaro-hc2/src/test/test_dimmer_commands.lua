-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-- Mock fibaro.sync before driver loads so command tests have no real I/O.
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

local mock_child_dimmer = test.mock_device.build_test_child_device({
  profile = t_utils.get_profile_definition("fibaro-dimmer.yml"),
  device_network_id = "fibaro-hc2-bridge-001:device:2",
  parent_device_id = mock_bridge.id,
  parent_assigned_child_key = "device:2",
})

local function test_init()
  test.mock_device.add_test_device(mock_bridge)
  test.mock_device.add_test_device(mock_child_dimmer)
  -- Set kind AFTER add_test_device so the optimistic-event guard fires correctly.
  mock_child_dimmer:set_field(fields.HC2_DEVICE_KIND, "dimmer", { persist = true })
  mock_sync.calls = {}
end

test.set_test_init_function(test_init)

-- ============================================================
-- setLevel > 0: emits switch.on + level event
-- ============================================================

test.register_coroutine_test(
  "Dimmer - setLevel(50) emits optimistic switch.on and level(50)",
  function()
    test.socket.capability:__queue_receive({
      mock_child_dimmer.id,
      { capability = "switchLevel", component = "main", command = "setLevel",
        args = { 50 } }
    })

    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switch.switch.on())
    )
    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switchLevel.level(50))
    )
  end
)

test.register_coroutine_test(
  "Dimmer - setLevel(50) calls setValue action",
  function()
    test.socket.capability:__queue_receive({
      mock_child_dimmer.id,
      { capability = "switchLevel", component = "main", command = "setLevel",
        args = { 50 } }
    })

    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switch.switch.on())
    )
    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switchLevel.level(50))
    )

    test.wait_for_events()

    assert(#mock_sync.calls >= 1,
      "Expected a sync call, got: " .. tostring(#mock_sync.calls))
    local last = mock_sync.calls[#mock_sync.calls]
    assert(last.action_name == "setValue",
      "Expected setValue action, got: " .. tostring(last.action_name))
  end
)

-- ============================================================
-- setLevel to 0: emits switch.off + level(0)
-- ============================================================

test.register_coroutine_test(
  "Dimmer - setLevel(0) emits optimistic switch.off and level(0)",
  function()
    test.socket.capability:__queue_receive({
      mock_child_dimmer.id,
      { capability = "switchLevel", component = "main", command = "setLevel",
        args = { 0 } }
    })

    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switch.switch.off())
    )
    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switchLevel.level(0))
    )
  end
)

-- ============================================================
-- Level clamping
-- ============================================================

test.register_coroutine_test(
  "Dimmer - setLevel(100) is clamped to 99",
  function()
    test.socket.capability:__queue_receive({
      mock_child_dimmer.id,
      { capability = "switchLevel", component = "main", command = "setLevel",
        args = { 100 } }
    })

    -- 100 is clamped to 99, which is > 0, so switch.on
    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switch.switch.on())
    )
    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switchLevel.level(99))
    )
  end
)

-- ============================================================
-- setLevel calls setValue (not turnOn/turnOff) regardless of level
-- ============================================================

test.register_coroutine_test(
  "Dimmer - setLevel(0) calls setValue not turnOff",
  function()
    test.socket.capability:__queue_receive({
      mock_child_dimmer.id,
      { capability = "switchLevel", component = "main", command = "setLevel",
        args = { 0 } }
    })

    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switch.switch.off())
    )
    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switchLevel.level(0))
    )

    test.wait_for_events()

    assert(#mock_sync.calls >= 1,
      "Expected a sync call, got: " .. tostring(#mock_sync.calls))
    local last = mock_sync.calls[#mock_sync.calls]
    assert(last.action_name == "setValue",
      "setLevel should always call setValue, got: " .. tostring(last.action_name))
  end
)

-- ============================================================
-- switch.on / switch.off on a dimmer device
-- ============================================================

test.register_coroutine_test(
  "Dimmer - switch.on emits optimistic on event",
  function()
    test.socket.capability:__queue_receive({
      mock_child_dimmer.id,
      { capability = "switch", component = "main", command = "on", args = {} }
    })

    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switch.switch.on())
    )
  end
)

test.register_coroutine_test(
  "Dimmer - switch.off emits optimistic off event",
  function()
    test.socket.capability:__queue_receive({
      mock_child_dimmer.id,
      { capability = "switch", component = "main", command = "off", args = {} }
    })

    test.socket.capability:__expect_send(
      mock_child_dimmer:generate_test_message("main", capabilities.switch.switch.off())
    )
  end
)

test.run_registered_tests()
