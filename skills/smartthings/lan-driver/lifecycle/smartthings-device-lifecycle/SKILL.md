---
name: smartthings-device-lifecycle
description: >
  Manage SmartThings Edge device lifecycle events (added, init, infoChanged, removed).
  Covers startup sequences, bridge vs child initialization, reboot handling, datastore
  persistence, and clean teardown. Use when: (1) implementing lifecycle callbacks in
  init.lua, (2) handling device renames or setting updates, (3) managing hub reboot recovery,
  or (4) cleaning up resources (timers, sockets) when a device is deleted.
---

# SmartThings Edge Device Lifecycle

This skill explains how to handle the standard SmartThings Edge driver device lifecycle events. Proper lifecycle management ensures that your driver starts up reliably, recovers after hub reboots, updates dynamically when settings change, and cleans up resources when devices are removed.

## Lifecycle Event Map

SmartThings Edge drivers register lifecycle handlers during instantiation:

```lua
local my_driver = Driver("my_driver", {
  discovery = discovery.discover,
  lifecycle_handlers = {
    added = lifecycle.device_added,
    init = lifecycle.device_init,
    infoChanged = lifecycle.device_info_changed,
    removed = lifecycle.device_removed
  },
  driver_lifecycle_handlers = {
    -- Optional: global startup/shutdown events
  }
})
```

---

## 1. Lifecycle Events Flow

When a device is added, initialized, updated, or removed, events are triggered in a specific sequence:

### Device Creation Flow
```
[User starts Discovery / Child Added]
               ↓
          1. added()         -- One-time setup, default settings
               ↓
          2. init()          -- Driver startup, network setup, start polling
```

### Hub Reboot / Driver Restart Flow
```
[Hub Reboot / Driver Update]
               ↓
          1. init()          -- Network setup, start polling (added NOT called)
```

### Configuration / Renaming Flow
```
[User edits Settings or Renames Device]
               ↓
       infoChanged()         -- Compare preferences, restart loops if settings changed
```

### Deletion Flow
```
[User deletes Device]
               ↓
          removed()          -- Clean up timers, close sockets, free memory
```

---

## 2. Event Handlers Reference & Implementation

### A. `added` (Device Added)
Called **exactly once** when the device is first created (either via discovery or child device addition).
- **Purpose**: Initialize default states in the driver's datastore (`device:set_field`), emit default capability states, or set initial metadata.
- **Rules**: Do not start network communication, long-running timers, or polling loops in `added` — do these in `init`.

```lua
local function device_added(driver, device)
  log.info(string.format("[%s] Device added", device.label))
  
  -- Check if it is the parent bridge or a child device.
  -- A bridge has NO parent_assigned_child_key. Do NOT test parent_device_id == nil —
  -- it can behave inconsistently in the Edge runtime (see Rule 15).
  if device.parent_assigned_child_key == nil then
    -- It is the parent/bridge device
    device:set_field("is_bridge", true, {persist = true})
  else
    -- It is a child device
    log.info(string.format("[%s] Child device added. Key: %s", device.label, device.parent_assigned_child_key))
  end
end
```

### B. `init` (Device Initialized)
Called **every time the driver starts up** (after driver update, hub reboot) and right after the `added` lifecycle event when a new device is created.
- **Purpose**: Initialize network clients, establish TCP/WebSocket connections, restore persistent state from the datastore, and start polling loops or timers.
- **Rules**: Must handle the case where the device is already initialized (defend against duplicate init).

```lua
local function device_init(driver, device)
  log.info(string.format("[%s] Device initialized", device.label))
  
  -- Restore network address or API tokens from preferences or field store
  local ip = device.preferences.ipAddress
  local port = device.preferences.port
  
  -- Start device-specific polling timer or connection if it's the parent bridge
  if device:get_field("is_bridge") then
    -- Prevent duplicate init if already running
    if device:get_field("polling_timer") ~= nil then
      log.info(string.format("[%s] Polling loop already active", device.label))
      return
    end
    
    -- Instantiate API client
    local client = ApiClient.new(ip, port)
    device:set_field("api_client", client)
    
    -- Start polling loop
    local timer = driver:call_on_schedule(30, function()
      -- Perform poll safely wrapped in pcall
      local status, err = pcall(function()
        client:poll_device_states(driver, device)
      end)
      if not status then
        log.error("Poll failed: ", err)
      end
    end)
    device:set_field("polling_timer", timer)
  else
    -- Child device: parent handles its communication
    log.info(string.format("[%s] Child initialized", device.label))
  end
end
```

### C. `infoChanged` (Info/Settings Changed)
Called when device settings (preferences) are changed in the SmartThings app, or when the device is renamed/assigned to a room.
- **Purpose**: Detect configuration updates, validate network credentials, and restart polling or sockets if the IP/token changed.
- **Rules**: Check what changed by comparing current preferences against previous values. Do not tear down loops unless a critical setting (IP, port, token) changed.

