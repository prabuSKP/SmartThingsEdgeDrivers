-- src/init.lua
--
-- BroadLink RM4 driver — stock-capabilities model (see docs/broadlink-rm4/SHIPPING_PLAN-STOCK-CAPS.md).
--   * The RM4 blaster is a LAN parent; each appliance is an EDGE_CHILD of a known TYPE
--     (tv / ac / fan / media / generic), each mapped to a fixed profile of STOCK capabilities.
--   * Stock command -> code slot mapping is fixed here; the driver blasts the stored hex.
--   * "Learn mode" (a boolean preference) turns the native controls into recorders instead of
--     senders, so codes are captured in-app with no custom capability.
local capabilities = require "st.capabilities"
local Driver       = require "st.driver"
local log          = require "log"
local socket       = require "cosock.socket"

local BL         = require "broadlink"
local discovery  = require "discovery"
local utils      = require "utils"
local code_store = require "code_store"

-- authed Device handles keyed by the RM4 parent's device.id
local handles = {}
-- per-RM4 send locks so children of one blaster don't interleave packets
local locks = {}

-- appliance type -> profile name
local PROFILE = { tv = "ir-tv", ac = "ir-ac", fan = "ir-fan", media = "ir-media", generic = "ir-generic" }

------------------------------------------------------------------- helpers
local function is_parent(device)
  return device.parent_assigned_child_key == nil
end

local function rm4_device(device)
  if is_parent(device) then return device end
  return device:get_parent_device()
end

local function appliance_type(device)
  local k = device.parent_assigned_child_key or ""
  return k:match("^(%w+)%-") or "generic"
end

local function learn_on(device)
  return (device.preferences or {}).learnMode == true
end

-- emit an event but never let a bad attribute constructor crash the command handler
local function emit(device, thunk)
  local ok, err = pcall(function() device:emit_event(thunk()) end)
  if not ok then log.warn_with({ hub_logs = true }, "[BroadLink] emit error: " .. tostring(err)) end
end

local function with_lock(key, fn)
  local waited = 0
  while locks[key] do
    socket.sleep(0.05); waited = waited + 0.05
    if waited > 20 then
      log.warn_with({ hub_logs = true }, "[BroadLink] send-lock wait exceeded 20s; proceeding")
      break
    end
  end
  locks[key] = true
  local ok, res = pcall(fn)
  locks[key] = nil
  if not ok then
    log.error_with({ hub_logs = true }, "[BroadLink] op error: " .. tostring(res))
    return false
  end
  return res
end

-- mark an RM4 parent and all its children online/offline
local function set_health(driver, rm4, online)
  if not rm4 then return end
  local fn = online and "online" or "offline"
  pcall(function() rm4[fn](rm4) end)
  for _, d in ipairs(driver:get_devices()) do
    if d.parent_device_id == rm4.id then pcall(function() d[fn](d) end) end
  end
end

-- get (or create) an authed handle for the RM4 owning `device`
local function get_handle(driver, device)
  local rm4 = rm4_device(device)
  if not rm4 then
    log.error_with({ hub_logs = true }, "[BroadLink] child has no parent RM4")
    return nil
  end
  if handles[rm4.id] then return handles[rm4.id] end

  local ip, mac, devtype = rm4:get_field("ip"), rm4:get_field("mac"), rm4:get_field("devtype")
  if not (ip and mac and devtype) then
    log.error_with({ hub_logs = true }, "[BroadLink] RM4 missing network fields; run Refresh or re-discover")
    return nil
  end

  local h = BL.new(ip, utils.hex_to_bytes(mac), devtype)
  local ok, err = h:auth()
  if not ok then
    log.error_with({ hub_logs = true }, "[BroadLink] login failed: " .. tostring(err))
    if type(err) == "string" and err:find("login error") then
      log.error_with({ hub_logs = true },
        "[BroadLink] device replied but REJECTED login — it may be CLOUD-LOCKED. Open the BroadLink app -> this RM4 -> settings -> turn OFF 'Lock device'.")
    end
    set_health(driver, rm4, false)
    return nil
  end
  handles[rm4.id] = h
  log.info_with({ hub_logs = true }, "[BroadLink] logged in to RM4 " .. tostring(ip))
  return h
end

