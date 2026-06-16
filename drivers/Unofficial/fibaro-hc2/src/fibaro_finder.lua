-- Fibaro "find server" discovery over UDP broadcast.
--
-- Per the Fibaro manual's factory-default interface table, the Home Center exposes a
-- "Fibaro find server" on UDP ports 44444 and 9999 -- this is how the official web/mobile
-- app locates the hub on the LAN. It is NOT SSDP and NOT mDNS service discovery (HC3 supports
-- neither): it is a proprietary UDP broadcast request/response.
--
-- The exact request/response packet format is not published, so this module is written
-- INSTRUMENTATION-FIRST: it broadcasts a small set of candidate probe payloads on both ports
-- and logs EVERYTHING it receives (source, length, hex, ASCII, and every parse attempt) via
-- log.info_with{hub_logs=true}. Even before the payload is decoded, any responder on these
-- Fibaro-specific ports is treated as the HC3 and a candidate is built from the datagram's
-- source IP -- so discovery can work immediately, and the logs let us tune the parser once a
-- real HC3 reply is seen. Everything here is deliberately verbose by design.
local socket = require "cosock.socket"
local json = require "st.json"
local log = require "log"

local utils = require "utils"

local finder = {}

-- Test injection point: tests replace finder._socket with a mock before calling finder.scan().
finder._socket = socket

-- Fibaro find-server port. Packet capture (june_12) showed the HC replies only on 44444
-- (port 9999 yielded nothing), and it ACKs essentially any datagram there, so a single probe
-- on 44444 is enough -- no need for the original 5-probe x 2-port sweep.
local FINDER_PORTS = { 44444 }
local LIMITED_BROADCAST = "255.255.255.255"
local DEFAULT_LISTEN_WINDOW = 3.0 -- total seconds to probe + listen per sweep
local MAX_HEX_BYTES = 64           -- cap hex/ascii dumps so a reply cannot flood the log

-- Broadcast-rate controls. Frequent broadcast can trip switch/AP "storm control" or Wi-Fi
-- multicast limiting and start getting dropped, so we keep the volume low: retry with an
-- EXPONENTIAL BACKOFF, hard-CAP the number of probe rounds per sweep, and STOP broadcasting
-- as soon as a controller replies (then listen briefly for any others).
local RESEND_INTERVAL_START = 0.3   -- first retry gap
local RESEND_INTERVAL_MAX = 1.2     -- backoff ceiling
local RESEND_BACKOFF = 1.6          -- per-round multiplier
local MAX_BROADCAST_ROUNDS = 6      -- never send more than this many probe rounds per sweep
local FOUND_GRACE_SECONDS = 0.5     -- after the first reply, listen this long for other HCs, then end

-- Request payload. The HC's reply is "ACK <serial> <mac>" to any datagram on 44444, so the
-- exact bytes do not matter; "discover" is a readable choice.
local PROBE_PAYLOADS = {
  { name = "discover", data = "discover" },
}

-- =====================================================================================
-- Debug helpers
-- =====================================================================================

