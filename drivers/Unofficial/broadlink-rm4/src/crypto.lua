-- src/crypto.lua
--
-- Thin wrapper over the vendored pure-Lua AES-128-CBC (src/vendor/aes.lua).
-- Public functions take and return 1-indexed byte arrays; the vendored AES works
-- on strings, so we convert at this boundary.
--
-- The initial key/IV below are BroadLink's fixed constants, used only for the login
-- handshake (command 0x65). After login you switch to the per-session key the device
-- returns; BroadLink reuses this same fixed IV for session traffic too.
local AES   = require "vendor.aes"
local utils = require "utils"

local M = {}

M.INITIAL_KEY = {
  0x09,0x76,0x28,0x34,0x3f,0xe9,0x9e,0x23,
  0x76,0x5c,0x15,0x13,0xac,0xcf,0x8b,0x02,
}
M.IV = {
  0x56,0x2e,0x17,0x99,0x6d,0x09,0x3d,0x28,
  0xdd,0xb3,0xba,0x69,0x5a,0x2e,0x6f,0x58,
}

-- key, iv, data are byte arrays; returns a byte array.
-- CBC, no padding -- BroadLink payloads are already 16-byte aligned; assert it.
function M.encrypt(key, iv, data)
  assert(#data % 16 == 0, "encrypt: payload not 16-aligned (" .. #data .. ")")
  local ct = AES.cbc_encrypt(utils.from_bytes(key),
                             utils.from_bytes(iv),
                             utils.from_bytes(data))
  return utils.to_bytes(ct)
end

function M.decrypt(key, iv, data)
  local pt = AES.cbc_decrypt(utils.from_bytes(key),
                             utils.from_bytes(iv),
                             utils.from_bytes(data))
  return utils.to_bytes(pt)
end

return M
