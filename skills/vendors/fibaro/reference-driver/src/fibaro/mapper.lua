local log = require "log"
local utils = require "utils"

local mapper = {}

local function has_action(actions, action_name)
  return type(actions) == "table" and actions[action_name] ~= nil
end

local function has_interface(interfaces, needle)
  if type(interfaces) ~= "table" then
    return false
  end

  for _, value in ipairs(interfaces) do
    if tostring(value) == needle then
      return true
    end
  end

  return false
end

local function has_value(device)
  return type(device) == "table" and device.value ~= nil
end

local function contains(haystack, needle)
  return tostring(haystack or ""):find(needle, 1, true) ~= nil
end

-- Multi-attribute mapping rules table
-- Design Principle 1: Interfaces are checked FIRST, then type/role, then actions
-- Checked in order; first match wins.
local MAPPING_RULES = {
  -- =============================================================================
  -- GROUP 1: INTERFACE-BASED MATCHING (Highest Priority - Design Principle 1)
  -- =============================================================================

  -- 1. BLINDS / WINDOW COVERINGS (by interface)
  {
    match = function(d)
      return has_interface(d.interfaces, "windowCovering")
    end,
    kind = "blind",
    profile = "fibaro-blind",
    reason = "BLIND (interface: windowCovering)"
  },

  -- 2. SMOKE DETECTOR (by interface)
  {
    match = function(d)
      return has_interface(d.interfaces, "smokeDetector")
    end,
    kind = "smoke-detector",
    profile = "fibaro-smoke-detector",
    reason = "SMOKE-DETECTOR (interface: smokeDetector)"
  },

  -- 3. MOTION SENSOR (by interface)
  {
    match = function(d)
      return has_interface(d.interfaces, "motionSensor")
    end,
    kind = "motion",
    profile = "fibaro-motion",
    reason = "MOTION (interface: motionSensor)"
  },

  -- 4. CONTACT SENSOR (by interface)
  {
    match = function(d)
      return has_interface(d.interfaces, "contactSensor") or has_interface(d.interfaces, "doorWindowSensor")
    end,
    kind = "contact",
    profile = "fibaro-contact",
    reason = "CONTACT (interface: contactSensor/doorWindowSensor)"
  },

  -- 5. TEMPERATURE SENSOR (by interface)
  {
    match = function(d)
      return has_interface(d.interfaces, "temperatureSensor")
    end,
    kind = "temperature-sensor",
    profile = "fibaro-temperature-sensor",
    reason = "TEMPERATURE-SENSOR (interface: temperatureSensor)"
  },

  -- 6. HUMIDITY SENSOR (by interface)
  {
    match = function(d)
      return has_interface(d.interfaces, "humiditySensor")
    end,
    kind = "humidity-sensor",
    profile = "fibaro-humidity-sensor",
    reason = "HUMIDITY-SENSOR (interface: humiditySensor)"
  },

  -- 7. ILLUMINANCE / LIGHT SENSOR (by interface)
  {
    match = function(d)
      return has_interface(d.interfaces, "lightSensor")
    end,
    kind = "illuminance-sensor",
    profile = "fibaro-illuminance-sensor",
    reason = "ILLUMINANCE-SENSOR (interface: lightSensor)"
  },

  -- 8. WATER / FLOOD SENSOR (by interface)
  {
    match = function(d)
      return has_interface(d.interfaces, "waterSensor") or has_interface(d.interfaces, "floodSensor")
    end,
    kind = "water-sensor",
    profile = "fibaro-water-sensor",
    reason = "WATER-SENSOR (interface: waterSensor/floodSensor)"
  },

  -- =============================================================================
  -- GROUP 2: MULTI-ENDPOINT DEVICES (Design Principle 3)
  -- Multiple endpoints = Multiple components
  -- =============================================================================

  -- 9. MULTI-ENDPOINT SWITCH (double switch with 2 endpoints)
  {
    match = function(d)
      return d.is_multi_endpoint == true and #d.endpoints == 3
        and has_interface(d.interfaces, "light")
    end,
    kind = "double-switch",
    profile = "fibaro-double-switch",
    reason = "DOUBLE-SWITCH (multi-endpoint: 2 relays)"
  },

  -- 10. MULTI-ENDPOINT SWITCH (triple switch with 3 endpoints)
  {
    match = function(d)
      return d.is_multi_endpoint == true and #d.endpoints == 4
        and has_interface(d.interfaces, "light")
    end,
    kind = "triple-switch",
    profile = "fibaro-triple-switch",
    reason = "TRIPLE-SWITCH (multi-endpoint: 3 relays)"
  },

  -- =============================================================================
  -- GROUP 3: TYPE/ROLE-BASED MATCHING (Secondary Priority)
  -- For devices where interfaces are not available or not reliable
  -- =============================================================================

  -- 11. BLINDS / WINDOW COVERINGS (by type/role)
  {
    match = function(d)
      return contains(d.type, "rollerShutter")
        or contains(d.type, "FGR")
        or contains(d.base_type, "baseShutter")
        or contains(d.role, "BlindsWithPositioning")
        or contains(d.role, "Blind")
    end,
    kind = "blind",
    profile = "fibaro-blind",
    reason = "BLIND (type/role match)"
  },

  -- 12. SMOKE / HEAT DETECTOR (by type/role)
  {
    match = function(d)
      return contains(d.type, "smokeSensor")
        or contains(d.type, "heatDetector")
        or contains(d.base_type, "lifeDangerSensor")
        or contains(d.role, "Smoke")
        or contains(d.role, "HeatDetector")
    end,
    kind = "smoke-detector",
    profile = "fibaro-smoke-detector",
    reason = "SMOKE-DETECTOR (type/role match)"
  },

  -- 13. MOTION SENSOR (by type/role)
  {
    match = function(d)
      return contains(d.type, "motionSensor")
        or contains(d.base_type, "motionSensor")
        or contains(d.role, "Motion")
    end,
    kind = "motion",
    profile = "fibaro-motion",
    reason = "MOTION (type/role match)"
  },

  -- 14. CONTACT SENSOR (by type/role)
  {
    match = function(d)
      return contains(d.type, "doorSensor")
        or contains(d.type, "windowSensor")
        or contains(d.type, "doorWindowSensor")
        or contains(d.base_type, "doorSensor")
        or contains(d.base_type, "windowSensor")
        or contains(d.role, "Door")
        or contains(d.role, "Window")
    end,
    kind = "contact",
    profile = "fibaro-contact",
    reason = "CONTACT (type/role match)"
  },

  -- 15. TEMPERATURE SENSOR (by type/role)
  {
    match = function(d)
      return contains(d.type, "temperatureSensor")
        or contains(d.role, "Temperature")
    end,
    kind = "temperature-sensor",
    profile = "fibaro-temperature-sensor",
    reason = "TEMPERATURE-SENSOR (type/role match)"
  },

  -- 16. HUMIDITY SENSOR (by type/role)
  {
    match = function(d)
      return contains(d.type, "humiditySensor")
        or contains(d.role, "Humidity")
    end,
    kind = "humidity-sensor",
    profile = "fibaro-humidity-sensor",
    reason = "HUMIDITY-SENSOR (type/role match)"
  },

  -- 17. ILLUMINANCE / LIGHT SENSOR (by type/role)
  {
    match = function(d)
      return contains(d.type, "lightSensor")
        or contains(d.role, "LightSensor")
    end,
    kind = "illuminance-sensor",
    profile = "fibaro-illuminance-sensor",
    reason = "ILLUMINANCE-SENSOR (type/role match)"
  },

  -- 18. WATER / FLOOD SENSOR (by type/role)
  {
    match = function(d)
      return contains(d.type, "floodSensor")
        or contains(d.type, "waterSensor")
        or contains(d.role, "Water")
        or contains(d.role, "Flood")
    end,
    kind = "water-sensor",
    profile = "fibaro-water-sensor",
    reason = "WATER-SENSOR (type/role match)"
  },

  -- =============================================================================
  -- GROUP 4: ACTION-BASED MATCHING (Lowest Priority - Fallback)
  -- For devices where neither interfaces nor type provide clear classification
  -- =============================================================================

  -- 19. DIMMER (has setValue action)
  {
    match = function(d)
      return has_action(d.actions, "setValue")
    end,
    kind = "dimmer",
    profile = "fibaro-dimmer",
    reason = "DIMMER (action: setValue)"
  },

  -- 20. SWITCH (has turnOn/turnOff actions)
  {
    match = function(d)
      return has_action(d.actions, "turnOn") and has_action(d.actions, "turnOff")
    end,
    kind = "switch",
    profile = "fibaro-switch",
    reason = "SWITCH (actions: turnOn/turnOff)"
  },

  -- 21. GENERIC SENSOR (has value but no actionable type)
  {
    match = function(d)
      return has_value(d)
    end,
    kind = "generic-sensor",
    profile = "fibaro-generic-sensor",
    reason = "GENERIC-SENSOR (has value property)"
  },
}

