-- src/vendor/aes.lua
--
-- Self-contained pure-Lua AES-128 (block cipher) + CBC mode for Lua 5.3+ (native bitwise).
-- The S-box, inverse S-box and GF(2^8) exp/log tables are DERIVED at load time from the AES
-- field arithmetic, so there are no hand-typed 256-byte tables that could carry a typo.
--
-- Public API (operates on Lua byte-strings):
--   aes.cbc_encrypt(key16, iv16, data)  -> ciphertext   (data length must be a multiple of 16)
--   aes.cbc_decrypt(key16, iv16, data)  -> plaintext
--
-- This matches the contract crypto.lua expects. You can swap this file for the lua-lockbox
-- fork if you prefer a third-party implementation -- keep crypto.lua's public functions the
-- same. Verify either choice with src/test/offline_crypto_test.lua (NIST SP 800-38A vector).

local M = {}

-- ------------------------------------------------------------------ GF(2^8)
-- exp/log tables using generator 0x03.
local EXP, LOG = {}, {}
do
  local a = 1
  for i = 0, 254 do
    EXP[i] = a
    LOG[a] = i
    local b = a << 1
    if b & 0x100 ~= 0 then b = b ~ 0x11b end
    a = (a ~ b) & 0xff          -- a * 3 in GF(2^8)
  end
end

local function gmul(x, y)
  if x == 0 or y == 0 then return 0 end
  return EXP[(LOG[x] + LOG[y]) % 255]
end

local function ginv(x)
  if x == 0 then return 0 end
  return EXP[(255 - LOG[x]) % 255]
end

-- --------------------------------------------------------------- S-boxes
local function rotl8(x, n) return ((x << n) | (x >> (8 - n))) & 0xff end

local SBOX, INV_SBOX = {}, {}
for i = 0, 255 do
  local inv = ginv(i)
  local s = inv ~ rotl8(inv, 1) ~ rotl8(inv, 2) ~ rotl8(inv, 3) ~ rotl8(inv, 4) ~ 0x63
  s = s & 0xff
  SBOX[i] = s
  INV_SBOX[s] = i
end

-- --------------------------------------------------------- key expansion
-- key: 0-indexed array of 16 bytes. Returns a 176-byte (0-indexed) round-key array.
local function key_expansion(key)
  local w = {}
  for i = 0, 15 do w[i] = key[i] end
  local rcon = 1
  local i = 16
  while i < 176 do
    local a0, a1, a2, a3 = w[i - 4], w[i - 3], w[i - 2], w[i - 1]
    if i % 16 == 0 then
      a0, a1, a2, a3 = a1, a2, a3, a0                              -- RotWord
      a0 = SBOX[a0]; a1 = SBOX[a1]; a2 = SBOX[a2]; a3 = SBOX[a3]   -- SubWord
      a0 = a0 ~ rcon                                                -- Rcon
      rcon = rcon << 1
      if rcon & 0x100 ~= 0 then rcon = rcon ~ 0x11b end
      rcon = rcon & 0xff
    end
    w[i]     = w[i - 16] ~ a0
    w[i + 1] = w[i - 15] ~ a1
    w[i + 2] = w[i - 14] ~ a2
    w[i + 3] = w[i - 13] ~ a3
    i = i + 4
  end
  return w
end

-- ------------------------------------------------------------- transforms
-- State bytes are laid out column-major: index = row + 4*col.
local function shift_rows(s)
  local o = {}
  for c = 0, 3 do
    for r = 0, 3 do
      o[r + 4 * c] = s[r + 4 * ((c + r) % 4)]
    end
  end
  return o
end

local function inv_shift_rows(s)
  local o = {}
  for c = 0, 3 do
    for r = 0, 3 do
      o[r + 4 * c] = s[r + 4 * ((c - r) % 4)]
    end
  end
  return o
end

