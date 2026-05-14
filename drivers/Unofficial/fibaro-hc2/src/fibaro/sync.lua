local capabilities = require "st.capabilities"
local socket = require "cosock.socket"
local log = require "log"

local adapter_lib = require "fibaro.adapter"
local fields = require "fields"
local FibaroApi = require "fibaro.api"
local mapper = require "fibaro.mapper"
local utils = require "utils"

local sync = {}

local DEFAULT_POLL_INTERVAL = 30

local function value_matches_switch(value, expected_on)
  local is_on = utils.value_is_truthy(value)
  return expected_on and is_on or (not expected_on and not is_on)
end

local function value_matches_level(value, expected_level)
  local numeric_value = utils.safe_tonumber(value) or 0
  return math.abs(numeric_value - expected_level) <= 1
end

local function expected_state_matcher(kind, action_name, args)
  if kind == "switch" then
    if action_name == "turnOn" then
      return function(normalized_device)
        return value_matches_switch(normalized_device.value, true)
      end
    elseif action_name == "turnOff" then
      return function(normalized_device)
        return value_matches_switch(normalized_device.value, false)
      end
    end
  elseif kind == "dimmer" then
    if action_name == "setValue" then
      local expected = utils.clamp(utils.safe_tonumber(args and args[1]) or 0, 0, 99)
      return function(normalized_device)
        return value_matches_level(normalized_device.level or normalized_device.value, expected)
      end
    elseif action_name == "turnOn" then
      return function(normalized_device)
        return (utils.safe_tonumber(normalized_device.level or normalized_device.value) or 0) > 0
      end
    elseif action_name == "turnOff" then
      return function(normalized_device)
        return value_matches_level(normalized_device.level or normalized_device.value, 0)
      end
    end
  end

  return nil
end

local function normalize_scheme(raw_value)
  local value = utils.trim(raw_value or "")
  if type(value) == "string" then
    value = value:lower()
  end

  if value == "https" then
    return "https"
  end

  return "http"
end

local function get_poll_interval(device)
  local poll_value = utils.safe_tonumber(device.preferences and device.preferences.pollInterval) or DEFAULT_POLL_INTERVAL
  return math.max(10, poll_value)
end

local function get_bridge_endpoint_config(bridge)
  local prefs = bridge.preferences or {}
  local field_scheme = bridge:get_field(fields.BRIDGE_SCHEME)
  local field_host = bridge:get_field(fields.BRIDGE_HOST)
  local field_port = bridge:get_field(fields.BRIDGE_PORT)
  local scheme = normalize_scheme(field_scheme or prefs.scheme)
  local host = utils.trim(field_host or prefs.host or "")
  local port = utils.safe_tonumber(field_port or prefs.port) or (scheme == "https" and 443 or 80)

  if host == "" then
    return nil, "bridge host unavailable"
  end

  return {
    scheme = scheme,
    host = host,
    port = port,
  }, nil
end

local function get_bridge_auth(bridge)
  local prefs = bridge.preferences or {}
  local username = utils.trim(prefs.username or "")
  local password = prefs.password or ""

  if username == "" or password == "" then
    return nil, "bridge credentials incomplete"
  end

  return {
    username = username,
    password = password,
  }, nil
end

local function bridge_has_inventory_config(bridge)
  local _, endpoint_err = get_bridge_endpoint_config(bridge)
  if endpoint_err ~= nil then
    return false, endpoint_err
  end

  local _, auth_err = get_bridge_auth(bridge)
  if auth_err ~= nil then
    return false, auth_err
  end

  return true, nil
end

local function get_bridge_config(bridge, opts)
  local endpoint, endpoint_err = get_bridge_endpoint_config(bridge)
  if endpoint_err ~= nil then
    return nil, endpoint_err
  end

  opts = opts or {}
  local auth, auth_err = get_bridge_auth(bridge)
  if auth_err ~= nil and not opts.allow_anonymous then
    return nil, auth_err
  end

  local config = {
    scheme = endpoint.scheme,
    host = endpoint.host,
    port = endpoint.port,
    username = auth and auth.username or "",
    password = auth and auth.password or "",
  }

  return config, nil
end

