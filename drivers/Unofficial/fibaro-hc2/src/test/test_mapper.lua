-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local test = require "integration_test"
local mapper = require "fibaro.mapper"

-- Room lookup table used across all tests
local rooms = {
  [1] = "Living Room",
  [2] = "Bedroom",
  [3] = "Kitchen",
}

local function test_init() end
test.set_test_init_function(test_init)

-- ============================================================
-- SWITCH mapping (actions: turnOn + turnOff, no setValue)
-- ============================================================

test.register_coroutine_test(
  "Mapper - switch device maps to kind=switch with fibaro-switch profile",
  function()
    local device = {
      id = 10,
      label = "Light Switch",
      type = "com.fibaro.binarySwitch",
      actions = { turnOn = true, turnOff = true },
      interfaces = {},
      value = false,
      room_id = 1,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "switch", "Kind should be switch, got: " .. tostring(mapped.kind))
    assert(mapped.profile == "fibaro-switch", "Profile should be fibaro-switch, got: " .. tostring(mapped.profile))
  end
)

test.register_coroutine_test(
  "Mapper - switch label includes room name",
  function()
    local device = {
      id = 10,
      label = "Living Room Light",
      type = "com.fibaro.binarySwitch",
      actions = { turnOn = true, turnOff = true },
      interfaces = {},
      value = false,
      room_id = 1,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.label:find("Living Room") ~= nil,
      "Label should include room name, got: " .. tostring(mapped.label))
  end
)

-- ============================================================
-- DIMMER mapping (has setValue action - wins over turnOn/turnOff)
-- ============================================================

test.register_coroutine_test(
  "Mapper - dimmer device with setValue maps to kind=dimmer",
  function()
    local device = {
      id = 11,
      label = "Dimmer Light",
      type = "com.fibaro.multilevelSwitch",
      actions = { turnOn = true, turnOff = true, setValue = true },
      interfaces = {},
      value = 50,
      room_id = 2,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "dimmer", "Kind should be dimmer, got: " .. tostring(mapped.kind))
    assert(mapped.profile == "fibaro-dimmer", "Profile should be fibaro-dimmer, got: " .. tostring(mapped.profile))
  end
)

-- ============================================================
-- BLIND mapping
-- ============================================================

test.register_coroutine_test(
  "Mapper - blind device by windowCovering interface maps to kind=blind",
  function()
    local device = {
      id = 12,
      label = "Living Room Blinds",
      type = "com.fibaro.rollerShutter",
      interfaces = { "windowCovering" },
      actions = {},
      value = 0,
      room_id = 1,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "blind", "Kind should be blind, got: " .. tostring(mapped.kind))
    assert(mapped.profile == "fibaro-blind", "Profile should be fibaro-blind, got: " .. tostring(mapped.profile))
  end
)

test.register_coroutine_test(
  "Mapper - blind device by rollerShutter type maps to kind=blind",
  function()
    local device = {
      id = 17,
      label = "Bedroom Blinds",
      type = "com.fibaro.rollerShutter",
      actions = { setValue = true },
      interfaces = {},
      value = 0,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "blind", "Kind should be blind, got: " .. tostring(mapped.kind))
  end
)

-- ============================================================
-- SENSOR mapping by interface
-- ============================================================

test.register_coroutine_test(
  "Mapper - smoke detector by smokeDetector interface",
  function()
    local device = {
      id = 13,
      label = "Kitchen Smoke Sensor",
      type = "com.fibaro.smokeSensor",
      interfaces = { "smokeDetector" },
      actions = {},
      value = false,
      room_id = 3,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "smoke-detector",
      "Kind should be smoke-detector, got: " .. tostring(mapped.kind))
    assert(mapped.profile == "fibaro-smoke-detector",
      "Profile should be fibaro-smoke-detector, got: " .. tostring(mapped.profile))
  end
)

test.register_coroutine_test(
  "Mapper - motion sensor by motionSensor interface",
  function()
    local device = {
      id = 14,
      label = "Motion Sensor",
      type = "com.fibaro.motionSensor",
      interfaces = { "motionSensor" },
      actions = {},
      value = false,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "motion", "Kind should be motion, got: " .. tostring(mapped.kind))
    assert(mapped.profile == "fibaro-motion",
      "Profile should be fibaro-motion, got: " .. tostring(mapped.profile))
  end
)

