---
name: edge-log-analysis
description: >
  Debug and troubleshoot SmartThings Edge drivers using logcat and log analysis.
  Covers the smartthings CLI logcat command, common runtime errors (nil indexing,
  yield boundary issues, socket timeouts, JSON decode failures), and strategies
  for parsing logs to identify driver crashes or device disconnects. Use when:
  (1) a driver crashes or fails to respond, (2) you need to analyze log output,
  (3) debug connection errors, or (4) diagnose device health issues.
---

# SmartThings Edge Driver Log Analysis & Diagnostics

This skill explains how to debug and trace SmartThings Edge drivers using the SmartThings CLI and how to interpret and resolve the most common Lua runtime errors.

---

## 1. Using SmartThings CLI Logcat

The most important tool for debugging Edge drivers is the log stream, accessed via the SmartThings CLI:

### Start Log Tail (Live Stream)
```bash
smartthings edge:drivers:logcat
```

- This command will query your network for active SmartThings Hubs.
- Select the target Hub.
- Select your target driver from the list.
- To tail log output of **all** drivers concurrently:
  ```bash
  smartthings edge:drivers:logcat --all
  ```

---

## 2. Common Errors & How to Fix Them

### A. "attempt to index a nil value"
This is the most common error in Lua. It happens when you try to access a key on a variable that is `nil`.

#### Example log output:
```
2026-05-27T12:00:00.123Z ERROR my-driver  init.lua:42: attempt to index a nil value (field 'preferences')
```

#### Causes & Fixes:
1. **Uninitialized device settings**: On first add, `device.preferences` might not contain some user settings.
   - *Fix*: Always use default fallbacks:
     ```lua
     local ip = device.preferences.ipAddress or "192.168.1.100"
     ```
2. **Accessing parent field before it exists**: Child devices attempting to call API methods on a parent bridge that hasn't finished booting up.
   - *Fix*: Defend with safety checks:
     ```lua
     local parent = driver:get_device_info(device.parent_device_id)
     if parent then
       local client = parent:get_field("api_client")
       if client then
         -- safely use client
       end
     end
     ```

---

### B. "attempt to yield across C-call boundary"
This error happens when code running inside a standard Lua `pcall` or `xpcall` tries to yield control back to the `cosock` scheduler (e.g. by using `socket.sleep` or making a non-blocking network socket call).

#### Example log output:
```
2026-05-27T12:05:00.456Z ERROR my-driver  cosock/socket.lua:89: attempt to yield across C-call boundary
```

#### Causes & Fixes:
- SmartThings runs Lua 5.3, which allows yielding across C boundaries in many cases, but certain standard library function wrappers (like `table.foreach` or custom C-based libraries) can still trigger it.
- *Fix*: If you are wrapping code in `pcall` that performs socket I/O or sleep calls, make sure you aren't doing it within standard C-boundary loops. For network calls, let `cosock` handle errors at the coroutine level instead of nested pcalls, or write custom yield-safe pcall logic.

---

### C. Socket Timeouts ("timeout")
Cooperative socket calls fail if the target device is offline or the hub's network changes.

#### Example log output:
```
2026-05-27T12:10:00.789Z WARN  my-driver  vendor/api.lua:35: GET request failed: timeout
```

#### Causes & Fixes:
- **Set realistic timeouts**: The default TCP timeout in Lua can be extremely long (sometimes minutes). If not set, it will lock your coroutine.
- *Fix*: Always set a cooperative timeout (between 2 to 5 seconds):
  ```lua
  local client = socket.tcp()
  client:settimeout(3.0) -- 3 seconds timeout
  ```
- **Emit Offline health status**: If a poll fails multiple times in a row, mark the device offline:
  ```lua
  device:offline()
  ```

---

### D. JSON Decode Failures ("Expected value at line 1 column 1")
Occurs when parsing HTTP responses that return HTML error pages or empty bodies instead of JSON.

#### Example log output:
```
2026-05-27T12:15:00.999Z ERROR my-driver  st.json:110: Expected value at line 1 column 1
```

#### Causes & Fixes:
- *Fix*: Check the HTTP response status code and the response header first before decoding the body:
  ```lua
  if status_code == 200 then
    local data, err = json.decode(body)
    if err then
      log.error("Failed to decode JSON: " .. tostring(err))
    end
  else
    log.warn("Server returned HTTP: " .. tostring(status_code))
  end
  ```

---

## 3. Log Levels and Best Practices

Use structured log levels to make analysis cleaner:

| Log Level | Function | Target / Use Case |
|---|---|---|
| **Debug** | `log.debug` | High-frequency events (raw bytes, packet headers, JSON payloads) |
| **Info** | `log.info` | Lifecycle events, successful state changes, user interactions |
| **Warn** | `log.warn` | Transient connection failures, retries, bad user configuration |
| **Error** | `log.error` | Driver crashes, hardware disconnects, unrecoverable states |

---

## 4. Diagnostics Checklist

When analyzing logs to troubleshoot a bug:
1. **Identify the device**: Check which device label or device ID the error logs reference.
2. **Find the stack trace**: Trace the error back to the filename and line number (e.g. `init.lua:124`).
3. **Verify the network state**: Check if the hub and device are on the same subnet (subnet mismatch is a common cause of LAN discovery/communication issues).
4. **Inspect device datastore**: Dump fields or preferences to make sure they contain what you expect.
