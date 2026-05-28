---
name: lua-refactor
description: >
  Refactor and modularize SmartThings Edge Lua drivers.
  Covers architectural code patterns, modular file structures, preventing global
  variable leaks, and establishing unit tests by mocking the SmartThings Edge Lua SDK.
  Use when: (1) cleaning up monolith init.lua files, (2) preventing memory leaks and global state
  pollution, or (3) implementing test scripts to run outside the hub environment.
---

# SmartThings Edge Lua Refactoring & Testing

This skill outlines how to organize complex driver source code, prevent memory leaks by avoiding global variable pollution, and write unit tests by mocking the SmartThings Edge SDK.

---

## 1. Modularization Guidelines

As drivers expand (supporting more capabilities, vendors, or device kinds), keeping all code in `init.lua` becomes unmanageable. Break down the code into logical modules:

```
src/
├── init.lua                  # Registers handlers and starts loop
├── fields.lua                # Shared field keys (strings)
├── utils.lua                 # Utility helpers (IP validation, etc.)
├── discovery.lua             # SSDP/mDNS discovery routines
└── vendor/
    ├── api.lua               # Vendor API client class
    ├── mapper.lua            # Capability mapping rules
    └── device_handlers/      # Sub-handlers for complex components
        ├── switch.lua
        └── sensor.lua
```

### Exposing Modules Cleanly
When writing modular Lua files, always return a local table containing the module's functions, preventing namespace pollution:

```lua
-- src/utils.lua
local utils = {}

function utils.validate_ip(ip)
  if not ip or type(ip) ~= "string" then return false end
  local chunks = {ip:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")}
  if #chunks ~= 4 then return false end
  for _, v in ipairs(chunks) do
    if tonumber(v) > 255 then return false end
  end
  return true
end

return utils
```

---

## 2. Preventing Global Variable Leaks

In Lua, omitting the keyword `local` implicitly declares a variable in the global table (`_G`). In an Edge driver, this can cause variables to be shared between different devices, leak memory, or crash the driver during updates.

### Rules for Safe Lua Scope
1. **Always use `local`**: Ensure every variable, function, and imported module is declared as `local`.
2. **Check for leaked globals**:
   Before packaging a driver, run a static check. If `luacheck` is not available, you can add a temporary global audit block at the bottom of `init.lua`:
   ```lua
   -- Global Audit Utility
   for k, v in pairs(_G) do
     -- List all globals that are not part of standard Lua or SmartThings SDK
     if k ~= "_G" and k ~= "capabilities" and k ~= "Driver" and k ~= "log" then
       log.warn("Potential Global Leak detected: " .. tostring(k))
     end
   end
   ```

---

## 3. Mocking the SmartThings Edge SDK for Unit Testing

Because SmartThings Edge drivers use custom SDK libraries (`st.capabilities`, `st.driver`, `log`) that are only available on the hub, you cannot run your driver files directly with standard Lua interpreter unless you mock the SDK.

Below is a lightweight mocking framework for unit testing modules (like `mapper.lua` or `utils.lua`) locally:

### Mock SDK Implementation (`test/mock_sdk.lua`)
```lua
-- test/mock_sdk.lua
local mock_sdk = {}

-- Mock st.capabilities
package.loaded["st.capabilities"] = {
  switch = {
    ID = "switch",
    commands = {
      on = { NAME = "on" },
      off = { NAME = "off" }
    },
    switch = {
      on = function() return { capability = "switch", attribute = "switch", value = "on" } end,
      off = function() return { capability = "switch", attribute = "switch", value = "off" } end
    }
  }
}

-- Mock log
package.loaded["log"] = {
  info = function(...) print("[INFO]", ...) end,
  warn = function(...) print("[WARN]", ...) end,
  error = function(...) print("[ERROR]", ...) end,
  debug = function(...) print("[DEBUG]", ...) end
}

-- Mock device structure
function mock_sdk.create_mock_device(id, label, profile_name)
  local device = {
    id = id,
    device_network_id = id,
    label = label,
    profile = { name = profile_name },
    datastore = {},
    emitted_events = {}
  }
  
  function device:set_field(key, val, opts)
    self.datastore[key] = val
  end
  
  function device:get_field(key)
    return self.datastore[key]
  end
  
  function device:emit_event(event)
    table.insert(self.emitted_events, event)
  end
  
  return device
end

return mock_sdk
```

### Test Case Runner (`test/test_mapper.lua`)
Now you can test your mapper logic without deploying it to the hub:

```lua
-- Run this locally using: lua test/test_mapper.lua
local mock_sdk = require "test.mock_sdk"
local mapper = require "src.vendor.mapper"

-- 1. Create mock device
local device = mock_sdk.create_mock_device("12345", "Test Switch", "switch-profile")

-- 2. Define test case inputs
local api_payload = {
  id = "12345",
  type = "relay",
  properties = {
    value = true
  }
}

-- 3. Execute unit under test
mapper.sync_states(nil, device, api_payload)

-- 4. Assert results
local events = device.emitted_events
assert(#events == 1, "Should emit exactly 1 event")
assert(events[1].capability == "switch", "Should be a switch capability event")
assert(events[1].value == "on", "State should be mapped to 'on'")

print("✓ All tests passed!")
```
