local capabilities = require "st.capabilities"
local log = require "log"

local sync = require "fibaro.sync"
local utils = require "utils"

local commands = {}

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
  local ok, err = sync.execute_child_action(driver, device, "turnOn", {})
  if not ok and err then
    log.warn(string.format("Switch on failed for %s: %s", device.label, tostring(err)))
  end
end

function commands.switch_off(driver, device)
  local ok, err = sync.execute_child_action(driver, device, "turnOff", {})
  if not ok and err then
    log.warn(string.format("Switch off failed for %s: %s", device.label, tostring(err)))
  end
end

function commands.set_level(driver, device, cmd)
  local level = cmd.args.level or 0
  local scaled = utils.clamp(math.floor(level + 0.5), 0, 99)
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
