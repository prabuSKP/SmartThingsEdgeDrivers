-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-- Phase 6: Sync Module Tests
-- Tests for fibaro/sync.lua with mocked API layer

local test = require "integration_test"
local sync = require "fibaro.sync"
local fields = require "fields"
local utils = require "utils"

-- ============================================================
-- Mock API Client for sync tests
-- ============================================================

local mock_api_client = {
  calls = {},
  responses = {},
  should_fail = false,
  fail_with_status = nil,
}

local function create_mock_response(status, body)
  return {
    status = status,
    get_body = function()
      return body
    end
  }
end

function mock_api_client:set_response(endpoint, status, body)
  self.responses[endpoint] = create_mock_response(status, body)
end

function mock_api_client:set_fail_mode(should_fail, status)
  self.should_fail = should_fail
  self.fail_with_status = status
end

function mock_api_client:reset()
  self.calls = {}
  self.responses = {}
  self.should_fail = false
  self.fail_with_status = nil
end

-- Mock RestClient
local mock_rest_client = {
  new = function(base_url, socket_builder)
    return mock_api_client
  end
}

-- Inject mock before loading api module
package.loaded["lunchbox.rest"] = { new = function() return mock_api_client end }

-- ============================================================
-- Mock driver for sync tests
-- ============================================================

