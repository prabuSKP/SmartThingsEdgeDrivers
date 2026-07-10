-- src/test/offline_code_store_test.lua
-- Plain-Lua test of code_store (no hub). Run from the driver root:
--   lua src/test/offline_code_store_test.lua
package.path = package.path .. ";./src/?.lua"
package.preload["log"] = function()
  return setmetatable({}, { __index = function() return function() end end })
end

local code_store = require "code_store"

local function new_device(child_key)
  local fields = {}
  return {
    parent_assigned_child_key = child_key,
    get_field = function(_, k) return fields[k] end,
    set_field = function(_, k, v) fields[k] = v end,
  }
end

-- use a type with NO seed codes (fan) so learned-vs-empty behaviour is clean
local d = assert(new_device("fan-Bedroom Fan"))

assert(code_store.get(d, "power_on") == nil, "should be empty initially")
assert(code_store.save(d, "power_on", "2600aabb0d05"), "save power_on")
assert(code_store.get(d, "power_on") == "2600aabb0d05", "get after save")
assert(code_store.save(d, "speed_2", "2600ccdd0d05"), "save speed_2")

local list = code_store.list(d)
assert(#list == 2, "index has 2 entries, got " .. #list)

assert(not code_store.save(d, "bad name!", "2600"), "reject invalid slot name")
assert(not code_store.save(d, "x", ""), "reject empty code")
assert(not code_store.save(d, "x", string.rep("a", 5000)), "reject oversized code")

code_store.remove(d, "power_on")
assert(code_store.get(d, "power_on") == nil, "gone after remove")
assert(#code_store.list(d) == 1, "index has 1 after remove")

-- ac has no seed codes -> fallback nil
local ac = new_device("ac-Bedroom AC")
assert(code_store.get(ac, "cool_24_auto") == nil, "ac fallback empty")

-- tv HAS generated seed codes -> a tv device with nothing learned falls back to codes.lua
local tv = new_device("tv-Living Room TV")
assert(type(code_store.get(tv, "power_on")) == "string", "tv seed fallback present")
-- ...and a learned code overrides the seed
code_store.save(tv, "power_on", "2600deadbeef0d05")
assert(code_store.get(tv, "power_on") == "2600deadbeef0d05", "learned overrides seed")

print("code_store tests: PASS")
