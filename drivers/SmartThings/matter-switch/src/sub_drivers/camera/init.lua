-- Copyright © 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-------------------------------------------------------------------------------------
-- Matter Camera Sub Driver
-------------------------------------------------------------------------------------

local attribute_handlers = require "sub_drivers.camera.camera_handlers.attribute_handlers"
local camera_cfg = require "sub_drivers.camera.camera_utils.device_configuration"
local camera_fields = require "sub_drivers.camera.camera_utils.fields"
local camera_utils = require "sub_drivers.camera.camera_utils.utils"
local capabilities = require "st.capabilities"
local capability_handlers = require "sub_drivers.camera.camera_handlers.capability_handlers"
local clusters = require "st.matter.clusters"
local event_handlers = require "sub_drivers.camera.camera_handlers.event_handlers"
local fields = require "switch_utils.fields"
local switch_utils = require "switch_utils.utils"
local log = require "log"
-- [single_bridge spike] reach the native ONVIF->Matter bridge IPC from this forked driver.
local bridge_ipc = require "sub_drivers.camera.camera_utils.bridge_ipc"

local CameraLifecycleHandlers = {}

function CameraLifecycleHandlers.device_init(driver, device)
  device:set_component_to_endpoint_fn(camera_utils.component_to_endpoint)
  device:set_endpoint_to_component_fn(switch_utils.endpoint_to_component)
  device:extend_device("emit_event_for_endpoint", switch_utils.emit_event_for_endpoint)
  if device:get_field(fields.IS_PARENT_CHILD_DEVICE) then
    device:set_find_child(switch_utils.find_child)
  end
  device:extend_device("subscribe", camera_utils.subscribe)
  device:subscribe()

  -- [single_bridge spike] One-time: force a profile re-apply so the ONVIF credential
  -- preferences (added to camera.yml) appear on an EXISTING camera. Deferred a few
  -- seconds so the device is fully initialised, and logged so we can confirm via logcat.
  if not device:get_field("onvif_prefs_applied_v3") then
    device:set_field("onvif_prefs_applied_v3", true, { persist = true })
    device.thread:call_with_delay(3, function()
      log.info_with({ hub_logs = true }, "[single_bridge spike] forcing camera profile re-apply; profile id=" ..
        tostring(device.profile and device.profile.id))
      local ok, err = pcall(function() camera_cfg.match_profile(device, true) end)
      log.info_with({ hub_logs = true }, "[single_bridge spike] match_profile(force) ok=" .. tostring(ok) ..
        " err=" .. tostring(err))
    end)
  end

  -- [single_bridge] Cache the daemon-side camera dni: one-shot read of
  -- BridgedDeviceBasicInformation.UniqueID (0x0039/0x0012), which the bridge sets to its
  -- stable camera id (e.g. "onvif-mac-98eb03ed535f"). The response lands in
  -- attribute_handlers.bridged_device_unique_id_handler, which persists it as
  -- camera_fields.ONVIF_DNI for the removed handler below. Skip bridge cards: their
  -- device record can leak camera endpoints into this sub-driver (see the endpoint
  -- filtering note in test/test_matter_bridge.lua).
  if not switch_utils.detect_bridge(device) and not device:get_field(camera_fields.ONVIF_DNI) then
    camera_utils.read_bridged_device_unique_id(device)
  end
end

function CameraLifecycleHandlers.do_configure(driver, device)
  camera_utils.update_camera_component_map(device)
  if #device:get_endpoints(clusters.CameraAvStreamManagement.ID) == 0 then
    camera_cfg.match_profile(device)
  end
  camera_cfg.create_child_devices(driver, device)
  camera_cfg.initialize_camera_capabilities(device)
end

function CameraLifecycleHandlers.driver_switched(driver, device)
  camera_utils.update_camera_component_map(device)
  if #device:get_endpoints(clusters.CameraAvStreamManagement.ID) == 0 then
    camera_cfg.match_profile(device)
  end
  device:try_update_metadata({provisioning_state = "PROVISIONED"})
end

