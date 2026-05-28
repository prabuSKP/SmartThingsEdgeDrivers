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

### Basic HTTPS Request
To perform a secure HTTP request, import `cosock.ssl` and configure your request options:

```lua
local http = require "cosock.http"
local ssl = require "cosock.ssl"
local socket = require "cosock.socket"
local log = require "log"

local function secure_get(url)
  local response_body = {}
  local res, code, headers, status = http.request({
    url = url,
    method = "GET",
    -- TLS options go in the request parameters if supported by the client library
    sink = ltn12.sink.table(response_body)
  })
  
  if code == 200 then
    return table.concat(response_body)
  else
    return nil, string.format("Code: %s, Status: %s", tostring(code), tostring(status))
  end
end
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

---

## 2. Authentication Implementations

### A. HTTP Basic Authentication
Basic auth requires Base64-encoding the string `username:password` and adding it to the `Authorization` header.

The SmartThings SDK provides a helper module `st.base64` for encoding.

```lua
local base64 = require "st.base64"
local http = require "cosock.http"

local function make_basic_auth_header(username, password)
  local credentials = string.format("%s:%s", username, password)
  local encoded = base64.encode(credentials)
  return "Basic " .. encoded
end

-- Usage in http.request
local function get_with_basic_auth(url, username, password)
  local response_body = {}
  local res, code, headers, status = http.request({
    url = url,
    method = "GET",
    headers = {
      ["Authorization"] = make_basic_auth_header(username, password),
      ["Accept"] = "application/json"
    },
    sink = ltn12.sink.table(response_body)
  })
  return code == 200, table.concat(response_body)
end
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

function perform_digest_request(url, path, method, username, password)
  local http = require "cosock.http"
  
  -- 1. Initial request to get the 401 challenge
  local response_body = {}
  local _, code, headers, status = http.request({
    url = url,
    method = method,
    sink = ltn12.sink.table(response_body)
  })
  
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
  
  -- 5. Submit final request
  local final_body = {}
  local _, final_code, _, final_status = http.request({
    url = url,
    method = method,
    headers = {
      ["Authorization"] = auth_header
    },
    sink = ltn12.sink.table(final_body)
  })
  
  if final_code == 200 then
    return table.concat(final_body), nil
  else
    return nil, "Authentication failed with status: " .. tostring(final_status)
  end
end
```