local function api_for_bridge(bridge, opts)
  local config, err = get_bridge_config(bridge, opts)
  if err ~= nil then
    return nil, err
  end

  return FibaroApi.new(config, bridge.label or bridge.device_network_id), nil
end

local function persist_bridge_identity(bridge, info, adapter_name)
  if type(info) ~= "table" then
    return
  end

  local platform = tostring(info.platform or "")
  local serial_number = tostring(info.serialNumber or "")
  local api_version = utils.api_version_for_serial(serial_number)

  if platform ~= "" then
    bridge:set_field(fields.PLATFORM, platform, { persist = true })
  end

  if serial_number ~= "" then
    bridge:set_field(fields.SERIAL_NUMBER, serial_number, { persist = true })
  end

  if api_version ~= nil then
    bridge:set_field(fields.API_VERSION, api_version, { persist = true })
  end

  if adapter_name ~= nil then
    bridge:set_field(fields.CONTROLLER_KIND, adapter_name, { persist = true })
  end
end

local function controller_for_bridge(bridge, payload, info)
  local endpoint, _ = get_bridge_endpoint_config(bridge)
  local scheme = endpoint and endpoint.scheme or "http"

  if info ~= nil then
    local adapter = adapter_lib.for_info(info, scheme)
    persist_bridge_identity(bridge, info, adapter.NAME)
    return adapter
  end

  if payload ~= nil then
    local adapter = adapter_lib.detect_devices(payload, scheme)
    bridge:set_field(fields.CONTROLLER_KIND, adapter.NAME, { persist = true })
    return adapter
  end

  local adapter_name = bridge:get_field(fields.CONTROLLER_KIND)
  local adapter = adapter_name and adapter_lib.for_name(adapter_name) or nil
  if adapter ~= nil then
    return adapter
  end

  return adapter_lib.default_for_scheme(scheme)
end

local function bootstrap_bridge(bridge)
  local api, api_err = api_for_bridge(bridge, { allow_anonymous = true })
  if api == nil then
    return nil, api_err
  end

  local _, login_err, login_status = api:get_login_status()
  if login_err ~= nil or (login_status ~= 200 and login_status ~= 401 and login_status ~= 403) then
    api:shutdown()
    return nil, login_err or ("unexpected loginStatus status " .. tostring(login_status))
  end

  local info, info_err, info_status = api:get_settings_info()
  api:shutdown()
  if info_err ~= nil or info_status ~= 200 then
    return nil, info_err or ("unexpected settings/info status " .. tostring(info_status))
  end

  local adapter = controller_for_bridge(bridge, nil, info)
  return {
    info = info,
    adapter = adapter,
  }, nil
end

local function child_devices_for_bridge(driver, bridge)
  local children = {}
  for _, device in ipairs(driver:get_devices()) do
    if device.parent_device_id == bridge.id and device.parent_assigned_child_key ~= nil then
      children[device.parent_assigned_child_key] = device
    end
  end
  return children
end

local function child_for_bridge_and_device_id(driver, bridge, device_id)
  return child_devices_for_bridge(driver, bridge)[utils.child_key_for_id(device_id)]
end

local function cache_child_metadata(driver, bridge, mapped)
  driver.datastore.pending_child_data = driver.datastore.pending_child_data or {}
  driver.datastore.pending_child_data[bridge.device_network_id .. "|" .. mapped.key] = {
    bridge_dni = bridge.device_network_id,
    hc2_device_id = mapped.id,
    hc2_device_type = mapped.type,
    hc2_device_kind = mapped.kind,
  }
end

function sync.apply_pending_child_metadata(driver, device)
  if utils.is_bridge(device) then return end

  driver.datastore.pending_child_data = driver.datastore.pending_child_data or {}
  local bridge = utils.find_parent_bridge(driver, device)
  local bridge_dni = bridge and bridge.device_network_id or device:get_field(fields.PARENT_BRIDGE_DNI)
  local child_key = device.parent_assigned_child_key
  if not bridge_dni or not child_key then return end

  local cache_key = bridge_dni .. "|" .. child_key
  local pending = driver.datastore.pending_child_data[cache_key]
  if pending == nil then return end

  device:set_field(fields.PARENT_BRIDGE_DNI, pending.bridge_dni, { persist = true })
  device:set_field(fields.HC2_DEVICE_ID, pending.hc2_device_id, { persist = true })
  device:set_field(fields.HC2_DEVICE_TYPE, pending.hc2_device_type, { persist = true })
  device:set_field(fields.HC2_DEVICE_KIND, pending.hc2_device_kind, { persist = true })
  driver.datastore.pending_child_data[cache_key] = nil