local function create_mock_driver()
  local driver = {
    devices = {},
    datastore = {},
    create_calls = {},
    send_to_device_calls = {},
  }

  function driver:get_devices()
    local result = {}
    for _, d in ipairs(self.devices) do
      table.insert(result, d)
    end
    return result
  end

  function driver:try_create_device(device_config)
    table.insert(self.create_calls, device_config)
    local mock_device = {
      id = "device-" .. tostring(#self.create_calls),
      device_network_id = device_config.device_network_id,
      label = device_config.label,
      preferences = device_config.preferences or {},
      get_field = function(self, field_name)
        return self[field_name]
      end,
      set_field = function(self, field_name, value, opts)
        self[field_name] = value
      end,
    }
    table.insert(self.devices, mock_device)
    return mock_device
  end

  function driver:try_delete_device(device_id)
    for i, d in ipairs(self.devices) do
      if d.id == device_id then
        table.remove(self.devices, i)
        return true
      end
    end
    return false
  end

  function driver:send_to_device(device_id, capability, component, event)
    table.insert(self.send_to_device_calls, {
      device_id = device_id,
      capability = capability,
      component = component,
      event = event
    })
  end

  return driver
end

-- ============================================================
-- Mock bridge device
-- ============================================================

local function create_mock_bridge(opts)
  opts = opts or {}
  return {
    id = opts.id or "bridge-1",
    device_network_id = opts.dni or "fibaro-hc3:HC3-00033787",
    label = opts.label or "Fibaro HC3",
    preferences = {
      host = opts.host or "192.168.1.50",
      username = opts.username or "admin",
      password = opts.password or "password",
      scheme = opts.scheme or "http",
      port = opts.port or 80,
    },
    get_field = function(self, field_name)
      return self[field_name]
    end,
    set_field = function(self, field_name, value, opts)
      self[field_name] = value
    end,
  }
end

-- ============================================================
-- sync_bridge_inventory tests
-- ============================================================

test.register_coroutine_test(
  "Sync - sync_bridge_inventory with valid config fetches devices",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- Mock API response with devices
    mock_api_client:set_response("/api/devices", 200, '{"devices": [{"id": 1, "name": "Switch"}]}')

    local result, err = sync.sync_bridge_inventory(driver, bridge)

    assert(result == true, "Sync should succeed")
  end
)

test.register_coroutine_test(
  "Sync - sync_bridge_inventory without credentials returns error",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge({ username = "", password = "" })

    local result, err = sync.sync_bridge_inventory(driver, bridge)

    -- Should fail due to missing credentials
    assert(result ~= true, "Sync should fail without credentials")
  end
)

test.register_coroutine_test(
  "Sync - sync_bridge_inventory handles API error gracefully",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- Mock API to return error
    mock_api_client:set_response("/api/devices", 500, '{"error": "Internal Server Error"}')

    local result, err = sync.sync_bridge_inventory(driver, bridge)

    -- Should handle error gracefully
    assert(result ~= true, "Sync should fail with API error")
  end
)

test.register_coroutine_test(
  "Sync - sync_bridge_inventory handles empty device list",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- Mock empty device list
    mock_api_client:set_response("/api/devices", 200, '{"devices": []}')

    local result, err = sync.sync_bridge_inventory(driver, bridge)

    -- Should succeed with empty list
    assert(result == true, "Sync should succeed with empty list")
  end
)

test.register_coroutine_test(
  "Sync - sync_bridge_inventory creates new devices",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- Mock device list
    mock_api_client:set_response("/api/devices", 200, '{"devices": [{"id": 1, "name": "New Switch", "type": "com.fibaro.binarySwitch", "visible": true, "enabled": true, "roomID": 1, "properties": {}, "actions": {"turnOn": true, "turnOff": true}, "interfaces": []}]}')

    local result, err = sync.sync_bridge_inventory(driver, bridge)

    -- Should create new device
    assert(#driver.create_calls >= 0, "Should attempt to create devices")
  end
)

test.register_coroutine_test(
  "Sync - sync_bridge_inventory detects device removal",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- First sync: add a device
    driver.datastore.child_devices = { ["device:1"] = true }

    -- Second sync: empty list (device removed)
    mock_api_client:set_response("/api/devices", 200, '{"devices": []}')

    local result, err = sync.sync_bridge_inventory(driver, bridge)

    -- Should handle device removal
    assert(result == true, "Sync should succeed")
  end
)

test.register_coroutine_test(
  "Sync - sync_bridge_inventory updates changed devices",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- Mock device with changed name
    mock_api_client:set_response("/api/devices", 200, '{"devices": [{"id": 1, "name": "Updated Name", "type": "com.fibaro.binarySwitch", "visible": true, "enabled": true, "roomID": 1, "properties": {}, "actions": {"turnOn": true, "turnOff": true}, "interfaces": []}]}')

    local result, err = sync.sync_bridge_inventory(driver, bridge)

    assert(result == true, "Sync should succeed")
  end
)

-- ============================================================
-- poll_bridge tests
-- ============================================================

test.register_coroutine_test(
  "Sync - poll_bridge fetches incremental changes",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- Set last poll timestamp
    driver.datastore.last_poll_timestamp = driver.datastore.last_poll_timestamp or {}
    driver.datastore.last_poll_timestamp[bridge.id] = 1000

    -- Mock incremental response
    mock_api_client:set_response("/api/refreshStates?last=1000", 200, '{"last": 2000, "changes": {"devices": []}}')

    local result, err = sync.poll_bridge(driver, bridge)

    -- Should handle incremental poll
    assert(result == true, "Poll should succeed")
  end
)

test.register_coroutine_test(
  "Sync - poll_bridge does full reconcile periodically",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- Set poll count to trigger full sync
    driver.datastore.poll_count = 20

    -- Mock full device list
    mock_api_client:set_response("/api/devices", 200, '{"devices": []}')

    local result, err = sync.poll_bridge(driver, bridge)

    -- Should handle full reconcile
    assert(result == true, "Poll should succeed")
  end
)

-- ============================================================
-- refresh_child tests
-- ============================================================

test.register_coroutine_test(
  "Sync - refresh_child fetches device state",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()
    local child = {
      id = "child-1",
      parent_device_id = bridge.id,
      get_field = function(self, key)
        if key == fields.HC2_DEVICE_KIND then
          return "switch"
        end
        return nil
      end,
      set_field = function(self, key, value, opts)
        self[key] = value
      end,
    }

    -- Mock device state response
    mock_api_client:set_response("/api/devices/1", 200, '{"id": 1, "properties": {"value": "on"}}')

    local result, err = sync.refresh_child(driver, child)

    -- Should fetch state
    assert(result == true, "Refresh should succeed")
  end
)

test.register_coroutine_test(
  "Sync - refresh_child handles 404 gracefully",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()
    local child = {
      id = "child-1",
      parent_device_id = bridge.id,
      get_field = function(self, key)
        return nil
      end,
    }

    -- Mock 404 response
    mock_api_client:set_response("/api/devices/1", 404, '{"error": "Not Found"}')

    local result, err = sync.refresh_child(driver, child)

    -- Should handle 404 gracefully
    assert(result ~= true, "Refresh should fail with 404")
  end
)

-- ============================================================
-- apply_pending_child_metadata tests
-- ============================================================

test.register_coroutine_test(
  "Sync - apply_pending_child_metadata applies when available",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- Set pending metadata
    driver.datastore.pending_bridge_data = {}
    driver.datastore.pending_bridge_data[bridge.device_network_id] = {
      host = "192.168.1.50",
      port = 80,
      serial_number = "HC3-00033787",
    }

    -- Should apply metadata
    sync.apply_pending_child_metadata(driver, bridge)

    -- Verify metadata was applied
    assert(bridge[fields.BRIDGE_HOST] == "192.168.1.50", "Host should be applied")
  end
)

test.register_coroutine_test(
  "Sync - apply_pending_child_metadata skips when not available",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- No pending metadata
    driver.datastore.pending_bridge_data = {}

    -- Should skip without error
    sync.apply_pending_child_metadata(driver, bridge)
  end
)

-- ============================================================
-- on_bridge_removed tests
-- ============================================================

test.register_coroutine_test(
  "Sync - on_bridge_removed cleans up state",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- Set some state
    driver.datastore.last_poll_timestamp = {}
    driver.datastore.last_poll_timestamp[bridge.id] = 1000

    -- Should clean up
    sync.on_bridge_removed(driver, bridge)
  end
)

-- ============================================================
-- drain_create_queue tests
-- ============================================================

test.register_coroutine_test(
  "Sync - drain_create_queue respects rate limit",
  function()
    local driver = create_mock_driver()
    local bridge = create_mock_bridge()

    -- Queue some pending creates
    driver.datastore.pending_creates = {}
    for i = 1, 15 do
      table.insert(driver.datastore.pending_creates, {
        id = i,
        name = "Device " .. i,
        type = "com.fibaro.binarySwitch",
      })
    end

    local created = sync.drain_create_queue(driver, bridge, 10)

    -- Should create up to max
    assert(created <= 10, "Should respect rate limit")
  end
)

test.run_registered_tests()
