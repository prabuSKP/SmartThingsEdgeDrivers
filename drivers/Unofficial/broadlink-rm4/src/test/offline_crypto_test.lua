-- src/test/offline_crypto_test.lua
--
-- Plain-Lua verification of the self-contained AES (no hub, no ST test framework).
-- Run from the driver root:  lua src/test/offline_crypto_test.lua
-- Requires Lua 5.3 or 5.4 (native bitwise). This is plan pre-flight test T4, part (a).
package.path = package.path .. ";./src/?.lua"

local crypto = require "crypto"
local utils  = require "utils"

local function bytes(hex) return utils.hex_to_bytes(hex) end

-- NIST SP 800-38A, F.2.1 (AES-128-CBC, first block)
local key = bytes("2b7e151628aed2a6abf7158809cf4f3c")
local iv  = bytes("000102030405060708090a0b0c0d0e0f")
local pt  = bytes("6bc1bee22e409f96e93d7e117393172a")
local exp = "7649abac8119b246cee98e9b12e9197d"

local ct = utils.bytes_to_hex(crypto.encrypt(key, iv, pt))
assert(ct == exp, "AES encrypt FAIL: expected " .. exp .. " got " .. ct)
print("AES encrypt KAT: PASS")

local back = utils.bytes_to_hex(crypto.decrypt(key, iv, bytes(exp)))
assert(back == "6bc1bee22e409f96e93d7e117393172a", "AES decrypt FAIL: got " .. back)
print("AES decrypt KAT: PASS")

print("All crypto self-tests passed.")
