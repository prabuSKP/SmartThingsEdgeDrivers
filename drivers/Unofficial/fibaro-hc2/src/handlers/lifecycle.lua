local log = require "log"

local discovery = require "discovery"
local fields = require "fields"
local sync = require "fibaro.sync"
local utils = require "utils"

local lifecycle = {}

function lifecycle.init(driver, device)
  log.info_with({hub_logs = true}, string.format("[Fibaro] lifecycle.init called for device: %s", device.label))
  
  if device:get_field(fields.INIT) then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s already initialized, skipping", device.label))
    return
  end

  if utils.is_bridge(device) then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Initializing bridge device: %s", device.label))
    discovery.apply_pending_bridge_metadata(driver, device)
    sync.reschedule_bridge_poll(driver, device)
    local ok, err = sync.sync_bridge_inventory(driver, device)
    if not ok and err then
      log.info_with({hub_logs = true}, string.format("[Fibaro] Bridge %s initialized without active Fibaro connection: %s", device.label, tostring(err)))
    else
      log.info_with({hub_logs = true}, string.format("[Fibaro] Bridge %s initialized successfully", device.label))
    end
  else
    log.info_with({hub_logs = true}, string.format("[Fibaro] Initializing child device: %s", device.label))
    sync.apply_pending_child_metadata(driver, device)
  end

  device:set_field(fields.INIT, true, { persist = false })
  log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s initialization complete", device.label))
end

function lifecycle.added(driver, device)
  log.info_with({hub_logs = true}, string.format("[Fibaro] lifecycle.added called for device: %s", device.label))
  
  if utils.is_bridge(device) then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Bridge device added: %s", device.label))
    discovery.apply_pending_bridge_metadata(driver, device)
  else
    log.info_with({hub_logs = true}, string.format("[Fibaro] Child device added: %s", device.label))
    sync.apply_pending_child_metadata(driver, device)
  end

  lifecycle.init(driver, device)
end

function lifecycle.info_changed(driver, device)
  log.info_with({hub_logs = true}, string.format("[Fibaro] lifecycle.info_changed called for device: %s", device.label))
  
  if not utils.is_bridge(device) then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Skipping info_changed for non-bridge device: %s", device.label))
    return
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Bridge device info changed: %s, rescheduling poll", device.label))
  sync.reschedule_bridge_poll(driver, device)
  local ok, err = sync.sync_bridge_inventory(driver, device)
  if not ok and err then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Bridge %s infoChanged sync failed: %s", device.label, tostring(err)))
  else
    log.info_with({hub_logs = true}, string.format("[Fibaro] Bridge %s infoChanged sync successful", device.label))
  end
end

function lifecycle.removed(driver, device)
  log.info_with({hub_logs = true}, string.format("[Fibaro] lifecycle.removed called for device: %s", device.label))
  
  if utils.is_bridge(device) then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Removing bridge device: %s", device.label))
    sync.on_bridge_removed(driver, device)
  else
    log.info_with({hub_logs = true}, string.format("[Fibaro] Removing child device: %s", device.label))
  end
end

return lifecycle
