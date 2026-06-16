-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-- Phase 4: Discovery Provider Tests
-- Tests for discovery_provider.lua and fibaro_finder.lua

local test = require "integration_test"
local discovery_provider = require "discovery_provider"
local fibaro_finder = require "fibaro_finder"
local utils = require "utils"

-- ============================================================
-- Mock socket for fibaro_finder tests
-- ============================================================

local mock_socket = {
  udp_calls = 0,
  send_calls = {},
  receive_calls = {},
}

local function create_mock_udp_socket()
  local sock = {
    closed = false,
    responses = {},
    current_response = 1,
  }

  function sock:setsockname(addr, port)
    return true, nil
  end

  function sock:setoption(option, value)
    if option == "broadcast" then
      return true, nil
    end
    return false, "unsupported option"
  end

  function sock:sendto(data, target, port)
    table.insert(mock_socket.send_calls, {
      data = data,
      target = target,
      port = port
    })
    return true, nil
  end

  function sock:settimeout(timeout)
    return true
  end

  function sock:receivefrom()
    if self.current_response <= #self.responses then
      local resp = self.responses[self.current_response]
      self.current_response = self.current_response + 1
      return resp.payload, resp.ip, resp.port
    end
    return nil, "timeout"
  end

  function sock:close()
    self.closed = true
  end

  function sock:add_response(payload, ip, port)
    table.insert(self.responses, {
      payload = payload,
      ip = ip,
      port = port
    })
  end

  return sock
end

mock_socket.udp = function()
  mock_socket.udp_calls = mock_socket.udp_calls + 1
  return create_mock_udp_socket()
end

-- ============================================================
-- Test utilities
-- ============================================================

local function reset_mock_socket()
  mock_socket.udp_calls = 0
  mock_socket.send_calls = {}
  mock_socket.receive_calls = {}
end

local function set_mock_socket(finder)
  finder._socket = mock_socket
end

local function restore_real_socket(finder)
  finder._socket = require "cosock.socket"
end

-- ============================================================
-- fibaro_finder.scan tests
-- ============================================================

