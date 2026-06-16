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

local mock_child_blind = test.mock_device.build_test_child_device({
  profile = t_utils.get_profile_definition("fibaro-blind.yml"),
  device_network_id = "fibaro-hc2-bridge-001:device:3",
  parent_device_id = mock_bridge.id,
  parent_assigned_child_key = "device:3",
})

local function test_init()
  test.mock_device.add_test_device(mock_bridge)
  test.mock_device.add_test_device(mock_child_blind)
  -- Set kind AFTER add_test_device so the optimistic-event guard fires correctly.
  mock_child_blind:set_field(fields.HC2_DEVICE_KIND, "blind", { persist = true })
  mock_sync.calls = {}
end

test.set_test_init_function(test_init)

-- ============================================================
-- open: emits windowShade.open + shadeLevel(99), calls setValue(99)
-- ============================================================

test.register_coroutine_test(
  "Blind - open emits windowShade.open and shadeLevel(99)",
  function()
    test.socket.capability:__queue_receive({
      mock_child_blind.id,
      { capability = "windowShade", component = "main", command = "open", args = {} }
    })

    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShade.windowShade.open())
    )
    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShadeLevel.shadeLevel(99))
    )
  end
)

test.register_coroutine_test(
  "Blind - open calls setValue(99)",
  function()
    test.socket.capability:__queue_receive({
      mock_child_blind.id,
      { capability = "windowShade", component = "main", command = "open", args = {} }
    })

    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShade.windowShade.open())
    )
    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShadeLevel.shadeLevel(99))
    )

    test.wait_for_events()

    assert(#mock_sync.calls >= 1,
      "Expected a sync call, got: " .. tostring(#mock_sync.calls))
    local last = mock_sync.calls[#mock_sync.calls]
    assert(last.action_name == "setValue",
      "Expected setValue, got: " .. tostring(last.action_name))
    assert(last.args and last.args[1] == 99,
      "Expected setValue(99), got args[1]=" .. tostring(last.args and last.args[1]))
  end
)

-- ============================================================
-- close: emits windowShade.closed + shadeLevel(0), calls setValue(0)
-- ============================================================

test.register_coroutine_test(
  "Blind - close emits windowShade.closed and shadeLevel(0)",
  function()
    test.socket.capability:__queue_receive({
      mock_child_blind.id,
      { capability = "windowShade", component = "main", command = "close", args = {} }
    })

    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShade.windowShade.closed())
    )
    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShadeLevel.shadeLevel(0))
    )
  end
)

test.register_coroutine_test(
  "Blind - close calls setValue(0)",
  function()
    test.socket.capability:__queue_receive({
      mock_child_blind.id,
      { capability = "windowShade", component = "main", command = "close", args = {} }
    })

    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShade.windowShade.closed())
    )
    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShadeLevel.shadeLevel(0))
    )

    test.wait_for_events()

    assert(#mock_sync.calls >= 1,
      "Expected a sync call, got: " .. tostring(#mock_sync.calls))
    local last = mock_sync.calls[#mock_sync.calls]
    assert(last.action_name == "setValue",
      "Expected setValue, got: " .. tostring(last.action_name))
    assert(last.args and last.args[1] == 0,
      "Expected setValue(0), got args[1]=" .. tostring(last.args and last.args[1]))
  end
)

-- ============================================================
-- setShadeLevel: partially open for mid values
-- ============================================================

test.register_coroutine_test(
  "Blind - setShadeLevel(75) emits partially_open and shadeLevel(75)",
  function()
    test.socket.capability:__queue_receive({
      mock_child_blind.id,
      { capability = "windowShadeLevel", component = "main", command = "setShadeLevel",
        args = { 75 } }
    })

    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShade.windowShade.partially_open())
    )
    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShadeLevel.shadeLevel(75))
    )
  end
)

test.register_coroutine_test(
  "Blind - setShadeLevel(75) calls setValue(75)",
  function()
    test.socket.capability:__queue_receive({
      mock_child_blind.id,
      { capability = "windowShadeLevel", component = "main", command = "setShadeLevel",
        args = { 75 } }
    })

    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShade.windowShade.partially_open())
    )
    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShadeLevel.shadeLevel(75))
    )

    test.wait_for_events()

    assert(#mock_sync.calls >= 1,
      "Expected a sync call, got: " .. tostring(#mock_sync.calls))
    local last = mock_sync.calls[#mock_sync.calls]
    assert(last.action_name == "setValue",
      "Expected setValue, got: " .. tostring(last.action_name))
    assert(last.args and last.args[1] == 75,
      "Expected setValue(75), got: " .. tostring(last.args and last.args[1]))
  end
)

-- ============================================================
-- setShadeLevel edge: 0 → closed, 99 → open
-- ============================================================

test.register_coroutine_test(
  "Blind - setShadeLevel(0) emits closed state",
  function()
    test.socket.capability:__queue_receive({
      mock_child_blind.id,
      { capability = "windowShadeLevel", component = "main", command = "setShadeLevel",
        args = { 0 } }
    })

    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShade.windowShade.closed())
    )
    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShadeLevel.shadeLevel(0))
    )
  end
)

test.register_coroutine_test(
  "Blind - setShadeLevel(99) emits open state",
  function()
    test.socket.capability:__queue_receive({
      mock_child_blind.id,
      { capability = "windowShadeLevel", component = "main", command = "setShadeLevel",
        args = { 99 } }
    })

    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShade.windowShade.open())
    )
    test.socket.capability:__expect_send(
      mock_child_blind:generate_test_message(
        "main", capabilities.windowShadeLevel.shadeLevel(99))
    )
  end
)

test.run_registered_tests()
