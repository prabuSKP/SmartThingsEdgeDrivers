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

### Choosing auth at runtime (do this FIRST, before any deploy)

Decide PAT vs. session once, then **thread the choice through every command** (there is **no `SMARTTHINGS_TOKEN` env var**, so a PAT must be passed on each call). Decision rule:

1. **Default to the existing logged-in session** (browser auth) — probe it cheaply; if it works, no token is needed.
2. **Use a PAT only** when the user supplies one or no session exists.
3. **Security (preferred for agents):** put the token in `config.yaml` (`token:`) or use the session, rather than inline `--token` — an inline token is visible in the process list (`ps`) and shell history, and PATs expire in 24h.

```bash
# --- Auth selection: PAT or existing browser/session login ---
PAT=""        # set ONLY to use PAT auth; leave EMPTY to use the logged-in CLI session (preferred)
PROFILE=""    # a config.yaml PROFILE NAME (e.g. acceptance/staging/development); empty = default
              # NOTE: --profile selects a named profile in config.yaml — it is NOT an "environment" flag

# Prefer an existing session: if this succeeds, you are authenticated and need no PAT
if smartthings locations --json >/dev/null 2>&1; then
  echo "Using existing CLI session"
else
  echo "No session — set PAT, or run 'smartthings locations' once to log in via browser"
fi

# Build a single prefix and reuse it for EVERY command below
ST="smartthings"
[ -n "$PAT" ]     && ST="$ST --token $PAT"        # prefer config.yaml token: over this inline form
[ -n "$PROFILE" ] && ST="$ST --profile $PROFILE"
```

Then run all subsequent commands as `$ST <subcommand>` (e.g. `$ST edge:drivers:package …`). The
device-control examples elsewhere in this skill work the same way — prefix them with `$ST` when you
need a non-default profile or an explicit PAT.

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

> **🛑 BLOCKING PRECONDITION — run the `edge-validation` gate and confirm it passes BEFORE the first
> `edge:drivers:package`.** A clean package/install of a driver that crashes at load (missing `:run()`,
> `cosock.sleep`, a bad capability command, a forward-ref, `driver.open`) just deploys a broken driver
> that shows `BACKOFF`/`NODEVICE` on the hub and "the bridge never loads." Packaging is **not** a test.
> Run the gate first (see `smartthings/lan-driver/diagnostics/edge-validation`):
> ```bash
> G=<skills>/smartthings/lan-driver/diagnostics/edge-validation/scripts
> node "$G/check-lua-nils.js"          $(find src -name '*.lua')   # → clean
> node "$G/check-driver-api.js"        src/init.lua                # → Driver construction OK
> node "$G/check-capability-commands.js" $(find src -name '*.lua') # → capability commands OK
> grep -q ':run()' src/init.lua && echo ":run() OK" || echo "FAIL: init.lua never calls :run()"
> ```
> If anything FAILs, fix it and re-run — **do not package/install until the gate is green.**

### Speed rules (read first — these are the slow-downs to avoid)

