local log = require "log"

local discovery = {}

local BRIDGE_DNI = "fibaro-hc2-bridge"

function discovery.discover(driver, _, _)
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == BRIDGE_DNI and device.parent_assigned_child_key == nil then
      return
    end
  end

  log.info("Creating manual Fibaro HC bridge placeholder")
  driver:try_create_device({
    type = "LAN",
    device_network_id = BRIDGE_DNI,
    label = "Fibaro HC Bridge",
    profile = "hc2-bridge",
    manufacturer = "Fibaro",
    model = "HC",
    vendor_provided_label = "Fibaro HC Bridge",
  })
end

return discovery
