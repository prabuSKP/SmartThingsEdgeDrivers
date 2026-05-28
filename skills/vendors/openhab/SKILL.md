---
name: openhab
description: >
  Integrate openHAB smart home servers with SmartThings Edge drivers.
  Covers fetching items (/rest/items), sending state commands (POST plaintext), and
  reading real-time event updates via Server-Sent Events (SSE) streams in Lua. Use
  when building or debugging openHAB-to-SmartThings bridge integrations.
---

# openHAB Local Integration Guide

This skill details how to interface with local openHAB instances using REST APIs and Server-Sent Events (SSE) for real-time updates.

---

## 1. Inventory & Command REST API

openHAB uses a clean, local REST interface that does not require tokens by default unless API security is enabled on the server (which uses standard HTTP Basic Auth or Bearer tokens).

### Fetching Items (Inventory)
- **Endpoint**: `GET /rest/items?recursive=false`
- **Response**: An array of item objects.

#### Key JSON Fields:
- `name`: Unique item ID (e.g. `LivingRoom_Light_Switch`).
- `type`: openHAB item type (e.g. `Switch`, `Dimmer`, `Number:Temperature`, `Contact`).
- `state`: Current string state (e.g. `ON`, `OFF`, `21.5`).
- `label`: Human-readable label name.

---

## 2. Controlling openHAB Items

To control an item, send a `POST` request with the command as raw plaintext in the body of the request:

- **Endpoint**: `POST /rest/items/<itemName>`
- **Headers**: `Content-Type: text/plain`
- **Payload**: Plaintext command string.

### Examples

#### Turn Switch ON
- **Endpoint**: `POST /rest/items/LivingRoom_Light_Switch`
- **Body**: `ON`

#### Turn Switch OFF
- **Endpoint**: `POST /rest/items/LivingRoom_Light_Switch`
- **Body**: `OFF`

#### Set Dimmer Level (0-100)
- **Endpoint**: `POST /rest/items/Kitchen_Lights_Dimmer`
- **Body**: `75`

---

## 3. Real-Time Push Events via Server-Sent Events (SSE)

openHAB publishes all state changes over Server-Sent Events (SSE) at `/rest/events`.

### SSE Protocol Details
An SSE stream is a persistent HTTP request. The server keeps the connection open and sends packets in the format:
```
event: ItemStateChangedEvent
data: {"type":"Switch","value":"ON","oldType":"Switch","oldValue":"OFF"}
```

### Implementing an SSE Listener in Lua
Since SSE is a long-lived TCP connection, read it line-by-line using a cooperative TCP socket:

```lua
local socket = require "cosock.socket"
local cosock = require "cosock"
local json = require "st.json"
local log = require "log"

local function read_sse_stream(ip, port, driver)
  cosock.spawn(function()
    local retry_delay = 2
    
    while true do
      local conn = socket.tcp()
      conn:settimeout(60.0) -- Long timeout for event streams
      
      local success, err = conn:connect(ip, port)
      if success then
        retry_delay = 2 -- Reset retry delay
        
        -- Send HTTP Request
        local req = "GET /rest/events?topics=openhab/items/*/statechanged HTTP/1.1\r\n" ..
                    "Host: " .. ip .. "\r\n" ..
                    "Accept: text/event-stream\r\n\r\n"
        conn:send(req)
        
        -- Skip HTTP response headers
        while true do
          local line = conn:receive("*l")
          if not line or line == "" then break end
        end
        
        log.info("SSE Stream connected.")
        
        -- Read Stream Loop
        local current_event_type = nil
        while true do
          local line, read_err = conn:receive("*l")
          if not line then
            log.error("SSE stream disconnected: " .. tostring(read_err))
            break
          end
          
          -- Parse SSE fields
          local event_type = string.match(line, "^event:%s*(.*)$")
          if event_type then
            current_event_type = event_type
          end
          
          local data_payload = string.match(line, "^data:%s*(.*)$")
          if data_payload and current_event_type == "ItemStateChangedEvent" then
            -- Find the item name from the topic metadata if available, 
            -- or extract details from the json
            local status, data = pcall(json.decode, data_payload)
            if status and data then
              -- Example: openHAB event payload contains "payload" and "topic"
              -- Extract item and value
              sync_openhab_item(driver, data)
            end
            current_event_type = nil -- reset
          end
        end
      else
        log.warn(string.format("SSE Connection failed: %s. Retrying in %d seconds...", tostring(err), retry_delay))
      end
      
      conn:close()
      socket.sleep(retry_delay)
      retry_delay = math.min(retry_delay * 2, 60)
    end
  end, "openhab_sse_listener")
end
```
