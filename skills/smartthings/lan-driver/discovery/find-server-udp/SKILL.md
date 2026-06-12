---
name: find-server-udp
description: >
  Discover a LAN hub that advertises neither SSDP/UPnP nor a browsable mDNS service by
  speaking its proprietary "find server" UDP broadcast protocol. Covers the broadcast
  socket setup, limited + subnet-directed targets, exponential backoff with storm-control
  limits, tolerant response parsing, source-IP-as-host fallback, and building a bridge
  candidate from any responder on the vendor port. Use when a hub (e.g. Fibaro HC2/HC3)
  has a documented UDP discovery port but no SSDP/mDNS browse, or when mDNS/SSDP scans
  return nothing on the target network.
---

# Vendor "Find Server" UDP Broadcast Discovery

Some hubs are located by the official app through a **proprietary UDP broadcast** request/response
on a vendor-specific port — **not** SSDP and **not** a browsable mDNS service. This is the only
auto-discovery these hubs support: they advertise no SSDP/UPnP root device, and their mDNS
(Avahi) is hostname-resolution only (no enumerable `_service._tcp`). **Fibaro HC2/HC3 is the
canonical case: a "Fibaro find server" on UDP 44444** (the manual also lists 9999, but packet
capture showed the HC answers only on 44444 and ACKs essentially any datagram there).

When a hub fits this shape, generate this discovery tier **instead of** an `st.mdns` scan — an
mDNS browse will silently find nothing. See `discovery/hub-discovery` for how this tier slots in
beside the manual-entry fallback, and `vendors/fibaro/reference-driver/src/fibaro_finder.lua` for
the complete reference implementation.

---

## When to use this instead of mDNS/SSDP

| Symptom | Discovery to generate |
|---|---|
| Hub documents a UDP discovery/"find" port; app finds it without UPnP | **This skill (UDP find-server)** |
| Hub advertises `_http._tcp` / a browsable mDNS service | `discovery/mdns-analysis` |
| Hub advertises a UPnP `rootdevice` you can validate | `discovery/ssdp-analysis` |
| Hub resolves only `<host>.local` (A record) but does not browse | mDNS **resolver** for serial→host (a lookup, not a scan) — keep it in the sync/bootstrap path, not discovery |

Do **not** emit an `st.mdns` browse "just in case" for a UDP-find hub: it adds latency, never
returns a candidate, and misleads the next maintainer into thinking mDNS is the discovery path.

---

## Design rules (instrumentation-first)

The request/response packet format for these proprietary protocols is usually **undocumented**, so
the finder is written to **work before the payload is fully decoded** and to **log everything** so
the parser can be tuned from a real capture:

1. **Treat any responder on the vendor port as the hub.** The port is vendor-specific, so any
   datagram received there is the hub. Build the candidate from the **datagram's source IP** when
   the payload does not advertise its own address — discovery then works on day one.
2. **Parse tolerantly: JSON first, then a raw-text scan.** Extract serial / IP / name / mac /
   platform / port best-effort; any field may be `nil`. Log the raw response (length, hex, ASCII)
   and every extracted field so an unrecognized reply can be decoded later.
3. **Broadcast to both the limited and the subnet-directed address.** Send to
   `255.255.255.255` *and* `x.y.z.255` derived from `driver.environment_info.hub_ipv4`, because
   many routers/APs drop the limited broadcast.
4. **Respect storm control.** Frequent broadcast trips switch/AP "storm control" and Wi-Fi
   multicast limiting, after which your packets are dropped. Keep volume low: **exponential
   backoff** between probe rounds, a **hard cap** on rounds per sweep, and **stop broadcasting as
   soon as a hub replies** — then listen a short grace window for any other hubs.
5. **Dedup by source IP** before parsing/logging (the hub re-sends its ACK).
6. **Cap hex/ASCII dumps** (e.g. 64 bytes) so a large reply cannot flood the hub log.
7. Log under a single greppable tag with `hub_logs = true` so captures are retrievable.

---

## Reference implementation

