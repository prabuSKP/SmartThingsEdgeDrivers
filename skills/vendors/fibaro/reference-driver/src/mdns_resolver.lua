-- Raw mDNS A-record resolver for Fibaro HC3 hostname lookup.
--
-- HC3 Avahi publishes "hc3-<serial>.local" as a plain DNS-SD A-record (hostname only --
-- it does NOT advertise a browsable service), but the SmartThings hub's cosock socket
-- layer cannot resolve .local names (no nss-mdns), so the usual getaddrinfo path fails.
-- This module fills the gap by sending a hand-crafted mDNS A-record query to the mDNS
-- multicast group 224.0.0.251:5353 and parsing the unicast reply.
--
-- Per RFC 6762 §6.7: "If the source UDP port in a received Multicast DNS query is not
-- port 5353, the Multicast DNS responder MUST send a UDP response directly back to the
-- querier, via unicast." Since we send from an ephemeral port (not 5353), the HC3 is
-- required to reply unicast straight to our socket -- no group join needed.
--
-- mDNS multicast is commonly reflected across VLANs by routers (UniFi "Multicast DNS",
-- Omada, Avahi reflector), so this path works in more topologies than the UDP 44444
-- broadcast, which is never reflected.

local socket = require "cosock.socket"
local log = require "log"

local resolver = {}

local MDNS_GROUP   = "224.0.0.251"
local MDNS_PORT    = 5353
local QUERY_TIMEOUT = 2.0   -- seconds to wait for reply per attempt
local MAX_RETRIES  = 2      -- total query rounds before giving up

-- =====================================================================================
-- DNS packet builder
-- =====================================================================================

