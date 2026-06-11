local capabilities = require "st.capabilities"
local socket = require "cosock.socket"
local log = require "log"

local adapter_lib = require "fibaro.adapter"
local cert = require "fibaro.cert"
local fields = require "fields"
local FibaroApi = require "fibaro.api"
local mapper = require "fibaro.mapper"
local utils = require "utils"

local sync = {}

local DEFAULT_POLL_INTERVAL = 30

-- Child-create pacing / retry tuning. SmartThings rate-limits device creation, so a
-- bulk discovery of a large hub must spread creates out rather than firing hundreds
-- of try_create_device calls at once.
local MAX_CREATES_PER_INVENTORY = 25     -- created inline at the end of a full sync
local MAX_CREATES_PER_POLL = 10          -- drained from the queue each incremental poll
local CREATE_SPACING_SECONDS = 0.15      -- pause between consecutive create calls
local MAX_CREATE_ATTEMPTS = 8            -- give up on a child after this many failures
local FULL_SYNC_EVERY_N_POLLS = 20       -- periodic full reconcile (~10 min at 30s poll)
local INFLIGHT_TTL_SECONDS = 600         -- forget submitted-but-unmaterialized creates

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
  elseif kind == "blind" then
    if action_name == "setValue" then
      local expected = utils.clamp(utils.safe_tonumber(args and args[1]) or 0, 0, 99)
      return function(normalized_device)
        return value_matches_level(normalized_device.level or normalized_device.value, expected)
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

local function get_pref_override(pref_value)
  if type(pref_value) == "string" then
    local trimmed = utils.trim(pref_value)
    if trimmed ~= "" then
      return trimmed
    end
  end
  return nil
end

