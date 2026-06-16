-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local test = require "integration_test"
local adapter = require "fibaro.adapter"
local hc2 = require "fibaro.adapters.hc2"
local hc3 = require "fibaro.adapters.hc3"

-- ============================================================
-- adapter.for_name tests
-- ============================================================

test.register_coroutine_test(
  "Adapter - for_name returns correct adapter",
  function()
    assert(adapter.for_name("hc2") == hc2, "Should return hc2 adapter")
    assert(adapter.for_name("hc3") == hc3, "Should return hc3 adapter")
    assert(adapter.for_name("unknown") == nil, "Should return nil for unknown")
  end
)

-- ============================================================
-- adapter.default_for_scheme tests
-- ============================================================

test.register_coroutine_test(
  "Adapter - default_for_scheme returns correct adapter",
  function()
    assert(adapter.default_for_scheme("https") == hc3, "Should return hc3 for https")
    assert(adapter.default_for_scheme("http") == hc2, "Should return hc2 for http")
    assert(adapter.default_for_scheme(nil) == hc2, "Should return hc2 as default")
  end
)

-- ============================================================
-- adapter.for_info tests
-- ============================================================

test.register_coroutine_test(
  "Adapter - for_info detects by platform",
  function()
    local info = { platform = "HC3", serialNumber = "HC3-00033787" }
    assert(adapter.for_info(info, "http") == hc3, "Should return hc3 for HC3 platform")
    
    info = { platform = "HC3L", serialNumber = "HC3L-12345" }
    assert(adapter.for_info(info, "http") == hc3, "Should return hc3 for HC3L platform")
    
    info = { platform = "HC2", serialNumber = "HC2-00012345" }
    assert(adapter.for_info(info, "http") == hc2, "Should return hc2 for HC2 platform")
    
    info = { platform = "HCL", serialNumber = "HCL-12345" }
    assert(adapter.for_info(info, "http") == hc2, "Should return hc2 for HCL platform")
  end
)

test.register_coroutine_test(
  "Adapter - for_info detects by serial prefix",
  function()
    local info = { platform = "Unknown", serialNumber = "YH-12345" }
    assert(adapter.for_info(info, "http") == hc3, "Should return hc3 for YH serial")
    
    info = { platform = "Unknown", serialNumber = "HC2-12345" }
    assert(adapter.for_info(info, "http") == hc2, "Should return hc2 for HC2 serial")
    
    info = { platform = "Unknown", serialNumber = "HC3-12345" }
    assert(adapter.for_info(info, "http") == hc3, "Should return hc3 for HC3 serial")
  end
)

test.register_coroutine_test(
  "Adapter - for_info handles edge cases",
  function()
    local info = { platform = "Unknown", serialNumber = "UNKNOWN-12345" }
    assert(adapter.for_info(info, "https") == hc3, "Should fall back to https default")
    
    assert(adapter.for_info(nil, "http") == hc2, "Should return default for nil info")
  end
)

-- ============================================================
-- adapter.detect_devices tests
-- ============================================================

test.register_coroutine_test(
  "Adapter - detect_devices detects controller type",
  function()
    local payload = {
      devices = {
        { type = "HC3", name = "HC3" },
        { type = "com.fibaro.binarySwitch", name = "Switch" },
      }
    }
    assert(adapter.detect_devices(payload, "http") == hc3, "Should detect hc3")
    
    payload = {
      devices = {
        { type = "com.fibaro.binarySwitch", name = "Switch", interfaces = { "gateway" } },
      }
    }
    assert(adapter.detect_devices(payload, "http") == hc2, "Should detect hc2")
    
    payload = {
      devices = {
        { type = "unknown", name = "Unknown" },
      }
    }
    assert(adapter.detect_devices(payload, "https") == hc3, "Should fall back to default")
  end
)

-- ============================================================
-- hc2.is_match tests
-- ============================================================

test.register_coroutine_test(
  "HC2 Adapter - is_match detects HC2 devices",
  function()
    assert(hc2.is_match({ type = "HC2", name = "Home Center 2" }) == true,
      "Should match HC2 type")
    assert(hc2.is_match({ type = "unknown", name = "Home Center 2" }) == true,
      "Should match Home Center 2 name")
    assert(hc2.is_match({ type = "unknown", name = "Gateway", interfaces = { "gateway" } }) == true,
      "Should match gateway interface")
    assert(hc2.is_match({ type = "HC3", name = "Home Center 3" }) == false,
      "Should not match HC3")
    assert(hc2.is_match(nil) == false, "Should return false for nil")
  end
)

-- ============================================================
-- hc3.is_match tests
-- ============================================================

test.register_coroutine_test(
  "HC3 Adapter - is_match detects HC3 devices",
  function()
    assert(hc3.is_match({ type = "HC3", name = "Home Center 3" }) == true,
      "Should match HC3 type")
    assert(hc3.is_match({ type = "unknown", name = "Home Center 3" }) == true,
      "Should match Home Center 3 name")
    assert(hc3.is_match({ type = "unknown", name = "Device", modified = 123 }) == true,
      "Should match modified marker")
    assert(hc3.is_match({ type = "unknown", name = "Device", properties = { deviceRole = "Blind" } }) == true,
      "Should match deviceRole marker")
    assert(hc3.is_match({ type = "HC2", name = "Home Center 2" }) == false,
      "Should not match HC2")
    assert(hc3.is_match(nil) == false, "Should return false for nil")
  end
)

-- ============================================================
-- hc2/hc3 normalize_device_list tests
-- ============================================================

