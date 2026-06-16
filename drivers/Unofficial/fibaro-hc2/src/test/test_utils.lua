-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local test = require "integration_test"
local utils = require "utils"

local function test_init() end
test.set_test_init_function(test_init)

-- ============================================================
-- safe_tonumber
-- ============================================================

test.register_coroutine_test(
  "Utils - safe_tonumber: integer value returns as-is",
  function()
    assert(utils.safe_tonumber(42) == 42, "Number should return as-is")
  end
)

test.register_coroutine_test(
  "Utils - safe_tonumber: string number converts to number",
  function()
    assert(utils.safe_tonumber("42") == 42, "String number should convert")
  end
)

test.register_coroutine_test(
  "Utils - safe_tonumber: decimal string converts to float",
  function()
    assert(utils.safe_tonumber("3.14") == 3.14, "Decimal string should convert")
  end
)

test.register_coroutine_test(
  "Utils - safe_tonumber: nil returns nil",
  function()
    assert(utils.safe_tonumber(nil) == nil, "Nil should return nil")
  end
)

test.register_coroutine_test(
  "Utils - safe_tonumber: empty string returns nil",
  function()
    assert(utils.safe_tonumber("") == nil, "Empty string should return nil")
  end
)

test.register_coroutine_test(
  "Utils - safe_tonumber: non-numeric string returns nil",
  function()
    assert(utils.safe_tonumber("abc") == nil, "Invalid string should return nil")
  end
)

-- ============================================================
-- clamp
-- ============================================================

test.register_coroutine_test(
  "Utils - clamp: value within range stays unchanged",
  function()
    assert(utils.clamp(50, 0, 100) == 50, "Value in range should stay")
  end
)

test.register_coroutine_test(
  "Utils - clamp: value below min clamps to min",
  function()
    assert(utils.clamp(-10, 0, 100) == 0, "Value below min should clamp to min")
  end
)

test.register_coroutine_test(
  "Utils - clamp: value above max clamps to max",
  function()
    assert(utils.clamp(150, 0, 100) == 100, "Value above max should clamp to max")
  end
)

test.register_coroutine_test(
  "Utils - clamp: value equal to min stays at min",
  function()
    assert(utils.clamp(0, 0, 100) == 0, "Value at min boundary should stay")
  end
)

test.register_coroutine_test(
  "Utils - clamp: value equal to max stays at max",
  function()
    assert(utils.clamp(100, 0, 100) == 100, "Value at max boundary should stay")
  end
)

-- ============================================================
-- trim
-- ============================================================

test.register_coroutine_test(
  "Utils - trim: removes leading and trailing whitespace",
  function()
    assert(utils.trim("  hello  ") == "hello", "Should trim spaces")
  end
)

test.register_coroutine_test(
  "Utils - trim: string without spaces returns unchanged",
  function()
    assert(utils.trim("hello") == "hello", "No spaces should stay same")
  end
)

test.register_coroutine_test(
  "Utils - trim: non-string returns as-is",
  function()
    assert(utils.trim(123) == 123, "Non-string should return as-is")
  end
)

-- ============================================================
-- value_is_truthy
-- ============================================================

test.register_coroutine_test(
  "Utils - value_is_truthy: boolean true is truthy",
  function()
    assert(utils.value_is_truthy(true) == true, "Boolean true is truthy")
  end
)

test.register_coroutine_test(
  "Utils - value_is_truthy: boolean false is not truthy",
  function()
    assert(utils.value_is_truthy(false) == false, "Boolean false is not truthy")
  end
)

test.register_coroutine_test(
  "Utils - value_is_truthy: non-zero number is truthy",
  function()
    assert(utils.value_is_truthy(1) == true, "Non-zero number is truthy")
  end
)

test.register_coroutine_test(
  "Utils - value_is_truthy: zero is not truthy",
  function()
    assert(utils.value_is_truthy(0) == false, "Zero is not truthy")
  end
)

test.register_coroutine_test(
  "Utils - value_is_truthy: string 'true' is truthy",
  function()
    assert(utils.value_is_truthy("true") == true, "String 'true' is truthy")
  end
)

test.register_coroutine_test(
  "Utils - value_is_truthy: string 'on' is truthy",
  function()
    assert(utils.value_is_truthy("on") == true, "String 'on' is truthy")
  end
)

test.register_coroutine_test(
  "Utils - value_is_truthy: string 'open' is truthy",
  function()
    assert(utils.value_is_truthy("open") == true, "String 'open' is truthy")
  end
)

test.register_coroutine_test(
  "Utils - value_is_truthy: string 'active' is truthy",
  function()
    assert(utils.value_is_truthy("active") == true, "String 'active' is truthy")
  end
)

test.register_coroutine_test(
  "Utils - value_is_truthy: string 'false' is not truthy",
  function()
    assert(utils.value_is_truthy("false") == false, "String 'false' is not truthy")
  end
)

test.register_coroutine_test(
  "Utils - value_is_truthy: nil is not truthy",
  function()
    assert(utils.value_is_truthy(nil) == false, "Nil is not truthy")
  end
)

-- ============================================================
-- sanitize_host
-- ============================================================

test.register_coroutine_test(
  "Utils - sanitize_host: strips http scheme and extracts port",
  function()
    local host, port = utils.sanitize_host("http://192.168.1.50:8080")
    assert(host == "192.168.1.50", "Should strip scheme, got: " .. tostring(host))
    assert(port == 8080, "Should extract port, got: " .. tostring(port))
  end
)