local function get_bridge_endpoint_config(bridge)
  local prefs = bridge.preferences or {}
  local field_host = bridge:get_field(fields.BRIDGE_HOST)
  local field_port = bridge:get_field(fields.BRIDGE_PORT)

  -- Protocol is gated strictly on the settings-card "Protocol" selection. We deliberately
  -- ignore the auto-detected scheme so discovery alone never enables HTTPS: the default is
  -- http unless the card explicitly says https. normalize_scheme(nil) -> "http".
  local scheme = normalize_scheme(get_pref_override(prefs.scheme))

  -- Host resolution precedence:
  --  1. Explicit host/IP on the settings card (manual override, also covers HC2).
  --  2. Serial number on the card (or captured during sync) -> "hc3-<serial>.local",
  --     resolved by the hub's mDNS resolver. This is the primary HC3 path since HC3
  --     does not advertise a browsable mDNS service for auto-discovery.
  --  3. A host previously captured by discovery.
  local host_override, host_override_port = utils.sanitize_host(get_pref_override(prefs.host))
  local serial = utils.trim(get_pref_override(prefs.serialNumber) or bridge:get_field(fields.SERIAL_NUMBER) or "")
  local host, host_source, embedded_port
  if host_override ~= "" then
    host, host_source, embedded_port = host_override, "host-preference", host_override_port
  elseif serial ~= "" then
    host, host_source = utils.hostname_for_serial(serial), "serial-mdns"
  else
    host, host_source = utils.trim(field_host or ""), "discovered-field"
  end

  -- Port precedence: explicit card value > a port embedded in the host field
  -- (e.g. "192.168.1.50:8080") > the resolved scheme's well-known port (80/443).
  -- A discovered non-standard port is preserved, but a discovered 80/443 is
  -- replaced by the scheme default so leaving the card on http never targets the
  -- hub's 443 (and choosing https never targets 80).
  local opt_port = utils.safe_tonumber(get_pref_override(prefs.port))
  local default_port = (scheme == "https" and 443 or 80)
  local port = opt_port or embedded_port
  if not port then
    local detected_port = utils.safe_tonumber(field_port)
    if detected_port and detected_port ~= 80 and detected_port ~= 443 then
      port = detected_port
    else
      port = default_port
    end
  end

  if host == nil or host == "" then
    log.warn_with({hub_logs = true}, string.format(
      "[Fibaro] Bridge %s has no usable host: set an IP/hostname in 'Fibaro Host' or a serial in 'Fibaro Serial Number'.",
      bridge.label))
    return nil, "bridge host unavailable"
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Bridge %s endpoint resolved: %s://%s:%d (host source: %s%s)",
    bridge.label, scheme, host, port, host_source,
    (host_source == "serial-mdns") and (", serial=" .. serial) or ""))

  -- TLS trust model for HTTPS (only relevant when scheme=https):
  --  * "auto" (default): dynamic CA pin — fetch the hub CA and validate against it.
  --  * "none": encrypt-only fallback, no validation.
  --  * "bundled": legacy static pin against src/fibaro_server.crt.
  local tls_verify = tostring(get_pref_override(prefs.tlsVerify) or "auto"):lower()

  -- Pinned CA fingerprint captured by maybe_provision_ca on first HTTPS contact. When
  -- present (and tls_verify="auto") the api layer enforces it after every handshake.
  local ca_fp = bridge:get_field(fields.BRIDGE_CA_FP)

  return {
    scheme = scheme,
    host = host,
    port = port,
    tls_verify = tls_verify,
    ca_fp = ca_fp,
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
    tls_verify = endpoint.tls_verify,
    ca_fp = endpoint.ca_fp,
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

-- Dynamic CA provisioning. On the first successful HTTPS bootstrap of a bridge (while the
-- connection is still verify=none / trust-on-first-use), fetch the hub's CA certificate,
-- fingerprint it, and persist both so every subsequent connection is pinned to it. Only
-- runs in "auto" TLS mode and only until a CA is pinned. Failures degrade gracefully:
-- the integration keeps working encrypt-only and provisioning is retried next bootstrap.
local function maybe_provision_ca(bridge, api)
  local endpoint = get_bridge_endpoint_config(bridge)
  if not endpoint or endpoint.scheme ~= "https" then
    return
  end
  if (endpoint.tls_verify or "auto") ~= "auto" then
    return  -- "none"/"bundled" do not use the dynamic pin
  end
  if bridge:get_field(fields.BRIDGE_CA_FP) then
    return  -- already pinned
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Provisioning CA for bridge %s via GET /api/settings/certificates/ca", bridge.label))

  local raw, err, status = api:get_ca_certificate()
  if err ~= nil or status ~= 200 or raw == nil then
    log.warn_with({hub_logs = true}, string.format(
      "[Fibaro] CA provisioning skipped for %s (staying encrypt-only): err=%s status=%s",
      bridge.label, tostring(err), tostring(status)))
    return
  end

  local pem, pem_err = cert.extract_pem(raw)
  if not pem then
    log.warn_with({hub_logs = true}, string.format(
      "[Fibaro] CA provisioning: could not extract PEM for %s: %s", bridge.label, tostring(pem_err)))
    return
  end

  -- Print the received certificate for debugging, as requested.
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Received CA certificate for bridge %s from /api/settings/certificates/ca:\n%s",
    bridge.label, pem))

  local fp, fp_err = cert.fingerprint(pem)
  if not fp then
    -- Keep the PEM for visibility but do not pin without a usable fingerprint.
    bridge:set_field(fields.BRIDGE_CA_PEM, pem, { persist = true })
    log.warn_with({hub_logs = true}, string.format(
      "[Fibaro] CA provisioning: fingerprint unavailable for %s (%s); remaining encrypt-only",
      bridge.label, tostring(fp_err)))
    return
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] CA certificate details for bridge %s: %s", bridge.label, cert.describe(pem)))

  bridge:set_field(fields.BRIDGE_CA_PEM, pem, { persist = true })
  bridge:set_field(fields.BRIDGE_CA_FP, fp, { persist = true })

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] CA pinned for bridge %s: sha256=%s. Subsequent HTTPS calls are certificate-validated.",
    bridge.label, fp))
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
  if info_err ~= nil or info_status ~= 200 then
    api:shutdown()
    return nil, info_err or ("unexpected settings/info status " .. tostring(info_status))
  end

  -- Fetch + pin the hub CA on first HTTPS contact, reusing this verify=none connection.
  maybe_provision_ca(bridge, api)

  api:shutdown()

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

local function find_bridge_by_dni(driver, dni)
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == dni and utils.is_bridge(device) then
      return device
    end
  end
  return nil
end