test.register_coroutine_test(
  "Mapper - contact sensor by contactSensor interface",
  function()
    local device = {
      id = 15,
      label = "Door Sensor",
      type = "com.fibaro.doorSensor",
      interfaces = { "contactSensor" },
      actions = {},
      value = false,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "contact", "Kind should be contact, got: " .. tostring(mapped.kind))
  end
)

test.register_coroutine_test(
  "Mapper - temperature sensor by temperatureSensor interface",
  function()
    local device = {
      id = 16,
      label = "Temp Sensor",
      type = "com.fibaro.temperatureSensor",
      interfaces = { "temperatureSensor" },
      actions = {},
      value = 21.5,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "temperature-sensor",
      "Kind should be temperature-sensor, got: " .. tostring(mapped.kind))
  end
)

test.register_coroutine_test(
  "Mapper - humidity sensor by humiditySensor interface",
  function()
    local device = {
      id = 18,
      label = "Humidity Sensor",
      type = "com.fibaro.humiditySensor",
      interfaces = { "humiditySensor" },
      actions = {},
      value = 65,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "humidity-sensor",
      "Kind should be humidity-sensor, got: " .. tostring(mapped.kind))
  end
)

test.register_coroutine_test(
  "Mapper - illuminance sensor by lightSensor interface",
  function()
    local device = {
      id = 19,
      label = "Light Sensor",
      type = "com.fibaro.lightSensor",
      interfaces = { "lightSensor" },
      actions = {},
      value = 300,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "illuminance-sensor",
      "Kind should be illuminance-sensor, got: " .. tostring(mapped.kind))
  end
)

test.register_coroutine_test(
  "Mapper - water sensor by waterSensor interface",
  function()
    local device = {
      id = 20,
      label = "Flood Sensor",
      type = "com.fibaro.floodSensor",
      interfaces = { "waterSensor" },
      actions = {},
      value = false,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "water-sensor",
      "Kind should be water-sensor, got: " .. tostring(mapped.kind))
  end
)

-- ============================================================
-- MULTI-ENDPOINT mapping
-- ============================================================

test.register_coroutine_test(
  "Mapper - double switch with 3 endpoints and light interface",
  function()
    local device = {
      id = 21,
      label = "Double Switch",
      type = "com.fibaro.FGBS222",
      interfaces = { "light" },
      actions = { turnOn = true, turnOff = true },
      is_multi_endpoint = true,
      endpoints = { "1", "2", "3" },  -- 3 items = 2 relays + parent
      value = false,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "double-switch",
      "Kind should be double-switch, got: " .. tostring(mapped.kind))
    assert(mapped.profile == "fibaro-double-switch",
      "Profile should be fibaro-double-switch, got: " .. tostring(mapped.profile))
  end
)

test.register_coroutine_test(
  "Mapper - triple switch with 4 endpoints and light interface",
  function()
    local device = {
      id = 22,
      label = "Triple Switch",
      type = "com.fibaro.FGBS223",
      interfaces = { "light" },
      actions = { turnOn = true, turnOff = true },
      is_multi_endpoint = true,
      endpoints = { "1", "2", "3", "4" },  -- 4 items = 3 relays + parent
      value = false,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "triple-switch",
      "Kind should be triple-switch, got: " .. tostring(mapped.kind))
    assert(mapped.profile == "fibaro-triple-switch",
      "Profile should be fibaro-triple-switch, got: " .. tostring(mapped.profile))
  end
)

-- ============================================================
-- METERED profiles
-- ============================================================

test.register_coroutine_test(
  "Mapper - switch with power/energy interface maps to metered profile",
  function()
    local device = {
      id = 23,
      label = "Metered Switch",
      type = "com.fibaro.multilevelSwitch",
      actions = { turnOn = true, turnOff = true },
      interfaces = { "light", "power", "energy" },
      value = false,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "switch", "Kind should be switch, got: " .. tostring(mapped.kind))
    assert(mapped.profile == "fibaro-switch-metered",
      "Profile should be metered variant, got: " .. tostring(mapped.profile))
    assert(mapped.metered == true, "Should be marked as metered")
  end
)

