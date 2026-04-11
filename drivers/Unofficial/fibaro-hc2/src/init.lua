local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"

local commands = require "handlers.commands"
local discovery = require "discovery"
local lifecycle = require "handlers.lifecycle"

local fibaro_hc2 = Driver("fibaro-hc2", {
  discovery = discovery.discover,
  lifecycle_handlers = {
    init = lifecycle.init,
    added = lifecycle.added,
    infoChanged = lifecycle.info_changed,
    removed = lifecycle.removed,
  },
  capability_handlers = commands.capability_handlers,
  supported_capabilities = {
    capabilities.refresh,
    capabilities.switch,
    capabilities.switchLevel,
    capabilities.contactSensor,
    capabilities.motionSensor,
  },
})

if fibaro_hc2.datastore.pending_child_data == nil then
  fibaro_hc2.datastore.pending_child_data = {}
end

log.info("Starting Fibaro HC driver")
fibaro_hc2:run()