-- send the code stored under `slot`; one-shot re-login if the session expired
local function send_slot(driver, device, slot)
  local hex = code_store.get(device, slot)
  if not hex or hex == "" then
    log.warn_with({ hub_logs = true }, string.format("[BroadLink] no code for %s/%s", appliance_type(device), slot))
    return false
  end
  local rm4 = rm4_device(device)
  local h = get_handle(driver, device)
  if not h then return false end
  local ir = utils.hex_to_bytes(hex)
  local ok = with_lock(rm4.id, function()
    if h:send_ir(ir) then return true end
    handles[rm4.id] = nil
    if h:auth() then handles[rm4.id] = h; return h:send_ir(ir) ~= nil end
    return false
  end)
  set_health(driver, rm4, ok and true or false)
  return ok
end

-- capture an IR code from the user's remote into `slot`
local function learn_slot(driver, device, slot)
  local rm4 = rm4_device(device)
  local h = get_handle(driver, device)
  if not h then return false end
  log.info_with({ hub_logs = true }, "[BroadLink] LEARN: capturing '" .. slot .. "' — point the remote at the RM4 and press now")
  return with_lock(rm4.id, function()
    h:enter_learning()
    for _ = 1, 15 do
      socket.sleep(1)
      local ir = h:check_learned()
      if ir and #ir > 0 then
        -- Log the captured blob itself, not just its size. `LEARN OK` alone is a weak signal: the
        -- capture succeeds whatever the remote sent, so a mis-timed press stores the wrong code
        -- under the right slot name. The hex lets you decode what was actually captured (and paste
        -- it into codes.lua as a seed). Same `... : <hex>` shape as the send_ir line.
        local hex = utils.bytes_to_hex(ir)
        local saved, serr = code_store.save(device, slot, hex)
        if saved then
          log.info_with({ hub_logs = true }, string.format(
            "[BroadLink] LEARN OK: '%s' (%d bytes) : %s", slot, #ir, hex))
        else
          -- The code is still good even though we couldn't store it (e.g. per-device code limit).
          log.warn_with({ hub_logs = true }, string.format(
            "[BroadLink] LEARN store failed for '%s': %s — captured code was: %s",
            slot, tostring(serr), hex))
        end
        return saved
      end
    end
    log.warn_with({ hub_logs = true }, "[BroadLink] LEARN timeout for '" .. slot .. "' (no IR received)")
    return false
  end)
end

-- the core: learn OR send, depending on the Learn-mode preference.
-- success_thunk (optional) builds the optimistic event, emitted only on a real send.
local function action(driver, device, slot, success_thunk)
  if learn_on(device) then
    learn_slot(driver, device, slot)
  elseif send_slot(driver, device, slot) and success_thunk then
    emit(device, success_thunk)
  end
end

------------------------------------------------------------------- child mgmt
local function create_child(driver, parent, atype, name)
  local key = atype .. "-" .. name
  driver:try_create_device({
    type = "EDGE_CHILD",
    device_network_id = parent.device_network_id .. ":" .. key,
    parent_device_id = parent.id,
    parent_assigned_child_key = key,
    label = name,
    profile = PROFILE[atype] or "ir-generic",
  })
end

------------------------------------------------------------------- handlers: switch
-- Power style: "toggle" (default for TV/monitors) sends the single toggle code for both On and
-- Off; "discrete" sends separate power_on/power_off codes. Types without the preference (media/
-- generic/fan) fall through to discrete.
local function power_slot(device, on)
  if (device.preferences or {}).powerStyle == "toggle" then return "power" end
  return on and "power_on" or "power_off"
end

local function h_on(driver, device)
  action(driver, device, power_slot(device, true), function() return capabilities.switch.switch.on() end)
end
local function h_off(driver, device)
  action(driver, device, power_slot(device, false), function() return capabilities.switch.switch.off() end)
end

------------------------------------------------------------------- handlers: TV audio/channel/media
local function vol_get(device) return device:get_field("vol_level") or 30 end
local function vol_set(device, v)
  v = math.max(0, math.min(100, v)); device:set_field("vol_level", v, { persist = true }); return v
end

local function h_vol_up(driver, device)
  action(driver, device, "vol_up", function() return capabilities.audioVolume.volume(vol_set(device, vol_get(device) + 5)) end)
end
local function h_vol_down(driver, device)
  action(driver, device, "vol_down", function() return capabilities.audioVolume.volume(vol_set(device, vol_get(device) - 5)) end)
end
local function h_set_vol(driver, device, command)
  local target = command.args.volume or vol_get(device)
  local slot = (target >= vol_get(device)) and "vol_up" or "vol_down"   -- one relative step toward target
  action(driver, device, slot, function() return capabilities.audioVolume.volume(vol_set(device, target)) end)
end

local function h_mute(driver, device, command)
  local state = "muted"
  if command and command.command == "unmute" then state = "unmuted" end
  if command and command.args and command.args.state then state = command.args.state end
  action(driver, device, "mute", function() return capabilities.audioMute.mute(state) end)
end

local function h_ch_up(driver, device)   action(driver, device, "channel_up") end
local function h_ch_down(driver, device) action(driver, device, "channel_down") end

local function h_play(driver, device)  action(driver, device, "play",  function() return capabilities.mediaPlayback.playbackStatus.playing() end) end
local function h_pause(driver, device) action(driver, device, "pause", function() return capabilities.mediaPlayback.playbackStatus.paused() end) end
local function h_stop(driver, device)  action(driver, device, "stop",  function() return capabilities.mediaPlayback.playbackStatus.stopped() end) end
local function h_ff(driver, device)    action(driver, device, "ff") end
local function h_rew(driver, device)   action(driver, device, "rew") end

local function h_next(driver, device) action(driver, device, "next") end
local function h_prev(driver, device) action(driver, device, "prev") end

------------------------------------------------------------------- handlers: AC
-- An AC remote transmits its WHOLE state per press, so a code slot is the full combination
-- `<mode>_<setpoint>_<fan>` — i.e. the slot name IS the combination shown on the card.
--
-- Therefore the three ac_* fields must never drift away from the card. If we persisted a
-- selection whose code we cannot actually send, `ac_key` would keep rebuilding a slot nobody
-- ever taught, and every later AC command would fail too. So: derive the slot from the PROPOSED
-- values, and only commit them once the operation actually took effect.
local function ac_key(device, over)
  over = over or {}
  local mode = over.mode     or device:get_field("ac_mode")     or "cool"
  local sp   = over.setpoint or device:get_field("ac_setpoint") or 24
  local fan  = over.fan      or device:get_field("ac_fan")      or "auto"
  return string.format("%s_%d_%s", mode, sp, fan)
end

-- Change one part of the AC state: send (or learn) the resulting full-state code, then commit
-- the selection and update the card only if that succeeded.
local function ac_apply(driver, device, over, event_thunk)
  local slot = ac_key(device, over)

  local function commit()
    if over.mode     then device:set_field("ac_mode",     over.mode,     { persist = true }) end
    if over.setpoint then device:set_field("ac_setpoint", over.setpoint, { persist = true }) end
    if over.fan      then device:set_field("ac_fan",      over.fan,      { persist = true }) end
    emit(device, event_thunk)
  end

  if learn_on(device) then
    -- The selection defines the slot we're about to teach, so commit it and let the card show it.
    -- (Unlike other types, an AC's slot name is the displayed combination — a frozen card here
    -- would mean teaching a combination the user cannot see.)
    commit()
    learn_slot(driver, device, slot)
  elseif send_slot(driver, device, slot) then
    commit()
  end
  -- Send failed (usually: no code taught for this combination). Commit nothing, emit nothing —
  -- the card snaps back to the last working combination rather than stranding the driver on a
  -- slot that has no code.
end

local function set_ac_mode(driver, device, mode)
  if mode == "off" then
    action(driver, device, "power_off", function() return capabilities.thermostatMode.thermostatMode.off() end)
    return
  end
  ac_apply(driver, device, { mode = mode },
    function() return capabilities.thermostatMode.thermostatMode(mode) end)
end

local function h_set_tmode(driver, device, command) set_ac_mode(driver, device, command.args.mode) end
local function h_tmode_cool(driver, device) set_ac_mode(driver, device, "cool") end
local function h_tmode_heat(driver, device) set_ac_mode(driver, device, "heat") end
local function h_tmode_auto(driver, device) set_ac_mode(driver, device, "auto") end
local function h_tmode_off(driver, device)  set_ac_mode(driver, device, "off") end

local function h_set_setpoint(driver, device, command)
  local t = math.floor((command.args.setpoint or 24) + 0.5)
  ac_apply(driver, device, { setpoint = t },
    function() return capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = t, unit = "C" }) end)