function mapper.map_device(device, rooms, parent_is_multichannel)
  if type(device) ~= "table" or device.id == nil then
    log.info_with({hub_logs = true}, "[Fibaro] map_device: invalid device payload")
    return nil, "invalid device payload"
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] map_device: id=%s, name=%s, type=%s, base_type=%s, role=%s",
    tostring(device.id),
    tostring(device.label),
    tostring(device.type),
    tostring(device.base_type),
    tostring(device.device_role)
  ))

  -- Skip non-device types
  if device.is_gateway then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is a gateway/controller, skipping", tostring(device.id)))
    return nil, "controller device"
  end

  if device.is_user then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is a user device, skipping", tostring(device.id)))
    return nil, "user device"
  end

  if device.is_plugin then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is a plugin/virtual device, skipping", tostring(device.id)))
    return nil, "plugin or virtual device"
  end

  if device.enabled == false then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is disabled, skipping", tostring(device.id)))
    return nil, "disabled device"
  end

  -- Respect the hub's own visibility flag. Fibaro marks internal/auxiliary endpoints
  -- hidden (visible=false): per-module phantom "heatDetector"/sensor sub-endpoints,
  -- hidden Z-Wave root aggregation nodes, and secondary channels the user has hidden.
  -- Surfacing any of these produces duplicate/unnecessary SmartThings devices, so skip
  -- them. (HC2 devices that carry no visible flag normalize to visible=true and are
  -- unaffected; this only filters endpoints the hub itself has chosen to hide.)
  if device.visible == false then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Device %s ('%s') is hidden in Fibaro (visible=false), skipping",
      tostring(device.id), tostring(device.label)))
    return nil, "hidden device"
  end

  -- Filter out device types that don't need user control
  if contains(device.type, "iOS_device") then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is a mobile device, skipping", tostring(device.id)))
    return nil, "mobile device"
  end

  if contains(device.type, "remoteController") then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Device %s is a remote controller, skipping", tostring(device.id)))
    return nil, "remote controller"
  end

  -- Skip Z-Wave/Zigbee parent container devices (they don't control anything)
  if contains(device.type, "zwaveDevice") or contains(device.type, "zigbeeDevice") then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Device %s is a Z-Wave/Zigbee container device, skipping", tostring(device.id)))
    return nil, "zwave/zigbee container device"
  end

  -- A multi-channel Z-Wave/Zigbee module exposes each physical relay as its own Fibaro
  -- device, plus an endpoint-0 aggregation node ("<parentId>.0") that drives no real
  -- load. Most roots are already hidden (filtered by the visible=false check above), but
  -- some installs leave the root visible alongside the real named channels. Skip that
  -- aggregation node so it does not appear as a duplicate switch; the real per-channel
  -- devices (user-named, or visible numeric endpoints like "217.2") are kept.
  local raw_label = device.label or ""
  local parent_id = device.parent_id or 0
  if parent_id > 1 and parent_is_multichannel then
    local is_numeric_endpoint =
      raw_label:match("^%d+%.%d+$") ~= nil or raw_label:match("^%d+%.%d+%.%d+$") ~= nil
    local is_root_endpoint = is_numeric_endpoint and raw_label:match("%.0$") ~= nil
    if is_root_endpoint then
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] Device %s ('%s') is the endpoint-0 root of multi-channel parent %s, skipping",
        tostring(device.id), raw_label, tostring(parent_id)))
      return nil, "multi-channel root endpoint"
    end
  end

  -- Prepare normalized attributes for matching
  local actions = device.actions or {}
  local device_type = tostring(device.type or "")
  local base_type = tostring(device.base_type or "")
  local device_role = tostring(device.device_role or "")
  local interfaces = device.interfaces or {}
  local parent_id = device.parent_id or 0
  local room_id = device.room_id or 0
  local raw_label = device.label or ("Fibaro Device " .. tostring(device.id))

  -- Look up room name from rooms table and prefix label
  local room_name = ""
  if type(rooms) == "table" and room_id > 0 then
    room_name = rooms[room_id] or rooms[tostring(room_id)] or ""
  end

  local label = raw_label
  if room_name ~= "" then
    -- Format: [RoomName:roomId] DeviceLabel
    -- This encodes the Fibaro room_id in the label since SmartThings
    -- does NOT preserve vendorProvidedLabel for EDGE_CHILD devices.
    -- The roomId is essential for the Python room assignment script.
    label = string.format("[%s:%s] %s", room_name, tostring(room_id), raw_label)
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Device %s: roomId=%s, roomName='%s', label='%s', rawLabel='%s'",
    tostring(device.id),
    tostring(room_id),
    tostring(room_name),
    tostring(label),
    tostring(raw_label)
  ))

  -- Include endpoint information for multi-endpoint device detection
  local endpoints = device.endpoints or {}
  local is_multi_endpoint = device.is_multi_endpoint == true

  local match_context = {
    type = device_type,
    base_type = base_type,
    role = device_role,
    actions = actions,
    interfaces = interfaces,
    value = device.value,
    endpoints = endpoints,
    is_multi_endpoint = is_multi_endpoint,
  }

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Device %s: type=%s, base_type=%s, role=%s, actions=%s, interfaces=%s, value=%s",
    tostring(device.id),
    device_type,
    base_type,
    device_role,
    tostring(actions),
    tostring(interfaces),
    tostring(device.value)
  ))

  -- Apply mapping rules in order
  for _, rule in ipairs(MAPPING_RULES) do
    if rule.match(match_context) then
      -- Energy/power metering: Fibaro relays and dimmers that meter consumption
      -- expose the 'power' and/or 'energy' interface (and carry properties.power /
      -- properties.energy). Surface that via a "-metered" profile variant
      -- (switch/dimmer + powerMeter + energyMeter) instead of discarding the data.
      -- Detection is interface-driven, matching the rest of the mapper.
      local profile = rule.profile
      local metered = false
      if (rule.kind == "switch" or rule.kind == "dimmer" or rule.kind == "blind") then
        -- Primary signal: the device advertises the energy/power interface. Fallback:
        -- some HC3 firmware reports properties.power / properties.energy values without
        -- listing the interface, so treat a present metering value as metered too.
        local by_interface = has_interface(interfaces, "energy") or has_interface(interfaces, "power")
        local by_value = device.power ~= nil or device.energy ~= nil
        if by_interface or by_value then
          profile = rule.profile .. "-metered"
          metered = true
          log.info_with({hub_logs = true}, string.format(
            "[Fibaro] Device %s metered detected (interface=%s, value=%s) -> %s",
            tostring(device.id), tostring(by_interface), tostring(by_value), profile))
        end
      end

      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] Device %s mapped as %s%s", tostring(device.id), rule.reason,
        metered and " [metered]" or ""))
      return {
        id = device.id,
        key = utils.child_key_for_id(device.id),
        kind = rule.kind,
        profile = profile,
        metered = metered,
        label = label,
        type = device_type,
        parent_id = parent_id,
        room_id = room_id,
        room_name = room_name,
        raw = device,
      }
    end
  end

  -- DEFAULT: No specific rule matched — give device a default card instead of skipping.
  -- This ensures ALL Fibaro devices are visible in SmartThings, even unrecognized types.
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Device %s mapped as DEFAULT (no specific rule matched, type=%s)", tostring(device.id), device_type))
  return {
    id = device.id,
    key = utils.child_key_for_id(device.id),
    kind = "default",
    profile = "fibaro-default",
    label = label,
    type = device_type,
    parent_id = parent_id,
    room_id = room_id,
    room_name = room_name,
    raw = device,
  }
end

return mapper