test.register_coroutine_test(
  "Adapter - normalize_device_list extracts arrays",
  function()
    local payload = { devices = { { id = 1 }, { id = 2 } } }
    assert(#hc2.normalize_device_list(payload) == 2, "HC2 should extract devices")
    assert(#hc3.normalize_device_list(payload) == 2, "HC3 should extract devices")
    
    payload = { { id = 1 }, { id = 2 } }
    assert(#hc2.normalize_device_list(payload) == 2, "HC2 should return payload directly")
    
    assert(#hc2.normalize_device_list(nil) == 0, "HC2 should return empty for nil")
  end
)

-- ============================================================
-- hc2/hc3 normalize_scene_list tests
-- ============================================================

test.register_coroutine_test(
  "Adapter - normalize_scene_list extracts arrays",
  function()
    local payload = { scenes = { { id = 1 }, { id = 2 } } }
    assert(#hc2.normalize_scene_list(payload) == 2, "HC2 should extract scenes")
    assert(#hc3.normalize_scene_list(payload) == 2, "HC3 should extract scenes")
  end
)

-- ============================================================
-- hc2.normalize_device tests
-- ============================================================

test.register_coroutine_test(
  "HC2 Adapter - normalize_device extracts fields",
  function()
    local raw = {
      id = 10,
      name = "Test Switch",
      type = "com.fibaro.binarySwitch",
      visible = true,
      enabled = true,
      properties = { value = "on", power = "50.5", energy = "1.5", dead = "true" },
      actions = { turnOn = true, turnOff = true },
      interfaces = { "gateway" },
    }
    local result = hc2.normalize_device(raw)
    assert(result.id == 10, "Should extract id")
    assert(result.label == "Test Switch", "Should extract name")
    assert(result.type == "com.fibaro.binarySwitch", "Should extract type")
    assert(result.value == "on", "Should extract value")
    assert(result.power == 50.5, "Should extract power")
    assert(result.energy == 1.5, "Should extract energy")
    assert(result.dead == true, "Should parse dead as boolean")
    assert(result.is_gateway == true, "Should detect gateway")
  end
)

test.register_coroutine_test(
  "HC2 Adapter - normalize_device detects plugin",
  function()
    local raw = {
      id = 1,
      name = "Plugin",
      type = "virtual_device",
      properties = {},
      actions = {},
      interfaces = {},
    }
    local result = hc2.normalize_device(raw)
    assert(result.is_plugin == true, "Should detect virtual_device type")
  end
)

-- ============================================================
-- hc3.normalize_device tests
-- ============================================================

test.register_coroutine_test(
  "HC3 Adapter - normalize_device extracts fields",
  function()
    local raw = {
      id = 10,
      name = "Test Switch",
      type = "com.fibaro.binarySwitch",
      visible = true,
      enabled = true,
      properties = { value = "on", state = true },
      actions = { turnOn = true, turnOff = true },
      interfaces = {},
    }
    local result = hc3.normalize_device(raw)
    assert(result.id == 10, "Should extract id")
    assert(result.label == "Test Switch", "Should extract name")
    assert(result.controller == "hc3", "Should set controller")
    assert(result.value == true, "Should extract state as value")
  end
)

test.register_coroutine_test(
  "HC3 Adapter - normalize_device handles endpoints",
  function()
    local raw = {
      id = 10,
      name = "Multi-channel",
      type = "com.fibaro.device",
      properties = {},
      actions = {},
      interfaces = {},
      endpoints = { { id = 1 }, { id = 2 }, { id = 3 } },
    }
    local result = hc3.normalize_device(raw)
    assert(#result.endpoints == 3, "Should extract endpoints")
    assert(result.is_multi_endpoint == true, "Should detect multi-endpoint")
    
    raw.endpoints = { { id = 1 } }
    result = hc3.normalize_device(raw)
    assert(result.is_multi_endpoint == false, "Single endpoint not multi-endpoint")
  end
)

-- ============================================================
-- hc2/hc3 normalize_scene tests
-- ============================================================

test.register_coroutine_test(
  "Adapter - normalize_scene extracts fields",
  function()
    local raw = { id = 5, name = "My Scene", type = "scene" }
    local result = hc2.normalize_scene(raw)
    assert(result.id == 5, "Should extract id")
    assert(result.label == "My Scene", "Should extract name")
    
    result = hc3.normalize_scene(raw)
    assert(result.id == 5, "HC3 should extract id")
    assert(result.label == "My Scene", "HC3 should extract name")
    
    assert(hc2.normalize_scene(nil) == nil, "Should return nil for nil")
  end
)

-- ============================================================
-- hc2/hc3 build_action_body tests
-- ============================================================

test.register_coroutine_test(
  "Adapter - build_action_body wraps args",
  function()
    local result = hc2.build_action_body({ arg1 = "value1" })
    assert(result.args.arg1 == "value1", "HC2 should wrap args")
    
    result = hc3.build_action_body({ arg1 = "value1" })
    assert(result.args.arg1 == "value1", "HC3 should wrap args")
    assert(result.delay == 0, "HC3 should include delay")
  end
)

-- ============================================================
-- hc2/hc3 command_refresh_attempts tests
-- ============================================================

test.register_coroutine_test(
  "Adapter - command_refresh_attempts returns correct count",
  function()
    assert(hc2.command_refresh_attempts(202) == 3, "HC2 should return 3 for 202")
    assert(hc2.command_refresh_attempts(200) == 4, "HC2 should return 4 for other")
    assert(hc3.command_refresh_attempts(202) == 3, "HC3 should return 3 for 202")
    assert(hc3.command_refresh_attempts(200) == 4, "HC3 should return 4 for other")
  end
)

test.run_registered_tests()