-- driver.datastore returns a SNAPSHOT/proxy: `table.insert` and `#` on the value it returns
-- do NOT persist (and `#` reports the committed length, so it reads 0 right after an insert).
-- Read a materialized plain-array copy, mutate that, then write the whole table back with
-- save_queue (a top-level datastore assignment) for changes to stick.
local function create_queue(driver)
  local stored = driver.datastore.pending_create_queue
  local queue = {}
  if type(stored) == "table" then
    for _, entry in ipairs(stored) do
      queue[#queue + 1] = entry
    end
  end
  return queue
end

local function save_queue(driver, queue)
  driver.datastore.pending_create_queue = queue
end

local function inflight_creates(driver)
  driver.datastore.inflight_creates = driver.datastore.inflight_creates or {}
  return driver.datastore.inflight_creates
end

-- Exponential backoff (capped) for a child create that keeps failing.
local function create_backoff_seconds(attempts)
  local base = 5 * (2 ^ math.max(0, attempts - 1))
  return math.min(300, base)
end

-- Cache the metadata a freshly created child needs, so lifecycle.init can apply it.
local function cache_child_metadata_entry(driver, entry)
  driver.datastore.pending_child_data = driver.datastore.pending_child_data or {}
  driver.datastore.pending_child_data[entry.bridge_dni .. "|" .. entry.key] = {
    bridge_dni = entry.bridge_dni,
    hc2_device_id = entry.id,
    hc2_device_type = entry.type,
    hc2_device_kind = entry.kind,
    hc2_room_id = entry.room_id or 0,
    hc2_room_name = entry.room_name or "",
  }
end

-- Add a child to the create queue instead of creating it immediately. De-duplicates
-- against entries already queued and creates already submitted to the platform.
local function enqueue_child_create(driver, bridge, mapped)
  local queue = create_queue(driver)
  local qkey = bridge.device_network_id .. "|" .. mapped.key

  local infl = inflight_creates(driver)
  if infl[qkey] ~= nil and (os.time() - infl[qkey]) < INFLIGHT_TTL_SECONDS then
    return
  end
  for _, existing in ipairs(queue) do
    if existing.qkey == qkey then return end
  end

  table.insert(queue, {
    qkey = qkey,
    bridge_dni = bridge.device_network_id,
    key = mapped.key,
    kind = mapped.kind,
    profile = mapped.profile,
    label = mapped.label,
    type = mapped.type,
    id = mapped.id,
    room_id = mapped.room_id or 0,
    room_name = mapped.room_name or "",
    raw_label = (type(mapped.raw) == "table") and tostring(mapped.raw.label or "") or "",
    attempts = 0,
    next_attempt_at = 0,
  })

  -- Persist the mutated queue. driver.datastore does not see in-place table.insert; the
  -- whole table must be reassigned (top-level set) or the enqueue is silently lost.
  save_queue(driver, queue)

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Queued child create: key=%s label='%s' (queue size %d)",
    tostring(mapped.key), tostring(mapped.label), #queue))
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
  device:set_field(fields.HC2_ROOM_ID, pending.hc2_room_id, { persist = true })
  device:set_field(fields.HC2_ROOM_NAME, pending.hc2_room_name, { persist = true })

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Child device metadata applied: deviceId=%s, label=%s, hc2_device_id=%s, kind=%s, room_id=%s, room_name='%s'",
    tostring(device.id),
    tostring(device.label),
    tostring(pending.hc2_device_id),
    tostring(pending.hc2_device_kind),
    tostring(pending.hc2_room_id),
    tostring(pending.hc2_room_name)
  ))

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
  elseif kind == "blind" then
    local level = utils.safe_tonumber(normalized_device.level or normalized_device.value) or 0
    local clamped = utils.clamp(math.floor(level + 0.5), 0, 99)
    if clamped == 0 then
      device:emit_event(capabilities.windowShade.windowShade.closed())
    elseif clamped >= 99 then
      device:emit_event(capabilities.windowShade.windowShade.open())
    else
      device:emit_event(capabilities.windowShade.windowShade.partially_open())
    end
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(clamped))
  elseif kind == "smoke-detector" then
    if utils.value_is_truthy(value) then
      device:emit_event(capabilities.smokeDetector.smoke.detected())
    else
      device:emit_event(capabilities.smokeDetector.smoke.clear())
    end
  elseif kind == "temperature-sensor" then
    local temp = utils.safe_tonumber(value)
    if temp ~= nil then
      device:emit_event(capabilities.temperatureMeasurement.temperature({value = temp, unit = "C"}))
    end
  elseif kind == "humidity-sensor" then
    local humidity = utils.safe_tonumber(value)
    if humidity ~= nil then
      device:emit_event(capabilities.relativeHumidityMeasurement.humidity({value = math.floor(humidity + 0.5)}))
    end
  elseif kind == "illuminance-sensor" then
    local lux = utils.safe_tonumber(value)
    if lux ~= nil then
      device:emit_event(capabilities.illuminanceMeasurement.illuminance({value = math.floor(lux + 0.5), unit = "lux"}))
    end
  elseif kind == "water-sensor" then
    if utils.value_is_truthy(value) then
      device:emit_event(capabilities.waterSensor.water.wet())
    else
      device:emit_event(capabilities.waterSensor.water.dry())
    end
  elseif kind == "contact" then
    local event = utils.value_is_truthy(value) and capabilities.contactSensor.contact.open() or capabilities.contactSensor.contact.closed()
    device:emit_event(event)
  elseif kind == "motion" then
    local event = utils.value_is_truthy(value) and capabilities.motionSensor.motion.active() or capabilities.motionSensor.motion.inactive()
    device:emit_event(event)
  end

  -- Energy/power metering. Metered Fibaro relays/dimmers/roller-shutters expose
  -- properties.power (W) and properties.energy (kWh); their child uses the "-metered"
  -- profile variant which carries powerMeter + energyMeter. Non-metered devices
  -- normalize these to nil, so nothing is emitted and a plain profile is never sent
  -- metering events.
  if kind == "switch" or kind == "dimmer" or kind == "blind" then
    local power = utils.safe_tonumber(normalized_device.power)
    if power ~= nil then
      device:emit_event(capabilities.powerMeter.power({ value = power, unit = "W" }))
    end
    local energy = utils.safe_tonumber(normalized_device.energy)
    if energy ~= nil then
      device:emit_event(capabilities.energyMeter.energy({ value = energy, unit = "kWh" }))
    end
  end
  -- "default" and "generic-sensor" kinds: no specific state emission
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
    -- SmartThings keeps whatever profile a device was created with; updating the mapper
    -- alone never migrates an already-created child. Re-assign the profile when the
    -- mapping now resolves to a different one -- e.g. a "-metered" variant became
    -- available, or power/energy metering was newly detected on the hub -- so the new
    -- card (powerMeter/energyMeter) actually shows up. device.profile.id is the profile
    -- name, so this only fires on a real change and never loops on already-correct devices.
    local current_profile = existing_child.profile and existing_child.profile.id
    if mapped.profile and current_profile ~= mapped.profile then
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] Child %s profile change: %s -> %s; updating device metadata",
        existing_child.label, tostring(current_profile), tostring(mapped.profile)))
      existing_child:try_update_metadata({ profile = mapped.profile })
    end
    emit_child_state(existing_child, mapped.raw, mapped.kind)
    return existing_child
  end

  -- New device: queue it for paced/retryable creation rather than creating inline.
  -- This is what keeps a 100s-of-devices discovery from tripping the cloud rate limit.
  enqueue_child_create(driver, bridge, mapped)
  return nil