```lua
local socket = require "cosock.socket"
local json = require "st.json"
local log = require "log"
local utils = require "utils"

local finder = {}

local FINDER_PORTS = { 44444 }            -- vendor "find server" port(s)
local LIMITED_BROADCAST = "255.255.255.255"
local DEFAULT_LISTEN_WINDOW = 3.0          -- total seconds to probe + listen per sweep
local MAX_HEX_BYTES = 64                    -- cap dumps so a reply cannot flood the log

-- Storm-control limits: back off, cap rounds, stop sending once a hub answers.
local RESEND_INTERVAL_START = 0.3
local RESEND_INTERVAL_MAX = 1.2
local RESEND_BACKOFF = 1.6
local MAX_BROADCAST_ROUNDS = 6
local FOUND_GRACE_SECONDS = 0.5

-- Payload bytes do not matter when the hub ACKs any datagram; a readable token is fine.
local PROBE_PAYLOADS = { { name = "discover", data = "discover" } }

-- Subnet-directed broadcast (x.y.z.255) from the hub's own IPv4, for routers that drop the
-- limited 255.255.255.255 broadcast.
local function directed_broadcast(driver)
  local env = driver and driver.environment_info or {}
  local hub_ip = env.hub_ipv4
  if type(hub_ip) == "string" then
    local a, b, c = hub_ip:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
    if a then return string.format("%s.%s.%s.255", a, b, c) end
  end
  return nil
end

-- Tolerant parse: JSON first, then raw-text heuristics. Logs what it found.
local function parse_response(payload, rip)
  local fields = { source_ip = rip }
  local ok, decoded = pcall(json.decode, payload)
  if ok and type(decoded) == "table" then
    fields.serial   = decoded.serialNumber or decoded.serial or decoded.sn
    fields.ip       = decoded.ip or decoded.ipAddress or decoded.localIP
    fields.platform = decoded.platform or decoded.gatewayType or decoded.type
    fields.port     = utils.safe_tonumber(decoded.port or decoded.localPort)
  end
  local text = tostring(payload or "")
  fields.serial = fields.serial or text:match("[Hh][Cc]%w?%-?%d%d%d%d%d+")
  fields.ip     = fields.ip or text:match("(%d+%.%d+%.%d+%.%d+)")
  return fields
end

-- ANY reply on the vendor port is the hub; source IP is the connect target if none advertised.
local function candidate_from_response(payload, rip, rport)
  local f = parse_response(payload, rip)
  local ip = f.ip or rip
  if not ip then return nil end
  local serial = utils.trim(f.serial or "")
  local port = f.port or 80
  local dni_suffix = serial ~= "" and serial or ip:gsub("%.", "-")
  return {
    device_network_id = "fibaro-hc3:" .. dni_suffix,
    discovery_source = "find_server",
    host = ip,
    port = port,
    scheme = port == 443 and "https" or "http",
    serial_number = serial,
    platform = (f.platform and f.platform ~= "") and f.platform or "HC3",
    label = serial ~= "" and ("Fibaro " .. serial) or "Fibaro HC3",
  }
end

function finder.scan(driver, window)
  window = window or DEFAULT_LISTEN_WINDOW
  local sock = assert(socket.udp())
  sock:setsockname("0.0.0.0", 0)
  sock:setoption("broadcast", true)

  local targets = { LIMITED_BROADCAST }
  local directed = directed_broadcast(driver)
  if directed then table.insert(targets, directed) end

  local function broadcast_probes()
    for _, target in ipairs(targets) do
      for _, port in ipairs(FINDER_PORTS) do
        for _, probe in ipairs(PROBE_PAYLOADS) do
          sock:sendto(probe.data, target, port)
        end
      end
    end
  end

  local deadline = socket.gettime() + window
  local seen, candidates = {}, {}
  local rounds, interval, next_send, stop_sending = 0, RESEND_INTERVAL_START, 0, false

  while socket.gettime() < deadline do
    local now = socket.gettime()
    if not stop_sending and rounds < MAX_BROADCAST_ROUNDS and now >= next_send then
      broadcast_probes()
      rounds = rounds + 1
      next_send = now + interval
      interval = math.min(interval * RESEND_BACKOFF, RESEND_INTERVAL_MAX)
    end

    sock:settimeout(math.max(0, math.min(0.25, deadline - socket.gettime())))
    local payload, rip, rport = sock:receivefrom()
    if payload and not seen[rip] then
      local candidate = candidate_from_response(payload, rip, rport)
      if candidate then
        seen[rip] = true
        table.insert(candidates, candidate)
      end
      if not stop_sending and #candidates > 0 then
        stop_sending = true                                   -- stop the storm
        deadline = math.min(deadline, socket.gettime() + FOUND_GRACE_SECONDS)
      end
    end
  end

  sock:close()
  return candidates
end

return finder
```

If a real capture is available, refine `PROBE_PAYLOADS` and the listen port with:

```bash
tcpdump -n -X udp and \(port 44444 or port 9999\)
```

while the official app discovers the hub, then tune `parse_response` to the observed reply.
