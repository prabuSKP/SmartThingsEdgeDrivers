# BroadLink RM4 — Known Gaps (from real-device testing)

Findings from on-hub testing. The early gaps (G1–G5) were all in the **product/UX layer**
(getting to a controllable, code-backed device). A later session then found a real **protocol**
bug in the send path — **G6**, see the update block below.

**Evidence:** `logs/shortVersion*` (hub logs) + `logs/Screenshot_*.jpg`, sessions **2026-07-09**
on a real RM4 (devtype `0x520c`, ip `192.168.68.113`).

---

## Update (2026-07-09, later session) — G6: send path rejected with `-5`, now FIXED

The G1–G5 work got a **typed TV child with seed codes** onboarded and firing (`send_ir: 74 IR
bytes` + a reply each tap) — but the appliance still didn't react. Adding **errcode logging + a
TX packet dump** (log `shortVersion4`) exposed the real cause: **every `0x6a` IR send was
rejected by the RM4 with `errcode=65531` (`0xFFFB` = -5)** — the device received the packet and
**refused to emit**. Login always succeeded, which masked it.

**Root cause — wrong payload framing.** The RM4 (devtype `0x520c`) is a `rm4mini`, which in
`python-broadlink` uses the **`rmminib`** send format: a 2-byte LE length + 4-byte LE
sub-command, then data (`struct.pack("<HI", len(data)+4, command) + data`). Our `send_ir` sent
the **older RM-Mini (`rmmini`)** format `{0x02,0x00,0x00,0x00} + ir` with **no length prefix**,
so the RM4 read `0x02` as the length and rejected the frame. Login worked yet sends never
controlled anything because login uses the fixed INITIAL key and never exercises the `0x6a`
payload shape — the first *send* is the first thing that does.

**Fix (`broadlink.lua`):** added `cmd_6a(command, data)` building the `rmminib` frame; all three
`0x6a` sub-commands (send `0x02`, enter-learning `0x03`, check-learned `0x04`) now use it,
verified byte-for-byte against `python-broadlink`. `check_learned` now reads learned bytes from
decrypted offset `0x06` (was `0x04`). Also `auth()` resets key/IV/id to the initial values so a
re-login is clean (a re-auth on a live handle previously replied `-7` "control key expired"),
and `send_ir` now fails on any non-zero errcode instead of treating any reply as success.

**Related fix:** added the power **toggle** (`0xE0E040BF`) + a `powerStyle` preference so the TV
switch works on Samsung monitors that ignore discrete on/off codes.