test.register_coroutine_test(
  "Discovery - fibaro_finder.scan with successful response returns candidate",
  function()
    reset_mock_socket()
    set_mock_socket(fibaro_finder)

    local mock_sock = mock_socket.udp()
    -- Simulate a successful HC3 response
    mock_sock:add_response('{"serialNumber": "HC3-00033787", "platform": "HC3"}', "192.168.1.50", 44444)

    local driver = {}
    local candidates = fibaro_finder.scan(driver, 0.5)

    assert(#candidates == 1, "Should find 1 candidate, got: " .. tostring(#candidates))
    assert(candidates[1].serial_number == "HC3-00033787",
      "Serial should match, got: " .. tostring(candidates[1].serial_number))
    assert(candidates[1].host == "192.168.1.50",
      "Host should match, got: " .. tostring(candidates[1].host))
    assert(candidates[1].controller_kind == "hc3",
      "Controller kind should be hc3, got: " .. tostring(candidates[1].controller_kind))
  end
)

test.register_coroutine_test(
  "Discovery - fibaro_finder.scan with no response returns empty table",
  function()
    reset_mock_socket()
    set_mock_socket(fibaro_finder)

    local mock_sock = mock_socket.udp()
    -- No responses added - socket will return timeout

    local driver = {}
    local candidates = fibaro_finder.scan(driver, 0.3)

    assert(#candidates == 0, "Should find 0 candidates, got: " .. tostring(#candidates))
    assert(mock_socket.udp_calls >= 1, "Should create UDP socket")
  end
)

test.register_coroutine_test(
  "Discovery - fibaro_finder.scan sends probe to correct port",
  function()
    reset_mock_socket()
    set_mock_socket(fibaro_finder)

    local mock_sock = mock_socket.udp()

    local driver = {}
    local candidates = fibaro_finder.scan(driver, 0.3)

    -- Verify probe was sent to port 44444
    local found_probe = false
    for _, call in ipairs(mock_socket.send_calls) do
      if call.port == 44444 and call.data == "discover" then
        found_probe = true
        break
      end
    end
    assert(found_probe, "Should send probe to port 44444")
  end
)

test.register_coroutine_test(
  "Discovery - fibaro_finder.scan with JSON response parses correctly",
  function()
    reset_mock_socket()
    set_mock_socket(fibaro_finder)

    local mock_sock = mock_socket.udp()
    -- Simulate JSON response with all fields
    mock_sock:add_response(
      '{"serialNumber": "HC3-12345", "platform": "HC3", "ip": "10.0.0.100", "hcName": "MyHC3"}',
      "10.0.0.100",
      44444
    )

    local driver = {}
    local candidates = fibaro_finder.scan(driver, 0.5)

    assert(#candidates == 1, "Should find 1 candidate")
    assert(candidates[1].serial_number == "HC3-12345",
      "Serial should match, got: " .. tostring(candidates[1].serial_number))
    assert(candidates[1].label == "Fibaro HC3-12345",
      "Label should include serial, got: " .. tostring(candidates[1].label))
    assert(candidates[1].host == "10.0.0.100",
      "Host should match, got: " .. tostring(candidates[1].host))
  end
)

test.register_coroutine_test(
  "Discovery - fibaro_finder.scan with text response extracts serial",
  function()
    reset_mock_socket()
    set_mock_socket(fibaro_finder)

    local mock_sock = mock_socket.udp()
    -- Simulate text response with HC3 serial pattern
    mock_sock:add_response("ACK HC3-99999 192.168.1.100", "192.168.1.100", 44444)

    local driver = {}
    local candidates = fibaro_finder.scan(driver, 0.5)

    assert(#candidates == 1, "Should find 1 candidate")
    assert(candidates[1].serial_number == "HC3-99999",
      "Serial should be extracted from text, got: " .. tostring(candidates[1].serial_number))
  end
)

test.register_coroutine_test(
  "Discovery - fibaro_finder.scan deduplicates by source IP",
  function()
    reset_mock_socket()
    set_mock_socket(fibaro_finder)

    local mock_sock = mock_socket.udp()
    -- Same IP, multiple responses
    mock_sock:add_response('{"serialNumber": "HC3-001"}', "192.168.1.50", 44444)
    mock_sock:add_response('{"serialNumber": "HC3-001"}', "192.168.1.50", 44444)
    mock_sock:add_response('{"serialNumber": "HC3-001"}', "192.168.1.50", 44444)

    local driver = {}
    local candidates = fibaro_finder.scan(driver, 0.5)

    assert(#candidates == 1, "Should deduplicate to 1 candidate, got: " .. tostring(#candidates))
  end
)

test.register_coroutine_test(
  "Discovery - fibaro_finder.scan with multiple IPs returns multiple candidates",
  function()
    reset_mock_socket()
    set_mock_socket(fibaro_finder)

    local mock_sock = mock_socket.udp()
    -- Different IPs
    mock_sock:add_response('{"serialNumber": "HC3-001"}', "192.168.1.50", 44444)
    mock_sock:add_response('{"serialNumber": "HC3-002"}', "192.168.1.51", 44444)

    local driver = {}
    local candidates = fibaro_finder.scan(driver, 0.5)

    assert(#candidates == 2, "Should find 2 candidates, got: " .. tostring(#candidates))
  end
)

-- ============================================================
-- discovery_provider.build_manual_bridge tests
-- ============================================================

test.register_coroutine_test(
  "Discovery - build_manual_bridge returns placeholder with correct DNI",
  function()
    local bridge = discovery_provider.build_manual_bridge()

    assert(bridge ~= nil, "Should return a bridge")
    assert(bridge.device_network_id == discovery_provider.MANUAL_BRIDGE_DNI,
      "DNI should match MANUAL_BRIDGE_DNI, got: " .. tostring(bridge.device_network_id))
    assert(bridge.label == "Fibaro HC3",
      "Label should be Fibaro HC3, got: " .. tostring(bridge.label))
    assert(bridge.host == "",
      "Host should be empty, got: " .. tostring(bridge.host))
    assert(bridge.controller_kind == "hc3",
      "Controller kind should be hc3, got: " .. tostring(bridge.controller_kind))
    assert(bridge.api_version == 5,
      "API version should be 5, got: " .. tostring(bridge.api_version))
  end
)

test.register_coroutine_test(
  "Discovery - build_manual_bridge has correct discovery source",
  function()
    local bridge = discovery_provider.build_manual_bridge()

    assert(bridge.discovery_source == discovery_provider.METHOD.MANUAL,
      "Discovery source should be manual, got: " .. tostring(bridge.discovery_source))
  end
)

-- ============================================================
-- discovery_provider.discover_via_finder tests
-- ============================================================

test.register_coroutine_test(
  "Discovery - discover_via_finder wraps finder results with discovery source",
  function()
    reset_mock_socket()
    set_mock_socket(fibaro_finder)

    local mock_sock = mock_socket.udp()
    mock_sock:add_response('{"serialNumber": "HC3-TEST"}', "192.168.1.50", 44444)

    local driver = {}
    local devices = discovery_provider.discover_via_finder(driver)

    assert(#devices > 0, "Should find at least 1 device")
    assert(devices[1].discovery_source == discovery_provider.METHOD.FINDER,
      "Discovery source should be fibaro_finder, got: " .. tostring(devices[1].discovery_source))
  end
)

test.run_registered_tests()