function CameraLifecycleHandlers.info_changed(driver, device, event, args)
  do -- [single_bridge spike] log what preferences the device actually has now
    local p, keys = device.preferences or {}, {}
    for k, _ in pairs(p) do keys[#keys + 1] = k end
    log.info_with({ hub_logs = true }, "[single_bridge spike] info_changed: profile=" ..
      tostring(device.profile and device.profile.id) .. " pref_keys=[" .. table.concat(keys, ",") ..
      "] onvifUser=" .. tostring(p.onvifUser))
  end
  local software_version_changed = device.matter_version ~= nil and args.old_st_store.matter_version ~= nil and
    device.matter_version.software ~= args.old_st_store.matter_version.software
  local profile_changed = not switch_utils.deep_equals(device.profile, args.old_st_store.profile, { ignore_functions = true })

  if software_version_changed then
    camera_cfg.reconcile_profile_and_capabilities(device)
  elseif profile_changed then
    camera_cfg.reinitialize_changed_camera_capabilities_and_subscriptions(device, args.old_st_store.profile, device.profile)
  end

  -- [single_bridge spike] Did the ONVIF credentials on this camera card change?
  -- If so, prove this forked Matter driver can (a) read the preference and
  -- (b) reach the native bridge IPC over the LAN. (Real flow: send upsert_camera
  -- keyed off the camera's DNI; here we just ping to validate connectivity.)
  local prefs = device.preferences or {}
  local old_prefs = (args.old_st_store or {}).preferences or {}
  if prefs.onvifUser ~= old_prefs.onvifUser or prefs.onvifPassword ~= old_prefs.onvifPassword then
    log.info_with({ hub_logs = true }, string.format(
      "[single_bridge spike] ONVIF creds changed (user=%s, pass=%s) on device '%s' (id=%s) -> pinging bridge at %s:%d",
      tostring(prefs.onvifUser), (prefs.onvifPassword ~= nil and prefs.onvifPassword ~= "") and "***" or "(blank)",
      tostring(device.label), tostring(device.id), bridge_ipc.hub_ip(), bridge_ipc.PORT))
    local resp, err = bridge_ipc.ping()
    if resp then
      log.info_with({ hub_logs = true }, "[single_bridge spike] BRIDGE IPC OK: " .. tostring(resp))
    else
      log.error_with({ hub_logs = true }, "[single_bridge spike] BRIDGE IPC FAILED: " .. tostring(err))
    end
  end
end

function CameraLifecycleHandlers.added() end

-- [single_bridge] The user deleted this camera card in the app -> tell the native daemon
-- to drop the camera (bridged endpoint + cameras.json entry) so a later pull-to-refresh
-- can re-onboard it fresh (the daemon's discovery dedup would otherwise say
-- "already known" forever).
function CameraLifecycleHandlers.device_removed(driver, device)
  -- Never fire for the bridge card itself: its device record can leak camera endpoints
  -- into this sub-driver (see the endpoint filtering note in test/test_matter_bridge.lua).
  if switch_utils.detect_bridge(device) then return end

  -- CRITICAL GUARD: when the WHOLE bridge is removed/unpaired, ST deletes the parent and
  -- all its children together — firing per-child remove_camera then would wipe the
  -- daemon's camera fleet and break the "commission with >=1 camera" rule on re-pair.
  -- Only send when a bridge (Aggregator) device is still present in the driver's device
  -- list. Ordering caveat: if ST removes the parent first, this also (correctly)
  -- suppresses the trailing child removals; if a child were removed before the parent
  -- during an unpair, its removal would still reach the daemon — re-onboarded by boot
  -- discovery on re-commission. A second Matter bridge on this driver would also satisfy
  -- this check; the guard is a heuristic, not proof this camera's own parent survives.
  local bridge_present = false
  for _, d in ipairs(driver:get_devices() or {}) do
    if d.id ~= device.id and switch_utils.detect_bridge(d) then
      bridge_present = true
      break
    end
  end
  if not bridge_present then
    log.info_with({ hub_logs = true }, string.format(
      "[single_bridge] camera '%s' removed with no bridge device left -> whole-bridge removal, keeping daemon fleet intact",
      tostring(device.label)))
    return
  end

  -- Preferred key: the cached UniqueID (= daemon dni). In practice hub-core does NOT
  -- forward driver reads of BridgedDeviceBasicInformation, so the cache usually never
  -- populates (verified on hub: READ sent, response never delivered). Fallback key: the
  -- child's endpoint, which is the trailing number of its device_network_id
  -- ("<fabric>-<node>-3" -> 3); the daemon owns the endpoint->dni mapping and resolves it.
  local dni = device:get_field(camera_fields.ONVIF_DNI)
  if type(dni) ~= "string" or dni == "" then dni = nil end
  local endpoint = nil
  if not dni then
    local ep = tostring(device.device_network_id or ""):match("%-(%d+)%s*$")
    endpoint = ep and tonumber(ep) or nil
  end
  if not dni and not endpoint then
    log.warn_with({ hub_logs = true }, string.format(
      "[single_bridge] camera '%s' removed but no cached dni AND no endpoint in device_network_id '%s' -> skipping remove_camera",
      tostring(device.label), tostring(device.device_network_id)))
    return
  end

  bridge_ipc.set_driver(driver) -- hub IP from environment_info.hub_ipv4 (dns self-lookup is unreliable in the sandbox)
  log.info_with({ hub_logs = true }, string.format(
    "[single_bridge] camera '%s' deleted in app -> remove_camera %s on bridge %s:%d",
    tostring(device.label), dni and ("dni=" .. dni) or ("endpoint=" .. tostring(endpoint)),
    bridge_ipc.hub_ip(), bridge_ipc.PORT))
  local resp, err = bridge_ipc.remove_camera(dni, endpoint)
  if resp then
    log.info_with({ hub_logs = true }, "[single_bridge] remove_camera OK: " .. tostring(resp))
  else
    log.warn_with({ hub_logs = true }, "[single_bridge] remove_camera FAILED: " .. tostring(err))
  end
end

local camera_handler = {
  NAME = "Camera Handler",
  lifecycle_handlers = {
    init = CameraLifecycleHandlers.device_init,
    infoChanged = CameraLifecycleHandlers.info_changed,
    doConfigure = CameraLifecycleHandlers.do_configure,
    driverSwitched = CameraLifecycleHandlers.driver_switched,
    added = CameraLifecycleHandlers.added,
    removed = CameraLifecycleHandlers.device_removed
  },
  matter_handlers = {
    attr = {
      [clusters.CameraAvStreamManagement.ID] = {
        [clusters.CameraAvStreamManagement.attributes.HDRModeEnabled.ID] = attribute_handlers.enabled_state_factory(capabilities.hdr.hdr),
        [clusters.CameraAvStreamManagement.attributes.NightVision.ID] = attribute_handlers.night_vision_factory(capabilities.nightVision.nightVision),
        [clusters.CameraAvStreamManagement.attributes.NightVisionIllum.ID] = attribute_handlers.night_vision_factory(capabilities.nightVision.illumination),
        [clusters.CameraAvStreamManagement.attributes.ImageFlipHorizontal.ID] = attribute_handlers.enabled_state_factory(capabilities.imageControl.imageFlipHorizontal),
        [clusters.CameraAvStreamManagement.attributes.ImageFlipVertical.ID] = attribute_handlers.enabled_state_factory(capabilities.imageControl.imageFlipVertical),
        [clusters.CameraAvStreamManagement.attributes.ImageRotation.ID] = attribute_handlers.image_rotation_handler,
        [clusters.CameraAvStreamManagement.attributes.SoftRecordingPrivacyModeEnabled.ID] = attribute_handlers.enabled_state_factory(capabilities.cameraPrivacyMode.softRecordingPrivacyMode),
        [clusters.CameraAvStreamManagement.attributes.SoftLivestreamPrivacyModeEnabled.ID] = attribute_handlers.enabled_state_factory(capabilities.cameraPrivacyMode.softLivestreamPrivacyMode),
        [clusters.CameraAvStreamManagement.attributes.HardPrivacyModeOn.ID] = attribute_handlers.enabled_state_factory(capabilities.cameraPrivacyMode.hardPrivacyMode),
        [clusters.CameraAvStreamManagement.attributes.TwoWayTalkSupport.ID] = attribute_handlers.two_way_talk_support_handler,
        [clusters.CameraAvStreamManagement.attributes.SpeakerMuted.ID] = attribute_handlers.muted_handler,
        [clusters.CameraAvStreamManagement.attributes.SpeakerVolumeLevel.ID] = attribute_handlers.volume_level_handler,
        [clusters.CameraAvStreamManagement.attributes.SpeakerMaxLevel.ID] = attribute_handlers.max_volume_level_handler,
        [clusters.CameraAvStreamManagement.attributes.SpeakerMinLevel.ID] = attribute_handlers.min_volume_level_handler,
        [clusters.CameraAvStreamManagement.attributes.MicrophoneMuted.ID] = attribute_handlers.muted_handler,
        [clusters.CameraAvStreamManagement.attributes.MicrophoneVolumeLevel.ID] = attribute_handlers.volume_level_handler,
        [clusters.CameraAvStreamManagement.attributes.MicrophoneMaxLevel.ID] = attribute_handlers.max_volume_level_handler,
        [clusters.CameraAvStreamManagement.attributes.MicrophoneMinLevel.ID] = attribute_handlers.min_volume_level_handler,
        [clusters.CameraAvStreamManagement.attributes.StatusLightEnabled.ID] = attribute_handlers.status_light_enabled_handler,
        [clusters.CameraAvStreamManagement.attributes.StatusLightBrightness.ID] = attribute_handlers.status_light_brightness_handler,
        [clusters.CameraAvStreamManagement.attributes.RateDistortionTradeOffPoints.ID] = attribute_handlers.rate_distortion_trade_off_points_handler,
        [clusters.CameraAvStreamManagement.attributes.MaxEncodedPixelRate.ID] = attribute_handlers.max_encoded_pixel_rate_handler,
        [clusters.CameraAvStreamManagement.attributes.VideoSensorParams.ID] = attribute_handlers.video_sensor_parameters_handler,
        [clusters.CameraAvStreamManagement.attributes.MinViewportResolution.ID] = attribute_handlers.min_viewport_handler,
        [clusters.CameraAvStreamManagement.attributes.AllocatedVideoStreams.ID] = attribute_handlers.allocated_video_streams_handler,
        [clusters.CameraAvStreamManagement.attributes.Viewport.ID] = attribute_handlers.viewport_handler,
        [clusters.CameraAvStreamManagement.attributes.LocalSnapshotRecordingEnabled.ID] = attribute_handlers.enabled_state_factory(capabilities.localMediaStorage.localSnapshotRecording),
        [clusters.CameraAvStreamManagement.attributes.LocalVideoRecordingEnabled.ID] = attribute_handlers.enabled_state_factory(capabilities.localMediaStorage.localVideoRecording),
        [clusters.CameraAvStreamManagement.attributes.AttributeList.ID] = attribute_handlers.camera_av_stream_management_attribute_list_handler,
        [camera_fields.CameraAVSMFeatureMapAttr.ID] = attribute_handlers.camera_feature_map_handler
      },
      [clusters.CameraAvSettingsUserLevelManagement.ID] = {
        [clusters.CameraAvSettingsUserLevelManagement.attributes.MPTZPosition.ID] = attribute_handlers.ptz_position_handler,
        [clusters.CameraAvSettingsUserLevelManagement.attributes.MPTZPresets.ID] = attribute_handlers.ptz_presets_handler,
        [clusters.CameraAvSettingsUserLevelManagement.attributes.MaxPresets.ID] = attribute_handlers.max_presets_handler,
        [clusters.CameraAvSettingsUserLevelManagement.attributes.ZoomMax.ID] = attribute_handlers.zoom_max_handler,
        [clusters.CameraAvSettingsUserLevelManagement.attributes.PanMax.ID] = attribute_handlers.pt_range_handler_factory(capabilities.mechanicalPanTiltZoom.panRange, camera_fields.pt_range_fields[camera_fields.PAN_IDX].max),
        [clusters.CameraAvSettingsUserLevelManagement.attributes.PanMin.ID] = attribute_handlers.pt_range_handler_factory(capabilities.mechanicalPanTiltZoom.panRange, camera_fields.pt_range_fields[camera_fields.PAN_IDX].min),
        [clusters.CameraAvSettingsUserLevelManagement.attributes.TiltMax.ID] = attribute_handlers.pt_range_handler_factory(capabilities.mechanicalPanTiltZoom.tiltRange, camera_fields.pt_range_fields[camera_fields.TILT_IDX].max),
        [clusters.CameraAvSettingsUserLevelManagement.attributes.TiltMin.ID] = attribute_handlers.pt_range_handler_factory(capabilities.mechanicalPanTiltZoom.tiltRange, camera_fields.pt_range_fields[camera_fields.TILT_IDX].min),
        [clusters.CameraAvSettingsUserLevelManagement.attributes.DPTZStreams.ID] = attribute_handlers.dptz_streams_handler,
        [camera_fields.CameraAVSULMFeatureMapAttr.ID] = attribute_handlers.camera_feature_map_handler
      },
      [clusters.ZoneManagement.ID] = {
        [clusters.ZoneManagement.attributes.MaxZones.ID] = attribute_handlers.max_zones_handler,
        [clusters.ZoneManagement.attributes.Zones.ID] = attribute_handlers.zones_handler,
        [clusters.ZoneManagement.attributes.Triggers.ID] = attribute_handlers.triggers_handler,
        [clusters.ZoneManagement.attributes.SensitivityMax.ID] = attribute_handlers.sensitivity_max_handler,
        [clusters.ZoneManagement.attributes.Sensitivity.ID] = attribute_handlers.sensitivity_handler,
        [camera_fields.ZoneManagementFeatureMapAttr.ID] = attribute_handlers.camera_feature_map_handler
      },
      [clusters.Chime.ID] = {
        [clusters.Chime.attributes.InstalledChimeSounds.ID] = attribute_handlers.installed_chime_sounds_handler,
        [clusters.Chime.attributes.SelectedChime.ID] = attribute_handlers.selected_chime_handler
      },
      -- [single_bridge] BridgedDeviceBasicInformation (0x0039) has no generated cluster in
      -- this SDK, so UniqueID (0x0012) is registered by raw ids (see camera_fields).
      [camera_fields.BridgedDeviceBasicInfoUniqueIDAttr.cluster] = {
        [camera_fields.BridgedDeviceBasicInfoUniqueIDAttr.ID] = attribute_handlers.bridged_device_unique_id_handler
      }
    },
    event = {
      [clusters.ZoneManagement.ID] = {
        [clusters.ZoneManagement.events.ZoneTriggered.ID] = event_handlers.zone_triggered_handler,
        [clusters.ZoneManagement.events.ZoneStopped.ID] = event_handlers.zone_stopped_handler
      }
    }
  },
  capability_handlers = {
    [capabilities.hdr.ID] = {
      [capabilities.hdr.commands.setHdr.NAME] = capability_handlers.set_enabled_factory(clusters.CameraAvStreamManagement.attributes.HDRModeEnabled)
    },
    [capabilities.nightVision.ID] = {
      [capabilities.nightVision.commands.setNightVision.NAME] = capability_handlers.set_night_vision_factory(clusters.CameraAvStreamManagement.attributes.NightVision),
      [capabilities.nightVision.commands.setIllumination.NAME] = capability_handlers.set_night_vision_factory(clusters.CameraAvStreamManagement.attributes.NightVisionIllum)
    },
    [capabilities.imageControl.ID] = {
      [capabilities.imageControl.commands.setImageFlipHorizontal.NAME] = capability_handlers.set_enabled_factory(clusters.CameraAvStreamManagement.attributes.ImageFlipHorizontal),
      [capabilities.imageControl.commands.setImageFlipVertical.NAME] = capability_handlers.set_enabled_factory(clusters.CameraAvStreamManagement.attributes.ImageFlipVertical),
      [capabilities.imageControl.commands.setImageRotation.NAME] = capability_handlers.handle_set_image_rotation
    },
    [capabilities.cameraPrivacyMode.ID] = {
      [capabilities.cameraPrivacyMode.commands.setSoftLivestreamPrivacyMode.NAME] = capability_handlers.set_enabled_factory(clusters.CameraAvStreamManagement.attributes.SoftLivestreamPrivacyModeEnabled),
      [capabilities.cameraPrivacyMode.commands.setSoftRecordingPrivacyMode.NAME] = capability_handlers.set_enabled_factory(clusters.CameraAvStreamManagement.attributes.SoftRecordingPrivacyModeEnabled)
    },
    [capabilities.audioMute.ID] = {
      [capabilities.audioMute.commands.setMute.NAME] = capability_handlers.handle_mute_commands_factory(capabilities.audioMute.commands.setMute.NAME),
      [capabilities.audioMute.commands.mute.NAME] = capability_handlers.handle_mute_commands_factory(capabilities.audioMute.commands.mute.NAME),
      [capabilities.audioMute.commands.unmute.NAME] = capability_handlers.handle_mute_commands_factory(capabilities.audioMute.commands.unmute.NAME)
    },
    [capabilities.audioVolume.ID] = {
      [capabilities.audioVolume.commands.setVolume.NAME] = capability_handlers.handle_set_volume,
      [capabilities.audioVolume.commands.volumeUp.NAME] = capability_handlers.handle_volume_up,
      [capabilities.audioVolume.commands.volumeDown.NAME] = capability_handlers.handle_volume_down
    },
    [capabilities.mode.ID] = {
      [capabilities.mode.commands.setMode.NAME] = capability_handlers.handle_set_status_light_mode
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = capability_handlers.handle_status_led_on,
      [capabilities.switch.commands.off.NAME] = capability_handlers.handle_status_led_off
    },
    [capabilities.audioRecording.ID] = {
      [capabilities.audioRecording.commands.setAudioRecording.NAME] = capability_handlers.handle_audio_recording
    },
    [capabilities.mechanicalPanTiltZoom.ID] = {
      [capabilities.mechanicalPanTiltZoom.commands.panRelative.NAME] = capability_handlers.ptz_relative_move_factory(camera_fields.PAN_IDX),
      [capabilities.mechanicalPanTiltZoom.commands.tiltRelative.NAME] = capability_handlers.ptz_relative_move_factory(camera_fields.TILT_IDX),
      [capabilities.mechanicalPanTiltZoom.commands.zoomRelative.NAME] = capability_handlers.ptz_relative_move_factory(camera_fields.ZOOM_IDX),
      [capabilities.mechanicalPanTiltZoom.commands.setPan.NAME] = capability_handlers.ptz_set_position_factory(capabilities.mechanicalPanTiltZoom.commands.setPan),
      [capabilities.mechanicalPanTiltZoom.commands.setTilt.NAME] = capability_handlers.ptz_set_position_factory(capabilities.mechanicalPanTiltZoom.commands.setTilt),
      [capabilities.mechanicalPanTiltZoom.commands.setZoom.NAME] = capability_handlers.ptz_set_position_factory(capabilities.mechanicalPanTiltZoom.commands.setZoom),
      [capabilities.mechanicalPanTiltZoom.commands.setPanTiltZoom.NAME] = capability_handlers.ptz_set_position_factory(capabilities.mechanicalPanTiltZoom.commands.setPanTiltZoom),
      [capabilities.mechanicalPanTiltZoom.commands.savePreset.NAME] = capability_handlers.handle_save_preset,
      [capabilities.mechanicalPanTiltZoom.commands.removePreset.NAME] = capability_handlers.handle_remove_preset,
      [capabilities.mechanicalPanTiltZoom.commands.moveToPreset.NAME] = capability_handlers.handle_move_to_preset
    },
    [capabilities.zoneManagement.ID] = {
      [capabilities.zoneManagement.commands.newZone.NAME] = capability_handlers.handle_new_zone,
      [capabilities.zoneManagement.commands.updateZone.NAME] = capability_handlers.handle_update_zone,
      [capabilities.zoneManagement.commands.removeZone.NAME] = capability_handlers.handle_remove_zone,
      [capabilities.zoneManagement.commands.createOrUpdateTrigger.NAME] = capability_handlers.handle_create_or_update_trigger,
      [capabilities.zoneManagement.commands.removeTrigger.NAME] = capability_handlers.handle_remove_trigger,
      [capabilities.zoneManagement.commands.setSensitivity.NAME] = capability_handlers.handle_set_sensitivity
    },
    [capabilities.sounds.ID] = {
      [capabilities.sounds.commands.playSound.NAME] = capability_handlers.handle_play_sound,
      [capabilities.sounds.commands.setSelectedSound.NAME] = capability_handlers.handle_set_selected_sound
    },
    [capabilities.videoStreamSettings.ID] = {
      [capabilities.videoStreamSettings.commands.setStream.NAME] = capability_handlers.handle_set_stream
    },
    [capabilities.cameraViewportSettings.ID] = {
      [capabilities.cameraViewportSettings.commands.setDefaultViewport.NAME] = capability_handlers.handle_set_default_viewport
    },
    [capabilities.localMediaStorage.ID] = {
      [capabilities.localMediaStorage.commands.setLocalSnapshotRecording.NAME] = capability_handlers.set_enabled_factory(clusters.CameraAvStreamManagement.attributes.LocalSnapshotRecordingEnabled),
      [capabilities.localMediaStorage.commands.setLocalVideoRecording.NAME] = capability_handlers.set_enabled_factory(clusters.CameraAvStreamManagement.attributes.LocalVideoRecordingEnabled)
    }
  },
  can_handle = require("sub_drivers.camera.can_handle")
}

return camera_handler
