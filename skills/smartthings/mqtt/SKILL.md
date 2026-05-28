---
name: mqtt
description: >
  Implement local MQTT clients inside SmartThings Edge drivers using cooperative sockets.
  Covers raw MQTT connection handshakes (CONNECT/CONNACK), subscribing to topics
  (SUBSCRIBE/SUBACK), publishing payloads (PUBLISH), variable-byte length parsing,
  and keep-alive heartbeats. Use when integrating local MQTT brokers (Mosquitto, etc.)
  directly with Edge drivers.
---

# SmartThings Edge Local MQTT Integration

Because the SmartThings Edge SDK does not include a native MQTT module, integrations that require MQTT (such as local Mosquitto brokers or MQTT-enabled devices) must implement a lightweight MQTT client using cooperative TCP sockets.

This skill provides a pure-Lua MQTT client skeleton designed to run inside a `cosock` coroutine.

---

## 1. MQTT Protocol Basics (V3.1.1)

MQTT is a binary protocol running over TCP. Communication involves sending packets with a **Fixed Header** (1 byte for type + flags, followed by a variable-byte length), a **Variable Header**, and a **Payload**.

### Packet Types (First Byte)
- `0x10`: CONNECT
- `0x20`: CONNACK (Server to Client)
- `0x30`: PUBLISH
- `0x82`: SUBSCRIBE
- `0x90`: SUBACK (Server to Client)
- `0xC0`: PINGREQ (Client to Server)
- `0xD0`: PINGRESP (Server to Client)
- `0xE0`: DISCONNECT

---

## 2. Implementing a Pure Lua MQTT Client

Below is a complete, cooperative client class:

```lua
local socket = require "cosock.socket"
local log = require "log"

local MQTTClient = {}
MQTTClient.__index = MQTTClient

function MQTTClient.new(ip, port, client_id)
  local self = setmetatable({}, MQTTClient)
  self.ip = ip
  self.port = port or 1883
  self.client_id = client_id or "st_edge_driver"
  self.socket = nil
  self.is_connected = false
  self.msg_id = 1
  return self
end

-- Helper to encode length (Variable Byte Integer)
local function encode_length(len)
  local bytes = {}
  repeat
    local digit = len % 128
    len = math.floor(len / 128)
    if len > 0 then
      digit = bit32.bor(digit, 0x80)
    end
    table.insert(bytes, string.char(digit))
  until len == 0
  return table.concat(bytes)
end

-- Helper to decode length from socket
local function decode_length(socket_conn)
  local multiplier = 1
  local value = 0
  repeat
    local byte, err = socket_conn:receive(1)
    if not byte then return nil, err end
    local digit = string.byte(byte)
    value = value + bit32.band(digit, 127) * multiplier
    multiplier = multiplier * 128
    if multiplier > 128*128*128 then
      return nil, "Malformed Remaining Length"
    end
  until bit32.band(digit, 128) == 0
  return value
end
```

### A. CONNECT Handshake
```lua
function MQTTClient:connect()
  local conn = socket.tcp()
  conn:settimeout(5.0)
  
  local success, err = conn:connect(self.ip, self.port)
  if not success then return false, err end
  
  self.socket = conn
  
  -- Build CONNECT payload
  local protocol_name = "\0\4MQTT"
  local protocol_level = string.char(4) -- V3.1.1
  local connect_flags = string.char(2)  -- Clean session
  local keep_alive = "\0\60"            -- 60 seconds
  local client_id_len = string.char(0, #self.client_id)
  
  local var_header = protocol_name .. protocol_level .. connect_flags .. keep_alive
  local payload = client_id_len .. self.client_id
  
  local remaining_len = #var_header + #payload
  local packet = string.char(0x10) .. encode_length(remaining_len) .. var_header .. payload
  
  self.socket:send(packet)
  
  -- Read CONNACK (Fixed 4 bytes)
  local connack, conn_err = self.socket:receive(4)
  if not connack or string.byte(connack, 1) ~= 0x20 or string.byte(connack, 4) ~= 0 then
    self:close()
    return false, "CONNACK rejected or failed: " .. tostring(conn_err)
  end
  
  self.is_connected = true
  log.info("MQTT Connection established.")
  return true
end

function MQTTClient:close()
  if self.socket then
    self.socket:send(string.char(0xE0, 0x00)) -- DISCONNECT
    self.socket:close()
  end
  self.socket = nil
  self.is_connected = false
end
```

### B. SUBSCRIBE to Topics
```lua
function MQTTClient:subscribe(topic)
  if not self.is_connected then return false, "Not connected" end
  
  local packet_id = self.msg_id
  self.msg_id = self.msg_id + 1
  
  local var_header = string.char(math.floor(packet_id / 256), packet_id % 256)
  local payload = string.char(0, #topic) .. topic .. string.char(0) -- QoS 0
  
  local remaining_len = #var_header + #payload
  local packet = string.char(0x82) .. encode_length(remaining_len) .. var_header .. payload
  
  self.socket:send(packet)
  
  -- Server responds with SUBACK (Header + 2 length bytes + 2 packet ID bytes + QoS status)
  local suback_head = self.socket:receive(2)
  if not suback_head or string.byte(suback_head, 1) ~= 0x90 then
    return false, "SUBACK failed"
  end
  
  local rem_len = decode_length(self.socket)
  self.socket:receive(rem_len) -- Consume packet payload
  return true
end
```

### C. PUBLISH Messages
```lua
function MQTTClient:publish(topic, payload)
  if not self.is_connected then return false, "Not connected" end
  
  local var_header = string.char(0, #topic) .. topic
  local remaining_len = #var_header + #payload
  local packet = string.char(0x30) .. encode_length(remaining_len) .. var_header .. payload
  
  local success, err = self.socket:send(packet)
  return success, err
end
```

---

## 3. The Listener Loop & Message Parser

To process incoming PUBLISH packets pushed by the broker, run a socket read loop inside a spawned coroutine:

```lua
function MQTTClient:listen_loop(callback)
  while self.is_connected do
    -- 1. Read first byte (Packet Type)
    local first_byte, err = self.socket:receive(1)
    if not first_byte then
      log.error("MQTT socket read error: " .. tostring(err))
      self.is_connected = false
      break
    end
    
    local packet_type = bit32.rshift(string.byte(first_byte), 4)
    
    -- 2. Read Remaining Length
    local remaining_len, len_err = decode_length(self.socket)
    if not remaining_len then
      log.error("Failed to decode remaining length: " .. tostring(len_err))
      self.is_connected = false
      break
    end
    
    -- 3. Read variable header and payload
    local data = ""
    if remaining_len > 0 then
      data, err = self.socket:receive(remaining_len)
      if not data then
        log.error("Failed to read payload: " .. tostring(err))
        self.is_connected = false
        break
      end
    end
    
    -- 4. Parse PUBLISH packet (type == 3)
    if packet_type == 3 then
      local topic_len = string.byte(data, 1) * 256 + string.byte(data, 2)
      local topic = string.sub(data, 3, 2 + topic_len)
      local payload = string.sub(data, 3 + topic_len)
      
      -- Invoke callback to handle state update
      pcall(callback, topic, payload)
    end
  end
end
```

---

## 4. Heartbeats & Reconnections

MQTT brokers will disconnect clients that do not send packets within the Keep-Alive window.
- **PINGREQ**: Send `0xC0 0x00` (Ping Request) every 30 seconds if no messages have been published.
- **Reconnect Wrapper**: Wrap client connection, subscriptions, and the `listen_loop` in an exponential backoff reconnect handler (analogous to the WebSocket reconnection pattern).
