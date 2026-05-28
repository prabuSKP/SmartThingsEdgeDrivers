---
name: websocket-debugging
description: >
  Establish and maintain WebSocket connections in SmartThings Edge drivers.
  Covers websocket client handshakes, connection loops, heartbeat (ping/pong) management,
  reconnection with exponential backoff, and processing incoming message frames. Use when:
  (1) a local bridge pushes event streams via WebSocket, (2) you need to implement a websocket
  client, or (3) troubleshooting socket disconnects and stale connection loops.
---

# SmartThings Edge WebSocket Integration & Debugging

This skill explains how to build a reliable WebSocket client within the cooperative multitasking (`cosock`) environment of a SmartThings Edge driver. WebSockets are used for real-time state synchronization, enabling vendor bridges (like Home Assistant or custom hubs) to push instant updates to SmartThings.

---

## 1. WebSocket Client Architecture

In the single-threaded, cooperative environment of an Edge driver, a WebSocket listener must run in a dedicated background coroutine spawned via `cosock.spawn`.

```
[Main Driver Thread]
        │ (spawns)
        ▼
[WebSocket Coroutine] ──(handshake)──► [Vendor Hub WebSocket Server]
        │
        ├─► [Read Loop] ──────(receives frame)─────► Parse state & emit event
        │
        └─► [Heartbeat Loop] ──(sends ping/pong)──► Keeps socket alive
```

---

## 2. Implementing a WebSocket Client Skeletons

Below is a complete implementation of a WebSocket client built using cooperative TCP sockets.

### A. Connection and Handshake Logic
A WebSocket connection begins with an HTTP upgrade handshake request:

```lua
local socket = require "cosock.socket"
local log = require "log"
local base64 = require "st.base64"

local WebSocketClient = {}
WebSocketClient.__index = WebSocketClient

function WebSocketClient.new(ip, port, path)
  local self = setmetatable({}, WebSocketClient)
  self.ip = ip
  self.port = port or 80
  self.path = path or "/"
  self.socket = nil
  self.is_connected = false
  return self
end

function WebSocketClient:connect()
  log.info(string.format("Connecting WebSocket to %s:%d%s", self.ip, self.port, self.path))
  
  local tcp = socket.tcp()
  tcp:settimeout(5.0)
  
  local success, err = tcp:connect(self.ip, self.port)
  if not success then
    return false, "TCP connection failed: " .. tostring(err)
  end
  
  -- Generate handshake key
  local key = base64.encode("random_handshake_key_16bytes")
  
  -- Send HTTP Upgrade request
  local handshake = string.format(
    "GET %s HTTP/1.1\r\n" ..
    "Host: %s:%d\r\n" ..
    "Upgrade: websocket\r\n" ..
    "Connection: Upgrade\r\n" ..
    "Sec-WebSocket-Key: %s\r\n" ..
    "Sec-WebSocket-Version: 13\r\n\r\n",
    self.path, self.ip, self.port, key
  )
  
  tcp:send(handshake)
  
  -- Read HTTP response headers
  local status_line, err = tcp:receive("*l")
  if not status_line or not string.match(status_line, "101 Switching Protocols") then
    tcp:close()
    return false, "Handshake failed: " .. tostring(status_line or err)
  end
  
  -- Read remaining headers until empty line
  while true do
    local line = tcp:receive("*l")
    if not line or line == "" then
      break
    end
  end
  
  self.socket = tcp
  self.is_connected = true
  log.info("WebSocket handshake successful.")
  return true
end
```

---

### B. Frame Processing & Parsing
WebSocket messages are encapsulated in data frames. A basic text frame parser must inspect the opcode and extract the payload.

```lua
-- Minimal WebSocket frame reader (Opcode 1 = Text, 8 = Close)
function WebSocketClient:receive_frame()
  if not self.socket then return nil, "Closed" end
  
  -- Read first 2 bytes of the frame header
  local head_bytes, err = self.socket:receive(2)
  if not head_bytes then return nil, err end
  
  local byte1 = string.byte(head_bytes, 1)
  local byte2 = string.byte(head_bytes, 2)
  
  local fin = (bit32.band(byte1, 0x80) ~= 0)
  local opcode = bit32.band(byte1, 0x0F)
  local masked = (bit32.band(byte2, 0x80) ~= 0)
  local payload_len = bit32.band(byte2, 0x7F)
  
  if payload_len == 126 then
    local len_bytes = self.socket:receive(2)
    payload_len = string.byte(len_bytes, 1) * 256 + string.byte(len_bytes, 2)
  elseif payload_len == 127 then
    return nil, "64-bit frame payload sizes not supported"
  end
  
  -- If server masked the frame (rare, servers usually don't mask to clients)
  local mask = nil
  if masked then
    mask = {string.byte(self.socket:receive(4), 1, 4)}
  end
  
  -- Read payload
  local payload, read_err = self.socket:receive(payload_len)
  if not payload then return nil, read_err end
  
  if masked and mask then
    local unmasked = {}
    for i = 1, #payload do
      local p_byte = string.byte(payload, i)
      local m_byte = mask[((i - 1) % 4) + 1]
      table.insert(unmasked, string.char(bit32.bxor(p_byte, m_byte)))
    end
    payload = table.concat(unmasked)
  end
  
  return opcode, payload
end
```

---

### C. Connection Loop with Reconnection Backoff
Ensure your WebSocket handler includes automatic reconnect logic using exponential backoff to handle hub/router restarts:

```lua
local cosock = require "cosock"
local json = require "st.json"

function start_websocket_sync(driver, device, ip, port, path)
  cosock.spawn(function()
    local ws = WebSocketClient.new(ip, port, path)
    local retry_delay = 2 -- seconds
    local max_retry_delay = 60

    while true do
      local connected, err = ws:connect()
      if connected then
        retry_delay = 2 -- Reset backoff on success
        
        -- Start listening loop
        while ws.is_connected do
          local opcode, payload = ws:receive_frame()
          if not opcode then
            log.error("WebSocket receive error: " .. tostring(payload))
            ws.is_connected = false
            break
          end
          
          if opcode == 1 then -- Text Frame
            local status, data = pcall(json.decode, payload)
            if status and data then
              -- Sync states to SmartThings
              pcall(sync_websocket_message, driver, device, data)
            end
          elseif opcode == 8 then -- Close Frame
            log.info("Server closed WebSocket connection")
            ws.is_connected = false
            break
          end
        end
      else
        log.warn(string.format("WS Connect failed: %s. Retrying in %d seconds...", tostring(err), retry_delay))
        socket.sleep(retry_delay)
        retry_delay = math.min(retry_delay * 2, max_retry_delay)
      end
    end
  end, "websocket_sync_thread")
end
```

---

## 3. Keep-Alives & Heartbeats

Many servers automatically close WebSocket connections if no data is sent within a timeout period (typically 30–60 seconds).
- **Ping / Pong**: Add a heartbeat loop inside a separate coroutine or via `driver:call_on_schedule` that sends a ping frame (opcode 9) or a JSON ping payload (e.g. `{"type": "ping"}`) every 30 seconds to keep the connection alive.
- **Close handling**: Always close and clean up the TCP socket client explicitly if a write fails, which forces the reconnect loop to run.