end

local function h_set_fanmode(driver, device, command)
  local m = command.args.fanMode or "auto"
  ac_apply(driver, device, { fan = m },
    function() return capabilities.airConditionerFanMode.fanMode(m) end)
end

------------------------------------------------------------------- handlers: fan
local function h_set_fanspeed(driver, device, command)
  local n = command.args.speed or 0
  action(driver, device, "speed_" .. tostring(n), function() return capabilities.fanSpeed.fanSpeed(n) end)
end
local function h_set_oscillation(driver, device, command)
  local m = command.args.fanOscillationMode or "fixed"
  action(driver, device, "oscillate", function() return capabilities.fanOscillationMode.fanOscillationMode(m) end)
end

------------------------------------------------------------------- handlers: momentary (parent add / generic buttons)
-- generic child button slot (the parent adds appliances via preferences, not momentary —
-- momentary does not render on the LAN parent; see GAPS G2)
local function h_push(driver, device, command)
  action(driver, device, command.component or "button1")
end

------------------------------------------------------------------- handlers: refresh
local function h_refresh(driver, device)
  local rm4 = rm4_device(device)
  if rm4 == device then                       -- parent: re-discover IP, re-login
    handles[device.id] = nil
    for _, dev in ipairs(discovery.scan(driver, 4)) do
      if ("broadlink-" .. dev.mac) == device.device_network_id then
        device:set_field("ip", dev.ip, { persist = true })
        device:set_field("devtype", dev.devtype, { persist = true })
        log.info_with({ hub_logs = true }, "[BroadLink] refreshed RM4 ip=" .. tostring(dev.ip))
      end
    end
  end
  get_handle(driver, device)
