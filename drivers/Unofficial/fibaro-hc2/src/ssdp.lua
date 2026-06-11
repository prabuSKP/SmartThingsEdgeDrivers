-- SSDP / UPnP discovery for Fibaro Home Center controllers.
--
-- HC3 does not advertise a browsable mDNS service, and the hub's socket layer cannot
-- resolve "hc3-<serial>.local" hostnames, so mDNS-based discovery is unreliable. SSDP is
-- the alternative: a successful M-SEARCH reply carries a LOCATION header pointing at the
-- device's UPnP description XML, which gives us BOTH the controller's real IP (from the
-- LOCATION URL) and its serial number (from the XML). We then connect by IP -- no name
-- resolution needed.
--
-- There is no st.ssdp SDK helper, so this is hand-rolled cosock UDP multicast, modelled on
-- the SmartThings wemo / sonos drivers. All logging uses the "[Fibaro]" tag with
-- hub_logs = true so it is captured for debugging.
local socket = require "cosock.socket"
local http = require "socket.http"
local ltn12 = require "ltn12"
local log = require "log"
local xml2lua = require "xml2lua"
local xml_handler = require "xmlhandler.tree"

local utils = require "utils"

local ssdp = {}

local MULTICAST_IP = "239.255.255.250"
local MULTICAST_PORT = 1900
local MX = 4 -- seconds the responder may wait before replying (per SSDP spec)

-- HC3 advertises the Fibaro gateway service and replies to a targeted M-SEARCH for it
-- (confirmed via packet capture: it answers ST "urn:fibaro-com:device:Gateway:1" with a
-- LOCATION pointing at its description.xml). We query that ST first so only the HC3
-- responds; ssdp:all / upnp:rootdevice are kept as broad fallbacks in case a firmware
-- variant advertises under a different ST. Replies are still confirmed as Fibaro below.
local FIBARO_GATEWAY_ST = "urn:fibaro-com:device:Gateway:1"
local SEARCH_TARGETS = {
  FIBARO_GATEWAY_ST,
  "ssdp:all",
  "upnp:rootdevice",
}

local function build_msearch(st)
  return table.concat({
    "M-SEARCH * HTTP/1.1",
    "HOST: " .. MULTICAST_IP .. ":" .. tostring(MULTICAST_PORT),
    'MAN: "ssdp:discover"', -- the quotes are required by the spec
    "MX: " .. tostring(MX),
    "ST: " .. st,
    "",
    "",
  }, "\r\n")
end

-- Parse an SSDP datagram (status line + headers) into a lowercase-keyed table.
local function parse_headers(payload)
  local headers = {}
  for k, v in string.gmatch(tostring(payload or ""), "([%w_%-%.]+)%s*:%s*([%g ]*)\r\n") do
    headers[k:lower()] = utils.trim(v)
  end
  return headers
end

-- Split a LOCATION URL ("http://192.168.1.50:80/description.xml") into ip, port.
local function host_port_from_location(location)
  if type(location) ~= "string" then
    return nil, nil
  end
  local ip, port = location:match("^https?://([^:/]+):(%d+)")
  if ip then
    return ip, tonumber(port)
  end
  ip = location:match("^https?://([^:/]+)")
  return ip, nil
end

-- Heuristic: does this SSDP response look like it came from a Fibaro controller? Checks the
-- headers that vendors typically stamp (SERVER / USN / ST / NT / LOCATION). The authoritative
-- confirmation is the device-description manufacturer/model, fetched in build_candidate.
local function looks_like_fibaro(headers)
  local blob = string.lower(table.concat({
    headers.server or "",
    headers.usn or "",
    headers.st or "",
    headers.nt or "",
    headers.location or "",
  }, " "))
  return blob:find("fibaro", 1, true) ~= nil          -- matches "fibaro-com" in ST/USN
    or blob:find("device:gateway", 1, true) ~= nil    -- the Fibaro gateway URN
    or blob:find("home center", 1, true) ~= nil
    or blob:find("homecenter", 1, true) ~= nil
    or blob:find("hc3", 1, true) ~= nil
end

-- Fetch and parse the UPnP device description XML at `location`. Returns a table with
-- friendly_name / manufacturer / model / serial / udn (any may be nil) or nil, err.
function ssdp.fetch_description(location)
  log.info_with({hub_logs = true}, string.format("[Fibaro] SSDP fetching device description: %s", tostring(location)))
  local chunks = {}
  local _, status = http.request({
    url = location,
    method = "GET",
    sink = ltn12.sink.table(chunks),
    timeout = 5,
  })

  -- HC3/UPnP servers sometimes close without the final zero-length chunk; tolerate that and
  -- parse whatever body arrived (the wemo driver hits the same quirk).
  if status ~= 200 and not (type(status) == "string" and status:find("closed")) then
    return nil, "description request failed: " .. tostring(status)
  end

  local body = table.concat(chunks)
  if body == "" then
    return nil, "empty device description"
  end

  local handler = xml_handler:new()
  local parser = xml2lua.parser(handler)
  local ok = pcall(parser.parse, parser, body)
  if not ok or not handler.root then
    return nil, "could not parse device description XML"
  end

  local device = (handler.root.root or {}).device or {}
  local desc = {
    friendly_name = device.friendlyName,
    manufacturer = device.manufacturer,
    model = device.modelName or device.modelDescription,
    serial = device.serialNumber,
    udn = device.UDN,
  }
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] SSDP description parsed: manufacturer=%s model=%s serial=%s name=%s",
    tostring(desc.manufacturer), tostring(desc.model), tostring(desc.serial), tostring(desc.friendly_name)))
  return desc