end

local function emit_child_state(device, normalized_device, kind)
  if normalized_device.dead == true then
    device:offline()
  else
    device:online()
  end

  local value = normalized_device.value
  if kind == "switch" then
    local event = utils.value_is_truthy(value) and capabilities.switch.switch.on() or capabilities.switch.switch.off()
    device:emit_event(event)
  elseif kind == "dimmer" then
    local numeric_value = normalized_device.level or 0
    device:emit_event(numeric_value > 0 and capabilities.switch.switch.on() or capabilities.switch.switch.off())
    device:emit_event(capabilities.switchLevel.level(utils.clamp(math.floor(numeric_value + 0.5), 0, 99)))
  elseif kind == "contact" then
    local event = utils.value_is_truthy(value) and capabilities.contactSensor.contact.open() or capabilities.contactSensor.contact.closed()
    device:emit_event(event)
  elseif kind == "motion" then
    local event = utils.value_is_truthy(value) and capabilities.motionSensor.motion.active() or capabilities.motionSensor.motion.inactive()
    device:emit_event(event)
  end
end

local function refresh_child_with_api(api, bridge, child, adapter, hc2_device_id, kind)
  local payload, err, status = api:get_device(hc2_device_id)

  if err ~= nil or status ~= 200 then
    child:offline()
    bridge:offline()
    return nil, err or ("unexpected status " .. tostring(status)), nil
  end

  local normalized_device = adapter.normalize_device(payload)
  bridge:online()
  emit_child_state(child, normalized_device, kind)
  return true, nil, normalized_device
end

local function ensure_child_device(driver, bridge, mapped, existing_child)
  if existing_child then
    emit_child_state(existing_child, mapped.raw, mapped.kind)
    return existing_child
  end

  cache_child_metadata(driver, bridge, mapped)
  local metadata = {
    type = "EDGE_CHILD",
    label = mapped.label,
    profile = mapped.profile,
    manufacturer = "Fibaro",
    model = mapped.type ~= "" and mapped.type or "fibaro-hc2-device",
    vendor_provided_label = mapped.label,
    parent_device_id = bridge.id,
    parent_assigned_child_key = mapped.key,
  }

  local success, err = driver:try_create_device(metadata)
  if not success then
    log.error_with({hub_logs = true}, string.format("[Fibaro] Failed to create child %s: %s", mapped.key, tostring(err)))
  end

  return nil
end

local function delete_child(driver, child)
  if type(driver.try_delete_device) == "function" then
    driver:try_delete_device(child.id)
  else
    child:offline()
  end
end

local function prime_refresh_states_cursor(api, bridge)
  local payload, err, status = api:get_refresh_states()
  if err == nil and status == 200 and type(payload) == "table" and payload.last ~= nil then
    bridge:set_field(fields.LAST_REFRESH_STATES, payload.last, { persist = true })
  end
end