test.register_coroutine_test(
  "Utils - sanitize_host: strips trailing slash and returns nil port",
  function()
    local host, port = utils.sanitize_host("192.168.1.50/")
    assert(host == "192.168.1.50", "Should strip trailing slash, got: " .. tostring(host))
    assert(port == nil, "No port should return nil, got: " .. tostring(port))
  end
)

test.register_coroutine_test(
  "Utils - sanitize_host: trims surrounding whitespace",
  function()
    local host, port = utils.sanitize_host("  192.168.1.50  ")
    assert(host == "192.168.1.50", "Should trim whitespace, got: " .. tostring(host))
    assert(port == nil, "No port should return nil")
  end
)

test.register_coroutine_test(
  "Utils - sanitize_host: strips https scheme",
  function()
    local host, port = utils.sanitize_host("https://192.168.1.100")
    assert(host == "192.168.1.100", "Should strip https scheme, got: " .. tostring(host))
  end
)

-- ============================================================
-- hostname_for_serial
-- ============================================================

test.register_coroutine_test(
  "Utils - hostname_for_serial: bare serial gets hc3- prefix and .local suffix",
  function()
    local result = utils.hostname_for_serial("00033787")
    assert(result == "hc3-00033787.local",
      "Should build HC3 hostname, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - hostname_for_serial: prefixed serial preserves prefix",
  function()
    local result = utils.hostname_for_serial("hc3-00033787")
    assert(result == "hc3-00033787.local",
      "Should preserve prefix, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - hostname_for_serial: uppercase HC3L is lowercased",
  function()
    local result = utils.hostname_for_serial("HC3L-12345")
    assert(result == "hc3l-12345.local",
      "Should lowercase HC3L, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - hostname_for_serial: empty string returns nil",
  function()
    local result = utils.hostname_for_serial("")
    assert(result == nil, "Empty serial should return nil, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - hostname_for_serial: nil returns nil",
  function()
    local result = utils.hostname_for_serial(nil)
    assert(result == nil, "Nil serial should return nil, got: " .. tostring(result))
  end
)

-- ============================================================
-- child_key_for_id / device_id_from_child_key
-- ============================================================

test.register_coroutine_test(
  "Utils - child_key_for_id: formats numeric ID",
  function()
    assert(utils.child_key_for_id(42) == "device:42", "Should format numeric ID")
  end
)

test.register_coroutine_test(
  "Utils - child_key_for_id: formats string ID",
  function()
    assert(utils.child_key_for_id("abc") == "device:abc", "Should format string ID")
  end
)

test.register_coroutine_test(
  "Utils - device_id_from_child_key: extracts numeric ID",
  function()
    local result = utils.device_id_from_child_key("device:42")
    assert(result == 42, "Should extract numeric ID, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - device_id_from_child_key: returns string when not numeric",
  function()
    local result = utils.device_id_from_child_key("device:abc")
    assert(result == "abc", "Should extract string ID, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - device_id_from_child_key: returns nil for invalid key",
  function()
    local result = utils.device_id_from_child_key("invalid")
    assert(result == nil, "Invalid key should return nil, got: " .. tostring(result))
  end
)

-- ============================================================
-- is_bridge
-- ============================================================

test.register_coroutine_test(
  "Utils - is_bridge: device without parent_assigned_child_key is bridge",
  function()
    local bridge = { parent_assigned_child_key = nil }
    assert(utils.is_bridge(bridge) == true, "Device without child key should be bridge")
  end
)

test.register_coroutine_test(
  "Utils - is_bridge: device with parent_assigned_child_key is not bridge",
  function()
    local child = { parent_assigned_child_key = "device:1" }
    assert(utils.is_bridge(child) == false, "Device with child key should not be bridge")
  end
)

-- ============================================================
-- controller_kind_from_info
-- ============================================================

test.register_coroutine_test(
  "Utils - controller_kind_from_info: HC3 platform returns hc3",
  function()
    local result = utils.controller_kind_from_info({ platform = "HC3" })
    assert(result == "hc3", "HC3 platform should return hc3, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - controller_kind_from_info: HC2 platform returns hc2",
  function()
    local result = utils.controller_kind_from_info({ platform = "HC2" })
    assert(result == "hc2", "HC2 platform should return hc2, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - controller_kind_from_info: HC3 serial returns hc3",
  function()
    local result = utils.controller_kind_from_info({ serialNumber = "HC3-00033787" })
    assert(result == "hc3", "HC3 serial should return hc3, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - controller_kind_from_info: HC2 serial returns hc2",
  function()
    local result = utils.controller_kind_from_info({ serialNumber = "HC2-00012345" })
    assert(result == "hc2", "HC2 serial should return hc2, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - controller_kind_from_info: nil returns nil",
  function()
    local result = utils.controller_kind_from_info(nil)
    assert(result == nil, "Nil info should return nil, got: " .. tostring(result))
  end
)

-- ============================================================
-- api_version_for_serial
-- ============================================================

test.register_coroutine_test(
  "Utils - api_version_for_serial: HC3 serial returns version 5",
  function()
    local result = utils.api_version_for_serial("HC3-12345")
    assert(result == 5, "HC3 serial should return version 5, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - api_version_for_serial: HC2 serial returns version 4",
  function()
    local result = utils.api_version_for_serial("HC2-12345")
    assert(result == 4, "HC2 serial should return version 4, got: " .. tostring(result))
  end
)

test.register_coroutine_test(
  "Utils - api_version_for_serial: unknown serial returns nil",
  function()
    local result = utils.api_version_for_serial("UNKNOWN-12345")
    assert(result == nil, "Unknown serial should return nil, got: " .. tostring(result))
  end
)

test.run_registered_tests()
