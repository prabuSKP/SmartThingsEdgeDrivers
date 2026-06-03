---
name: secure-transport
description: >
  Implement HTTPS secure transport and API authentication in SmartThings Edge drivers.
  Covers TLS client setup, bypassing self-signed certificate validation for LAN hubs,
  and constructing HTTP Basic and Digest Authentication headers in Lua. Use when:
  (1) a local bridge requires HTTPS (SSL/TLS), (2) configuring self-signed cert verify rules,
  or (3) implementing Basic/Digest auth handshakes.
---

# SmartThings Edge Secure Transport & Authentication

This skill covers how to handle HTTPS connections and authentication methods (Basic and Digest) within the cooperative runtime of a SmartThings Edge driver. Many 3rd-party hubs (such as Fibaro Home Center 3 or Home Assistant) require TLS connection or authentication credentials.

---

## 1. TLS/HTTPS in the Edge Runtime

SmartThings Edge drivers use the `ssl` package under `cosock` for secure TCP and HTTP requests.
Do not assume `cosock.http` is available on the hub. Prefer a packaged REST client
that uses `cosock.socket` plus `cosock.ssl`, such as `lunchbox.rest`, or generate a
small raw-socket HTTP client and package it with the driver.

### Basic HTTPS Request
To perform a secure HTTP request, build a TLS-capable socket and pass it to a
packaged REST client. If this pattern is generated, include the `lunchbox` files
in `src/lunchbox/`.

```lua
local RestClient = require "lunchbox.rest"
local utils = require "utils"

local ssl_params = {
  mode = "client",
  protocol = "any",
  verify = "none",
  options = "all",
}

local client = RestClient.new(
  "https://192.168.1.50:443",
  utils.labeled_socket_builder("local hub", ssl_params)
)

local response, err = client:get("/api/status", {
  ["Accept"] = "application/json",
})
```

### Self-Signed Certificate Bypass
By default, secure clients verify the server's certificate. Because local hubs use self-signed certificates, this check will fail unless bypassed.

Configure the socket connection options:
```lua
local socket = require "cosock.socket"
local ssl = require "cosock.ssl"

local function connect_secure_socket(ip, port)
  local conn = socket.tcp()
  conn:settimeout(5.0)
  
  local success, err = conn:connect(ip, port)
  if not success then
    return nil, err
  end
  
  -- Wrap the socket in a TLS context
  local secure_conn, ssl_err = ssl.wrap(conn, {
    mode = "client",
    protocol = "tlsv1_2",
    verify = "none", -- Bypass verification for self-signed certificates
    options = "all"
  })
  
  if not secure_conn then
    return nil, ssl_err
  end
  
  local hand_success, hand_err = secure_conn:dohandshake()
  if not hand_success then
    secure_conn:close()
    return nil, hand_err
  end
  
  return secure_conn
end
```

### Production: validate the server — `verify="peer"` + pinned `cafile` (PREFERRED over bypass)