function sync.sync_bridge_inventory(driver, bridge)
  log.info_with({hub_logs = true}, string.format("[Fibaro] Starting sync_bridge_inventory for bridge: %s", bridge.label))
  
  local has_config, config_err = bridge_has_inventory_config(bridge)
  if not has_config then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Bridge %s discovered but not ready for inventory sync: %s. "
      .. "Please configure credentials in device settings.",
      bridge.label, tostring(config_err)
    ))
    bridge:offline()
    return nil, config_err
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Bridge %s has valid configuration, proceeding with bootstrap", bridge.label))
  
  local bootstrap, bootstrap_err = bootstrap_bridge(bridge)
  if bootstrap == nil then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Skipping bridge bootstrap for %s: %s", bridge.label, tostring(bootstrap_err)))
    bridge:offline()
    return nil, bootstrap_err
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Bridge %s bootstrap successful, creating API connection", bridge.label))
  
  local api, api_err = api_for_bridge(bridge)
  if api == nil then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Skipping bridge sync for %s: %s", bridge.label, tostring(api_err)))
    bridge:offline()
    return nil, api_err
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Fetching devices from bridge %s", bridge.label))
  
  local payload, err, status = api:get_devices()
  api:shutdown()
  if err ~= nil or status ~= 200 then
    log.error_with({hub_logs = true}, string.format("[Fibaro] Failed to get devices from bridge %s: %s, status: %s", bridge.label, tostring(err), tostring(status)))
    bridge:offline()
    return nil, err or ("unexpected status " .. tostring(status))
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Successfully fetched devices from bridge %s, processing inventory", bridge.label))
  
  bridge:online()
  local adapter = bootstrap.adapter or controller_for_bridge(bridge, payload)
  local discovered = adapter.normalize_device_list(payload)
  
  log.info_with({hub_logs = true}, string.format("[Fibaro] Received %d devices from bridge %s", #discovered, bridge.label))
  log.info_with({hub_logs = true}, string.format("[Fibaro] Device list response (first 1000 chars): %s", 
    type(payload) == "table" and tostring(payload):sub(1, 1000) or tostring(payload)))
  
  local children_by_key = child_devices_for_bridge(driver, bridge)
  local seen = {}

  for _, raw_device in ipairs(discovered) do
    local normalized_device = adapter.normalize_device(raw_device)
    
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Normalized device: id=%s, name=%s, type=%s, value=%s, level=%s, dead=%s",
      tostring(normalized_device.id),
      tostring(normalized_device.label),
      tostring(normalized_device.type),
      tostring(normalized_device.value),
      tostring(normalized_device.level),
      tostring(normalized_device.dead)
    ))
    
    local mapped, map_err = mapper.map_device(normalized_device)
    if mapped ~= nil then
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] Device %s mapped as kind=%s, profile=%s",
        tostring(mapped.id),
        tostring(mapped.kind),
        tostring(mapped.profile)
      ))
      seen[mapped.key] = true
      ensure_child_device(driver, bridge, mapped, children_by_key[mapped.key])
    else
      log.info_with({hub_logs = true}, string.format("[Fibaro] Skipping device %s: %s", tostring(raw_device.id), tostring(map_err)))
    end
  end

  for child_key, child in pairs(children_by_key) do
    if not seen[child_key] then
      log.info_with({hub_logs = true}, string.format("[Fibaro] Deleting stale child %s", child_key))
      delete_child(driver, child)
    end
  end

  if bridge:get_field(fields.LAST_REFRESH_STATES) == nil then
    local prime_api, prime_err = api_for_bridge(bridge)
    if prime_api ~= nil then
      prime_refresh_states_cursor(prime_api, bridge)
      prime_api:shutdown()
    else
      log.debug_with({hub_logs = true}, string.format("[Fibaro] Unable to prime refreshStates cursor for %s: %s", bridge.label, tostring(prime_err)))
    end
  end

  return true, nil
end

