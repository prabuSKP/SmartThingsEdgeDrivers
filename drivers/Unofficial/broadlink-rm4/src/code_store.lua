-- src/code_store.lua
--
-- Per-device IR code storage. Codes are learned in the app (see init.lua Learn mode) and
-- persisted as fields ON the appliance child device, so they survive reboots/updates and are
-- removed automatically when the device is deleted.
--
-- Layout on each child device:
--   code_index          -> { "power_on", "vol_up", ... }   (array of slot names)
--   code_<slot>         -> "2600...0d05"                    (hex string per slot)
--
-- get() falls back to the bundled src/codes.lua (keyed by appliance type) so a developer can
-- still seed codes, but nothing requires it.
local log   = require "log"
local codes = require "codes"

local store = {}

local MAX_CODES   = 40      -- per device (datastore size guard)
local MAX_HEX_LEN = 4096    -- per code

local function appliance_type(device)
  local k = device.parent_assigned_child_key or ""
  return k:match("^(%w+)%-") or "generic"
end

local function get_index(device)
  return device:get_field("code_index") or {}
end

-- Save a learned code under `slot`. Returns ok, err.
function store.save(device, slot, hex)
  if type(slot) ~= "string" or not slot:match("^[%w_]+$") then
    return false, "invalid slot name"
  end
  if type(hex) ~= "string" or #hex == 0 then
    return false, "empty code"
  end
  if #hex > MAX_HEX_LEN then
    return false, "code too large (" .. #hex .. ")"
  end

  local idx = get_index(device)
  local exists = false
  for _, n in ipairs(idx) do if n == slot then exists = true break end end
  if not exists then
    if #idx >= MAX_CODES then
      return false, "code limit reached (" .. MAX_CODES .. ")"
    end
    idx[#idx + 1] = slot
    device:set_field("code_index", idx, { persist = true })
  end
  device:set_field("code_" .. slot, hex, { persist = true })
  return true
end

-- Get the hex for `slot`: device-stored first, then the bundled codes.lua fallback.
function store.get(device, slot)
  local hex = device:get_field("code_" .. slot)
  if hex and hex ~= "" then return hex end
  local t = codes[appliance_type(device)]
  local fb = t and t[slot]
  if fb and fb ~= "" then return fb end
  return nil
end

-- List learned slot names.
function store.list(device)
  return get_index(device)
end

-- Remove a stored code.
function store.remove(device, slot)
  device:set_field("code_" .. slot, "", { persist = true })   -- "" == absent to get()
  local idx, out = get_index(device), {}
  for _, n in ipairs(idx) do if n ~= slot then out[#out + 1] = n end end
  device:set_field("code_index", out, { persist = true })
  log.info_with({ hub_logs = true }, "[BroadLink] removed code '" .. tostring(slot) .. "'")
end

return store