- **There is no `smartthings hubs` command, and bare `smartthings` is not a command.** Either one prints the full ~200-line help and burns a turn. List hubs from `devices` (below).
- Always pass `-j`/`--json` and parse with `jq` so each step is non-interactive and machine-readable. Bare commands can drop into interactive pickers that stall the agent.
- **`edge:drivers:install` MUST be given both `--hub` AND `--channel`** (plus `-j`). A bare `install --hub <id>` opens an interactive *"Select a channel"* picker that an agent cannot answer — it ends in `ExitPromptError: User force closed the prompt`. Same for `assign`/`enroll`: always pass the ids.
- A **`422`** from `package` is usually a **transient/flaky endpoint** — **retry 2–3× first** (same command, short backoff); the same bytes typically succeed. It is **never auth** (that's `401`/`403`), so never chase tokens or `curl` the API. Only diagnose content if every retry fails (see the 422 section below).
- Follow the **canonical flow** (package → channel → assign → enroll → install → verify) below. The one-shot `package --channel --hub` is only a shortcut for when the hub is **already enrolled**; do not reach for `--build-only`/`--upload` for a normal deploy.

### List hubs and channels (for selection)

```bash
# ($ST = smartthings + any --token/--profile from "Choosing auth at runtime" above)
# Hubs — NO `smartthings hubs`; filter the device list by type HUB
$ST devices --json | jq '[.[] | select(.type=="HUB") | {deviceId, label, locationId}]'

# Channels you own
$ST edge:channels --json | jq '[.[] | {channelId, name}]'

# Channels a specific hub is already enrolled in
$ST edge:channels:enrollments <hub-id> --json
```

Present these lists and ask the user which **hub** and which **channel** to deploy to before running the install.

### Canonical end-to-end flow (package → channel → assign → enroll → install → verify)

The full, reliable deploy. **First set up `$ST` from "Choosing auth at runtime" above** (PAT or
session), then run in order; capture the id printed by each step. Every command is prefixed with
`$ST` so the chosen auth/profile flows through. Commands verified against the installed SmartThings
CLI (`@smartthings/cli`, `smartthings edge:*`).

```bash
# 1. PACKAGE — build + upload. Prints the Driver Id + version; capture the Driver Id.
$ST edge:drivers:package <driver-dir> --json
#    -> { "driverId": "<driver-id>", "version": "<version>", ... }

# 2. CHANNEL — select an existing channel...
$ST edge:channels --json | jq '[.[] | {channelId, name}]'
#    ...or CREATE one. Input MUST be a file — stdin/heredoc is NOT supported by this command.
cat > /tmp/channel.json <<'JSON'
{ "name": "My Edge Drivers", "description": "Local custom Edge drivers", "termsOfServiceUrl": "https://www.smartthings.com" }
JSON
$ST edge:channels:create --input /tmp/channel.json --json   # add --dry-run to validate first, no submit
#    -> { "channelId": "<channel-id>", ... }

# 3. ASSIGN the driver to the channel (assigns the latest version when no version arg is given)
$ST edge:channels:assign <driver-id> --channel <channel-id>

# 4. ENROLL the hub in the channel — one-time per hub/channel pair, REQUIRED before install
$ST edge:channels:enroll <hub-id> --channel <channel-id>

# 5. INSTALL the driver onto the hub
$ST edge:drivers:install <driver-id> --hub <hub-id> --channel <channel-id>

# 6. VERIFY it is installed
$ST edge:drivers:installed --hub <hub-id> --json | jq '[.[] | {driverId, name, version}]'
```

`$ST` is `smartthings` plus any `--token`/`--profile` you selected. If you're using the default
session and profile, `$ST` is just `smartthings` and these are the bare commands. Get the `<hub-id>`
/ `<channel-id>` from "List hubs and channels" above. Steps 3 and 4 are independent (assign =
driver→channel, enroll = hub→channel); both must be done before step 5.

### One-shot shortcut (only when the hub is ALREADY enrolled)

If the hub is already enrolled in the channel (step 4 done previously), steps 1+3+5 collapse into a
single call:

```bash
$ST edge:drivers:package <driver-dir> --channel <channel-id> --hub <hub-id>
# or, to be prompted for channel/hub instead of passing ids:
$ST edge:drivers:package <driver-dir> --install
```

> **Gotcha:** the one-shot does **not enroll** the hub. On a *fresh* channel/hub pairing its install
> sub-step fails — run the enroll (step 4) once first, or use the full sequence above. A failure here
> is about enrollment, **not** driver content: if `package` alone (no `--channel/--hub`) succeeds, the
> package is valid.

### `--build-only` and `--upload` — you usually do NOT need these

`package <driver-dir>` already builds **and** uploads. The two-step split is for special cases only,
not the normal deploy:

```bash
$ST edge:drivers:package <driver-dir> --build-only /tmp/driver.zip  # build zip, NO upload, NO API call
unzip -l /tmp/driver.zip                                            # inspect exactly what gets packaged
$ST edge:drivers:package --upload /tmp/driver.zip --json           # upload a previously built zip
```

- `--build-only <zip>` — **diagnostics**: produce the package and inspect it (`unzip -l`) without
  hitting the API or consuming the rate limit; or CI build/deploy separation.
- `--upload <zip>` — uploads a prebuilt zip but does **not** assign or install, so you still run
  steps 3–5. Don't substitute it for the canonical flow.

For day-to-day deploys, prefer the **canonical flow** (or the one-shot when already enrolled) — not
`--build-only` + `--upload`.

### After install — updates & logs

Re-running `edge:drivers:package` to the same channel triggers an OTA hot-reload on enrolled hubs (the hub re-runs each device's `init`; see the `ota-analysis` skill). Stream live driver logs by hub IP:

```bash
$ST edge:drivers:logcat <driver-id> --hub-address <hub-ip>
$ST edge:drivers:logcat --all --hub-address <hub-ip> --log-level info
```

### Auth check before deploying

If a deploy command errors on auth, confirm the CLI is logged in and which profile is active:

```bash
smartthings config
```

The CLI authenticates via `config.yaml` or the browser login flow (see [Auth](#auth) above). Warn the user if no credentials are set.

### Resolving 422 (Unprocessable Entity) on `edge:drivers:package`

**STEP 1 — RETRY FIRST. The `/drivers/package` endpoint returns transient 422s.** This is the
*dominant* cause of "package keeps failing": the **same bytes** that 422 will succeed on the next
attempt. So on a 422, **retry the exact same `package` command 2–3 times with a short backoff before
concluding anything** — do not edit the driver, do not touch `search-parameters.yml`, do not chase
auth. (Proven repeatedly: identical content 422s then packages cleanly on retry. A 422 is **never**
auth — a failed login is `401`/`403`.)

```bash
# Retry-with-backoff: succeeds on the first transient-clear, otherwise falls through to diagnosis
for i in 1 2 3; do
  out=$(smartthings edge:drivers:package "$DRIVER_DIR" --json 2>&1)
  echo "$out" | grep -q '"driverId"' && { echo "$out"; break; }
  echo "package attempt $i got 422/err — retrying…"; sleep 4
done
```

**STEP 2 — only if ALL retries fail, THEN it's a content problem.** The CLI truncates the real
message as `error: [Object]`; read it and/or run the local gate:

```bash
SMARTTHINGS_DEBUG=true smartthings edge:drivers:package . 2>&1 | grep -iA2 'unprocess\|constraint\|detail\|"message"'
# and the local validation gate (categories, name/parity, luac) — see the `edge-validation` skill
```

> **Do not misattribute a transient 422.** If you edit a file, retry, and it succeeds, that is almost
> always the flaky endpoint clearing — **not** your edit. Confirm a claimed "fix" against a
> known-good driver before believing it (e.g. v312 packages fine *with* `serviceType:`, so that key
> is not a 422 cause). Don't cite an unrelated edit as the root cause.

Common real content causes (only relevant after retries are exhausted):

- **Invalid profile category** — a `categories:` entry in `profiles/*.yml` uses a non-standard name. Use only verified values (see the `smartthings-profile-generation` skill): `TempSensor` (not `TemperatureSensor`), `LeakSensor` (not `WaterSensor`), `Blind` (not `Blinds`/`BlindController`), `Bridges` (not `Bridge`), `SmartLock` (not `Lock`), `Light` (not `Dimmer`), `GenericSensor` (not `Sensor`/`Other`).
- **Missing/duplicate profile fields** — the YAML lacks a top-level `name:`, or two components share an `id`. Ensure `name: vendor-profile-name` exists and component ids are unique (`main`, `switch2`, …).
- **Profile-name mismatch in Lua** — a `src/*.lua` file references a profile that no profile YAML declares (or differs in case). Verify: `grep -rn "profile =" src/` and match each against a `name:` in `profiles/`.
- **Lua syntax error** — validate locally before packaging: `luac -p src/**/*.lua`.

> **🚫 Never do these (security + dead-ends).** When a deploy command errors, the CLI already holds
> valid auth — so:
> - **Do NOT** read or scrape credential stores (`~/.smartthings/credentials.json`, `config.json`,
>   the OS keyring / `secret-tool`, `/proc/self/environ`, `$SMARTTHINGS_TOKEN`).
> - **Do NOT** reuse a bearer token seen in an error message or log — that token is a leaked
>   credential; using it is a security violation (and won't fix a content 422 anyway).
> - **Do NOT** `curl https://api.smartthings.com/...` directly to bypass the CLI. The CLI is the
>   supported, authenticated path; bypassing it wastes effort and mishandles credentials.
> If auth genuinely failed (401/403), fix it via `smartthings config` / re-login (see [Auth](#auth)) —
> not by extracting tokens.

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
