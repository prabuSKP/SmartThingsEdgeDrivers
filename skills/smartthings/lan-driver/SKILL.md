---
name: lan-driver
description: >
  Orchestrate the complete development of a SmartThings Edge driver for LAN/HTTP-connected
  devices and 3rd-party hub bridges (Fibaro, Home Assistant, Hubitat, OpenHAB, etc.).
  This is the master skill — it determines the driver architecture and delegates to
  sub-skills for each phase. Use when a developer asks to: (1) create a new Edge driver
  for a LAN device or hub, (2) bridge a 3rd-party smart home hub to SmartThings,
  (3) understand the full Edge driver development lifecycle, or (4) decide between
  single-device vs bridge/gateway driver architecture.
---

# SmartThings LAN Edge Driver — Master Orchestrator

This skill guides you through building a complete SmartThings Edge driver for LAN/HTTP devices.
It covers two primary architecture patterns and delegates to specialized sub-skills for each phase.

## Architecture Decision

Before writing any code, determine which pattern fits your integration:

### Pattern A: Single-Device Driver

Use when integrating a **single device** that speaks HTTP on the LAN (e.g., a smart plug with a REST API).

```
SmartThings Hub → Edge Driver → Device HTTP API
```

- One SmartThings device per physical device
- Direct mDNS/SSDP discovery or manual IP entry
- Simple lifecycle: discover → create → poll → command

### Pattern B: Hub Bridge Driver

Use when integrating a **3rd-party hub** that manages many child devices (e.g., Fibaro HC2/HC3, Home Assistant, Hubitat).

```
SmartThings Hub → Edge Driver → 3rd-Party Hub API → Child Devices
                       ↓
              Bridge Device (parent)
              ├── Child Device 1
              ├── Child Device 2
              └── Child Device N
```

- One bridge device per 3rd-party hub
- Child devices created as `EDGE_CHILD` type
- Complex lifecycle: discover hub → bootstrap → inventory sync → map devices → create children → poll/sync

**Pattern B is the dominant architecture for 3rd-party hub integrations.** The Fibaro driver is a production reference implementation of this pattern.

## Development Workflow

### Phase 1: Discovery — How does SmartThings find the device/hub?

Load the appropriate sub-skill:

| Discovery Method | Sub-Skill | When to Use |
|---|---|---|
| mDNS (Bonjour) | `smartthings/lan-driver/discovery/mdns-analysis` | Device advertises `_http._tcp` or similar service |
| SSDP (UPnP) | `smartthings/lan-driver/discovery/ssdp-analysis` | Device advertises UPnP services |
| Manual IP Entry | `smartthings/lan-driver/discovery/hub-discovery` | No auto-discovery available |
| Combined | `smartthings/lan-driver/discovery/hub-discovery` | Multiple discovery methods |

### Phase 2: Transport — How does the driver talk to the device/hub?

| Transport | Sub-Skill | When to Use |
|---|---|---|
| HTTP/REST (plain) | `smartthings/lan-driver/bridge/hub-bridge-core` | Standard REST API |
| HTTPS (TLS) | `smartthings/lan-driver/bridge/secure-transport` | Self-signed cert hubs |
| WebSocket | `smartthings/lan-driver/bridge/websocket-debugging` | Push event streams |
| Packet Capture | `smartthings/lan-driver/bridge/packet-analysis` | Reverse engineering |

### Phase 3: Mapping — How do 3rd-party devices become SmartThings devices?

| Task | Sub-Skill |
|---|---|
| Map device types to profiles | `smartthings/lan-driver/mapping/hub-profile-mapping` |
| Generate profile YAML files | `smartthings/lan-driver/mapping/smartthings-profile-generation` |
| Map capabilities & events | `smartthings/lan-driver/mapping/smartthings-capability-mapping` |
| Create/manage child devices | `smartthings/lan-driver/mapping/smartthings-child-devices` |

### Phase 4: Sync — How does state stay current?

