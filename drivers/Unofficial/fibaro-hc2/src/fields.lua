local fields = {
  INIT = "_init",
  POLL_TIMER = "_poll_timer",
  CONTROLLER_KIND = "controller_kind",
  API_VERSION = "api_version",
  POLL_COUNT = "_poll_count",
  BRIDGE_HOST = "bridge_host",
  BRIDGE_PORT = "bridge_port",
  BRIDGE_SCHEME = "bridge_scheme",
  -- Dynamically fetched HC3 CA certificate (PEM) and its SHA-256 fingerprint.
  -- Populated from GET /api/settings/certificates/ca after the first HTTPS bootstrap,
  -- then used to pin/validate every subsequent TLS connection. See fibaro/cert.lua.
  BRIDGE_CA_PEM = "bridge_ca_pem",
  BRIDGE_CA_FP = "bridge_ca_fp",
  DISCOVERY_SOURCE = "discovery_source",
  LAST_REFRESH_STATES = "last_refresh_states",
  PLATFORM = "platform",
  SERIAL_NUMBER = "serial_number",
  PARENT_BRIDGE_DNI = "parent_bridge_dni",
  HC2_DEVICE_ID = "hc2_device_id",
  HC2_DEVICE_TYPE = "hc2_device_type",
  HC2_DEVICE_KIND = "hc2_device_kind",
  HC2_ROOM_ID = "hc2_room_id",
  HC2_ROOM_NAME = "hc2_room_name",
}

return fields