`verify="none"` encrypts but does **not authenticate** the hub — it accepts *any* certificate, so it is **MITM-vulnerable on the LAN**. Treat it as a logged fallback, not the default. The production pattern (used by SmartThings' own `jbl` driver, and Aqara/DeepSmart) **pins the hub certificate**: `verify="peer"` + a `cafile` cert **bundled in `src/`**.

```lua
-- module-level, cf. drivers/SmartThings/jbl/src/jbl/api.lua
local SSL_CONFIG = {
  mode = "client", protocol = "any", options = "all",
  verify = "peer",               -- actually validate the server
  cafile = "./hub_server.crt",   -- bundled cert; "./" resolves from src/ at runtime
}
local socket_builder = utils.labeled_socket_builder(label, SSL_CONFIG)
```

- **Bundle the cert under `src/`** (only `src/` is packaged); the relative `./` path resolves from the driver's `src/` working dir — proven by shipping drivers incl. SmartThings' own `jbl`.
- **Obtain it** — first inspect the chain, then extract:
  ```bash
  openssl s_client -connect <hub-ip>:443 -showcerts </dev/null 2>/dev/null | grep -E "s:|i:"
  openssl s_client -connect <hub-ip>:443 -showcerts </dev/null 2>/dev/null | openssl x509 -outform PEM > hub_server.crt
  ```
  If `s:`==`i:` (self-signed leaf) bundle **that leaf** — openssl trusts a self-signed cert that is present in the `cafile`. If there is a separate issuer **CA**, bundle the **CA** (one CA validates every device that vendor signs).
- **Hostname/IP:** `verify="peer"`+`cafile` validates the **chain**, not the hostname — so connecting by IP while the cert CN is a hostname is fine.
- **Per-device vs shared-CA:** a pinned self-signed leaf validates only that one hub (replace the file per deployment); a shared vendor CA validates all that vendor's hubs.
- **Expiry:** `verify="peer"` enforces validity dates (an expired hub cert is rejected) — expose a `tlsVerify` (peer/none) **preference** so the user can fall back, with a clear log message. Default to `peer`.

**TOFU (Trust On First Use)** alternative for per-device certs without bundling: on first connect capture the server cert fingerprint, persist it in `driver.datastore`, and verify it matches on every reconnect.

---

## 2. Authentication Implementations

### A. HTTP Basic Authentication
Basic auth requires Base64-encoding the string `username:password` and adding it to the `Authorization` header.

The SmartThings SDK provides a helper module `st.base64` for encoding.

```lua
local base64 = require "st.base64"

local function make_basic_auth_header(username, password)
  local credentials = string.format("%s:%s", username, password)
  local encoded = base64.encode(credentials)
  return "Basic " .. encoded
end

local headers = {
  ["Authorization"] = make_basic_auth_header(username, password),
  ["Accept"] = "application/json",
}
```

### B. HTTP Digest Authentication
Digest auth is more complex and involves a handshake challenge:
1. Make a request to the server.
2. The server responds with `401 Unauthorized` containing a `WWW-Authenticate` header with `nonce`, `realm`, `qop`, etc.
3. Calculate the MD5 hash signature of credentials and request details.
4. Resubmit the request with the `Authorization` header containing the signature.

Because the Edge environment does not have a standard `crypto` module, we can use the MD5 library provided by SmartThings (`st.md5` or `st.utils` if it contains an MD5 function) or a lightweight pure-Lua MD5 implementation.

```lua
local md5 = require "st.md5" -- MD5 hashing library in the ST SDK

local function parse_www_authenticate(header_str)
  local params = {}
  for k, v in string.gmatch(header_str, '(%w+)="?([^",]+)"?') do
    params[k] = v
  end
  return params
end

local function calculate_digest_response(username, password, realm, nonce, method, uri, nc, cnonce, qop)
  -- H(A1) = MD5(username:realm:password)
  local ha1 = md5.hex(string.format("%s:%s:%s", username, realm, password))
  -- H(A2) = MD5(method:uri)
  local ha2 = md5.hex(string.format("%s:%s", method, uri))
  
  -- response = MD5(H(A1):nonce:nc:cnonce:qop:H(A2))
  local raw_response = string.format("%s:%s:%s:%s:%s:%s", ha1, nonce, nc, cnonce, qop, ha2)
  return md5.hex(raw_response)
end

function perform_digest_request(rest_request, path, method, username, password)
  -- rest_request(method, path, headers) should use the driver's packaged REST client.
  -- 1. Initial request to get the 401 challenge.
  local response, err = rest_request(method, path, {})
  local code = response and response.status
  local headers = response and response:get_headers()
  headers = headers or {}
  
  if code ~= 401 or not headers["www-authenticate"] then
    return nil, "Failed to initiate challenge: " .. tostring(code)
  end
  
  -- 2. Parse WWW-Authenticate parameters
  local auth_params = parse_www_authenticate(headers["www-authenticate"])
  local realm = auth_params.realm
  local nonce = auth_params.nonce
  local qop = auth_params.qop or "auth"
  
  -- 3. Prepare parameters for MD5 calculation
  local nc = "00000001"
  local cnonce = "0a2b3c4d5e6f"
  
  local response = calculate_digest_response(
    username, password, realm, nonce, method, path, nc, cnonce, qop
  )
  
  -- 4. Build authorization header
  local auth_header = string.format(
    'Digest username="%s", realm="%s", nonce="%s", uri="%s", qop=%s, nc=%s, cnonce="%s", response="%s"',
    username, realm, nonce, path, qop, nc, cnonce, response
  )
  
  -- 5. Submit final request through the same packaged REST client.
  local final_response, final_err = rest_request(method, path, {
    ["Authorization"] = auth_header
  })
  local final_code = final_response and final_response.status
  
  if final_code == 200 then
    return final_response:get_body(), nil
  else
    return nil, "Authentication failed: " .. tostring(final_err or final_code)
  end
end
```