| Task | Sub-Skill |
|---|---|
| State sync architecture | `smartthings/lan-driver/bridge/hub-event-sync` |
| Lifecycle handlers | `smartthings/lan-driver/lifecycle/smartthings-device-lifecycle` |
| Runtime environment | `smartthings/lan-driver/lifecycle/smartthings-edge-runtime` |

### Phase 5: Diagnostics — How do you debug and maintain?

| Task | Sub-Skill |
|---|---|
| Hub log analysis | `smartthings/lan-driver/diagnostics/edge-log-analysis` |
| Lua code quality | `smartthings/lan-driver/diagnostics/lua-refactor` |
| PR review | `smartthings/lan-driver/diagnostics/github-pr-review` |

### Phase 6: Templates — Start from a working skeleton

Load `smartthings/lan-driver/templates` for complete boilerplate drivers.

## Project Structure (Reference)

A complete LAN bridge driver follows this structure:

```
my-driver/
├── src/
│   ├── init.lua                 # Driver entrypoint
│   ├── discovery.lua            # mDNS/SSDP/manual discovery
│   ├── discovery_provider.lua   # Discovery implementation details
│   ├── handlers/
│   │   ├── commands.lua         # Capability command handlers
│   │   └── lifecycle.lua        # added/init/removed handlers
│   ├── vendor/                  # Vendor-specific modules
│   │   ├── api.lua              # HTTP API client
│   │   ├── adapter.lua          # Device normalization
│   │   ├── mapper.lua           # Device type → profile mapping
│   │   └── sync.lua             # State synchronization engine
│   ├── fields.lua               # Persisted field name constants
│   ├── utils.lua                # Shared utility functions
│   └── lunchbox/                # HTTP client library (optional)
│       └── rest.lua
├── profiles/
│   ├── bridge.yml               # Bridge/gateway profile
│   ├── switch.yml               # Child device profiles
│   ├── dimmer.yml
│   ├── sensor.yml
│   └── ...
├── config.yml                   # Driver manifest
└── search-parameters.yml        # Discovery filters (optional)
```

## Vendor-Specific Skills

For vendor-specific API knowledge, load the appropriate vendor skill:

| Vendor | Skill |
|---|---|
| Fibaro HC2/HC3 | `vendors/fibaro` |
| Home Assistant | `vendors/homeassistant` |
| Hubitat | `vendors/hubitat` |
| OpenHAB | `vendors/openhab` |

## Quick Reference: Key SDK Imports

```lua
local capabilities = require "st.capabilities"   -- Capability definitions
local Driver = require "st.driver"                -- Driver constructor
local log = require "log"                         -- Logging
local cosock = require "cosock"                   -- Cooperative socket library
local socket = require "cosock.socket"            -- Socket operations
local json = require "st.json"                    -- JSON encode/decode (or "dkjson")
local base64 = require "st.base64"               -- Base64 encoding
```

## Key Constraints

- **All blocking I/O must use cosock** — the hub runs a single Lua coroutine thread
- **File extension is `.yml`, not `.yaml`** for config and profiles
- **`{persist = true}`** — always persist critical device fields for hub restart recovery
- **`pcall` wrap** — wrap all polling and command functions to prevent driver crashes
- **`hub_logs = true`** — use for startup, discovery, and error logs visible via logcat

## Related SmartThings Skills (Non-LAN)

| Skill | Location | Purpose |
|---|---|---|
| CLI Device Control | `smartthings/cli-control` | Runtime device commands, status queries, scenes via SmartThings CLI |
| Cloud-to-Cloud (Schema) | `smartthings/cloud-to-cloud` | OAuth, Lambda, st-schema Node.js, WWST certification |
| Zigbee Drivers | `smartthings/zigbee` | ZCL clusters, attribute reports, configure_reporting |
| Z-Wave Drivers | `smartthings/zwave` | Command Classes, multichannel, configuration parameters |
| Matter Drivers | `smartthings/matter` | Interaction Model, cluster attributes, endpoint routing |
| MQTT Integration | `smartthings/mqtt` | Pure Lua cooperative MQTT client for local brokers |