end

-- Process up to `max_count` queued child creates, pacing them and retrying failures
-- with backoff. Called at the end of a full sync (large budget) and on every
-- incremental poll (small budget) so the queue always drains over time.
function sync.drain_create_queue(driver, max_count)
  local queue = create_queue(driver)
  if #queue == 0 then return 0 end

  max_count = max_count or MAX_CREATES_PER_POLL
  local now = os.time()
  local infl = inflight_creates(driver)
  local processed = 0
  local remaining = {}

  for _, entry in ipairs(queue) do
    if processed >= max_count or (entry.next_attempt_at or 0) > now then
      table.insert(remaining, entry)               -- budget spent or backing off
    else
      local bridge = find_bridge_by_dni(driver, entry.bridge_dni)
      if bridge == nil then
        table.insert(remaining, entry)             -- bridge not loaded yet; retry later
      elseif child_devices_for_bridge(driver, bridge)[entry.key] ~= nil then
        infl[entry.qkey] = nil                     -- already created on a prior attempt
      else
        cache_child_metadata_entry(driver, entry)

        local metadata = {
          type = "EDGE_CHILD",
          label = entry.label,
          profile = entry.profile,
          manufacturer = "Fibaro",
          model = (entry.type ~= "" and entry.type) or "fibaro-hc2-device",
          vendor_provided_label = string.format(
            "fibaro|roomId:%s|roomName:%s|label:%s",
            tostring(entry.room_id or 0), tostring(entry.room_name or ""), tostring(entry.raw_label or "")),
          parent_device_id = bridge.id,
          parent_assigned_child_key = entry.key,
        }

        local success, err = driver:try_create_device(metadata)
        processed = processed + 1

        if success then
          infl[entry.qkey] = now
          log.info_with({hub_logs = true}, string.format(
            "[Fibaro] Child create submitted: key=%s label='%s'", tostring(entry.key), tostring(entry.label)))
        else
          entry.attempts = (entry.attempts or 0) + 1
          entry.next_attempt_at = now + create_backoff_seconds(entry.attempts)
          if entry.attempts < MAX_CREATE_ATTEMPTS then
            table.insert(remaining, entry)
            log.warn_with({hub_logs = true}, string.format(
              "[Fibaro] Child create failed (attempt %d), retry in %ds: key=%s err=%s",
              entry.attempts, entry.next_attempt_at - now, tostring(entry.key), tostring(err)))
          else
            log.error_with({hub_logs = true}, string.format(
              "[Fibaro] Child create permanently failed after %d attempts: key=%s err=%s",
              entry.attempts, tostring(entry.key), tostring(err)))
          end
        end

        socket.sleep(CREATE_SPACING_SECONDS)
      end
    end
  end

  driver.datastore.pending_create_queue = remaining

  -- Opportunistically prune stale in-flight markers.
  for qkey, ts in pairs(infl) do
    if (now - ts) > INFLIGHT_TTL_SECONDS then infl[qkey] = nil end
  end

  if processed > 0 then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Drained %d child create(s); %d remaining in queue", processed, #remaining))
  end

  return processed
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
  if err ~= nil or status ~= 200 then
    api:shutdown()
    log.error_with({hub_logs = true}, string.format("[Fibaro] Failed to get devices from bridge %s: %s, status: %s", bridge.label, tostring(err), tostring(status)))
    bridge:offline()
    return nil, err or ("unexpected status " .. tostring(status))
  end

  -- Fetch rooms from Fibaro to build room name lookup
  local rooms = {}
  local rooms_payload, rooms_err, rooms_status = api:get_rooms()
  if rooms_err == nil and rooms_status == 200 and type(rooms_payload) == "table" then
    for _, room in ipairs(rooms_payload) do
      if type(room) == "table" and room.id ~= nil then
        local room_key = tonumber(room.id) or room.id
        rooms[room_key] = tostring(room.name or "")
      end
    end
    log.info_with({hub_logs = true}, string.format("[Fibaro] Loaded %d rooms from bridge %s", #rooms_payload, bridge.label))
  else
    log.info_with({hub_logs = true}, string.format("[Fibaro] Could not fetch rooms from bridge %s: %s, status: %s", bridge.label, tostring(rooms_err), tostring(rooms_status)))
  end

  api:shutdown()

  log.info_with({hub_logs = true}, string.format("[Fibaro] Successfully fetched devices from bridge %s, processing inventory", bridge.label))
  
  bridge:online()
  local adapter = bootstrap.adapter or controller_for_bridge(bridge, payload)
  local discovered = adapter.normalize_device_list(payload)
  
  log.info_with({hub_logs = true}, string.format("[Fibaro] Received %d devices from bridge %s", #discovered, bridge.label))
  log.info_with({hub_logs = true}, string.format("[Fibaro] Device list response (first 1000 chars): %s", 
    type(payload) == "table" and tostring(payload):sub(1, 1000) or tostring(payload)))


  local children_by_key = child_devices_for_bridge(driver, bridge)
  local seen = {}

  -- Count controllable channels per parent so we can recognise genuinely
  -- multi-channel Z-Wave/Zigbee modules. Fibaro exposes each physical relay as its
  -- own device, so each controllable channel must become its own SmartThings child;
  -- only the parent's endpoint-0 aggregation node should be filtered out (and only
  -- when the module actually has more than one channel).
  local parent_channel_counts = {}
  local normalized_devices = {}
  for _, raw_device in ipairs(discovered) do
    local normalized_device = adapter.normalize_device(raw_device)
    table.insert(normalized_devices, normalized_device)
    local parent_id = normalized_device.parent_id or 0
    local actions = normalized_device.actions or {}
    local is_controllable = actions.turnOn ~= nil or actions.setValue ~= nil
    if parent_id > 1 and is_controllable then
      parent_channel_counts[parent_id] = (parent_channel_counts[parent_id] or 0) + 1
    end
  end

  for _, normalized_device in ipairs(normalized_devices) do
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Normalized device: id=%s, name=%s, type=%s, value=%s, level=%s, dead=%s, roomId=%s",
      tostring(normalized_device.id),
      tostring(normalized_device.label),
      tostring(normalized_device.type),
      tostring(normalized_device.value),
      tostring(normalized_device.level),
      tostring(normalized_device.dead),
      tostring(normalized_device.room_id)
    ))
    
    local parent_id = normalized_device.parent_id or 0
    local parent_is_multichannel = parent_id > 1 and (parent_channel_counts[parent_id] or 0) > 1
    local mapped, map_err = mapper.map_device(normalized_device, rooms, parent_is_multichannel)
    if mapped ~= nil then
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] Device %s mapped as kind=%s, profile=%s, label=%s",
        tostring(mapped.id),
        tostring(mapped.kind),
        tostring(mapped.profile),
        tostring(mapped.label)
      ))
      seen[mapped.key] = true
      ensure_child_device(driver, bridge, mapped, children_by_key[mapped.key])
    else
      log.info_with({hub_logs = true}, string.format("[Fibaro] Skipping device %s: %s", tostring(normalized_device.id), tostring(map_err)))
    end
  end

  for child_key, child in pairs(children_by_key) do
    if not seen[child_key] then
      log.info_with({hub_logs = true}, string.format("[Fibaro] Deleting stale child %s", child_key))
      delete_child(driver, child)
    end
  end

  -- Create a first paced batch now; the rest drain across subsequent poll ticks so a
  -- large hub never floods the SmartThings device-creation rate limit in one burst.
  sync.drain_create_queue(driver, MAX_CREATES_PER_INVENTORY)

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

  -- Keep draining any queued/failed child creates regardless of poll outcome.
  sync.drain_create_queue(driver, MAX_CREATES_PER_POLL)

  local has_config, config_err = bridge_has_inventory_config(bridge)
  if not has_config then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Bridge %s poll skipped: %s. Waiting for credentials.",
      bridge.label, tostring(config_err)
    ))
    bridge:offline()
    return nil, config_err
  end

  -- Periodic full reconcile catches devices added/removed on the hub that never emit
  -- an incremental change (e.g. a freshly paired but idle sensor), and re-queues any
  -- children that previously failed to create.
  local poll_count = (utils.safe_tonumber(bridge:get_field(fields.POLL_COUNT)) or 0) + 1
  bridge:set_field(fields.POLL_COUNT, poll_count, { persist = false })
  if poll_count % FULL_SYNC_EVERY_N_POLLS == 0 then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Periodic full reconcile (poll #%d) for %s", poll_count, bridge.label))
    return sync.sync_bridge_inventory(driver, bridge)
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

  -- Fibaro reports newly paired / removed / reconfigured devices as events (not as
  -- property changes), so scan them to trigger a reconcile when the topology shifts.
  local events = payload.events or {}
  for _, event in ipairs(events) do
    local etype = tostring((type(event) == "table" and event.type) or "")
    if etype:find("DeviceCreated") or etype:find("DeviceRemoved") or etype:find("DeviceModified") then
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] refreshStates event '%s' -> scheduling full inventory reconcile", etype))
      should_resync_inventory = true
    end
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
