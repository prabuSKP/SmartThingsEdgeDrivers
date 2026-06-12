local json = require "st.json"
local log = require "log"

-- Dynamic HC3 CA certificate handling.
--
-- HC3 serves its local API over HTTPS with a certificate chain anchored by a Fibaro CA, so
-- the driver fetches that CA from GET /api/settings/certificates/ca on first contact and
-- pins it. Because the SmartThings Edge sandbox cannot write a `cafile` to disk at runtime,
-- validation is enforced at the application layer: the luasec transport stays verify="none"
-- (encrypt-only, the Philips Hue precedent) and, immediately after the TLS handshake, we
-- compare the certificate(s) the hub presented against the pinned CA fingerprint. A mismatch
-- (rotation or MITM) causes the connection to be refused.
--
-- Fingerprints are SHA-256 over the certificate's DER encoding. We compute them with the
-- pure-Lua primitives below rather than luasec's `loadcertificate`, because that helper is
-- not exposed in the hub runtime (confirmed from hub-agent.log). The pure-Lua SHA-256 and
-- base64 decoder were verified to reproduce the exact fingerprint openssl/luasec produce.
--
-- All logging uses the "[Fibaro]" tag with hub_logs = true so it is captured for debugging.
local cert = {}

local PEM_BEGIN = "-----BEGIN CERTIFICATE-----"
local PEM_END = "-----END CERTIFICATE-----"

-- ===========================================================================
-- Pure-Lua primitives (Lua 5.3 native bitwise ops; no external module, so they
-- cannot be blocked by the sandbox the way luasec.loadcertificate is).
-- ===========================================================================

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64_ALPHABET do
  B64_INDEX[B64_ALPHABET:sub(i, i)] = i - 1
end