local function to_hex(s)
  local n = math.min(#s, MAX_HEX_BYTES)
  local parts = {}
  for i = 1, n do
    parts[#parts + 1] = string.format("%02X", string.byte(s, i))
  end
  local suffix = (#s > MAX_HEX_BYTES) and string.format(" ...(+%d bytes)", #s - MAX_HEX_BYTES) or ""
  return table.concat(parts, " ") .. suffix
end

local function to_ascii(s)
  local n = math.min(#s, MAX_HEX_BYTES)
  return (s:sub(1, n):gsub("[^\32-\126]", "."))
end

-- =====================================================================================
-- Broadcast target derivation
-- =====================================================================================

-- Compute the subnet-directed broadcast (x.y.z.255) from the hub's own IPv4 if we can read
-- it, so routers that drop the limited 255.255.255.255 broadcast still get the probe.
local function directed_broadcast(driver)
  local env = driver and driver.environment_info or {}
  local hub_ip = env.hub_ipv4
  if type(hub_ip) == "string" then
    local a, b, c = hub_ip:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
    if a then
      return string.format("%s.%s.%s.255", a, b, c)
    end
  end
  return nil
end

-- =====================================================================================
-- Response parsing (tolerant -- logs everything, extracts what it can)
-- =====================================================================================

-- Pull a serial / IP / name out of whatever the HC3 returned, trying JSON first then a raw
-- text scan. Returns a table of best-effort fields (any may be nil). ALWAYS logs what it did.
local function parse_response(payload, rip)
  local fields = { source_ip = rip }

  -- 1. Try JSON.
  local ok, decoded = pcall(json.decode, payload)
  if ok and type(decoded) == "table" then
    log.info_with({hub_logs = true}, "[Fibaro] finder: response parsed as JSON")
    fields.json = decoded
    fields.serial = decoded.serialNumber or decoded.serial or decoded.sn
    fields.ip = decoded.ip or decoded.ipAddress or decoded.localIP or decoded.localAddress
    fields.name = decoded.hcName or decoded.name or decoded.friendlyName
    fields.mac = decoded.mac or decoded.macAddress
    fields.platform = decoded.platform or decoded.gatewayType or decoded.type
    fields.port = utils.safe_tonumber(decoded.port or decoded.localPort)
  else
    log.info_with({hub_logs = true}, "[Fibaro] finder: response is not JSON, scanning raw text")
  end

  -- 2. Raw-text heuristics (fills any gaps JSON left, and covers non-JSON payloads).
  local text = tostring(payload or "")
  if not fields.serial then
    -- Fibaro serials look like "HC3-00033787" / "HCL-..." etc.
    fields.serial = text:match("[Hh][Cc]%w?%-?%d%d%d%d%d+")
  end
  if not fields.ip then
    fields.ip = text:match("(%d+%.%d+%.%d+%.%d+)")
  end
  if not fields.platform then
    fields.platform = text:match("[Hh][Cc]3[Ll]?") and "HC3" or nil
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] finder: extracted fields -> serial=%s ip=%s name=%s mac=%s platform=%s port=%s (source_ip=%s)",
    tostring(fields.serial), tostring(fields.ip), tostring(fields.name),
    tostring(fields.mac), tostring(fields.platform), tostring(fields.port), tostring(rip)))

  return fields
end

-- Decide whether a datagram is (probably) from a Fibaro HC and turn it into a candidate.
-- Because 44444/9999 are Fibaro-specific, ANY reply there is treated as the HC3; the source
-- IP is the connection target if the payload didn't advertise one.
local function candidate_from_response(payload, rip, rport)
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] finder: RAW response from %s:%s len=%d", tostring(rip), tostring(rport), #payload))
  log.info_with({hub_logs = true}, string.format("[Fibaro] finder: response ASCII: %s", to_ascii(payload)))
  log.info_with({hub_logs = true}, string.format("[Fibaro] finder: response HEX  : %s", to_hex(payload)))

  local f = parse_response(payload, rip)
  local ip = f.ip or rip
  if not ip then
    log.warn_with({hub_logs = true}, "[Fibaro] finder: no usable IP in response or source; skipping")
    return nil
  end

  local serial = utils.trim(f.serial or "")
  local port = f.port or 80
  local dni_suffix = serial ~= "" and serial or ip:gsub("%.", "-")
  local label = serial ~= "" and ("Fibaro " .. serial) or "Fibaro HC3"

  local candidate = {
    api_version = 5,
    controller_kind = "hc3",
    device_network_id = "fibaro-hc3:" .. dni_suffix,
    discovery_source = "fibaro_finder",
    host = ip,
    label = label,
    platform = (f.platform and f.platform ~= "") and f.platform or "HC3",
    port = port,
    scheme = port == 443 and "https" or "http",
    serial_number = serial,
  }

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] finder: HC3 candidate built -> host=%s port=%d serial=%s dni=%s",
    candidate.host, candidate.port, tostring(serial), candidate.device_network_id))
  return candidate
end

-- =====================================================================================
-- Scan
-- =====================================================================================

