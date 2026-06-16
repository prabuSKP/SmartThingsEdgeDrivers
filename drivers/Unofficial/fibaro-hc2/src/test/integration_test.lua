-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0
--
-- Local mock for SmartThings Edge Driver integration_test framework
-- This allows running unit tests outside the SmartThings Hub runtime

local integration_test = {}

-- Test storage
local registered_tests = {}
local test_init_function = nil

-- Mock socket for device lifecycle and capability
integration_test.socket = {
  device_lifecycle = {
    __queue_receive = function(self, event)
      -- Mock: just store the event
      self._last_event = event
    end,
    _last_event = nil
  },
  capability = {
    __queue_receive = function(self, event)
      self._last_event = event
    end,
    __expect_send = function(self, expected)
      -- Mock: just acknowledge
    end,
    _last_event = nil
  }
}

-- Mock device utilities
local function create_mock_device(opts)
  local device = {
    id = opts.id or "test-device-" .. tostring(os.time()),
    profile = opts.profile or {},
    parent_assigned_child_key = opts.parent_assigned_child_key,
    device_network_id = opts.device_network_id,
    parent_device_id = opts.parent_device_id,
    _fields = opts.fields or {},
    _messages = {}
  }
  
  function device:generate_test_message(component, event)
    table.insert(self._messages, { component = component, event = event })
    return { component = component, event = event }
  end
  
  function device:set_field(key, value, opts)
    self._fields[key] = value
  end
  
  function device:get_field(key)
    return self._fields[key]
  end
  
  return device
end

integration_test.mock_device = {
  build_test_lan_device = function(opts)
    return create_mock_device(opts)
  end,
  build_test_generic_device = function(opts)
    return create_mock_device(opts)
  end,
  build_test_child_device = function(opts)
    return create_mock_device(opts)
  end,
  add_test_device = function(device)
    -- Mock: just acknowledge
  end
}

-- Register a test case
function integration_test.register_coroutine_test(name, test_fn)
  table.insert(registered_tests, { name = name, fn = test_fn })
end

-- Set the initialization function
function integration_test.set_test_init_function(fn)
  test_init_function = fn
end

-- Wait for events (mock - no-op)
function integration_test.wait_for_events()
  -- Mock: no-op in local testing
end

-- Run all registered tests
function integration_test.run_registered_tests()
  local passed = 0
  local failed = 0
  
  -- Run init function if set
  if test_init_function then
    test_init_function()
  end
  
  print(string.format("Running %d tests...", #registered_tests))
  print("")
  
  for _, test_case in ipairs(registered_tests) do
    print(string.format('Running test "%s"', test_case.name))
    
    local success, err = pcall(test_case.fn)
    
    if success then
      print("PASSED")
      passed = passed + 1
    else
      print("FAILED")
      print(string.format("  Error: %s", tostring(err)))
      failed = failed + 1
    end
  end
  
  print("")
  print(string.format("Passed %d of %d tests", passed, #registered_tests))
  
  if failed > 0 then
    print(string.format("Failed %d of %d tests", failed, #registered_tests))
    os.exit(1)
  end
end

return integration_test
