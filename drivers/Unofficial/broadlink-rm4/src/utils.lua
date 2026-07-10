-- src/utils.lua
--
-- Byte helpers for the BroadLink protocol. BroadLink needs in-place byte
-- mutation, but Lua strings are immutable, so we work on 1-indexed byte
-- arrays and convert to/from strings only at the socket boundary.
-- Everything here is version-safe (no native bitwise; uses % and math.floor).
local M = {}

-- string -> array of byte values (1-indexed)
function M.to_bytes(s)
  local t = {}
  for i = 1, #s do t[i] = s:byte(i) end
  return t
end

-- array of byte values -> string
function M.from_bytes(t)
  local out = {}
  for i = 1, #t do out[i] = string.char(t[i] % 256) end
  return table.concat(out)
end

-- allocate a zero-filled byte array of length n
function M.zeros(n)
  local t = {}
  for i = 1, n do t[i] = 0 end
  return t
end

-- BroadLink checksum over bytes[from..to] (inclusive, 1-indexed); seed 0xBEAF
function M.checksum(bytes, from, to)
  local sum = 0xBEAF
  for i = (from or 1), (to or #bytes) do
    sum = (sum + bytes[i]) % 0x10000
  end
  return sum -- 16-bit
end

-- low / high byte of a 16-bit value
function M.lo(v) return v % 256 end
function M.hi(v) return math.floor(v / 256) % 256 end

-- hex string ("2600...") -> byte array, for pasting captured codes
function M.hex_to_bytes(hex)
  local t = {}
  hex = hex:gsub("%s", "")
  for i = 1, #hex, 2 do t[#t + 1] = tonumber(hex:sub(i, i + 1), 16) end
  return t
end

function M.bytes_to_hex(t)
  local out = {}
  for i = 1, #t do out[i] = string.format("%02x", t[i] % 256) end
  return table.concat(out)
end

return M