end

-- Turn a single SSDP response into a bridge candidate, fetching the description for identity.
-- `source_ip` is the datagram's source address (used to cross-check / fall back on).
local function build_candidate(headers, source_ip)
  local ip, port = host_port_from_location(headers.location)
  ip = ip or source_ip
  if not ip then
    return nil
  end
  port = port or 80

  local desc = ssdp.fetch_description(headers.location)

  -- Confirm Fibaro: prefer the description's manufacturer/model; fall back to header heuristic.
  local is_fibaro = looks_like_fibaro(headers)
  if desc then
    local mm = string.lower((tostring(desc.manufacturer or "")) .. " " .. tostring(desc.model or ""))
    if mm:find("fibaro", 1, true) or mm:find("home center", 1, true) or mm:find("hc3", 1, true) then
      is_fibaro = true
    end
  end
  if not is_fibaro then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] SSDP response from %s is not a Fibaro controller; skipping", tostring(ip)))
    return nil
  end

  -- Serial: device description first, else a uuid pulled from USN, else the IP.
  local serial = utils.trim((desc and desc.serial) or "")
  if serial == "" then
    serial = utils.trim(tostring(headers.usn or ""):match("uuid:([%w%-]+)") or "")
  end

  local dni_suffix = serial ~= "" and serial or ip:gsub("%.", "-")
  local label = serial ~= "" and ("Fibaro " .. serial) or "Fibaro HC3"

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] SSDP HC3 candidate: host=%s port=%d serial=%s dni=fibaro-hc3:%s",
    ip, port, tostring(serial), dni_suffix))

  return {
    api_version = 5,
    controller_kind = "hc3",
    device_network_id = "fibaro-hc3:" .. dni_suffix,
    discovery_source = "ssdp",
    host = ip,
    label = label,
    platform = "HC3",
    port = port,
    scheme = port == 443 and "https" or "http",
    serial_number = serial,
  }
end

-- Run a single SSDP discovery sweep. Returns a list of unique HC3 candidates.
-- `timeout` is the total listen window in seconds (defaults to MX + 1).
function ssdp.scan(timeout)
  timeout = timeout or (MX + 1)
  log.info_with({hub_logs = true}, "[Fibaro] ========== Starting SSDP discovery sweep ==========")

  local sock, err = socket.udp()
  if not sock then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] SSDP: could not create UDP socket: %s", tostring(err)))
    return {}
  end

  local ok, bind_err = sock:setsockname("0.0.0.0", 0)
  if not ok then
    sock:close()
    log.warn_with({hub_logs = true}, string.format("[Fibaro] SSDP: setsockname failed: %s", tostring(bind_err)))
    return {}
  end

  -- Fire an M-SEARCH for every search target (UDP is lossy, so the sweep is cheap insurance).
  for _, st in ipairs(SEARCH_TARGETS) do
    local sent, send_err = sock:sendto(build_msearch(st), MULTICAST_IP, MULTICAST_PORT)
    if sent then
      log.info_with({hub_logs = true}, string.format("[Fibaro] SSDP M-SEARCH sent (ST: %s)", st))
    else
      log.warn_with({hub_logs = true}, string.format("[Fibaro] SSDP M-SEARCH send failed (ST: %s): %s", st, tostring(send_err)))
    end
  end

  local deadline = socket.gettime() + timeout
  local seen = {}        -- dedupe key (USN or location) -> true
  local candidates = {}

  while socket.gettime() < deadline do
    sock:settimeout(math.max(0, deadline - socket.gettime()))
    local payload, rip = sock:receivefrom()
    if payload then
      local headers = parse_headers(payload)
      local key = headers.usn or headers.location
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] SSDP response from %s: ST=%s USN=%s SERVER=%s LOCATION=%s",
        tostring(rip), tostring(headers.st), tostring(headers.usn),
        tostring(headers.server), tostring(headers.location)))

      if headers.location and key and not seen[key] then
        seen[key] = true
        if looks_like_fibaro(headers) then
          local candidate = build_candidate(headers, rip)
          if candidate then
            table.insert(candidates, candidate)
          end
        end
      end
    elseif rip ~= "timeout" then
      -- Any non-timeout receive error ends the sweep.
      log.info_with({hub_logs = true}, string.format("[Fibaro] SSDP receive ended: %s", tostring(rip)))
      break
    end
  end

  sock:close()
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] SSDP discovery sweep complete: %d HC3 candidate(s)", #candidates))
  return candidates
end

return ssdp