```lua
local function device_info_changed(driver, device, event, args)
  log.info(string.format("[%s] Info changed", device.label))
  
  -- Compare previous preference values with current values
  local old_ip = args.old_st_store.preferences.ipAddress
  local new_ip = device.preferences.ipAddress
  
  local old_port = args.old_st_store.preferences.port
  local new_port = device.preferences.port
  
  if old_ip ~= new_ip or old_port ~= new_port then
    log.info("Network settings changed. Reinitializing API client...")
    
    -- 1. Cancel existing polling timer
    local old_timer = device:get_field("polling_timer")
    if old_timer then
      device.thread:cancel_timer(old_timer)
      device:set_field("polling_timer", nil)
    end
    
    -- 2. Build new client
    local client = ApiClient.new(new_ip, new_port)
    device:set_field("api_client", client)
    
    -- 3. Restart polling timer
    local timer = device.thread:call_on_schedule(30, function()
      pcall(client.poll_device_states, client, driver, device)
    end)
    device:set_field("polling_timer", timer)
  end
end
```

### D. `removed` (Device Removed)
Called when the user deletes the device from their SmartThings account.
- **Purpose**: Terminate background threads, close sockets, cancel timers, and purge metadata caches to prevent memory leaks.
- **Rules**: You must release all resources associated with the device. If the deleted device is a bridge, cleanly disconnect from the vendor hub.

```lua
local function device_removed(driver, device)
  log.info(string.format("[%s] Device removed", device.label))
  
  -- 1. Cancel timers
  local timer = device:get_field("polling_timer")
  if timer then
    device.thread:cancel_timer(timer)
    device:set_field("polling_timer", nil)
  end
  
  -- 2. Close active network connections
  local client = device:get_field("api_client")
  if client and client.close then
    client:close()
  end
  
  -- 3. Clean up datastore references
  device:set_field("api_client", nil)
  device:set_field("is_bridge", nil)
  
  log.info(string.format("[%s] Cleanup complete", device.label))
end
```

---

## 3. Bridge vs. Child Device Startup Sequences

When managing a parent-child topology, startup initialization must follow a strict dependency order:

### Bridge Startup Sequence
1. **`device_init`** starts on the Bridge device.
2. Bridge fetches or reads stored child metadata from `device.datastore`.
3. Bridge sets up its vendor HTTP/WS client.
4. Bridge initializes state-sync.

### Child Device Startup Sequence
1. **`device_init`** starts on the Child device.
2. The Child checks if the parent bridge exists in the driver's active devices list:
   ```lua
   local parent = driver:get_device_info(device.parent_device_id)
   ```
3. If parent is initialized, the child registers itself with the parent's mapping cache.
4. If parent is not yet initialized (e.g. during a hub reboot where child init fired first), the child registers a callback or waits for the parent to take control.

**Robust Child-Parent Hook Pattern:**
```lua
-- In child device init
local parent = driver:get_device_info(device.parent_device_id)
if parent then
  local parent_client = parent:get_field("api_client")
  if parent_client then
    -- Parent is ready, map state immediately
    log.info("Parent is active, sync child status")
  else
    log.warn("Parent is present but API client is not initialized yet")
  end
else
  log.error("Parent bridge device not found!")
end
```

---

## 4. Troubleshooting & Best Practices

- **Avoid heavy computation in init**: The SmartThings Edge runtime kills drivers that block the main loop for more than a few seconds. Do heavy sync work inside a spawned `cosock` coroutine or spread it using timers.
- **Timer Management**: Always store timer references in the device fields: `device:set_field("my_timer", timer)`. Cancel the timer explicitly on `removed` or before creating a new timer.
- **Handling infoChanged Loops**: SmartThings can occasionally fire `infoChanged` repeatedly on startup. Ensure you compare the values inside the args to see if a change actually occurred before restarting connection pools.
- **Double-Initialization Guard (must be SESSION-ONLY, `persist = false`)**: A guard prevents duplicate init **within one boot** (e.g. `added` then `init`). It must **NOT be persisted**. `device_init` is meant to run on *every* driver start — that is where you (re)start the poll timer and rebuild non-persisted runtime state. If the guard is persisted (`persist = true`), then after a **hub reboot or driver update** `init` sees the stored flag, returns early, and **never restarts the poll timer — state sync silently dies** until the user changes a setting or re-adds the device. Use `persist = false`, and make timer setup idempotent (`cancel_*_timer()` then `start_*_timer()`) so re-running init is always safe:
  ```lua
  if device:get_field(fields.INIT) then
    log.info("Device already initialized this session, skipping init")
    return
  end
  device:set_field(fields.INIT, true, { persist = false })  -- session-only; resets on reboot so init runs again
  ```
