# BroadLink RM4 — Shipping Plan (Alternative: **stock capabilities only**)

An alternative to `SHIPPING_PLAN.md`. Same goal (ship to end users), but with
**two design constraints**:

1. **No custom capabilities.** Use only SmartThings' built-in (stock) capabilities.
2. **Known device types upfront.** We decide in advance which appliance types to support
   (TV, AC, fan, media box, generic) and give each a fixed profile of stock capabilities.

The main plan and this one are **mutually exclusive choices** — pick one. This doc explains
whether the stock-only route is viable, exactly how it works, and where it hurts.

> ✅ **This is the plan that was IMPLEMENTED.** The driver in `src/` follows this document:
> typed appliances (`ir-tv`/`ir-ac`/`ir-fan`/`ir-media`/`ir-generic`), a `momentary` Add
> button, Learn-mode preference, per-device `code_store.lua`, health/IP-refresh/cloud-lock.
> The TV profile also has a **`powerStyle`** preference (**Toggle** default / **Discrete
> On/Off**) — see the send-path note below.
> Not yet done: the bundled brand code-database (§4 add-on) and channel distribution (Phase 5).
> End-user flow: `USER_GUIDE.md`.

> **Send path fixed for the RM4 (rmminib framing).** Login was already hardware-validated
> (`login OK` on a real RM4, devtype `0x520c`), but IR **sends** were being rejected
> (`errcode=65531`) because the driver used the older RM-Mini payload
> `{0x02,0x00,0x00,0x00}+ir`. It now prepends a 2-byte little-endian length —
> `{len_lo,len_hi,0x02,0x00,0x00,0x00}+ir` (len = #ir + 4, padded to 16), matching
> python-broadlink's `rmminib._send`; a correct send now returns `errcode=0`. This was the
> reason sends never controlled the device. Relatedly, the TV power switch now defaults to a
> **Toggle** code (Samsung `0xE0E040BF`) via the `powerStyle` preference — most Samsung smart
> monitors ignore discrete on/off — with **Discrete On/Off** as the alternative. Everything
> else here is the *product* layer on top.

> **Initial state is seeded on child `init`.** Stock capabilities start `null`, and the app draws
> null as `NaN`/`–`, so a fresh card looked broken. `seed_child_state` emits placeholder values
> (plus the `supported*` lists that enable the transport buttons and mode/fan pickers) via
> **`emit_event` only — it never transmits IR**. An attribute is seeded only when null, so
> restarts don't clobber user state. The values are **optimistic placeholders, not readings**.

> **Only the `tv` type ships bundled codes.** `codes.ac = {}` deliberately: an AC transmits its
> whole state per press (Samsung: 14-byte frame, 2×7-byte sections, per-section checksum, layout
> varying by generation), so a generated table would be model-specific and unverifiable — and a
> wrong AC code is indistinguishable from a right one in the logs (`errcode=0`, the AC ignores
> it). `fan`/`media` have no seed table at all. Everything except TV is taught via **Learn mode**.

---

## 1. Verdict — is this possible?

**Yes — and it's the better route for distribution.** It works *because* we fix the device
types upfront: knowing "this is a TV" lets us attach `audioVolume`, `tvChannel`, etc. — real
capabilities that already exist and render natively in the app. What you give up is
**flexibility** (only functions that have a matching stock capability can be exposed) and a
**clean in-app learning UX** (no custom attribute to show "captured/timeout").

The single hardest problem this route creates: **how does a user get their IR codes in
without a custom "Learn" command?** Solved below (§4) with a "Learn mode" preference — no
custom capability required.

---

## 2. Why "known device types upfront" is the key enabler

The main plan needed custom capabilities *because* it modeled **one generic IR appliance** —
and SmartThings has no stock "generic IR remote" capability, so you must invent `irLearn` /
`irSend`.

The moment you instead say "we support **TVs, ACs, fans, media boxes**," each of those maps
onto capabilities SmartThings already ships. No invention needed. The cost is that you must
**enumerate and maintain a profile per type**, and anything outside those types (or any button
without a stock equivalent) falls back to a generic slot or isn't supported.

---

## 3. Supported device types (the upfront catalog)

Each type = a fixed profile of **stock** capabilities, and a fixed set of **code slots** the
driver learns/sends. The user picks the type when adding the appliance (§ Add-appliance).

> ⚠️ Verify exact capability IDs/commands against the live catalog (`smartthings capabilities`
> / `capabilities:namespaces`) before building — names below are the standard ones but the
> catalog evolves.

| Device type (profile) | Stock capabilities | Code slots the driver maps to |
|---|---|---|
| **TV** (`ir-tv`) | `switch`, `audioVolume`, `audioMute`, `tvChannel`, `mediaPlayback`*, `refresh` | `power_on`/`power_off` (or `power` toggle), `vol_up`, `vol_down`, `mute`, `channel_up`, `channel_down`, `play`,`pause`,`stop` |
| **Air Conditioner** (`ir-ac`) | `switch`, `thermostatMode`, `thermostatCoolingSetpoint`, `airConditionerFanMode`*, `refresh` | one blob **per full state**: `cool_24_auto`, `cool_23_auto`, `heat_20_low`, … (see challenge C6) |
| **Fan** (`ir-fan`) | `switch`, `fanSpeed`, `fanOscillationMode`*, `refresh` | `power_on`/`power_off`, `speed_1..speed_n`, `oscillate` |
| **Media / set-top box** (`ir-media`) | `switch`, `mediaPlayback`, `mediaTrackControl`, `tvChannel`*, `refresh` | `power`, `play`, `pause`, `stop`, `next`, `prev`, `channel_up/down` |
| **Generic** (`ir-generic`) | `switch`, N × `momentary` (button1..button6), `refresh` | `power_on`/`power_off`, `button1..button6` |

`*` = optional per type. `momentary` (the `push` command) is the only stock "press this to
*send*" control — used for the generic type's arbitrary buttons (SmartThings' `button`
capability is the opposite: it *reports* presses, it can't *send*).

**Command → code-slot mapping** is fixed and lives in the driver, e.g.:
```
audioVolume.volumeUp      -> "vol_up"
audioVolume.volumeDown    -> "vol_down"
tvChannel.channelUp       -> "channel_up"
audioMute.setMute(muted)  -> "mute"
switch.on / switch.off    -> "power_on" / "power_off"
momentary.push (buttonK)  -> "buttonK"
```
The handler looks up the slot's stored hex (`code_store.get`) and blasts it — no custom
`sendCode`. Routines and voice use the **native** commands ("volume up", "turn on") directly.

---

## 3.5 Adding & removing appliances

> ⚠️ **Implemented differently than designed below.** The `momentary` "Add" button described
> here **does not render on the LAN parent** (confirmed on hardware — see
> `GAPS.md` G2). The shipped mechanism is **preference-driven**: set the type +
> name in the parent's Settings and **Save** → an `info_changed` handler creates the child
> (no button). The design text below is retained for context.

Because each type needs a **different profile** (different stock capabilities), the user must
tell the driver **which type** to create — a bare name isn't enough (that was fine in the main
plan's single generic child). This is done with **stock mechanisms only**: enum/text
**preferences** + one **`momentary`** button on the parent RM4. No custom capability.

### Adding — type picker + name + an "Add" button
The parent `rm4-hub` profile gains:
- a `momentary` capability (the "Add appliance" action button),
- preference **`applianceType`** — enumeration: `tv | ac | fan | media | generic`,
- preference **`applianceName`** — text (optional; defaults to e.g. "IR TV").

Flow:
1. **BroadLink RM4** tile → Settings → pick **Type** (e.g. TV) + optionally a **Name**
   ("Living Room TV") → save.
2. Tap the **Add appliance** button on the tile.
3. The `momentary.push` handler reads `applianceType` + `applianceName` and calls
   `create_child(driver, parent, type, name)` with the profile for that type
   (`tv→ir-tv`, `ac→ir-ac`, `fan→ir-fan`, `media→ir-media`, `generic→ir-generic`).

**Why a `momentary` button and not "on preference change"?**
- `momentary.push` **fires every time** → the user can add a *second* TV by pressing Add
  again. An `infoChanged`-on-preference approach would NOT re-fire when the type is unchanged,
  and the driver **can't reset a preference** — so repeated same-type adds would be impossible.
- It cleanly separates "editing the fields" from "commit now."

Dedup: the child DNI encodes type+name, so pressing Add twice with the same name is a no-op
(`try_create_device` ignores a duplicate DNI). A genuinely second TV just needs a different name.

### Removing — native delete (no special mechanism)
- Open the appliance tile → **⋮ → Delete** (standard SmartThings). The driver gets the child's
  `removed` lifecycle event; its learned codes were stored **as fields on that child**, so they
  vanish with the device — nothing to clean up.
- Deleting the **parent** RM4 cascades — all its appliance children are removed too.

### What's stored on each child
- `parent_assigned_child_key = "<type>-<name>"` → the driver derives the type from it (which
  fixes the command→slot map and, for generic, the button slots).
- `code_<slot>` fields → the learned codes (§4), removed automatically with the device.

Net: add/remove stays **100% stock** — an enum preference, a text preference, one `momentary`
button, and the platform's native delete.

---

## 3.6 The appliance card (how the tile & detail view are built)

The "card" (dashboard tile + detail view) is **auto-generated from the profile** — this is the
biggest payoff of going stock-only. You do **not** author presentation JSON.

**How a card is composed:**
- **Capabilities** in the profile → each stock capability ships its own control UI (volume
  slider/buttons, thermostat dial, fan-speed, play/pause…). SmartThings assembles the
  **detail view** from them automatically.
- **`categories`** in the profile → sets the **icon** and the default card behavior for that
  device kind.
- **Dashboard tile action/state** → auto-picked (usually `switch` on/off), so the home-screen
  tile is tappable with no extra config.

So we don't *inherit a standard profile file* — instead we **conform to the standard
capability + category combos** SmartThings already defines, and the generated card looks like a
native device of that type.

**Per-type profile → category:**

| Type | `categories: name` | Card looks like | Dashboard action |
|---|---|---|---|
| TV | `Television` | TV tile + volume/channel/playback in detail | `switch` on/off |
| AC | `AirConditioner` | AC tile (mode + setpoint) | `switch` on/off |
| Fan | `Fan` | fan tile + speed | `switch` on/off |
| Media box | `Television` (or `RemoteController`) | media controls | `switch` on/off |
| Generic | `RemoteController` | on/off + button slots | `switch` on/off |
| Parent RM4 | `RemoteController` | Add-appliance button + Refresh | (bridge; minimal) |

**When you'd add a *custom presentation* (optional, refinement only):** to reorder detail-view
controls, choose a non-`switch` dashboard action, or hide a control — via
`smartthings presentation:device-config:create` linked to the profile. **Not needed for v1**;
the auto-generated card is already native. (Contrast: custom capabilities *force* you to write
presentation JSON — stock capabilities don't. This is the whole point of the route.)

**Caveat (ties to C7):** the `AirConditioner`/thermostat card may expect a **current
temperature** we can't sense over IR. Either omit `temperatureMeasurement` (show setpoint +
mode only) or emit a purely optimistic value and label it — don't add sensor capabilities just
to fill the card.

> Verify the exact category names against the current catalog when building — `Television`,
> `AirConditioner`, `Fan`, `RemoteController` are the standard ones, but confirm.

---

## 4. Getting codes in **without** a custom Learn capability

This is the crux. The main plan used a custom `irLearn.startLearning` command + a
`learnStatus` attribute. Without custom capabilities we use a **preference-driven "Learn
mode"** — preferences are *not* capabilities, so this is fully stock-compatible.

### Design: "Learn mode" toggle reuses the native buttons

Add one boolean preference per device: **"Learn mode (on = next button press records)."**

- **Learn mode OFF (normal):** every command handler blasts the mapped code (normal control).
- **Learn mode ON:** every command handler, instead of blasting, runs
  `enter_learning → check_learned`, stores the captured hex into **that command's code slot**,
  and emits nothing (or the optimistic state anyway).

**User flow (batch-friendly):**
1. Add the appliance, pick type = TV.
2. Settings → **Learn mode = On**.
3. On the TV tile, tap **Volume Up** → point the real remote at the RM4, press its Volume-Up
   → the driver captures it into `vol_up`.
4. Repeat for each control (mute, channel, power…).
5. Settings → **Learn mode = Off**. Now every button *sends*.

No custom capability, no code editor. The native buttons the user already sees double as the
"which function am I teaching" selector.

### The unavoidable rough edges (all stem from "no custom attribute")
- **No status popup.** Nothing can display "captured!"/"timed out" in the tile — there's no
  stock attribute to write it to. The user **verifies by using the control in normal mode.**
  (Fallback: it's in the hub logs, developer-only.)
- **The driver can't turn Learn mode back off** (drivers can't write user preferences). So
  Learn mode stays on until the user flips it — which is *why* batch-learning is the intended
  flow, not one-shot.
- **Value commands don't learn cleanly** (see C3): `setVolume(37)`, `setCoolingSetpoint(24)`
  carry a number, not a discrete button. Learn the **relative** commands (`volumeUp/Down`)
  instead; for AC setpoints you must learn one code per temperature.

### Alternative / complement: a bundled code database
Instead of (or alongside) learning, ship a **preference dropdown "Brand"** per type and
bundle known code sets. User picks "Samsung TV" → slots auto-fill, no learning. Removes the
learning UX entirely for covered devices, at the cost of DB size/coverage/format-conversion
(same trade-offs noted in the main plan's Q1 discussion). Recommended as a **later add-on**,
not the v1 mechanism.

---

## 5. Challenges (the honest cost of going stock-only)

| # | Challenge | Detail / mitigation |
|---|---|---|
| **C1** | **Fixed function set per type** | Only functions with a matching stock capability can be exposed. Vendor/extra buttons (Netflix, Menu, Source-cycle) have no stock equivalent → use the **generic type's `momentary` slots** (generic labels "Button 1…6") or omit. |
| **C2** | **No clean learn-status UI** | Can't show captured/timeout without a custom attribute. Verify by testing the control (§4). Biggest UX regression vs. the custom-cap plan. |
| **C3** | **Value capabilities map poorly to discrete IR** | `setVolume(n)` / `setCoolingSetpoint(n)` are absolute values; IR codes are discrete. Prefer **relative** commands (`volumeUp/Down`). Absolute values need one code per value → impractical for volume, painful for AC. |
| **C4** | **Optimistic state is more *visible*** | Stock capabilities are **stateful** (volume level, switch on/off, setpoint). With no IR feedback the driver must fake/track state, and a drifting **volume slider or temperature readout** looks more "wrong" to users than a stateless custom button did. Choose relative controls and avoid showing absolute readouts you can't back up. |
| **C5** | **Must enumerate & maintain a profile per type** | More upfront profiles (`ir-tv`, `ir-ac`, `ir-fan`, `ir-media`, `ir-generic`) + a fixed command→slot map each. Less flexible than one generic device; adding a new appliance shape = new profile + driver code. |
| **C6** | **AC state explosion is worse under stock modeling** | `thermostatMode` + `thermostatCoolingSetpoint` + fan mode imply the app can set any combination — but each combination is a **separate learned blob** (ACs send full state per press). "Cool + 24 + auto" ≠ "Cool + 23 + auto". A full AC = dozens of learned codes. Consider limiting to a few presets, or documenting the effort. |
| **C7** | **Sensor capabilities imply data you don't have** | Don't add `temperatureMeasurement`/`thermostatOperatingState` etc. — IR can't sense. Only include **command** capabilities (setpoint/mode), or emit purely optimistic values and label them clearly. |
| **C8** | **Presentation still needs care (but less)** | Stock capabilities render natively (big win), but the **detail-view layout / dashboard action** per profile (`vid`/presentation) still wants tuning so the right control is the tile action. Far less fragile than custom-cap presentation, though. |
| **C9** | **Learn-mode can fire a real command by accident** | If the user forgets Learn mode is on, pressing a button records instead of controls (and vice-versa). Mitigate with a clear preference label and, optionally, an auto-timeout (driver clears its *internal* learn flag after N minutes even though the pref stays — belt and suspenders). |

---

## 6. Advantages (why you'd still choose this)

1. **No custom capabilities to create, publish, version, or maintain.**
2. **Native, familiar UI** per device type — real TV/AC/fan tiles with proper controls.
3. **Works in Routines & voice out of the box** via standard commands ("turn on", "volume up",
   "set cooling point"), no custom command wiring.
4. **No custom-capability presentation fragility** and **no capability-review friction.**
5. **Cleaner distribution:** users installing from your channel get a fully-working UI with
   **zero capability dependencies** in your namespace.
6. **Only route toward any "official-looking" distribution** — stock capabilities are a
   prerequisite for certification (the reverse-engineered protocol still blocks true WWST,
   but you're not adding a second blocker).

---

## 7. Phase-by-phase diff vs. the main plan

| Phase | Main plan (custom caps) | This plan (stock only) |
|---|---|---|
| **0 Hardware gate** | same | **same** (already passed) |
| **1 Product core** | publish `irLearn`/`irSend`; generic child; learn via custom command | **no capability publishing**; per-type profiles; **Learn-mode preference**; command→slot map. `code_store.lua` **unchanged** (storage isn't a capability) |
| **Add appliance** | type name (`ac:` prefix) | pick **type** (enum pref) + name, tap a `momentary` **Add** button → creates the matching profile child (see §3.5) |
| **2 Controls** | `momentary` button slots + custom `sendCode` | **native** per-type controls (volume/channel/mode/setpoint) + `momentary` only for the generic type |
| **3 Hardening** | health / IP refresh / cloud-lock | **same** |
| **4 Tests** | + custom-cap handler tests | **simpler** (stock handlers; no capability schemas) |
| **5 Distribution** | publish caps **then** channel | **channel only** — no capability publish step |

**Net:** removes the capability-publishing work and the presentation risk; adds per-type
profiles and the command→slot mapping; degrades the learning UX (no status feedback).

Unchanged from the main plan: the entire **protocol layer**, **`code_store.lua`**, **health /
IP-refresh / cloud-lock** hardening, and the **test/CI** approach.

---

## 8. Recommendation — which plan to pick

- **Pick this (stock-only) if:** you value a native, low-maintenance, easily-distributed
  product for a **fixed set of common appliance types**, and you can accept a clunkier
  learning flow (Learn-mode toggle, verify-by-testing).
- **Pick the custom-cap plan if:** you need a **truly generic** "any remote, any button, any
  name" device with in-app learn status, and you're willing to own custom-capability
  publishing/maintenance and presentation quirks.

**Suggested hybrid (best of both, if you have the appetite):** ship **stock-only** for the
five known types (this doc), and add the **bundled brand code-database** (§4) later so most
users never learn at all. Keep the custom-capability generic device as an optional "advanced"
add-on only if real demand appears.

---

## 9. Open items to confirm before building this route

1. Exact stock capability IDs/commands + whether `audioVolume`/`tvChannel`/`airConditionerFanMode`
   are available to **LAN Edge** drivers on your target hub firmware (`smartthings capabilities`).
2. Whether `momentary` renders as a usable dashboard button in the current app.
3. Per-profile presentation (which control is the tile's primary action).
4. AC scope decision (full mode×temp×fan matrix vs. a small preset set) — drives how much
   learning C6 imposes.
