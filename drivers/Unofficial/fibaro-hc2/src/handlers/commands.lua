local capabilities = require "st.capabilities"
local log = require "log"

local sync = require "fibaro.sync"
local utils = require "utils"
local fields = require "fields"

local commands = {}

local function emit_optimistic_switch(device, is_on)
  device:emit_event(is_on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
end

local function emit_optimistic_level(device, level)
  local scaled = utils.clamp(math.floor(level + 0.5), 0, 99)
  emit_optimistic_switch(device, scaled > 0)
  device:emit_event(capabilities.switchLevel.level(scaled))
end

function commands.do_refresh(driver, device)
  log.info_with({hub_logs = true}, string.format("[Fibaro] do_refresh called for device: %s", device.label))
  
  if utils.is_bridge(device) then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Refreshing bridge device: %s", device.label))
    local ok, err = sync.sync_bridge_inventory(driver, device)
    if not ok and err then
      log.warn_with({hub_logs = true}, string.format("[Fibaro] Bridge refresh failed for %s: %s", device.label, tostring(err)))
    else
      log.info_with({hub_logs = true}, string.format("[Fibaro] Bridge refresh successful for %s", device.label))
    end
  else
    log.info_with({hub_logs = true}, string.format("[Fibaro] Refreshing child device: %s", device.label))
    local ok, err = sync.refresh_child(driver, device)
    if not ok and err then
      log.warn_with({hub_logs = true}, string.format("[Fibaro] Child refresh failed for %s: %s", device.label, tostring(err)))
    else
      log.info_with({hub_logs = true}, string.format("[Fibaro] Child refresh successful for %s", device.label))
    end
  end
end

function commands.switch_on(driver, device)
  log.info_with({hub_logs = true}, string.format("[Fibaro] switch_on called for device: %s", device.label))
  
  if not utils.is_bridge(device) and (device:get_field(fields.HC2_DEVICE_KIND) == "switch" or device:get_field(fields.HC2_DEVICE_KIND) == "dimmer") then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Emitting optimistic switch ON for %s", device.label))
    emit_optimistic_switch(device, true)
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Executing turnOn action for device: %s", device.label))
  local ok, err = sync.execute_child_action(driver, device, "turnOn", {})
  if not ok and err then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Switch on failed for %s: %s", device.label, tostring(err)))
  else
    log.info_with({hub_logs = true}, string.format("[Fibaro] Switch on successful for %s", device.label))
  end
end

function commands.switch_off(driver, device)
  log.info_with({hub_logs = true}, string.format("[Fibaro] switch_off called for device: %s", device.label))
  
  if not utils.is_bridge(device) and (device:get_field(fields.HC2_DEVICE_KIND) == "switch" or device:get_field(fields.HC2_DEVICE_KIND) == "dimmer") then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Emitting optimistic switch OFF for %s", device.label))
    emit_optimistic_switch(device, false)
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Executing turnOff action for device: %s", device.label))
  local ok, err = sync.execute_child_action(driver, device, "turnOff", {})
  if not ok and err then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Switch off failed for %s: %s", device.label, tostring(err)))
  else
    log.info_with({hub_logs = true}, string.format("[Fibaro] Switch off successful for %s", device.label))
  end
end

function commands.set_level(driver, device, cmd)
  local level = cmd.args.level or 0
  local scaled = utils.clamp(math.floor(level + 0.5), 0, 99)
  
  log.info_with({hub_logs = true}, string.format("[Fibaro] set_level called for device: %s, level=%d, scaled=%d", device.label, level, scaled))

  if not utils.is_bridge(device) and device:get_field(fields.HC2_DEVICE_KIND) == "dimmer" then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Emitting optimistic level %d for %s", scaled, device.label))
    emit_optimistic_level(device, scaled)
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Executing setValue action for device: %s, level=%d", device.label, scaled))
  local ok, err = sync.execute_child_action(driver, device, "setValue", { scaled })
  if not ok and err then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Set level failed for %s: %s", device.label, tostring(err)))
  else
    log.info_with({hub_logs = true}, string.format("[Fibaro] Set level successful for %s, level=%d", device.label, scaled))
  end
end

commands.capability_handlers = {
  [capabilities.refresh.ID] = {
    [capabilities.refresh.commands.refresh.NAME] = commands.do_refresh,
  },
  [capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME] = commands.switch_on,
    [capabilities.switch.commands.off.NAME] = commands.switch_off,
  },
  [capabilities.switchLevel.ID] = {
    [capabilities.switchLevel.commands.setLevel.NAME] = commands.set_level,
  },
}

return commands
