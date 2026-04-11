local log = require "log"

local fields = require "fields"
local sync = require "fibaro.sync"
local utils = require "utils"

local lifecycle = {}

function lifecycle.init(driver, device)
  if device:get_field(fields.INIT) then
    return
  end

  if utils.is_bridge(device) then
    sync.reschedule_bridge_poll(driver, device)
    local ok, err = sync.sync_bridge_inventory(driver, device)
    if not ok and err then
      log.info(string.format("Bridge %s initialized without active Fibaro connection: %s", device.label, tostring(err)))
    end
  else
    sync.apply_pending_child_metadata(driver, device)
  end

  device:set_field(fields.INIT, true, { persist = false })
end

function lifecycle.added(driver, device)
  if not utils.is_bridge(device) then
    sync.apply_pending_child_metadata(driver, device)
  end

  lifecycle.init(driver, device)
end

function lifecycle.info_changed(driver, device)
  if not utils.is_bridge(device) then
    return
  end

  sync.reschedule_bridge_poll(driver, device)
  local ok, err = sync.sync_bridge_inventory(driver, device)
  if not ok and err then
    log.warn(string.format("Bridge %s infoChanged sync failed: %s", device.label, tostring(err)))
  end
end

function lifecycle.removed(driver, device)
  if utils.is_bridge(device) then
    sync.on_bridge_removed(driver, device)
  end
end

return lifecycle
