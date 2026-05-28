---
name: hubitat
description: >
  Integrate Hubitat Elevation hubs with SmartThings Edge drivers.
  Covers the Maker API local endpoints, command execution URLs, query string token
  authorization, and implementing a cooperative HTTP server in Lua to receive
  real-time event POST callbacks from Hubitat. Use when building or debugging
  Hubitat-to-SmartThings bridge integrations.
---

# Hubitat Elevation Local Integration Guide

This skill details how to connect to Hubitat hubs using the local **Maker API** application, including command URLs, security, and establishing an HTTP server inside the Edge driver to receive real-time push events.

---

## 1. Hubitat Maker API Reference

To integrate with Hubitat, the user must install the **Maker API** app on their Hubitat hub. This generates an App ID, an Access Token, and local endpoints.

- **URL Prefix Format**: `http://<Hubitat_IP>/apps/api/<App_ID>`
- **Token Format**: Appended to all requests as `?access_token=<Token>`

### Endpoints
1. **Get All Devices**: `GET /devices?access_token=<Token>`
2. **Get Single Device Details/Status**: `GET /devices/<Device_ID>?access_token=<Token>`
3. **Send Command to Device**: `GET /devices/<Device_ID>/<Command>/<Arguments>?access_token=<Token>`
   - *Example Command (On)*: `/devices/105/on?access_token=abcd`
   - *Example Command (Set Level)*: `/devices/105/setLevel/80?access_token=abcd`

---

## 2. Real-Time Push Events: Local HTTP Callback Server

Hubitat's Maker API pushes state changes by sending HTTP `POST` requests to a configurable callback URL.

To receive these events, the SmartThings Edge Driver must start a local HTTP TCP server inside a background coroutine to listen for incoming connections from the Hubitat hub.

### Cooperative HTTP Callback Listener (Lua)
This code binds a port and parses incoming HTTP POST requests using `cosock` sockets:

```lua
local socket = require "cosock.socket"
local cosock = require "cosock"
local json = require "st.json"
local log = require "log"

local function handle_client(client, driver)
  client:settimeout(2.0)
  
  -- 1. Read HTTP request request line (e.g., "POST /callback HTTP/1.1")
  local req_line, err = client:receive("*l")
  if not req_line then
    client:close()
    return
  end
  
  local method, path = string.match(req_line, "^(%a+)%s+([^%s]+)%s+HTTP")
  
  -- 2. Read headers to find Content-Length
  local content_len = 0
  while true do
    local header_line = client:receive("*l")
    if not header_line or header_line == "" then
      break
    end
    local key, val = string.match(header_line, "^([^:]+):%s*(.*)$")
    if key and string.lower(key) == "content-length" then
      content_len = tonumber(val) or 0
    end
  end
  
  -- 3. Read POST body payload
  local body = ""
  if content_len > 0 then
    body, err = client:receive(content_len)
  end
  
  -- 4. Send HTTP 200 Response
  local response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  client:send(response)
  client:close()
  
  -- 5. Process payload if valid callback
  if method == "POST" and body ~= "" then
    local status, data = pcall(json.decode, body)
    if status and data and data.content then
      -- Hubitat pushes events formatted inside the "content" subfield
      local event = data.content
      log.info(string.format("Received Hubitat Event: Device %s, Attribute %s, Value %s", 
        tostring(event.deviceId), tostring(event.name), tostring(event.value)))
        
      -- Sync state to appropriate SmartThings child device
      sync_hubitat_event_to_st(driver, event)
    end
  end
end

function start_callback_server(driver, port)
  cosock.spawn(function()
    local server = assert(socket.bind("*", port))
    log.info(string.format("Local HTTP Callback Server listening on port %d", port))
    
    while true do
      local client, err = server:accept()
      if client then
        -- Spawn a task to handle each client asynchronously
        cosock.spawn(function()
          pcall(handle_client, client, driver)
        end, "http_client_handler")
      else
        log.error("Server accept failed: " .. tostring(err))
        socket.sleep(1)
      end
    end
  end, "http_server_listener")
end
```

---

## 3. Dynamic Callback Registration

To configure Hubitat to push events to the Edge driver:
1. Determine the SmartThings Hub IP address on the local network (e.g. using `socket.tcp():getsockname()`).
2. Construct the callback URL: `http://<ST_Hub_IP>:<Port>/callback`.
3. Submit a POST request to Hubitat's Maker API setting configuration endpoint:
   - **Endpoint**: `POST /postURL/<encoded_callback_url>?access_token=<Token>`
   - This registers the callback automatically during driver startup (`init`).