end

------------------------------------------------------------------- initial state (APP UI ONLY)
-- The app renders a null attribute as "NaN" (numbers) or "–" (text). IR is one-way, so nothing
-- ever reports state back and every attribute would stay null until the user happens to tap a
-- control that emits one. So we seed them here.
--
-- These are OPTIMISTIC PLACEHOLDERS, not real readings — we cannot know the appliance's true
-- volume/mode. This path calls ONLY emit_event (hub -> cloud -> app); it NEVER sends IR.
-- (If a `send_ir`/`TX cmd=0x6a` line ever appears on a driver restart, this seed is wrong.)

-- Emit an attribute only when it has no value yet: fills blanks without clobbering state the
-- user already set (so a driver restart doesn't reset volume/setpoint).
local function seed_if_unset(device, cap, attr, thunk)
  local ok, cur = pcall(function()
    return device:get_latest_state("main", cap.ID, attr.NAME)
  end)
  if ok and cur ~= nil then return end
  emit(device, thunk)
end

local function seed_child_state(device)
  local c = capabilities
  local atype = appliance_type(device)

  -- every appliance type has a power switch
  seed_if_unset(device, c.switch, c.switch.switch, function() return c.switch.switch.off() end)

  if atype == "tv" then
    -- seed from vol_get so the shown number matches what vol_up/vol_down will step from
    seed_if_unset(device, c.audioVolume, c.audioVolume.volume,
      function() return c.audioVolume.volume(vol_get(device)) end)
    seed_if_unset(device, c.audioMute, c.audioMute.mute,
      function() return c.audioMute.mute("unmuted") end)
    seed_if_unset(device, c.tvChannel, c.tvChannel.tvChannel,
      function() return c.tvChannel.tvChannel("1") end)
    -- supported* lists are metadata gating which transport buttons the app enables: always refresh
    emit(device, function() return c.mediaPlayback.supportedPlaybackCommands(
      { "play", "pause", "stop", "fastForward", "rewind" }) end)
    seed_if_unset(device, c.mediaPlayback, c.mediaPlayback.playbackStatus,
      function() return c.mediaPlayback.playbackStatus("stopped") end)

  elseif atype == "ac" then
    emit(device, function() return c.thermostatMode.supportedThermostatModes(
      { "off", "cool", "heat", "auto" }) end)
    seed_if_unset(device, c.thermostatMode, c.thermostatMode.thermostatMode,
      function() return c.thermostatMode.thermostatMode(device:get_field("ac_mode") or "off") end)
    seed_if_unset(device, c.thermostatCoolingSetpoint, c.thermostatCoolingSetpoint.coolingSetpoint,
      function() return c.thermostatCoolingSetpoint.coolingSetpoint(
        { value = device:get_field("ac_setpoint") or 24, unit = "C" }) end)
    -- NOTE: airConditionerFanMode.fanMode is a FREE STRING (no enum in the schema) — the app's
    -- "Wind strength" picker shows exactly the list below, so fanMode must be one of these.
    emit(device, function() return c.airConditionerFanMode.supportedAcFanModes(
      { "auto", "low", "medium", "high" }) end)
    seed_if_unset(device, c.airConditionerFanMode, c.airConditionerFanMode.fanMode,
      function() return c.airConditionerFanMode.fanMode(device:get_field("ac_fan") or "auto") end)

  elseif atype == "fan" then
    seed_if_unset(device, c.fanSpeed, c.fanSpeed.fanSpeed,
      function() return c.fanSpeed.fanSpeed(0) end)
    emit(device, function() return c.fanOscillationMode.supportedFanOscillationModes(
      { "fixed", "all" }) end)
    seed_if_unset(device, c.fanOscillationMode, c.fanOscillationMode.fanOscillationMode,
      function() return c.fanOscillationMode.fanOscillationMode("fixed") end)

  elseif atype == "media" then
    emit(device, function() return c.mediaPlayback.supportedPlaybackCommands(
      { "play", "pause", "stop", "fastForward", "rewind" }) end)
    seed_if_unset(device, c.mediaPlayback, c.mediaPlayback.playbackStatus,
      function() return c.mediaPlayback.playbackStatus("stopped") end)
    emit(device, function() return c.mediaTrackControl.supportedTrackControlCommands(
      { "nextTrack", "previousTrack" }) end)
    seed_if_unset(device, c.tvChannel, c.tvChannel.tvChannel,
      function() return c.tvChannel.tvChannel("1") end)
  end
  -- generic: switch only (button1..4 are momentary/stateless — nothing to seed)

  log.info_with({ hub_logs = true }, string.format(
    "[BroadLink] seeded initial state for %s child '%s' (app display only, no IR sent)",
    atype, tostring(device.label)))
end

------------------------------------------------------------------- lifecycle
local function persist_net(driver, device)
  driver.datastore.pending_rm4 = driver.datastore.pending_rm4 or {}
  local info = driver.datastore.pending_rm4[device.device_network_id]
  if info then
    device:set_field("ip", info.ip, { persist = true })
    device:set_field("mac", info.mac, { persist = true })
    device:set_field("devtype", info.devtype, { persist = true })
    driver.datastore.pending_rm4[device.device_network_id] = nil
    log.info_with({ hub_logs = true }, "[BroadLink] stored network fields for " .. device.device_network_id)
  end
end

local function device_added(driver, device)
  if not is_parent(device) then return end
  persist_net(driver, device)
  -- No auto-created child. Appliances are added explicitly via the parent's Add flow
  -- (applianceType/applianceName preferences + the momentary Add button).
end

local function device_init(driver, device)
  if not is_parent(device) then
    seed_child_state(device)   -- fill the card's blank attributes (emit only, no IR)
    return
  end
  if not device:get_field("ip") then persist_net(driver, device) end
  if not device:get_field("ip") then
    for _, dev in ipairs(discovery.scan(driver, 4)) do
      if ("broadlink-" .. dev.mac) == device.device_network_id then
        device:set_field("ip", dev.ip, { persist = true })
        device:set_field("mac", dev.mac, { persist = true })
        device:set_field("devtype", dev.devtype, { persist = true })
      end
    end
  end
  if device:get_field("ip") then get_handle(driver, device) end
end

-- Preference-driven "add appliance": on the parent, when the name is set/changed to a new
-- non-empty value, create a child of the chosen type. (Momentary buttons don't render on the
-- LAN parent, so we trigger off a preference save instead — see GAPS G2.)
local function info_changed(driver, device, event, args)
  if not is_parent(device) then return end
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = device.preferences or {}
  local new_name = new.applianceName or ""
  if new_name ~= "" and new_name ~= (old.applianceName or "") then
    local atype = new.applianceType or "generic"
    if not PROFILE[atype] then atype = "generic" end
    log.info_with({ hub_logs = true }, string.format("[BroadLink] add appliance: type=%s name=%s", atype, new_name))
    create_child(driver, device, atype, new_name)
  end
end

------------------------------------------------------------------- capability handler table
local C = capabilities
local capability_handlers = {
  [C.switch.ID] = {
    [C.switch.commands.on.NAME] = h_on,
    [C.switch.commands.off.NAME] = h_off,
  },
  [C.refresh.ID] = {
    [C.refresh.commands.refresh.NAME] = h_refresh,
  },
  [C.momentary.ID] = {
    [C.momentary.commands.push.NAME] = h_push,
  },
  [C.audioVolume.ID] = {
    [C.audioVolume.commands.volumeUp.NAME] = h_vol_up,
    [C.audioVolume.commands.volumeDown.NAME] = h_vol_down,
    [C.audioVolume.commands.setVolume.NAME] = h_set_vol,
  },
  [C.audioMute.ID] = {
    [C.audioMute.commands.setMute.NAME] = h_mute,
    [C.audioMute.commands.mute.NAME] = h_mute,
    [C.audioMute.commands.unmute.NAME] = h_mute,
  },
  [C.tvChannel.ID] = {
    [C.tvChannel.commands.channelUp.NAME] = h_ch_up,
    [C.tvChannel.commands.channelDown.NAME] = h_ch_down,
  },
  [C.mediaPlayback.ID] = {
    [C.mediaPlayback.commands.play.NAME] = h_play,
    [C.mediaPlayback.commands.pause.NAME] = h_pause,
    [C.mediaPlayback.commands.stop.NAME] = h_stop,
    [C.mediaPlayback.commands.fastForward.NAME] = h_ff,
    [C.mediaPlayback.commands.rewind.NAME] = h_rew,
  },
  [C.mediaTrackControl.ID] = {
    [C.mediaTrackControl.commands.nextTrack.NAME] = h_next,
    [C.mediaTrackControl.commands.previousTrack.NAME] = h_prev,
  },
  [C.thermostatMode.ID] = {
    [C.thermostatMode.commands.setThermostatMode.NAME] = h_set_tmode,
    [C.thermostatMode.commands.cool.NAME] = h_tmode_cool,
    [C.thermostatMode.commands.heat.NAME] = h_tmode_heat,
    [C.thermostatMode.commands.auto.NAME] = h_tmode_auto,
    [C.thermostatMode.commands.off.NAME] = h_tmode_off,
  },
  [C.thermostatCoolingSetpoint.ID] = {
    [C.thermostatCoolingSetpoint.commands.setCoolingSetpoint.NAME] = h_set_setpoint,
  },
  [C.airConditionerFanMode.ID] = {
    [C.airConditionerFanMode.commands.setFanMode.NAME] = h_set_fanmode,
  },
  [C.fanSpeed.ID] = {
    [C.fanSpeed.commands.setFanSpeed.NAME] = h_set_fanspeed,
  },
  [C.fanOscillationMode.ID] = {
    [C.fanOscillationMode.commands.setFanOscillationMode.NAME] = h_set_oscillation,
  },
}

------------------------------------------------------------------- driver
pcall(function() math.randomseed(os.time()) end)

local broadlink_driver = Driver("broadlink-rm4", {
  discovery = discovery.handler,
  lifecycle_handlers = { added = device_added, init = device_init, infoChanged = info_changed },
  capability_handlers = capability_handlers,
  supported_capabilities = {
    C.switch, C.refresh, C.momentary, C.audioVolume, C.audioMute, C.tvChannel,
    C.mediaPlayback, C.mediaTrackControl, C.thermostatMode, C.thermostatCoolingSetpoint,
    C.airConditionerFanMode, C.fanSpeed, C.fanOscillationMode,
  },
})

-- Scheduled IP refresh (DHCP drift): every 10 min, re-match each RM4 by MAC and update a changed IP.
broadlink_driver:call_on_schedule(600, function(drv)
  for _, device in ipairs(drv:get_devices()) do
    if is_parent(device) and device:get_field("ip") then
      for _, dev in ipairs(discovery.scan(drv, 3)) do
        if ("broadlink-" .. dev.mac) == device.device_network_id and dev.ip ~= device:get_field("ip") then
          device:set_field("ip", dev.ip, { persist = true })
          handles[device.id] = nil
          log.info_with({ hub_logs = true }, "[BroadLink] IP refresh " .. device.device_network_id .. " -> " .. tostring(dev.ip))
        end
      end
    end
  end
end, "rm4-ip-refresh")

log.info_with({ hub_logs = true }, "[BroadLink] Starting driver (stock-caps)")
broadlink_driver:run()
