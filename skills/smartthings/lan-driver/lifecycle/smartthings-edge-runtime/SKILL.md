---
name: smartthings-edge-runtime
description: >
  Understand and debug the cooperative multitasking runtime environment of SmartThings Edge.
  Covers the cosock scheduler, coroutine management, non-blocking socket I/O, timers,
  avoiding main-thread blocking, and managing memory/CPU constraints. Use when:
  (1) writing polling loops, (2) handling asynchronous events via channels, (3) spawning
  background tasks using cosock, or (4) troubleshooting driver lockups/watchdog reboots.
---

# SmartThings Edge Runtime & Cosock Multitasking

SmartThings Edge drivers execute on a Lua runtime inside the SmartThings Hub. Because the hub environment uses cooperative multitasking, any driver that blocks the main execution thread will freeze the entire driver runtime, triggering the hub's watchdog to reboot or kill the driver.

This skill covers the mechanics of the `cosock` (Cooperative Sockets) scheduler, timers, and best practices for writing non-blocking asynchronous Lua code.

---

## 1. The Cosock Architecture

`cosock` is a coroutine-based cooperative multitasking scheduler. It intercepts network sockets and delays to run multiple tasks concurrently in a single-threaded runtime.

```
       [ Driver Main Event Loop ]
                   │
                   ▼
         [ Cosock Scheduler ]
          /        │        \
         ▼         ▼         ▼
  [Coroutine 1] [Coroutine 2] [Coroutine 3]
  (HTTP Poll)   (WS Client)   (Timer Queue)
```

### Cooperative Rules
- **No blocking calls**: Never use standard blocking APIs (e.g. `os.execute`, external blocking socket libraries, or infinite `while true do` loops without yields).
- **Explicit yielding**: Yield control back to the scheduler using `socket.sleep(seconds)` or by calling non-blocking socket operations.
- **Run under cosock**: All asynchronous threads must be spawned using `cosock.spawn`.

---

## 2. Asynchronous Tasks with `cosock.spawn`

To run background processes (like a WebSocket listener or a periodic state synchronization script), spawn them as a coroutine.

```lua
local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"

-- Spawn a background task
cosock.spawn(function()
  while true do
    log.info("Performing periodic network status check...")
    
    -- yield execution back to cosock for 5 seconds
    socket.sleep(5) 
  end
end, "network_monitor_task")
```

### Critical Rules for Spawned Tasks
1. **Always use `socket.sleep`**: Do **not** use `os.execute("sleep 5")` or a busy-loop (`while socket.gettime() < target do`). Doing so will block the entire driver.
2. **Error Handling inside Coroutines**: Standard Lua coroutines swallow errors. You must wrap the body of your task in `pcall` or `xpcall` to log errors, otherwise the thread will die silently.
3. **Use Descriptive Names**: Give the task a label (the second argument of `cosock.spawn`) to make logcat tracing easier.

---

## 3. Communication Channels (`cosock.channel`)

Channels are thread-safe message queues used to pass messages between different coroutines or driver threads.

```lua
local cosock = require "cosock"
local log = require "log"

-- Create a channel
local tx, rx = cosock.channel.new()

-- Writer thread
cosock.spawn(function()
  for i = 1, 5 do
    socket.sleep(1)
    tx:send("Message " .. tostring(i))
  end
end, "sender")

-- Reader thread
cosock.spawn(function()
  while true do
    -- Blocks this coroutine cooperatively until a message arrives
    local msg, err = rx:receive()
    if msg then
      log.info("Received: " .. msg)
    else
      log.error("Channel error: " .. tostring(err))
      break
    end
  end
end, "receiver")
```

---

## 4. Timers and Schedules

The SmartThings Edge SDK provides driver-level wrapper methods for timers. These should be used instead of raw `cosock` spawn loops for scheduling actions.

### A. One-Shot Timer (`call_with_delay`)
Runs a callback after a specified delay (in seconds).
```lua
driver:call_with_delay(5, function()
  log.info("Delayed action executed")
end)
```

### B. Recurring Schedule (`call_on_schedule`)
Runs a callback repeatedly at a specified interval (in seconds).
```lua
local my_timer = driver:call_on_schedule(60, function()
  log.info("Checking device health...")
end)

-- To cancel the schedule later
driver:cancel_timer(my_timer)
```

### Best Practices for Timers
- **Store Timer References**: Always save timer handles in the device’s fields (`device:set_field("poll_timer", timer)`) so you can cancel them on removal or update.
- **Wrap Callbacks in `pcall`**: If a timer callback crashes, it can crash the driver. Wrap calls in a protected call:
  ```lua
  driver:call_on_schedule(30, function()
    local success, err = pcall(do_network_poll, device)
    if not success then
      log.error("Poll error: " .. tostring(err))
    end
  end)
  ```

---

## 5. Cooperative Socket I/O

When building network clients (HTTP, TCP, UDP), import socket modules through `cosock` to get cooperative versions:

```lua
-- DO NOT do this:
-- local socket = require "socket"

-- DO THIS:
local socket = require "cosock.socket"
local http = require "cosock.http" -- if available
```

### TCP Client Example
```lua
local function connect_and_read(ip, port)
  local client = socket.tcp()
  client:settimeout(5.0) -- Cooperative timeout
  
  local success, err = client:connect(ip, port)
  if not success then
    log.error("Connect failed: " .. tostring(err))
    return nil
  end
  
  -- Send a command
  client:send("GET /api/status HTTP/1.1\r\nHost: " .. ip .. "\r\n\r\n")
  
  -- Receive a line (yields until data is available or timeout)
  local line, err = client:receive("*l")
  client:close()
  
  return line
end
```

---

## 6. CPU and Memory Limits

SmartThings hubs run on resource-constrained embedded systems. Follow these optimization guidelines:

- **Garbage Collection**: Lua uses automatic garbage collection, but in a bridge driver receiving hundreds of events, memory usage can balloon. Trigger manual GC collections during idle periods:
  ```lua
  collectgarbage("collect")
  ```
- **Limit Table Sizes**: Avoid appending infinite history to tables. If tracking events, use circular buffers or prune tables once they reach a maximum size.
- **Avoid string concatenation in tight loops**: Lua strings are immutable; concatenation (`a = a .. b`) allocates new memory. Use `string.format` or collect chunks in a list and use `table.concat`.
- **CPU Time Slices**: If you must loop through a large dataset (e.g. 500+ child devices), yield periodically to prevent watchdog alerts:
  ```lua
  for idx, child in ipairs(large_child_list) do
    process_child(child)
    if idx % 50 == 0 then
      socket.sleep(0.01) -- Yield briefly back to cosock
    end
  end
  ```