-- Decode standard base64 (ignoring any non-alphabet bytes) into a raw byte string.
local function base64_decode(data)
  local bytes = {}
  local bits, nbits = 0, 0
  for i = 1, #data do
    local ch = data:sub(i, i)
    if ch == "=" then break end
    local v = B64_INDEX[ch]
    if v ~= nil then
      bits = (bits << 6) | v
      nbits = nbits + 6
      if nbits >= 8 then
        nbits = nbits - 8
        bytes[#bytes + 1] = string.char((bits >> nbits) & 0xFF)
      end
    end
  end
  return table.concat(bytes)
end

local SHA256_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rrotate(x, n)
  return ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF
end

-- SHA-256 of a raw byte string -> uppercase hex digest (64 chars).
local function sha256_hex(msg)
  local h0, h1, h2, h3, h4, h5, h6, h7 =
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  local bitlen = #msg * 8
  msg = msg .. "\128"
  while (#msg % 64) ~= 56 do
    msg = msg .. "\0"
  end
  msg = msg .. string.pack(">I8", bitlen)

  local w = {}
  for chunk = 1, #msg, 64 do
    for j = 0, 15 do
      w[j] = string.unpack(">I4", msg, chunk + j * 4)
    end
    for j = 16, 63 do
      local x15, x2 = w[j - 15], w[j - 2]
      local s0 = rrotate(x15, 7) ~ rrotate(x15, 18) ~ (x15 >> 3)
      local s1 = rrotate(x2, 17) ~ rrotate(x2, 19) ~ (x2 >> 10)
      w[j] = (w[j - 16] + s0 + w[j - 7] + s1) & 0xFFFFFFFF
    end

    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for j = 0, 63 do
      local S1 = rrotate(e, 6) ~ rrotate(e, 11) ~ rrotate(e, 25)
      local ch = (e & f) ~ ((~e & 0xFFFFFFFF) & g)
      local temp1 = (h + S1 + ch + SHA256_K[j + 1] + w[j]) & 0xFFFFFFFF
      local S0 = rrotate(a, 2) ~ rrotate(a, 13) ~ rrotate(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local temp2 = (S0 + maj) & 0xFFFFFFFF
      h = g; g = f; f = e
      e = (d + temp1) & 0xFFFFFFFF
      d = c; c = b; b = a
      a = (temp1 + temp2) & 0xFFFFFFFF
    end

    h0 = (h0 + a) & 0xFFFFFFFF; h1 = (h1 + b) & 0xFFFFFFFF
    h2 = (h2 + c) & 0xFFFFFFFF; h3 = (h3 + d) & 0xFFFFFFFF
    h4 = (h4 + e) & 0xFFFFFFFF; h5 = (h5 + f) & 0xFFFFFFFF
    h6 = (h6 + g) & 0xFFFFFFFF; h7 = (h7 + h) & 0xFFFFFFFF
  end

  return string.format("%08X%08X%08X%08X%08X%08X%08X%08X", h0, h1, h2, h3, h4, h5, h6, h7)
end

-- Strip PEM armor + whitespace from a certificate and base64-decode it to DER bytes.
local function der_from_pem(pem)
  if type(pem) ~= "string" then return nil end
  local b = pem:find(PEM_BEGIN, 1, true)
  local e = pem:find(PEM_END, 1, true)
  local body = (b and e) and pem:sub(b + #PEM_BEGIN, e - 1) or pem
  body = body:gsub("[^A-Za-z0-9+/=]", "")
  if body == "" then return nil end
  return base64_decode(body)
end

local function pcall_method(obj, method, ...)
  if obj == nil then return nil end
  local fn = obj[method]
  if type(fn) ~= "function" then return nil end
  local ok, result = pcall(fn, obj, ...)
  if ok then return result end
  return nil
end

-- ===========================================================================
-- Public API
-- ===========================================================================

-- Normalize a certificate fingerprint to a canonical form (uppercase hex, no separators)
-- so values produced by different sources (our SHA-256, luasec :digest) compare equal.
function cert.normalize_fp(fp)
  if fp == nil then return nil end
  return (tostring(fp):gsub("[:%s]", "")):upper()
end

-- Extract a clean PEM certificate block from whatever the endpoint returned. The HC3 may
-- reply with raw PEM, a JSON object wrapping the PEM, or a JSON-encoded string with escaped
-- newlines. Returns pem, nil on success or nil, err on failure.
function cert.extract_pem(raw)
  if type(raw) == "table" then
    raw = raw.ca or raw.certificate or raw.cert or raw.pem or raw.value or raw[1]
  end

  if type(raw) ~= "string" or raw == "" then
    return nil, "no certificate string in response"
  end

  local s = raw:gsub("\\r", ""):gsub("\\n", "\n")
  s = s:gsub('^%s*"', ""):gsub('"%s*$', "")
  s = s:gsub("\\n", "\n")

  local b = s:find(PEM_BEGIN, 1, true)
  local e = s:find(PEM_END, 1, true)
  if not b or not e then
    return nil, "no PEM certificate block found in response"
  end

  return s:sub(b, e + #PEM_END - 1)
end

-- SHA-256 fingerprint (normalized) of a PEM certificate, computed with the pure-Lua path.
-- Returns fingerprint, der_byte_count on success or nil, err on failure.
function cert.fingerprint(pem)
  local der = der_from_pem(pem)
  if not der or #der == 0 then
    return nil, "could not base64-decode PEM body"
  end
  return cert.normalize_fp(sha256_hex(der)), #der
end

-- Fingerprint a certificate object returned by getpeercertificate/getpeerchain. Tries the
-- native :digest first (fast), then falls back to exporting the cert as PEM and hashing it
-- with the pure-Lua path, so it works even if luasec helpers are partially unavailable.
-- Returns fingerprint or nil, reason.
function cert.fingerprint_of_object(obj)
  if obj == nil then
    return nil, "nil certificate object"
  end

  local native = pcall_method(obj, "digest", "sha256")
  if native ~= nil then
    return cert.normalize_fp(native)
  end

  local pem = pcall_method(obj, "pem")
  if type(pem) == "string" then
    local fp = cert.fingerprint(pem)
    if fp then return fp end
  end

  return nil, "no usable digest/pem method on peer certificate"
end

-- Build a human-readable description of a PEM certificate for debug logs. Rich X.509 fields
-- are best-effort via luasec (often unavailable in the sandbox); otherwise falls back to the
-- DER size and fingerprint. The full PEM is logged separately by the caller regardless.
function cert.describe(pem)
  local ok_ssl, luasec = pcall(require, "ssl")
  if ok_ssl and type(luasec) == "table" and type(luasec.loadcertificate) == "function" then
    local ok_load, x509 = pcall(luasec.loadcertificate, pem)
    if ok_load and x509 then
      local parts = {}
      local function add(label, method)
        local v = pcall_method(x509, method)
        if v ~= nil then
          local okj, enc = pcall(json.encode, v)
          parts[#parts + 1] = string.format("%s=%s", label, okj and enc or tostring(v))
        end
      end
      add("subject", "subject")
      add("issuer", "issuer")
      add("notbefore", "notbefore")
      add("notafter", "notafter")
      if #parts > 0 then
        return table.concat(parts, " ")
      end
    end
  end

  local fp, der_len = cert.fingerprint(pem)
  return string.format("sha256=%s der_bytes=%s (luasec introspection unavailable)",
    tostring(fp), tostring(der_len))
end

-- Collect the certificate objects the peer presented after a handshake: the full chain if
-- available, otherwise just the leaf.
local function presented_certs(sock)
  local certs = {}

  local chain = pcall_method(sock, "getpeerchain")
  if type(chain) == "table" then
    for _, c in ipairs(chain) do
      certs[#certs + 1] = c
    end
  end

  if #certs == 0 then
    local leaf = pcall_method(sock, "getpeercertificate")
    if leaf ~= nil then
      certs[#certs + 1] = leaf
    end
  end

  return certs
end

-- Build a post-handshake verifier bound to a pinned CA fingerprint. Returns a function
-- compatible with the socket builder's pin_verify hook: (sock) -> ok, err. It passes when
-- any certificate the hub presented matches the pinned CA, covering both HC3 chain shapes
-- (a single self-signed cert, or a [leaf, ..., CA] chain). label is the bridge log prefix.
function cert.make_pin_verify(expected_fp, label)
  local want = cert.normalize_fp(expected_fp)
  label = (label and #label > 0) and (label .. " ") or ""

  return function(sock)
    if want == nil or want == "" then
      return false, "no pinned CA fingerprint configured"
    end

    local certs = presented_certs(sock)
    local readable = 0  -- how many presented certs we could actually fingerprint

    for idx, c in ipairs(certs) do
      local got, reason = cert.fingerprint_of_object(c)
      if got ~= nil then
        readable = readable + 1
        log.info_with({ hub_logs = true }, string.format(
          "[Fibaro] %sTLS pin check: presented cert[%d] sha256=%s", label, idx, got))
        if got == want then
          log.info_with({ hub_logs = true }, string.format(
            "[Fibaro] %sTLS pin OK: presented cert[%d] matches pinned CA sha256=%s", label, idx, want))
          return true
        end
      else
        log.warn_with({ hub_logs = true }, string.format(
          "[Fibaro] %sTLS pin check: could not fingerprint presented cert[%d]: %s",
          label, idx, tostring(reason)))
      end
    end

    -- Fail OPEN only when the runtime could not expose ANY peer certificate to inspect
    -- (a capability gap, not an attack): allow the connection but warn that pinning is
    -- inactive, so we are never worse than the existing encrypt-only transport and the
    -- integration is never bricked by a missing runtime feature.
    if readable == 0 then
      log.warn_with({ hub_logs = true }, string.format(
        "[Fibaro] %sTLS pin INACTIVE: runtime exposed no inspectable peer certificate "
        .. "(%d presented); allowing encrypt-only connection", label, #certs))
      return true
    end

    -- We could read the presented certificate(s) but none matched the pin: this is a real
    -- mismatch (certificate rotation or man-in-the-middle). Fail CLOSED.
    return false, string.format(
      "none of %d readable certificate(s) matched pinned CA sha256=%s", readable, want)
  end
end

return cert
