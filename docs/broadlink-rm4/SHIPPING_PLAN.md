# BroadLink RM4 — Shipping Plan (v1 skeleton → end-user product)

End-to-end plan, with code-level changes, to close every gap between the current
proof-of-concept driver and something an end user can install, onboard, and use without
touching a code editor or Python.

**Sequencing:** this plan is written *before* hardware validation, deliberately. Phases 1–5
build on top of the protocol layer, not inside it — hardware test results feed back only as
the small parametric fixes listed in [Phase 0](#phase-0--hardware-validation-gate). Plan now,
gate implementation on Phase 0 results.

---

## Current state vs. target

| | Today (v1 skeleton) | Ship target |
|---|---|---|
| Get codes in | Developer edits `codes.lua`, runs Python | **Learn from the ST app** (point remote at RM4, tap Learn) |
| Appliances | 1 hardcoded "IR Appliance" child | User **adds/names/removes** TV/AC/... children from the app |
| Code storage | Static file baked into driver | **Per-device persisted storage**, survives updates |
| Controls | switch on/off + refresh | on/off, arbitrary named codes in Routines, AC mode/setpoint (stretch) |
| Health | none — tile never shows offline | online/offline tracking, scheduled IP refresh |
| Errors | logs only | surfaced in app (offline state), cloud-lock detected |
| Tests | offline crypto KAT + ad-hoc protocol script | framework unit tests + CI |
| Distribution | local folder | shared channel + published capabilities + user docs |

---

## Phase 0 — Hardware validation gate (your test, no TV/AC needed)

This is the **pre-implementation verification procedure** — run it before building
Phases 1–5. It needs only the RM4, the hub, a laptop, and **any IR remote** (any brand);
no TV/AC required. Full step-by-step procedures live in `TESTING.md`;
success/failure log signatures live in `EXPECTED_LOGS.md`. The table maps
each check to those docs and defines the pass criterion for the no-appliance case.

| # | What to verify | How (doc ref) | Pass = (log ref) |
|---|---|---|---|
| 0a | RM4 answers locally, **not cloud-locked** | laptop `python-broadlink` — TESTING §3a | python prints `login OK devtype=... mac=... ip=...` |
| 0b | Driver installs; discovery + app onboarding | TESTING §4 (build/install) + §5 (onboard in ST app) | EXPECTED_LOGS Part 1.1–1.3; app shows parent **"BroadLink RM4"** + child **"IR Appliance"** |
| 0c | **Driver login — THE gate** | automatic on parent init — TESTING §6a | `login OK, device id=...` — EXPECTED_LOGS 1.4 |
| 0d | RM4 learn function works | laptop `python-broadlink` learn — TESTING §3b, point **any remote** at it. (The v1 driver has **no learn trigger yet** — the in-driver learn path is Phase 1 work; here you validate the hardware/protocol side only) | `check_data()` returns non-empty hex |
| 0e | Driver can blast a code (no appliance) | paste the 0d hex into `codes.lua` as `generic.power_on` → redeploy (TESTING §4 one-command deploy) → tap the child switch **On** (TESTING §6b) | clean `send_ir` + `<- reply` — EXPECTED_LOGS 1.5. **Without an appliance, the RM4's reply (+ its LED blink) IS the pass criterion** (per the EXPECTED_LOGS F12 note: logs prove emission, never appliance reaction) |

**Failure interpretation:** EXPECTED_LOGS Part 2 — F2 (discovery finds nothing),
F3 (garbage devtype/mac), F4 (login no-reply → suspect MAC order), F5 (login rejected →
cloud lock). Each entry there has cause + fix.

**How results feed back into this plan:**

| Result | Action |
|---|---|
| All pass | Implement Phases 1–5 as written, zero changes |
| Discovery garbage (devtype=0000 / mac zeros) | Fix reply offsets in `discovery.lua` `parse_reply` (2 lines) from a Wireshark capture |
| Login all-timeouts | Reverse the MAC copy loop in `broadlink.lua` `build_packet` (1 line); retest |
| Login rejected (non-zero error code), can't unlock in BroadLink app | 🛑 **Stop** — cloud-locked firmware; the local-control product is not viable for that unit; re-evaluate (HA bridge route) |
| 0d learn fails (via python-broadlink, remote pointed at it) | Reference implementation itself failing → device/firmware issue (re-check cloud lock, distance <5 cm, fresh remote batteries) — not a driver-code problem. Driver's own learn path gets validated in Phase 1 testing |

Nothing in Phases 1–5 changes shape based on which (non-abort) branch occurs.

---

## Phase 1 — Product core: learning, storage, appliance management

This phase alone removes the three hard blockers (no code input, no appliance management,
no real storage). After it, a user with a working RM4 can fully set up an appliance from
the app.

### 1.1 New custom capabilities (published once to your namespace)

Two capability definition files (source-of-truth in `capabilities/`), published with the
CLI; profiles then reference `<yourNamespace>.<id>`:

```bash
smartthings capabilities:create -i capabilities/ir-learn.json        # -> <ns>.irLearn v1
smartthings capabilities:create -i capabilities/ir-send.json         # -> <ns>.irSend  v1
smartthings capabilities:presentation:create <ns>.irLearn 1 -i capabilities/ir-learn-presentation.json
smartthings capabilities:presentation:create <ns>.irSend 1 -i capabilities/ir-send-presentation.json
```

**`capabilities/ir-learn.json`** — learning trigger + status:
```json
{
  "name": "IR Learn",
  "attributes": {
    "learnStatus": {
      "schema": { "type": "object", "additionalProperties": false, "required": ["value"],
        "properties": { "value": { "type": "string",
          "enum": ["idle", "learning", "captured", "timeout", "failed"] } } }
    },
    "lastCode": {
      "schema": { "type": "object", "additionalProperties": false, "required": ["value"],
        "properties": { "value": { "type": "string", "maxLength": 64 } } }
    }
  },
  "commands": {
    "startLearning": { "name": "startLearning", "arguments": [] }
  }
}
```

**`capabilities/ir-send.json`** — fire a stored code by name (usable from Routines):
```json
{
  "name": "IR Send",
  "attributes": {
    "codeList": {
      "schema": { "type": "object", "additionalProperties": false, "required": ["value"],
        "properties": { "value": { "type": "string", "maxLength": 2048 } } }
    }
  },
  "commands": {
    "sendCode": { "name": "sendCode",
      "arguments": [ { "name": "codeName", "schema": { "type": "string", "maxLength": 64 }, "optional": false } ] }
  }
}
```

> ⚠️ Known risk: custom-capability **presentation** rendering in the app is the flakiest
> part of the ST platform. Mitigation baked into this design: naming is done via
> **preferences** (always renders), learning is a plain argument-less command (renders as a
> button), and `sendCode` is primarily a **Routines** building block, not a dashboard
> control. Nothing user-critical depends on a fancy presentation.

### 1.2 Per-device code storage (replaces `codes.lua` as the primary source)

Storage schema on each **child** device (persisted fields — survive reboots and driver
updates):

```
code_index            -> { "power_on", "power_off", "vol_up", ... }   (table of names)
code_<name>           -> "2600...0d05"                                 (hex string per code)
```

New module **`src/code_store.lua`** (~60 lines):
```lua
local store = {}
function store.save(device, name, hex)      -- validates name, updates code_index + code_<name>
function store.get(device, name)            -- device codes first, codes.lua kind-fallback second
function store.list(device)                 -- returns code_index (for the codeList attribute)
function store.remove(device, name)
function store.emit_list(device)            -- emits <ns>.irSend.codeList as comma-joined names
return store
```
- `get()` fallback order: `device:get_field("code_"..name)` → `codes[kind][name]` — so the
  bundled `codes.lua` becomes an optional seed/dev convenience, never a requirement.
- Enforce limits: max ~40 codes/device, max 4 KB/code, sanitize names to `[%w_]+`
  (datastore size caps are real; log + emit `failed` when hit).

**Changes to `src/init.lua`:** replace the body of `fire()`'s lookup with
`code_store.get(device, name)`. (~5 lines changed.)

### 1.3 In-app learning flow

**User flow:** open child device → **Settings** → type the code name (e.g. `vol_up`) in the
**"Next code name"** preference → back → tap **Start learning** → point the appliance's
remote at the RM4, press the button → status shows `captured`; name appears in the code list.

**Profile change — `profiles/generic-ir.yml`** gains:
```yaml
      - id: <ns>.irLearn
        version: 1
      - id: <ns>.irSend
        version: 1
preferences:
  - name: codeName
    title: Next code name
    description: "Name for the next learned code, e.g. power_on, vol_up. Letters/digits/underscore."
    required: false
    preferenceType: string
    definition: { stringType: text, minLength: 0, maxLength: 64, default: "" }
  - name: powerOnCode
    title: Code fired by switch ON
    preferenceType: string
    definition: { stringType: text, minLength: 0, maxLength: 64, default: "power_on" }
  - name: powerOffCode
    title: Code fired by switch OFF
    preferenceType: string
    definition: { stringType: text, minLength: 0, maxLength: 64, default: "power_off" }
```

**New handler in `src/init.lua`** (uses the already-written `enter_learning`/`check_learned`):
```lua
local function handle_start_learning(driver, device)
  local name = ((device.preferences or {}).codeName or ""):match("^[%w_]+$")
  if not name then
    device:emit_event(cap_learn.learnStatus.failed())
    log.warn_with({hub_logs=true}, "[BroadLink] learn: set a valid 'Next code name' first")
    return
  end
  local h = get_handle(device); if not h then device:emit_event(cap_learn.learnStatus.failed()); return end
  device:emit_event(cap_learn.learnStatus.learning())
  local rm4 = rm4_device(device)
  with_lock(rm4.id, function()
    h:enter_learning()
    for _ = 1, 15 do                        -- ~15 s window
      socket.sleep(1)
      local ir = h:check_learned()
      if ir and #ir > 0 then
        code_store.save(device, name, utils.bytes_to_hex(ir))
        device:emit_event(cap_learn.learnStatus.captured())
        device:emit_event(cap_learn.lastCode({value = name}))
        code_store.emit_list(device)
        return true
      end
    end
    device:emit_event(cap_learn.learnStatus.timeout())
  end)
end
```
Also: `handle_send_code(driver, device, command)` → `fire(device, command.args.codeName)`;
`handle_on/off` read `preferences.powerOnCode` / `powerOffCode` instead of hardcoded
`power_on`/`power_off`. Register both capabilities in `capability_handlers`.

**Changes to `EXPECTED_LOGS.md` / `TESTING.md`:** add the learn-flow log
signatures and the in-app learning procedure (replacing the Python-only path; Python remains
documented as the power-user alternative).

### 1.4 Add / remove appliances from the ST app

Preference-driven (reliable UI), on the **parent** RM4 device.

**Profile change — `profiles/rm4-hub.yml`** gains:
```yaml
preferences:
  - name: addAppliance
    title: Add appliance (type a name)
    description: "Type a name (e.g. Living Room TV) and save; a new appliance device is created. Prefix with 'ac:' for an AC profile (e.g. ac:Bedroom AC)."
    required: false
    preferenceType: string
    definition: { stringType: text, minLength: 0, maxLength: 64, default: "" }
```

**New lifecycle handler in `src/init.lua`:**
```lua
local function info_changed(driver, device, event, args)
  if not is_parent(device) then return end
  local prev = (args.old_st_store.preferences or {}).addAppliance or ""
  local now  = (device.preferences or {}).addAppliance or ""
  if now ~= "" and now ~= prev then
    local kind, name = now:match("^(ac):%s*(.+)$")
    kind, name = kind or "generic", name or now
    create_child(driver, device, kind, name)     -- already implemented
    log.info_with({hub_logs=true}, "[BroadLink] user added appliance '" .. name .. "' (" .. kind .. ")")
  end
end
-- register: lifecycle_handlers = { ..., infoChanged = info_changed }
```
- Child DNI already includes the name → duplicate names are naturally rejected by
  `try_create_device` (same DNI = no-op). Removal = user deletes the child in the app
  (already works; document it).
- **Drop the auto-created "IR Appliance"** default child? Keep it — it gives first-time
  users an immediate thing to try; document rename.

### 1.5 Acceptance criteria (Phase 1 done when)
- [ ] From the app only: add "Living Room TV", learn `power_on`/`power_off` with the real
      remote, tap the switch, appliance reacts.
- [ ] Codes survive hub reboot and a driver version update.
- [ ] A Routine can call `sendCode("vol_up")`.
- [ ] `codes.lua` empty — everything works without it.

**Estimated new/changed code:** ~1 new module (60 L), ~120 L in `init.lua`, 2 profile edits,
2 capability JSONs + presentations. No changes to `broadlink.lua`/`crypto.lua`/`discovery.lua`.

---

## Phase 2 — Controls & profiles beyond on/off

### 2.1 Extra buttons on the child detail view
`sendCode` from Routines covers automation, but users expect tappable buttons. Approach:
**N generic "button slot" components** on `generic-ir.yml` (components `button1..button6`,
each with capability `momentary`), mapped by preferences `button1Code..button6Code`
(default: empty → tap logs "unmapped"). Handler: `momentary.push` on component `buttonK` →
`fire(device, preferences["button"..K.."Code"])`.
- Pros: stock capability (renders everywhere, works in Routines); no presentation risk.
- Cons: fixed slot count; labels are generic. Acceptable v2 trade-off.

### 2.2 AC support (`ir-ac` profile becomes functional)
- Wire `thermostatMode` (`off`/`cool`/`heat`/`auto`) + `thermostatCoolingSetpoint` handlers.
- Code lookup key: `string.format("%s_%d", mode, setpoint)` e.g. `cool_24` — learned via the
  same 1.3 flow (user names the code `cool_24`).
- Handler emits the mode/setpoint events optimistically after a successful fire; `off` fires
  code `power_off` (or `off` if stored).
- Missing state combo → log + emit nothing (tile unchanged) — honest failure.
- **Stretch, not a ship blocker**: v1 ships TV/generic; AC can follow.

### 2.3 RM4 Pro / RF (stretch, post-ship)
Add `sweep_frequency` (0x19), `find_rf_packet` (0x1a), `learn_rf` (0x1b) to `broadlink.lua`;
gate on devtype list. Not needed for RM4 Mini shipping.

---

## Phase 3 — Hardening

### 3.1 Device health (online/offline)
- `send_hex` success → `rm4:online()` + child `device:online()`; final failure (after
  re-login attempt) → `device:offline()` on parent + its children.
- New helper `set_lan_health(driver, rm4, is_online)` iterating `driver:get_devices()`
  filtered by `parent_device_id == rm4.id`.
- `config.yml`: profiles get `health` via LAN default (Edge marks LAN devices online by
  default — we must actively manage it; ~30 L in `init.lua`).

### 3.2 Scheduled IP refresh (DHCP drift)
```lua
driver:call_on_schedule(600, function(driver)      -- every 10 min
  for _, dev in ipairs(discovery.scan(driver, 3)) do
    -- match dni by mac; if ip changed: set_field("ip", ...), drop cached handle, log
  end
end, "rm4-ip-refresh")
```
Plus keep manual Refresh. (~25 L, reuses existing scan/refresh logic from `handle_refresh`.)

### 3.3 Cloud-lock detection & user-visible errors
- `auth()` non-zero error code → parent `offline()` + one-time log
  `"login rejected — device may be cloud-locked; disable 'Lock device' in the BroadLink app"`.
- README/user-guide troubleshooting entry (already drafted in EXPECTED_LOGS F5).
- Optimistic-state honesty: document (user guide) that tiles reflect *sent*, not *confirmed*;
  keep switch model (discrete codes recommended), buttons are stateless anyway.

---

## Phase 4 — Tests & CI (this is a unit-test repo — match house style)

New files under `src/test/`, runnable with the local env
(`edge-test-env\run-edge-tests.ps1 -Driver broadlink-rm4`):

| File | Covers | Style |
|---|---|---|
| `test_utils.lua` | checksum seed/wrap, hex round-trip, lo/hi | pure Lua asserts |
| `test_crypto.lua` | NIST KAT (exists as offline test — port to runner format) | pure |
| `test_broadlink.lua` | `build_packet` byte-exact vs. golden vector; auth parse; retry/backoff; 16-align padding (port of the session's `proto_test.lua`) | mock `cosock.socket` |
| `test_discovery.lua` | hello packet layout; reply parse; dedup; unicast fallback; short-reply guard | mock socket |
| `test_code_store.lua` | save/get/list/remove; fallback to codes.lua; name sanitize; size caps | mock device fields |
| `test_handlers.lua` | on/off → fire + optimistic event; sendCode; learn happy/timeout; add-appliance infoChanged; re-login-once path | framework `mock_device` + stubs, fibaro-hc2 test pattern |

CI: the repo's `run-tests` workflow picks up `src/test/test_*.lua` — verify the driver is
included, or add it to the matrix.

Also in this phase: **crypto decision** — keep the hand-written AES (NIST-verified, zero
deps) or swap to lockbox for "audited third-party" optics. Recommendation: keep, but add the
KAT to the test suite (already planned above) so any regression is caught in CI.

---

## Phase 5 — Distribution & user docs

1. **Publish capabilities** (1.1 commands) — one-time, from your namespace-owning account.
2. **Shared channel**: `edge:channels:create` → `edge:channels:invites:create` → gives a
   public **invite URL**; users click it, enroll their hub, install the driver from the
   channel — no CLI needed on their side.
3. **End-user guide** (`USER_GUIDE.md`, written for non-developers):
   install via invite link → Scan nearby → add appliance → learn codes → control/Routines →
   troubleshooting (cloud-lock, offline tile, "sent but nothing happened" IR reality).
4. **Versioning/support**: semantic version in `config.yml` description; CHANGELOG;
   channel description states it's community-maintained, reverse-engineered protocol, may
   break on BroadLink firmware updates.
5. Explicitly **not** pursuing WWST certification (reverse-engineered protocol).

---

## Sequencing & dependency graph

```
Phase 0 (hardware gate)
   │  pass
   ▼
Phase 1  learning + storage + appliances     ← the product core; biggest chunk
   │
   ├──► Phase 2.1 button slots               (independent of 2.2)
   ├──► Phase 2.2 AC handlers                (stretch — can ship without)
   ├──► Phase 3   hardening                  (3.1/3.2/3.3 independent of Phase 2)
   ▼
Phase 4  tests (grow alongside 1–3; gate on green before 5)
   ▼
Phase 5  channel + docs + release
```

**Minimum shippable** = Phases 0, 1, 3.1, 3.3, 4 (core tests), 5. Phases 2.2/2.3/3.2 can
land in point releases.

---

## What the hardware test can and cannot change (answering "plan before test?")

- **Cannot change** (safe to plan/design now): everything in Phases 1, 2, 4, 5 — these sit
  on top of `Device:*` APIs whose signatures don't depend on byte-order/offset outcomes.
- **Parametric one-liners** (absorbed without plan changes): MAC order, discovery reply
  offsets, learn-payload tweaks.
- **Abort trigger** (the only plan-invalidating outcome): login rejected on non-cloud-locked
  unit, or cloud-lock that can't be disabled → local control impossible → stop before
  Phase 1 spend.

So: plan now ✔, implement Phases 1+ only after Phase 0 says `login OK`.