> This corrects the "crux" note further down ("a UX/presentation problem, **not** a protocol
> problem"): true for G1–G5, but the *send path itself* did have a protocol bug (G6).

---

## Update (2026-07-10) — G7: blank card attributes (NaN / dashes), now FIXED

**Evidence:** app screenshots of the **TV** card (Volume shows **"NaN"**) and the **AC** card
(thermostat mode, cooling setpoint and wind strength all show **"–"**).

**Root cause.** SmartThings attributes start **null**, and the app renders null as `NaN`/a dash.
IR is **one-way**, so nothing ever reports state back and the driver never seeded any starting
value. Separately, the list attributes (`supportedPlaybackCommands`, `supportedThermostatModes`,
`supportedAcFanModes`, `supportedTrackControlCommands`, `supportedFanOscillationModes`) were
never set — which is why the media transport buttons were disabled and the mode/fan pickers were
empty.

**Fix (`init.lua`):** added `seed_child_state(device)`, called from the `init` lifecycle for
child devices. It emits sensible defaults per capability **only via `emit_event` — it never
sends IR** (verified: zero `send_ir` / `TX cmd=0x6a` on restart). Scalar attributes are seeded
only when currently **null** (checked via `get_latest_state`), so a restart never clobbers values
the user has set; the `supported*` lists are always re-emitted.

**Honest caveat:** seeded values are **optimistic placeholders, not real readings** — IR gives no
feedback, so the card can drift if the physical remote is used.

**Status: FIXED** — implemented and verified offline; pending hardware confirmation.

---

## Design decision (not a gap) — no AC seed codes; Learn mode is the supported path

`codes.ac = {}` **on purpose.** A TV sends one 32-bit NEC code per button, so codes can be
generated; an AC transmits its **entire state** per press — for Samsung a 14-byte frame (2 ×
7-byte sections), different timings, and a per-section checksum, with the layout varying across
AC generations. A wrong AC code is **indistinguishable from a right one in the logs** (the RM4
replies `errcode=0`; the AC simply ignores it). So ACs are taught via **Learn mode**: one code
per `"<mode>_<setpoint>_<fan>"` combo (e.g. `cool_24_auto`) plus `power_off`. Only the **TV**
type ships bundled seed codes (a Samsung codeset); `fan` and `media` have no seed table at all,
and `generic` and `ac` are empty. Everything except TV must be taught.

---

## Verified working (not gaps)

```
Starting driver (stock-caps)              ✓ loads clean
found 520c at 192.168.68.113              ✓ discovery
login OK, device id=01000000              ✓ login (first try timed out, retry succeeded)
IR Appliance added / init                 ✓ parent + generic child created
momentary push → "no code for generic/button1"   ✓ command routed + handled correctly
```
`no code for generic/button1` is **correct** behavior — there is genuinely no code for that
slot. Not a bug.

---

## Gaps

| # | Sev | Gap | Evidence | Proposed fix |
|---|---|---|---|---|
| **G1** | 🔴 High | **Samsung M5 seed codes are unreachable.** The only device is the auto-created **`generic`** "IR Appliance"; the Samsung seeds live under **`tv`**. `code_store.get()` on a generic device checks `codes.generic.*` (empty), never `codes.tv.*`. | Log: pushes hit `no code for generic/*`. Screenshots: only "IR Appliance" (generic) + "BroadLink RM4" exist. | Make the default child a **`tv`** (immediate), and/or let users add typed devices (G2). |
| **G2** | ✅ Resolved | **[FIXED via Phase 1b — preference-driven add, hardware-confirmed 2026-07-09.** Log `shortVersion3`: `add appliance: type=tv name=Living room tv` → TV child created → on/off taps fire the Samsung seed code (`74 IR bytes`) with `<- reply` each time.]** ~~Add-appliance flow is not usable in the app.~~ The parent "BroadLink RM4" detail shows only **"Status: Connected"**; the `momentary` Add button and `applianceType`/`applianceName` **preferences don't surface** (menu = Edit / Remove / Driver / Information — no Settings). So no TV appliance can be created. | Screenshot 2 (parent detail + menu). Log: **no `add appliance:` line ever appears.** | Verify/repair how preferences surface; move `momentary` to its own component; or replace the add mechanism. |
| **G3** | ✅ Resolved | **Default device does nothing.** ~~"IR Appliance" = switch + four no-code buttons.~~ **Auto-child removed 2026-07-09** (decision: no automatic child on onboard). Side effect: this **promotes G2 to a hard blocker** — with no default device, the Add-appliance flow is now the *only* way to get any controllable device. | — | Auto-create removed in `device_added`; G2 must now be fixed. |
| **G4** | 🟠 Med | **Learn mode never engaged.** The `learnMode` preference wasn't reachable/used, so the fallback path (teach a code) was also unavailable. | Log: **no `LEARN:` lines.** | Same preferences-surfacing fix as G2. |
| **G5** | 🟡 Low | **`momentary` renders inconsistently.** Renders as pushable tiles on the *child* (dedicated components) but not on the *parent* (shares `main` with `refresh`). Cosmetic: momentary tiles show a "Standby" state though it's stateless. | Screenshot 1 (child buttons) vs Screenshot 2 (parent). | Put the parent's Add momentary in its own component; accept/relabel the momentary state. |

---

## Root causes (exact)

**G1 — type/seed-key mismatch.** `code_store.get(device, slot)` derives the appliance type
from `device.parent_assigned_child_key` (`"<type>-<name>"` → `<type>`) and falls back to
`codes[<type>][slot]`. `codes.lua` only populates `codes.tv`. The auto-child was created as
`create_child(driver, device, "generic", "IR Appliance")`, so lookups hit `codes.generic`
(empty) and never `codes.tv`. → Fix requires a **`tv`** device to exist (i.e. G2), which is
now the only path since the auto-child is gone.

**G2 — degenerate auto-presentation on the `rm4-hub` parent (two compounding causes).**
1. `momentary` shares the `main` component with `refresh`. SmartThings' auto-generated detail
   view surfaces `momentary` as a visible push control only when it is the **sole/primary
   capability of its own component** (proven by the child, whose `button1..4` momentaries each
   sit in their own component and render fine). Mixed with `refresh` under `main`, the Add
   button isn't rendered.
2. The parent has **no stateful capability**, so the presentation's dashboard/detail "state"
   falls back to the LAN health indicator → the near-empty **"Status: Connected"** card.
Net effect: no Add button, and (leading hypothesis, to confirm on-device) the
`applianceType`/`applianceName` **preferences "Settings" entry didn't appear** in the 3-dot
menu — likely tied to the same degenerate presentation / a stale device that needs
re-onboarding after the profile is fixed.

**G3 — unconditional auto-create (RESOLVED).** `device_added` always called
`create_child(driver, device, "generic", "IR Appliance")`. Removed 2026-07-09.

**G4 — critical mode toggle hidden behind a preference.** `learn_on(device)` reads
`device.preferences.learnMode`. Engaging Learn mode requires opening the child's **Settings**,
which depends on the same preference-surfacing path as G2. So even the pre-existing generic
child's learn toggle was never reachable (no `LEARN:` lines in the log).

**G5 — component structure + stateless-capability placeholder.** Same as G2(1): momentary
renders as a push tile only in its own component. The **"Standby"** text is the app's default
placeholder shown for `momentary`, which is stateless (no real attribute value).

---

## The crux

Everything hinges on **G2**. The typed-appliance model (pick type → tap Add) is how a user
reaches a TV device, the Samsung seeds, and Learn mode — and in the app that path currently
**doesn't surface**, leaving only a generic no-code device. This is the "type-then-tap via
Settings is clunky" risk from the stock-caps design decision, now confirmed as *unreachable*,
not just clunky.

Note: G1–G5 are UX/presentation problems, **not** protocol problems — discovery, login, and
command dispatch all work. (The *send payload framing* was a separate, real protocol bug — see
**G6** at the top, now fixed.)

---

## End-to-end fix plan (with code)

Ordered so each phase is independently testable on the hub. Phases 1–2 are the critical path
(a usable Add flow → a controllable device); 3 hardens Learn; 4–5 are seeds/docs/retest.

### Phase 1 — momentary in its own component — ❌ TESTED & FAILED 2026-07-09

Moved `momentary` to its own `add` component and re-onboarded (log `shortVersion2`: old
devices removed 06:26, fresh parent created 06:29 with the new profile, login OK, no
auto-child). Result on the parent tile:
- **(a) No Add tile** — `momentary` does **not render on the LAN parent even in its own
  component** (it renders fine on the EDGE_CHILD's `button1..4`). So *both* the Phase 1 and
  Phase 2 momentary-based approaches are dead ends on the parent.
- **(b) Preferences DO surface** — the `applianceType` dropdown + `applianceName` show under
  Settings, and `infoChanged` fires on save.

**→ Pivot: preference-driven add (below).** ~~Phase 2 (per-type momentary buttons)~~ also
invalidated (same momentary-not-rendering cause).

### Phase 1b — Preference-driven add via `infoChanged` — ✅ IMPLEMENTED 2026-07-09

No momentary. Set the type + name in Settings and **Save**; `infoChanged` creates the child.

- **`profiles/rm4-hub.yml`:** removed the `add`/`momentary` component. Parent = `main`=[refresh]
  + preferences (`applianceType` enum, `applianceName` text, description updated to "Save to add").
- **`init.lua`:** added `info_changed` (on the parent, when `applianceName` changes to a new
  non-empty value → `create_child(applianceType, name)`); registered `infoChanged = info_changed`;
  simplified `h_push` to child-only (parent no longer uses momentary).

```lua
local function info_changed(driver, device, event, args)
  if not is_parent(device) then return end
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = device.preferences or {}
  local new_name = new.applianceName or ""
  if new_name ~= "" and new_name ~= (old.applianceName or "") then
    local atype = new.applianceType or "generic"
    if not PROFILE[atype] then atype = "generic" end
    create_child(driver, device, atype, new_name)   -- e.g. tv → ir-tv
  end
end
```
**User flow:** RM4 → Settings → Type = TV, Name = "Living Room TV" → Save → a TV child appears.
Add another by saving a **different** name (unique name = unique DNI). **Needs re-onboard** to
apply the profile change.

> **Old Phase 1 / Phase 2 (momentary) are retained below only for history — do not implement.**

**`profiles/rm4-hub.yml`:**
```yaml
name: rm4-hub
components:
  - id: main
    capabilities:
      - id: refresh
        version: 1
    categories:
      - name: RemoteController
  - id: add
    capabilities:
      - id: momentary
        version: 1
preferences:
  - name: applianceType   # (unchanged enum: tv|ac|fan|media|generic)
    ...
  - name: applianceName   # (unchanged text)
    ...
```
**`init.lua`:** no change — `h_push` already branches on `is_parent(device)` and reads the
prefs regardless of component.

**Test:** redeploy → re-onboard (delete + re-add the RM4 so the new profile applies) → confirm
(a) an **Add** push tile now shows on the parent, and (b) the 3-dot menu shows **Settings**
with the type/name preferences. If both true → G2/G5 fixed; skip Phase 2.

### Phase 2 — If the type preference still won't surface: per-type Add buttons (robust G2)

Removes reliance on the enum preference for the critical path — each button self-documents and
handles repeat-adds naturally.

**`profiles/rm4-hub.yml`:**
```yaml
components:
  - id: main
    capabilities: [ { id: refresh, version: 1 } ]
    categories: [ { name: RemoteController } ]
  - id: add_tv
    capabilities: [ { id: momentary, version: 1 } ]
  - id: add_ac
    capabilities: [ { id: momentary, version: 1 } ]
  - id: add_fan
    capabilities: [ { id: momentary, version: 1 } ]
  - id: add_media
    capabilities: [ { id: momentary, version: 1 } ]
  - id: add_generic
    capabilities: [ { id: momentary, version: 1 } ]
preferences:
  - name: applianceName   # optional; else a default name is used, rename in-app
    ...
```
**`init.lua`** — replace the parent branch of `h_push`:
```lua
local ADD_TYPE      = { add_tv="tv", add_ac="ac", add_fan="fan", add_media="media", add_generic="generic" }
local DEFAULT_NAME  = { tv="IR TV", ac="IR AC", fan="IR Fan", media="IR Media", generic="IR Appliance" }

local function h_push(driver, device, command)
  if is_parent(device) then
    local atype = ADD_TYPE[command.component]
    if not atype then return end
    local name = (device.preferences or {}).applianceName
    if not name or name == "" then name = DEFAULT_NAME[atype] end
    log.info_with({hub_logs=true}, ("[BroadLink] add appliance: type=%s name=%s"):format(atype, name))
    create_child(driver, device, atype, name)
  else
    action(driver, device, command.component)   -- generic child button slot
  end
end
```
Optional: a tiny device-config presentation to label the tiles "Add TV" / "Add AC" / …
(`smartthings presentation:device-config:create`) — otherwise they show as generic Momentary
tiles per component id.

### Phase 3 — Make Learn mode a stock switch, not a preference (G4)

A dedicated `switch` component renders reliably (no dependence on preference surfacing).

**Each appliance profile (`ir-tv`, `ir-ac`, …):** add a component
```yaml
  - id: learn
    capabilities:
      - id: switch
        version: 1
```
**`init.lua`:** distinguish the learn toggle from the power switch by component, and read the
learn flag from a field instead of `preferences.learnMode`:
```lua
local function learn_on(device) return device:get_field("learn_on") == true end

local function h_on(driver, device, command)
  if command and command.component == "learn" then
    device:set_field("learn_on", true, {persist=true})
    emit(device, function()
      return device:emit_component_event(device.profile.components["learn"], capabilities.switch.switch.on())
    end)
    return
  end
  action(driver, device, "power_on", function() return capabilities.switch.switch.on() end)
end
-- h_off mirrors this: component "learn" → set learn_on=false + emit; else power_off.
```
> Note: `h_on`/`h_off` gain a `command` parameter; and `emit_component_event` targets the
> `learn` component so the main power tile isn't affected. Keeps everything stock.

### Phase 4 — Seeds + docs (G1)

- **No code change for seeds:** once a **`tv`** child exists (Phase 1/2), `code_store.get`
  resolves `codes.tv.*` automatically. Verify with a power/volume tap on a TV child.
- **Docs to update** (they still mention the removed auto "IR Appliance"): `USER_GUIDE §2–3`,
  `TESTING §5–6`, `EXPECTED_LOGS 1.3/1.7` — reflect "onboard → parent only → add a typed
  appliance", and the per-type Add buttons if Phase 2 is taken.

### Phase 5 — Hardware re-test

1. Onboard → confirm **only** the parent appears.
2. Add a **TV** (Phase 1 Settings+Add, or Phase 2 "Add TV" button) → a TV child appears.
3. Aim RM4 at the M5, tap Power / Volume → Samsung seed codes fire (fill `TESTING §6.5` table).
4. Turn the **Learn** switch on, tap a control, press the IR remote → `LEARN OK`; turn Learn
   off → the control now sends. Confirms G4.

### Risk / sequencing notes
- **Re-onboard required** after any profile change — SmartThings binds the profile at device
  creation; an existing device won't pick up new components. Delete + re-add the RM4.
- Phase 1 is the smallest bet; only escalate to Phase 2 if preferences still don't surface.
- Phase 3 is independent of 1/2 and can land separately.

---

## Status

- Opened: 2026-07-09 (first on-hub product-layer test).
- **Decision (2026-07-09):** removed the auto-created child on onboard (G3). Consequence:
  **G2 is now the top blocker** — after onboarding there is *only* the parent RM4, and the
  Add-appliance flow is the sole path to a controllable device.
- **G2 resolved** via Phase 1b (preference-driven add); **G1** resolved once a `tv` child exists
  (its seeds then resolve automatically).
- **Update (2026-07-09, later):** **G6** (send rejected `-5`) root-caused to the `rmminib`
  payload framing and **fixed**; power **toggle** + `powerStyle` preference added; docs synced
  (PROTOCOL_FLOW §3/§4, EXPECTED_LOGS F5b, USER_GUIDE, TESTING, README). Pending: user hardware
  re-test that a send now returns `errcode=0` and the M5 physically reacts.
- **Update (2026-07-10):** **G7** (blank card attributes — `NaN`/dashes) **fixed** via
  `seed_child_state(device)` in `init.lua` (emit-only, null-guarded, `supported*` lists always
  re-emitted); implemented and verified offline, pending hardware confirmation. Also recorded a
  **design decision** (not a gap): **no AC seed codes** — an AC transmits its full state per
  press, so ACs are taught via **Learn mode**; only the **TV** type ships bundled (Samsung) seeds.
