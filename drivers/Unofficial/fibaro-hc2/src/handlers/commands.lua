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
  if utils.is_bridge(device) then
    local ok, err = sync.sync_bridge_inventory(driver, device)
    if not ok and err then
      log.warn(string.format("Bridge refresh failed for %s: %s", device.label, tostring(err)))
    end
  else
    local ok, err = sync.refresh_child(driver, device)
    if not ok and err then
      log.warn(string.format("Child refresh failed for %s: %s", device.label, tostring(err)))
    end
  end
end

function commands.switch_on(driver, device)
  if not utils.is_bridge(device) and (device:get_field(fields.HC2_DEVICE_KIND) == "switch" or device:get_field(fields.HC2_DEVICE_KIND) == "dimmer") then
    emit_optimistic_switch(device, true)
  end

  local ok, err = sync.execute_child_action(driver, device, "turnOn", {})
  if not ok and err then
    log.warn(string.format("Switch on failed for %s: %s", device.label, tostring(err)))
  end
end

function commands.switch_off(driver, device)
  if not utils.is_bridge(device) and (device:get_field(fields.HC2_DEVICE_KIND) == "switch" or device:get_field(fields.HC2_DEVICE_KIND) == "dimmer") then
    emit_optimistic_switch(device, false)
  end

  local ok, err = sync.execute_child_action(driver, device, "turnOff", {})
  if not ok and err then
    log.warn(string.format("Switch off failed for %s: %s", device.label, tostring(err)))
  end
end

function commands.set_level(driver, device, cmd)
  local level = cmd.args.level or 0
  local scaled = utils.clamp(math.floor(level + 0.5), 0, 99)

  if not utils.is_bridge(device) and device:get_field(fields.HC2_DEVICE_KIND) == "dimmer" then
    emit_optimistic_level(device, scaled)
  end

  local ok, err = sync.execute_child_action(driver, device, "setValue", { scaled })
  if not ok and err then
    log.warn(string.format("Set level failed for %s: %s", device.label, tostring(err)))
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