function sync.poll_bridge(driver, bridge)
  log.info_with({hub_logs = true}, string.format("[Fibaro] poll_bridge called for %s", bridge.label))
  
  local has_config, config_err = bridge_has_inventory_config(bridge)
  if not has_config then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Bridge %s poll skipped: %s. Waiting for credentials.",
      bridge.label, tostring(config_err)
    ))
    bridge:offline()
    return nil, config_err
  end

  local last = bridge:get_field(fields.LAST_REFRESH_STATES)
  if last == nil then
    log.info_with({hub_logs = true}, string.format("[Fibaro] No LAST_REFRESH_STATES for %s, doing full sync", bridge.label))
    return sync.sync_bridge_inventory(driver, bridge)
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Polling refreshStates with last=%s", tostring(last)))

  local bootstrap, bootstrap_err = bootstrap_bridge(bridge)
  if bootstrap == nil then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Bootstrap failed for %s: %s", bridge.label, tostring(bootstrap_err)))
    bridge:offline()
    return nil, bootstrap_err
  end

  local api, api_err = api_for_bridge(bridge)
  if api == nil then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Failed to create API for %s: %s", bridge.label, tostring(api_err)))
    bridge:offline()
    return nil, api_err
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Calling refreshStates API for bridge %s with last=%s", bridge.label, tostring(last)))
  
  local payload, err, status = api:get_refresh_states(last)
  api:shutdown()

  if err ~= nil or status ~= 200 or type(payload) ~= "table" then
    log.warn_with({hub_logs = true}, string.format(
      "[Fibaro] refreshStates poll failed for %s, falling back to full inventory sync: %s",
      bridge.label,
      tostring(err or status)
    ))
    return sync.sync_bridge_inventory(driver, bridge)
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] refreshStates API call successful for %s", bridge.label))
  
  bridge:online()

  if payload.last ~= nil then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Updated LAST_REFRESH_STATES to %s", tostring(payload.last)))
    bridge:set_field(fields.LAST_REFRESH_STATES, payload.last, { persist = true })
  end

  local changes = payload.changes or {}
  log.info_with({hub_logs = true}, string.format("[Fibaro] Received %d changes from refreshStates", #changes))

  local should_resync_inventory = false
  local touched = {}
  for _, change in ipairs(changes) do
    local device_id = change.id
    if device_id == nil then
      log.info_with({hub_logs = true}, string.format("[Fibaro] Change without device_id: %s", tostring(change)))
      goto continue
    end

    log.info_with({hub_logs = true}, string.format("[Fibaro] Change detected for device_id=%s", tostring(device_id)))

    local child = child_for_bridge_and_device_id(driver, bridge, device_id)
    if child ~= nil then
      log.info_with({hub_logs = true}, string.format("[Fibaro] Found child %s for device_id=%s", child.label, tostring(device_id)))
      touched[device_id] = child
    else
      log.info_with({hub_logs = true}, string.format("[Fibaro] No child found for device_id=%s, will resync inventory", tostring(device_id)))
      should_resync_inventory = true
    end

    ::continue::
  end

  for device_id, child in pairs(touched) do
    local ok, refresh_err = sync.refresh_child(driver, child)
    if not ok then
      log.warn_with({hub_logs = true}, string.format(
        "[Fibaro] Targeted refresh after refreshStates failed for %s (%s): %s",
        tostring(child.label),
        tostring(device_id),
        tostring(refresh_err)
      ))
    end
  end

  if should_resync_inventory then
    log.info_with({hub_logs = true}, "[Fibaro] New devices detected, triggering full inventory sync")
    return sync.sync_bridge_inventory(driver, bridge)
  end

  return true, nil
end

function sync.refresh_child(driver, child)
  log.info_with({hub_logs = true}, string.format("[Fibaro] refresh_child called for %s", child.label))
  
  local bridge = utils.find_parent_bridge(driver, child)
  if bridge == nil then
    log.error_with({hub_logs = true}, string.format("[Fibaro] Bridge not found for child %s", child.label))
    return nil, "bridge not found"
  end

  local api, api_err = api_for_bridge(bridge)
  if api == nil then
    log.error_with({hub_logs = true}, string.format("[Fibaro] Failed to create API for child %s: %s", child.label, tostring(api_err)))
    child:offline()
    bridge:offline()
    return nil, api_err
  end

  local adapter = controller_for_bridge(bridge)
  local hc2_device_id = child:get_field(fields.HC2_DEVICE_ID) or utils.device_id_from_child_key(child.parent_assigned_child_key)
  local kind = child:get_field(fields.HC2_DEVICE_KIND) or "generic-sensor"
  
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Refreshing child %s: device_id=%s, kind=%s",
    child.label, tostring(hc2_device_id), tostring(kind)
  ))
  
  local ok, refresh_err, normalized_device = refresh_child_with_api(api, bridge, child, adapter, hc2_device_id, kind)
  api:shutdown()
  
  if ok then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Child %s refreshed successfully: value=%s, level=%s",
      child.label, tostring(normalized_device.value), tostring(normalized_device.level)
    ))
  end
  
  return ok, refresh_err, normalized_device
end

