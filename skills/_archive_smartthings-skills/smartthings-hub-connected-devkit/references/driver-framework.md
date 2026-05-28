# Driver Framework — Full Lua SDK Reference

Load this when you need deep API details beyond what's in SKILL.md.

## Driver Constructor

```lua
local driver = Driver("driver_name", {
  discovery = function(driver, _, should_continue) end,
  lifecycle_handlers = {
    added = fn(driver, device),
    init = fn(driver, device),
    removed = fn(driver, device),
    goOnline = fn(driver, device),
    goOffline = fn(driver, device),
    infoChanged = fn(driver, device, event, args),
  },
  lan_info_changed_handler = fn(driver, hub_ipv4),  -- LAN only
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = fn(driver, device, command),
    },
  },
})

driver:run()
```

### Driver-level options

| Option | Type | Description |
|---|---|---|
| `shared_device_thread_enabled` | bool | Set `true` to share device threads. Used by multi-component drivers. |

### `lan_info_changed_handler`

Called when hub's IPv4 address changes. Used to resubscribe event listeners:
```lua
local function lan_info_changed(driver, hub_ipv4)
  if driver.server and driver.server.listen_ip ~= hub_ipv4 then
    log.info_with({ hub_logs = true }, "hub IP changed, resubscribing")
    driver.server:shutdown()
    driver.server = SubscriptionServer:new_server()
    resubscribe_all(driver)
  end
end
```

## Lifecycle Handlers

### `added` — Device first paired

Store initial config from `device.data`, start background tasks.

```lua
local function device_added(driver, device)
  local dd = device.data or {}
  if dd.host_ip then
    device:set_field("host_ip", dd.host_ip, {persist = true})
  end
  -- start event listening / polling
end
```

### `init` — Hub restart or driver reload

**Guard against the double-init bug:**
```lua
local function device_init(driver, device)
  if device:get_field("init_started") then return end
  device:set_field("init_started", true)

  -- Re-establish connections, poll schedules, etc.
end
```

### `removed` — Device unpaired

Cleanup timers, websockets, subscription servers:
```lua
local function device_removed(driver, device)
  local listener = device:get_field("listener")
  if listener then listener:stop() end
end
```

### `infoChanged` — Device label changed

```lua
local function info_changed(driver, device, event, args)
  if device.label ~= args.old_st_store.label then
    -- sync name to physical device
  end
end
```

## Device API

### Field Storage

```lua
device:set_field("key", value, {persist = true})  -- survives restart
device:set_field("key", value)                     -- temp, lost on restart
device:get_field("key")
```

### Parent / Child Navigation

```lua
local parent = device:get_parent()
for _, child in device:get_children() do
  -- each child is a full device object
end
```

### Device Metadata

```lua
device.label
device.device_network_id
device.data           -- pairing-time config data
device.profile        -- profile name string
device:get_field("key")
```

### Health

```lua
device:online()     -- mark reachable
device:offline()    -- mark unreachable
```

### Creating Devices

```lua
driver:try_create_device({
  type = "LAN",
  device_network_id = "my-device-123",    -- globally unique
  label = "My Device",
  profile = "my-switch",                   -- matches profiles/<name>.yml
  manufacturer = "Acme Corp",
  model = "Switch 2000",
  vendor_provided_label = "Acme Switch",
  data = {
    device_id = "123",                    -- accessible via device.data
  }
})
```

## Scheduling

### On device thread (preferred)
```lua
-- Periodic (every N seconds)
device.thread:call_on_schedule(30, function()
  poll_device(driver, device)
end, device.id .. "-poll")

-- One-shot delay
device.thread:call_with_delay(5, function()
  do_something()
end)

-- Cancel a timer
local timer = device.thread:call_with_delay(30, fn)
device.thread:cancel_timer(timer)
```

### Driver-level
```lua
driver:call_on_schedule(600, function()
  ip_change_check()
end, "IP Change Check")
```

## Backoff Pattern

From official Wemo/Bose drivers. Use during init re-discovery:

```lua
local function backoff_builder(max, inc, rand)
  local count = 0
  inc = inc or 1
  return function()
    local randval = 0
    if rand then
      randval = math.random() * rand * 2 - rand
    end
    local base = inc * (2 ^ count - 1)
    count = count + 1
    if max then base = math.min(base, max) end
    return math.max(base + randval, 0)
  end
end
```

## Enumeration

```lua
local device_list = driver:get_devices()
for _, device in ipairs(device_list) do
  -- all devices managed by this driver
end
```

## Utility Modules

```lua
local utils = require "st.utils"
utils.stringify_table(t)   -- pretty-print a table for logging
```

## Event Emission Reference

```lua
capabilities.switch.switch.on()
capabilities.switch.switch.off()
capabilities.switchLevel.level(number)                          -- 0-100
capabilities.motionSensor.motion.active()
capabilities.motionSensor.motion.inactive()
capabilities.contactSensor.contact.open()
capabilities.contactSensor.contact.closed()
capabilities.waterSensor.water.wet()
capabilities.waterSensor.water.dry()
capabilities.smokeDetector.smoke.detected()
capabilities.smokeDetector.smoke.clear()
capabilities.temperatureMeasurement.temperature({ value = number, unit = "C"|"F" })
capabilities.relativeHumidityMeasurement.humidity({ value = number, unit = "%" })
capabilities.illuminanceMeasurement.illuminance({ value = number, unit = "lux" })
capabilities.battery.battery({ value = number, unit = "%" })
capabilities.powerMeter.power({ value = number, unit = "W" })
capabilities.energyMeter.energy({ value = number, unit = "Wh" })
capabilities.voltageMeasurement.voltage({ value = number, unit = "V" })
capabilities.colorControl.hue({ value = number })               -- 0-360
capabilities.colorControl.saturation({ value = number })         -- 0-100
capabilities.colorControl.color({ hue = number, saturation = number })
capabilities.colorTemperature.colorTemperature({ value = number })  -- Kelvin
capabilities.lock.lock.lock()
capabilities.lock.lock.unlock()
capabilities.lock.lock.jammed()
capabilities.thermostatMode.thermostatMode({ value = "heat"|"cool"|"auto"|"off" })
capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = number, unit = "C" })
capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = number, unit = "C" })
capabilities.fanSpeed.fanSpeed({ speed = "low"|"medium"|"high"|"auto"|"off" })
capabilities.audioVolume.volume(number)                          -- 0-100
capabilities.audioMute.mute.muted()
capabilities.audioMute.mute.unmuted()
capabilities.mediaPlayback.playbackStatus.playing()
capabilities.mediaPlayback.playbackStatus.paused()
capabilities.mediaPlayback.playbackStatus.stopped()
```

## Command Object

```lua
command.args              -- table of arguments
command.args.level        -- for switchLevel.setLevel: 0-100
command.args.hue          -- for colorControl.setHue: 0-360
command.args.saturation   -- for colorControl.setSaturation: 0-100
command.args.url          -- for audioNotification.playTrack
```