-- Broadcast the find-server probes and collect HC3 candidates. `driver` is used only to
-- derive the subnet-directed broadcast; `window` is the listen duration in seconds.
function finder.scan(driver, window)
  window = window or DEFAULT_LISTEN_WINDOW
  log.info_with({hub_logs = true}, "[Fibaro] ========== Starting Fibaro find-server discovery (UDP 44444) ==========")

  local sock, err = finder._socket.udp()
  if not sock then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] finder: could not create UDP socket: %s", tostring(err)))
    return {}
  end

  local ok, bind_err = sock:setsockname("0.0.0.0", 0)
  if not ok then
    sock:close()
    log.warn_with({hub_logs = true}, string.format("[Fibaro] finder: setsockname failed: %s", tostring(bind_err)))
    return {}
  end

  local bcast_ok, bcast_err = sock:setoption("broadcast", true)
  if not bcast_ok then
    log.warn_with({hub_logs = true}, string.format(
      "[Fibaro] finder: setoption(broadcast) failed: %s (broadcast sends may be rejected)", tostring(bcast_err)))
  end

  -- Build the list of broadcast targets.
  local targets = { LIMITED_BROADCAST }
  local directed = directed_broadcast(driver)
  if directed then
    table.insert(targets, directed)
  end
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] finder: broadcast targets=[%s] ports=[%s]",
    table.concat(targets, ", "), table.concat(FINDER_PORTS, ", ")))

  -- Broadcast the probe to every target/port. UDP is lossy, so a single send is unreliable --
  -- the receive loop re-broadcasts with backoff until a controller replies (see below).
  local function broadcast_probes(verbose)
    for _, target in ipairs(targets) do
      for _, port in ipairs(FINDER_PORTS) do
        for _, probe in ipairs(PROBE_PAYLOADS) do
          local sent, send_err = sock:sendto(probe.data, target, port)
          if verbose then
            if sent then
              log.info_with({hub_logs = true}, string.format(
                "[Fibaro] finder: SENT probe '%s' -> %s:%d (len=%d)", probe.name, target, port, #probe.data))
            else
              log.warn_with({hub_logs = true}, string.format(
                "[Fibaro] finder: send '%s' -> %s:%d FAILED: %s", probe.name, target, port, tostring(send_err)))
            end
          end
        end
      end
    end
  end

  -- Probe + listen. We re-broadcast with exponential backoff (capped) ONLY until a controller
  -- replies; once one does we stop sending and just listen for a short grace period. This keeps
  -- broadcast volume minimal so storm control / Wi-Fi multicast limiting never starts dropping
  -- our packets. The HC re-sends the same ACK, so we dedup by source IP before parsing/logging.
  local deadline = socket.gettime() + window
  local seen = {}
  local candidates = {}
  local response_count = 0
  local rounds = 0
  local interval = RESEND_INTERVAL_START
  local next_send = 0          -- 0 => send immediately on the first iteration
  local stop_sending = false   -- set once a controller replies

  while socket.gettime() < deadline do
    local now = socket.gettime()

    -- Send another probe round only while no one has answered and we are under the cap.
    if not stop_sending and rounds < MAX_BROADCAST_ROUNDS and now >= next_send then
      broadcast_probes(rounds == 0)  -- log only the first round
      rounds = rounds + 1
      next_send = now + interval
      interval = math.min(interval * RESEND_BACKOFF, RESEND_INTERVAL_MAX)
    end

    -- Receive in short slices so we can loop back to re-broadcast / re-check the deadline.
    local slice = math.min(0.25, deadline - socket.gettime())
    sock:settimeout(math.max(0, slice))
    local payload, rip, rport = sock:receivefrom()
    if payload then
      response_count = response_count + 1
      if not seen[rip] then
        local candidate = candidate_from_response(payload, rip, rport)
        if candidate then
          seen[rip] = true
          table.insert(candidates, candidate)
        end
      end
      -- Got an answer: stop broadcasting and shrink the window to a brief grace period so any
      -- other controllers that already received our probes can still reply.
      if not stop_sending and #candidates > 0 then
        stop_sending = true
        deadline = math.min(deadline, socket.gettime() + FOUND_GRACE_SECONDS)
        log.info_with({hub_logs = true}, string.format(
          "[Fibaro] finder: controller replied after %d probe round(s); halting broadcasts, listening %.1fs more",
          rounds, FOUND_GRACE_SECONDS))
      end
    elseif rip ~= "timeout" then
      log.info_with({hub_logs = true}, string.format("[Fibaro] finder: receive ended: %s", tostring(rip)))
      break
    end
  end

  sock:close()
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] finder: discovery complete -- %d raw response(s), %d HC3 candidate(s)",
    response_count, #candidates))
  if response_count == 0 then
    log.info_with({hub_logs = true},
      "[Fibaro] finder: no responses. If the HC3 is on this subnet, it may reply to a FIXED port "
      .. "(try binding 9999) or require a specific request payload -- capture the official app with "
      .. "'tcpdump -n -X udp and (port 44444 or port 9999)' and tune PROBE_PAYLOADS / listen port.")
  end
  return candidates
end

return finder