function sync.execute_child_action(driver, child, action_name, args)
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] execute_child_action: child=%s, action=%s, args=%s",
    child.label, tostring(action_name), tostring(args)
  ))
  
  local bridge = utils.find_parent_bridge(driver, child)
  if bridge == nil then
    log.error_with({hub_logs = true}, string.format("[Fibaro] Bridge not found for child %s", child.label))
    return nil, "bridge not found"
  end

  local api, api_err = api_for_bridge(bridge)
  if api == nil then
    log.error_with({hub_logs = true}, string.format("[Fibaro] Failed to create API for child %s: %s", child.label, tostring(api_err)))
    child:offline()
    bridge:offline()
    return nil, api_err
  end

  local adapter = controller_for_bridge(bridge)
  local hc2_device_id = child:get_field(fields.HC2_DEVICE_ID) or utils.device_id_from_child_key(child.parent_assigned_child_key)
  local kind = child:get_field(fields.HC2_DEVICE_KIND) or "generic-sensor"
  
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Calling action %s on device_id=%s (kind=%s)",
    tostring(action_name), tostring(hc2_device_id), tostring(kind)
  ))
  
  log.info_with({hub_logs = true}, string.format("[Fibaro] Calling action %s on device_id=%s with body: %s", 
    tostring(action_name), tostring(hc2_device_id), tostring(adapter.build_action_body(args))))
  
  local _, err, status = api:call_action(hc2_device_id, action_name, adapter.build_action_body(args))

  if err ~= nil or (status ~= 200 and status ~= 202 and status ~= 204) then
    log.error_with({hub_logs = true}, string.format(
      "[Fibaro] Action %s failed for child %s: err=%s, status=%s",
      tostring(action_name), child.label, tostring(err), tostring(status)
    ))
    api:shutdown()
    child:offline()
    bridge:offline()
    return nil, err or ("unexpected status " .. tostring(status))
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Action %s successful, status=%d", tostring(action_name), status))
  
  bridge:online()
  local matcher = expected_state_matcher(kind, action_name, args)
  local attempts = math.max(adapter.command_refresh_attempts(status), matcher and 4 or 1)
  local last_err = nil

  for attempt = 1, attempts do
    if attempt > 1 then
      socket.sleep(0.4 * attempt)
    end

    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Post-action refresh attempt %d/%d for child %s (device_id=%s)",
      attempt,
      attempts,
      tostring(child.label),
      tostring(hc2_device_id)
    ))

    local ok, refresh_err, normalized_device = refresh_child_with_api(api, bridge, child, adapter, hc2_device_id, kind)
    if ok and (matcher == nil or matcher(normalized_device)) then
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] Post-action refresh successful for %s: value=%s, level=%s",
        child.label, tostring(normalized_device.value), tostring(normalized_device.level)
      ))
      api:shutdown()
      return true, nil
    end

    if refresh_err ~= nil then
      last_err = refresh_err
    end
  end

  log.warn_with({hub_logs = true}, string.format("[Fibaro] Post-action refresh failed for %s after %d attempts", child.label, attempts))
  api:shutdown()
  return nil, last_err or "refresh after action failed"
end

local function cancel_bridge_timer(bridge)
  local existing_timer = bridge:get_field(fields.POLL_TIMER)
  if existing_timer ~= nil then
    bridge.thread:cancel_timer(existing_timer)
    bridge:set_field(fields.POLL_TIMER, nil, { persist = false })
  end
end

function sync.reschedule_bridge_poll(driver, bridge)
  cancel_bridge_timer(bridge)

  local has_config = bridge_has_inventory_config(bridge)
  if not has_config then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Bridge %s poll scheduling deferred: waiting for endpoint and credentials.",
      bridge.label
    ))
    return
  end

  local timer = bridge.thread:call_on_schedule(
    get_poll_interval(bridge),
    function()
      sync.poll_bridge(driver, bridge)
    end,
    "Fibaro HC inventory poll"
  )

  bridge:set_field(fields.POLL_TIMER, timer, { persist = false })
end

function sync.on_bridge_removed(driver, bridge)
  cancel_bridge_timer(bridge)

  for _, device in ipairs(driver:get_devices()) do
    if device.parent_device_id == bridge.id and device.parent_assigned_child_key ~= nil then
      delete_child(driver, device)
    end
  end
end

return sync
