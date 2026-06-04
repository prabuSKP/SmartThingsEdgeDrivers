---
name: cli-control
description: Direct SmartThings hub control via the official SmartThings CLI. List devices and hubs, read device status, execute capability commands, and package/assign/install custom Edge drivers onto a hub (list hubs & channels, deploy, verify). Use when the user asks to control a SmartThings device, check device state, run a scene, package/deploy/install an Edge driver to a hub, list hubs or channels, or when "smartthings" / "ST" is mentioned.
homepage: https://github.com/SmartThingsCommunity/smartthings-cli
metadata: {"clawdbot": {"emoji": "🏠", "requires": {"bins": ["smartthings"]}}}
---

# SmartThings Direct

Direct control of a SmartThings hub using the official [`@smartthings/cli`](https://github.com/SmartThingsCommunity/smartthings-cli). This is the low-level path — bypasses Home Assistant and Matter bridging. Use this when you want to hit SmartThings devices directly.

For the Home Assistant / Matter setup, see the sibling `smart-home` skill instead.

## Install

```bash
# macOS (recommended)
brew install smartthingscommunity/smartthings/smartthings

# or npm (Node 24.8+)
npm install --global @smartthings/cli
```

Binary: `smartthings` (alias `st`).

Verify: `smartthings --version`.

## Auth

Two options. **Browser login is preferred** for long-lived use because the CLI stores a refresh token.

### Browser (preferred)

Run any command — the CLI opens a browser for Samsung account OAuth on first use.

```bash
smartthings locations      # first call triggers login
```

### Personal Access Token (PAT)

1. Create a PAT at https://account.smartthings.com/tokens
2. Required scopes: `r:devices:*`, `w:devices:*`, `x:devices:*`, `r:locations:*`, `r:scenes:*`, `x:scenes:*`
3. Either pass per command:
   ```bash
   smartthings devices --token <uuid>
   ```
   or add to the config file:
   - macOS: `~/Library/Preferences/@smartthings/cli/config.yaml`
   - Linux: `~/.config/@smartthings/cli/config.yaml`
   ```yaml
   default:
     token: your-pat-uuid-here
   ```

**Heads up:** PATs created after 2024-12-30 expire in **24 hours**. For durable agent use, prefer browser auth or expect to reissue the token.

Confirm config path any time with `smartthings config`.

## Core commands

### Devices

```bash
smartthings devices                              # list all devices
smartthings devices --json                       # JSON output
smartthings devices <id>                         # device detail + capabilities
smartthings devices:status <id>                  # current attribute values
smartthings devices:health <id>                  # online/offline
smartthings devices:capability-status <id> <component> <capability>
```

### Execute commands

Format: `[component:]<capability>:<command>[(args)]` — `component` defaults to `main`.

```bash
# Switch on/off
smartthings devices:commands <id> switch:switch:on
smartthings devices:commands <id> switch:switch:off

# Dimmer to 50 %
smartthings devices:commands <id> main:switchLevel:setLevel\(50\)

# Thermostat cool setpoint to 24 °C
smartthings devices:commands <id> main:thermostatCoolingSetpoint:setCoolingSetpoint\(24\)

# Color temperature
smartthings devices:commands <id> main:colorTemperature:setColorTemperature\(3000\)
```

Parentheses need escaping in bash/zsh. Running `devices:commands` with no args starts an interactive guided prompt — handy for discovering the right capability call.

### Locations, rooms, scenes, capabilities

```bash
smartthings locations
smartthings rooms --location-id <loc-id>
smartthings scenes
smartthings scenes:execute <scene-id>
smartthings capabilities                         # catalog of standard capabilities
```

### Output flags

| Flag | Effect |
|------|--------|
| `-j`, `--json` | JSON to stdout |
| `-y`, `--yaml` | YAML |
| `-o <file>` | write to file (extension sets format) |

No built-in field picker — pipe JSON through `jq`.

## Typical agent workflow

When the user says something like "turn off the living room light":

1. Resolve name → device id:
   ```bash
   scripts/st-find.sh "living room"
   ```
   or directly:
   ```bash
   smartthings devices --json | jq '.[] | select(.label | test("living room"; "i")) | {deviceId, label}'
   ```
2. Check current status before acting (optional but safer):
   ```bash
   smartthings devices:status <id>
   ```
3. Send the command:
   ```bash
   smartthings devices:commands <id> switch:switch:off
   ```
4. Confirm result by re-reading status if the action is consequential (HVAC setpoint, scene execute).

## Edge driver packaging & installation

Build a custom Edge driver (e.g. the Fibaro LAN bridge) and install it onto a hub. This is the complete deploy path — fast commands first, then error recovery at the end.

### Speed rules (read first — these are the slow-downs to avoid)

- **There is no `smartthings hubs` command, and bare `smartthings` is not a command.** Either one prints the full ~200-line help and burns a turn. List hubs from `devices` (below).
- Always pass `-j`/`--json` and parse with `jq` so each step is non-interactive and machine-readable. Bare commands can drop into interactive pickers that stall the agent.
- When you already know the hub id and channel id, use the **one-shot** command — don't run the 6-step sequence.

### List hubs and channels (for selection)

```bash
# Hubs — NO `smartthings hubs`; filter the device list by type HUB
smartthings devices --json | jq '[.[] | select(.type=="HUB") | {deviceId, label, locationId}]'

# Channels you own
smartthings edge:channels --json | jq '[.[] | {channelId, name}]'

# Channels a specific hub is already enrolled in
smartthings edge:channels:enrollments <hub-id> --json
```

Present these lists and ask the user which **hub** and which **channel** to deploy to before running the install.

### Fast path — one command (package + assign + install)

Once you have the channel id and hub id:

```bash
smartthings edge:drivers:package <driver-dir> --channel <channel-id> --hub <hub-id>
```

Builds + uploads, assigns to the channel, and installs on the hub in a single call. To let the CLI prompt interactively for the channel/hub instead of passing ids, use `--install` (implies `--assign`):

```bash
smartthings edge:drivers:package <driver-dir> --install
```

### Step-by-step path (when you need each id explicitly, or for recovery)

```bash
# 1. Package + upload — capture the Driver Id from the output
smartthings edge:drivers:package <driver-dir> --json

# 2. Pick a channel (or create one if none exists)
smartthings edge:channels --json | jq '[.[] | {channelId, name}]'
smartthings edge:channels:create --json <<'EOF'
{ "name": "Custom Edge Drivers", "description": "Local custom Edge drivers", "termsOfServiceUrl": "https://smartthings.com" }
EOF

# 3. Assign the driver to the channel
smartthings edge:channels:assign <driver-id> --channel <channel-id>

# 4. Enroll the hub in the channel (one-time per hub/channel pair)
smartthings edge:channels:enroll <hub-id> --channel <channel-id>

# 5. Install onto the hub
smartthings edge:drivers:install <driver-id> --hub <hub-id> --channel <channel-id>

# 6. Verify it is installed and active
smartthings edge:drivers:installed --hub <hub-id> --json
```

### After install — updates & logs

Re-running `edge:drivers:package` to the same channel triggers an OTA hot-reload on enrolled hubs (the hub re-runs each device's `init`; see the `ota-analysis` skill). Stream live driver logs by hub IP:

```bash
smartthings edge:drivers:logcat <driver-id> --hub-address <hub-ip>
smartthings edge:drivers:logcat --all --hub-address <hub-ip> --log-level info
```

### Auth check before deploying

If a deploy command errors on auth, confirm the CLI is logged in and which profile is active:

```bash
smartthings config
```

The CLI authenticates via `config.yaml` or the browser login flow (see [Auth](#auth) above). Warn the user if no credentials are set.

### Resolving 422 (Unprocessable Entity) on `edge:drivers:package`

A `422` from packaging means API-side validation failed. Common causes and fixes:

- **Invalid profile category** — a `categories:` entry in `profiles/*.yml` uses a non-standard name. Use only verified values (see the `smartthings-profile-generation` skill): `TempSensor` (not `TemperatureSensor`), `LeakSensor` (not `WaterSensor`), `Blind` (not `Blinds`/`BlindController`), `Bridges` (not `Bridge`), `SmartLock` (not `Lock`), `Light` (not `Dimmer`), `GenericSensor` (not `Sensor`/`Other`).
- **Missing/duplicate profile fields** — the YAML lacks a top-level `name:`, or two components share an `id`. Ensure `name: vendor-profile-name` exists and component ids are unique (`main`, `switch2`, …).
- **Profile-name mismatch in Lua** — a `src/*.lua` file references a profile that no profile YAML declares (or differs in case). Verify: `grep -rn "profile =" src/` and match each against a `name:` in `profiles/`.
- **Lua syntax error** — validate locally before packaging: `luac -p src/**/*.lua`.

## Rate limits

- Device commands: **12/min per device**, max 10 commands per request
- Locations: 100/min read, 20/hr write
- Rooms: 50/hr all ops
- Scenes: 50/min execute, 50/min list
- `HTTP 429` = rate limited, `HTTP 422` = guardrail violation

Back off rather than retrying tight.

## Notes

- Flags come **after** the subcommand: `smartthings devices -j`, not `smartthings -j devices`.
- `SMARTTHINGS_PROFILE` env var switches config profiles; there is no `SMARTTHINGS_TOKEN` env var.
- This skill is intentionally thin. Prefer invoking the CLI directly over adding wrapper scripts.