test.register_coroutine_test(
  "Mapper - dimmer with power/energy values maps to metered profile",
  function()
    local device = {
      id = 24,
      label = "Metered Dimmer",
      type = "com.fibaro.multilevelSwitch",
      actions = { turnOn = true, turnOff = true, setValue = true },
      interfaces = {},
      value = 75,
      power = 50.0,
      energy = 1.5,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.kind == "dimmer", "Kind should be dimmer, got: " .. tostring(mapped.kind))
    assert(mapped.profile == "fibaro-dimmer-metered",
      "Profile should be metered variant, got: " .. tostring(mapped.profile))
    assert(mapped.metered == true, "Should be marked as metered")
  end
)

-- ============================================================
-- SKIP / FILTER conditions
-- ============================================================

test.register_coroutine_test(
  "Mapper - hidden device (visible=false) returns nil with 'hidden device' error",
  function()
    local device = {
      id = 30,
      label = "Hidden Device",
      type = "com.fibaro.device",
      actions = { turnOn = true, turnOff = true },
      visible = false,
    }
    local mapped, err = mapper.map_device(device, rooms, false)
    assert(mapped == nil, "Hidden device should not be mapped")
    assert(err == "hidden device", "Error should indicate hidden device, got: " .. tostring(err))
  end
)

test.register_coroutine_test(
  "Mapper - disabled device (enabled=false) returns nil with 'disabled device' error",
  function()
    local device = {
      id = 31,
      label = "Disabled Device",
      type = "com.fibaro.device",
      actions = { turnOn = true, turnOff = true },
      enabled = false,
    }
    local mapped, err = mapper.map_device(device, rooms, false)
    assert(mapped == nil, "Disabled device should not be mapped")
    assert(err == "disabled device", "Error should indicate disabled, got: " .. tostring(err))
  end
)

test.register_coroutine_test(
  "Mapper - gateway device (is_gateway=true) returns nil with 'controller device' error",
  function()
    local device = {
      id = 32,
      label = "Gateway",
      type = "com.fibaro.device",
      actions = {},
      is_gateway = true,
    }
    local mapped, err = mapper.map_device(device, rooms, false)
    assert(mapped == nil, "Gateway should not be mapped")
    assert(err == "controller device",
      "Error should indicate controller device, got: " .. tostring(err))
  end
)

test.register_coroutine_test(
  "Mapper - invalid device payload (nil id) returns nil",
  function()
    local device = {
      label = "Invalid Device",
      type = "com.fibaro.device",
    }
    local mapped, err = mapper.map_device(device, rooms, false)
    assert(mapped == nil, "Invalid device should not be mapped")
    assert(err ~= nil, "Should return an error")
  end
)

-- ============================================================
-- DEFAULT fallback
-- ============================================================

test.register_coroutine_test(
  "Mapper - unknown device type falls back to kind=default",
  function()
    local device = {
      id = 99,
      label = "Unknown Device",
      type = "com.fibaro.unknownType",
      actions = {},
      interfaces = {},
      value = nil,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Unknown device should get default mapping")
    assert(mapped.kind == "default", "Kind should be default, got: " .. tostring(mapped.kind))
    assert(mapped.profile == "fibaro-default",
      "Profile should be fibaro-default, got: " .. tostring(mapped.profile))
  end
)

-- ============================================================
-- Mapped result structure
-- ============================================================

test.register_coroutine_test(
  "Mapper - result contains required fields",
  function()
    local device = {
      id = 50,
      label = "Test Device",
      type = "com.fibaro.binarySwitch",
      actions = { turnOn = true, turnOff = true },
      interfaces = {},
      value = true,
      room_id = 2,
    }
    local mapped = mapper.map_device(device, rooms, false)
    assert(mapped ~= nil, "Device should be mapped")
    assert(mapped.id == 50, "Should preserve device id")
    assert(mapped.key == "device:50", "Key should be device:50")
    assert(mapped.room_id == 2, "Should preserve room_id")
    assert(type(mapped.label) == "string", "Label should be a string")
  end
)

test.run_registered_tests()