local function mix_columns(s)
  local o = {}
  for c = 0, 3 do
    local i = 4 * c
    local a0, a1, a2, a3 = s[i], s[i + 1], s[i + 2], s[i + 3]
    o[i]     = gmul(a0, 2) ~ gmul(a1, 3) ~ a2 ~ a3
    o[i + 1] = a0 ~ gmul(a1, 2) ~ gmul(a2, 3) ~ a3
    o[i + 2] = a0 ~ a1 ~ gmul(a2, 2) ~ gmul(a3, 3)
    o[i + 3] = gmul(a0, 3) ~ a1 ~ a2 ~ gmul(a3, 2)
  end
  return o
end

local function inv_mix_columns(s)
  local o = {}
  for c = 0, 3 do
    local i = 4 * c
    local a0, a1, a2, a3 = s[i], s[i + 1], s[i + 2], s[i + 3]
    o[i]     = gmul(a0, 14) ~ gmul(a1, 11) ~ gmul(a2, 13) ~ gmul(a3, 9)
    o[i + 1] = gmul(a0, 9) ~ gmul(a1, 14) ~ gmul(a2, 11) ~ gmul(a3, 13)
    o[i + 2] = gmul(a0, 13) ~ gmul(a1, 9) ~ gmul(a2, 14) ~ gmul(a3, 11)
    o[i + 3] = gmul(a0, 11) ~ gmul(a1, 13) ~ gmul(a2, 9) ~ gmul(a3, 14)
  end
  return o
end

-- ------------------------------------------------------------- block cipher
local function encrypt_block(w, inp)
  local s = {}
  for i = 0, 15 do s[i] = inp[i] ~ w[i] end            -- initial AddRoundKey
  for round = 1, 9 do
    for i = 0, 15 do s[i] = SBOX[s[i]] end
    s = shift_rows(s)
    s = mix_columns(s)
    local base = round * 16
    for i = 0, 15 do s[i] = s[i] ~ w[base + i] end
  end
  for i = 0, 15 do s[i] = SBOX[s[i]] end               -- final round (no MixColumns)
  s = shift_rows(s)
  for i = 0, 15 do s[i] = s[i] ~ w[160 + i] end
  return s
end

local function decrypt_block(w, inp)
  local s = {}
  for i = 0, 15 do s[i] = inp[i] ~ w[160 + i] end
  for round = 9, 1, -1 do
    s = inv_shift_rows(s)
    for i = 0, 15 do s[i] = INV_SBOX[s[i]] end
    local base = round * 16
    for i = 0, 15 do s[i] = s[i] ~ w[base + i] end
    s = inv_mix_columns(s)
  end
  s = inv_shift_rows(s)
  for i = 0, 15 do s[i] = INV_SBOX[s[i]] end
  for i = 0, 15 do s[i] = s[i] ~ w[i] end
  return s
end

-- -------------------------------------------------------- CBC + string glue
local function to_bytes0(str)
  local t = {}
  for i = 1, #str do t[i - 1] = str:byte(i) end
  return t
end

function M.cbc_encrypt(key, iv, data)
  assert(#key == 16, "AES-128 key must be 16 bytes")
  assert(#data % 16 == 0, "cbc_encrypt: data length must be a multiple of 16")
  local w = key_expansion(to_bytes0(key))
  local prev = to_bytes0(iv)
  local db = to_bytes0(data)
  local out = {}
  for off = 0, #data - 1, 16 do
    local block = {}
    for i = 0, 15 do block[i] = db[off + i] ~ prev[i] end
    local enc = encrypt_block(w, block)
    for i = 0, 15 do out[#out + 1] = string.char(enc[i] & 0xff) end
    prev = enc
  end
  return table.concat(out)
end

function M.cbc_decrypt(key, iv, data)
  assert(#key == 16, "AES-128 key must be 16 bytes")
  assert(#data % 16 == 0, "cbc_decrypt: data length must be a multiple of 16")
  local w = key_expansion(to_bytes0(key))
  local prev = to_bytes0(iv)
  local db = to_bytes0(data)
  local out = {}
  for off = 0, #data - 1, 16 do
    local cblock = {}
    for i = 0, 15 do cblock[i] = db[off + i] end
    local dec = decrypt_block(w, cblock)
    for i = 0, 15 do out[#out + 1] = string.char((dec[i] ~ prev[i]) & 0xff) end
    prev = cblock
  end
  return table.concat(out)
end

return M