-- Encode a hostname into DNS wire-format length-prefixed labels terminated by 0x00.
-- "hc3-00033787.local" -> "\x0Chc3-00033787\x05local\x00"
local function encode_name(hostname)
  local parts = {}
  for label in hostname:gmatch("[^%.]+") do
    parts[#parts + 1] = string.char(#label) .. label
  end
  parts[#parts + 1] = "\x00"
  return table.concat(parts)
end

-- Build a DNS A-record query packet.
-- QCLASS = 0x8001 (IN | QU bit per RFC 6762 §5.4): requests a unicast response.
-- The non-5353 source port alone (§6.7) already forces unicast, so QU is belt-and-suspenders.
local function build_query(hostname)
  local txid = math.random(1, 65534)
  local qname = encode_name(hostname)
  local header = string.char(
    math.floor(txid / 256), txid % 256,  -- ID (2 bytes)
    0x00, 0x00,                          -- Flags: standard query, recursion NOT desired
    0x00, 0x01,                          -- QDCOUNT = 1
    0x00, 0x00,                          -- ANCOUNT = 0
    0x00, 0x00,                          -- NSCOUNT = 0
    0x00, 0x00                           -- ARCOUNT = 0
  )
  -- QTYPE A = 0x0001, QCLASS IN|QU = 0x8001
  return header .. qname .. "\x00\x01\x80\x01", txid
end

-- =====================================================================================
-- DNS response parser
-- =====================================================================================

-- Skip a DNS name in wire-format at `pos` (1-based). Handles compression pointers
-- (two-byte pointer when the top byte >= 0xC0). Returns the position after the name.
local function skip_name(data, pos)
  while pos <= #data do
    local len = string.byte(data, pos)
    if not len or len == 0 then return pos + 1 end
    if len >= 0xC0 then return pos + 2 end  -- compression pointer: top 2 bits set
    pos = pos + 1 + len
  end
  return pos
end

-- Read a big-endian 16-bit integer from `data` at `pos`. Returns (value, next_pos).
local function read_u16(data, pos)
  local hi = string.byte(data, pos) or 0
  local lo = string.byte(data, pos + 1) or 0
  return hi * 256 + lo, pos + 2
end

-- Parse a DNS response packet and extract the first A-record IPv4 address, or nil.
local function parse_response(data)
  if #data < 12 then return nil end

  -- Byte 3 flag byte: bit 7 (QR) must be 1 for a response.
  if string.byte(data, 3) < 0x80 then return nil end

  local qdcount = string.byte(data, 5) * 256 + string.byte(data, 6)
  local ancount = string.byte(data, 7) * 256 + string.byte(data, 8)
  if ancount == 0 then return nil end

  -- Skip the 12-byte header then the question section.
  local pos = 13
  for _ = 1, qdcount do
    pos = skip_name(data, pos)
    pos = pos + 4  -- QTYPE (2) + QCLASS (2)
  end

  -- Walk the answer section looking for an A record.
  for _ = 1, ancount do
    if pos > #data then break end
    pos = skip_name(data, pos)                      -- NAME
    local rtype; rtype, pos = read_u16(data, pos)   -- TYPE
    pos = pos + 2                                   -- CLASS (ignore cache-flush bit)
    pos = pos + 4                                   -- TTL
    local rdlen; rdlen, pos = read_u16(data, pos)   -- RDLENGTH

    if rtype == 1 and rdlen == 4 then               -- TYPE A, 4-byte IPv4 RDATA
      if pos + 3 <= #data then
        local b1, b2, b3, b4 = string.byte(data, pos, pos + 3)
        return string.format("%d.%d.%d.%d", b1, b2, b3, b4)
      end
    end

    pos = pos + (rdlen or 0)
  end

  return nil
end

-- =====================================================================================
-- Public API
-- =====================================================================================

-- Resolve `hostname` (e.g. "hc3-00033787.local") to an IPv4 address via mDNS.
-- Sends an A-record query to the mDNS multicast group and waits for the unicast reply.
-- Returns the IP string (e.g. "192.168.0.126") on success, or nil if unreachable.
function resolver.resolve(hostname, timeout)
  timeout = timeout or QUERY_TIMEOUT
  log.info_with({hub_logs = true}, string.format("[Fibaro] mDNS: resolving %s", hostname))

  local sock, err = socket.udp()
  if not sock then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] mDNS: UDP socket error: %s", tostring(err)))
    return nil
  end

  local ok, bind_err = sock:setsockname("0.0.0.0", 0)
  if not ok then
    sock:close()
    log.warn_with({hub_logs = true}, string.format("[Fibaro] mDNS: setsockname error: %s", tostring(bind_err)))
    return nil
  end

  local query, txid = build_query(hostname)
  local result = nil

  for attempt = 1, MAX_RETRIES do
    local sent, send_err = sock:sendto(query, MDNS_GROUP, MDNS_PORT)
    if sent then
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] mDNS: A query sent for %s (attempt %d/%d, txid=0x%04x)",
        hostname, attempt, MAX_RETRIES, txid))
    else
      log.warn_with({hub_logs = true}, string.format(
        "[Fibaro] mDNS: query send failed (attempt %d): %s", attempt, tostring(send_err)))
    end

    local deadline = socket.gettime() + timeout
    while socket.gettime() < deadline do
      local slice = math.min(0.25, deadline - socket.gettime())
      sock:settimeout(math.max(0, slice))
      local payload, rip, rport = sock:receivefrom()
      if payload then
        log.info_with({hub_logs = true}, string.format(
          "[Fibaro] mDNS: response from %s:%s len=%d", tostring(rip), tostring(rport), #payload))
        local ip = parse_response(payload)
        if ip then
          log.info_with({hub_logs = true}, string.format(
            "[Fibaro] mDNS: resolved %s -> %s", hostname, ip))
          result = ip
          break
        end
      elseif rip ~= "timeout" then
        log.info_with({hub_logs = true}, string.format(
          "[Fibaro] mDNS: receive ended: %s", tostring(rip)))
        break
      end
    end

    if result then break end
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] mDNS: no reply for %s (attempt %d/%d)", hostname, attempt, MAX_RETRIES))
  end

  sock:close()
  if not result then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] mDNS: could not resolve %s", hostname))
  end
  return result
end

return resolver
