# BroadLink RM4 — Real-Device Install & Test Procedure

Step-by-step guide for building, installing, onboarding, and testing the driver against a
real BroadLink RM4 Mini on a real SmartThings hub. Every phase says **what to do** and
**what you should see in the logs**.

> The driver is verified offline (AES against the NIST vector; framing + login against a
> mocked reply). Everything below is what proves it against actual hardware.

---

## 0. What you need

- A SmartThings hub with the Edge runtime, and its **LAN IP** (SmartThings app → hub →
  Information, or your router).
- The **SmartThings CLI**: `npm install -g @smartthings/cli` (or the binary release). Run
  `smartthings` once to sign in.
- The **SmartThings mobile app**, signed into the **same account** and viewing the **same
  Location** as that hub.
- An **RM4 Mini** already joined to the **same 2.4 GHz LAN as the hub** (set it up in the
  BroadLink app first).
- **`python-broadlink`** on a laptop on that LAN (`pip install broadlink`) — used to confirm
  the device and to capture IR codes.

---

## 1. Where the logs go, and how to read them

The driver logs every important step with `log.*_with({hub_logs = true}, ...)`. That flag
sends each line to the **hub's retained driver log** (the hub-core / hub-agent logging
pipeline) as well as the live stream, so entries are visible in `logcat` and are kept on the
hub rather than only existing during a live session.

Start a live log stream (keep this open in a second terminal during every test):

```bash
smartthings edge:drivers:logcat --hub-address <hub-ip>
# pick the "BroadLink RM4" driver when prompted
```

All of this driver's lines are prefixed `[BroadLink]` and are at **info/warn/error** level,
so they show with the default log level — no extra configuration needed. See
[§8 Log reference](#8-log-reference-what-each-line-means) for the full list.

---

## 2. Offline pre-check (no hub, ~10 s)

Confirm the crypto still builds on your machine before shipping anything:

```powershell
$lua = "C:\Users\s.chatakonda\Edge\edge-test-env\lua\lua.exe"
cd drivers\Unofficial\broadlink-rm4
& $lua src\test\offline_crypto_test.lua
```

Expected:
```
AES encrypt KAT: PASS
AES decrypt KAT: PASS
All crypto self-tests passed.
```
If this fails, stop — nothing on the hub will work until it passes.

---

## 3. Prepare the device (before the driver is useful)

### 3a. Confirm the RM4 answers and is NOT cloud-locked
```python
# check_device.py
import broadlink, time
d = broadlink.discover(timeout=5)[0]
assert d.auth(), "LOGIN FAILED — unlock 'Lock device' in the BroadLink app, or unit is cloud-only"
print("login OK  devtype=%#06x  mac=%s  ip=%s" % (d.devtype, d.mac.hex(), d.host[0]))
```
Note the **devtype**, **mac**, and **ip**. If login fails: in the BroadLink app, open the
RM4 → settings → turn **"Lock device" OFF**. If it still fails, this firmware won't allow
local control and the driver cannot work (use the Home Assistant bridge instead).

### 3b. Capture the IR codes you'll test with
`src/codes.lua` ships seed codes for the **`tv` type only** (a Samsung codeset: power toggle +
discrete on/off, volume, mute, channel, play/pause/stop, ff/rew). `ac` and `generic` are empty by
design, and `fan`/`media` have no table at all — so **every type except TV needs codes** before
its controls do anything. End users get them via Learn mode (§6.7); to seed a non-TV type for
development, capture a code:
```python
# learn.py
import broadlink, time
d = broadlink.discover(timeout=5)[0]; d.auth()
d.enter_learning()
print("Point a remote at the RM4 and press the button now..."); time.sleep(6)
print(d.check_data().hex())     # copy this hex
```
Paste into `src/codes.lua` under the appliance **type** you'll add (e.g. `tv` — the M5 already
ships Samsung `tv` seeds; `generic` for a Generic device). This `codes.lua` seed path is a
developer convenience — end users learn codes in-app (Learn mode):
```lua
tv = {
  power_on  = "2600....0d05",
  power_off = "2600....0d05",   -- if the device has a discrete off; else reuse the toggle
},
```

---

## 4. Build & install the driver on the hub

The driver must be installed on the hub **before** you onboard in the app — Scan-nearby runs
the discovery handler of *installed* Edge drivers, so without this step the RM4 won't be
found. From the driver root (`drivers/Unofficial/broadlink-rm4`):

```bash
# 1. build + upload; note the driverId it prints
smartthings edge:drivers:package .

# 2. one-time: create a test channel and enroll your hub
smartthings edge:channels:create          # name it e.g. "broadlink-test"
smartthings edge:channels:enroll           # pick your hub

# 3. publish this driver to that channel, then install it on the hub
smartthings edge:drivers:publish           # pick the BroadLink driver + your channel
smartthings edge:drivers:install           # pick your hub + channel + driver
```

Confirm it landed on the hub:
```bash
smartthings edge:drivers:installed         # "BroadLink RM4" should be listed
```

**What you should see in logcat right after install:**
```
[BroadLink] Starting driver
```
That line alone confirms the package loaded and ran with no Lua error (a syntax or require
error would show here instead).

### One-command deploy: `package --install`

The channel-create + hub-enroll in step 2 are **one-time** (re-running them errors). After
that, the `--install` (`-I`) flag on `package` does the whole thing — build, upload, and
install — in a single command. Grab your **channel ID** and **hub ID** once
(`smartthings edge:channels` for the channel; `smartthings devices` for the hub), then:

```bash
smartthings edge:drivers:package . --install -C <channelId> -H <hubId>
```

Same command works on Windows PowerShell, macOS, and Linux (the CLI is identical). Omit
`-C`/`-H` to have it prompt you to pick the channel and hub interactively:

```bash
smartthings edge:drivers:package . --install
```

> `--install` assigns the freshly uploaded version to a channel your hub is enrolled in and
> installs it — no separate `publish`/`install` steps and no capturing the driver ID. Re-run
> the same line after each code change to push a new version.

---

## 5. Onboard the blaster in the SmartThings app

This is the actual onboarding flow a user goes through. App wording varies slightly by
version; the labels below are the common ones.

**Steps:**
1. Open the **SmartThings app**. Make sure the Location selector (top-left) is the Location
   whose hub you installed the driver on in §4.
2. Tap **➕ (Add)** at the top → **Add device**.
3. On the Add device screen, scroll to the bottom and tap **Scan for nearby devices**
   (sometimes shown as **Scan nearby**). If asked, pick the **hub / Location** to scan with.
   This is what triggers the driver's LAN discovery.
4. Leave it scanning for **~20–40 seconds**. In your `logcat` window you should see the
   discovery block below appear as the hub broadcasts and the RM4 replies.
5. A device named **"BroadLink RM4"** appears in the results / your device list. This is the
   **blaster (parent)**. Open it, assign a **Room**, and optionally rename it (e.g.
   "Living Room Blaster").
6. That's the only device — **no appliance child is auto-created**. To add one: open
   **BroadLink RM4** → **⋮ → Settings**, pick a **type** (e.g. TV) and type a **name**
   (e.g. "Living Room TV") → **Save**. After up to ~1–2 min an appliance tile of that type
   appears (logcat: `add appliance: type=tv name=Living Room TV`).

**Expect in logcat during the scan:**
```
[BroadLink] ===== starting discovery =====
[BroadLink] found 649b at 192.168.1.50 (mac aabbccddeeff)
[BroadLink] creating/updating RM4 parent dni=broadlink-aabbccddeeff ip=192.168.1.50
[BroadLink] stored network fields for broadlink-aabbccddeeff
[BroadLink] discovery loop ended (1 RM4 seen)
```

**Verify onboarding in the app:**
- Only **"BroadLink RM4"** appears (no appliance yet).
- Confirm your driver is bound: open the device → **⋮ (three-dot menu) → Driver** → it should
  read **BroadLink RM4** with your version. (Or `smartthings edge:drivers:installed`.)
- The RM4's **Settings** show an **Appliance type** dropdown and an **Appliance name** field —
  saving a name is what creates an appliance.

**Pass criteria:** the RM4 onboards and logcat shows `found ...` then `login OK` (§6a); saving
a name in Settings creates a child tile (`add appliance:` in logcat).

**If "Scan for nearby devices" finds nothing:** confirm the driver is installed (§4,
`edge:drivers:installed`), the RM4 is powered on the **same LAN/subnet** as the hub, then see
[§7 Troubleshooting](#7-troubleshooting-by-log-symptom) case *discovery finds nothing*.

**Mapping your real appliance:** add a child of the right **type** (Settings → type → Save a
name). A **TV** child automatically falls back to the bundled Samsung `codes.tv` seeds; any
type can also be taught in-app (Learn mode, §USER_GUIDE §4). You can add **several** appliances
(TV, AC, …) — each Save with a new name creates another child.

---

## 6. Control & test from the SmartThings app

> **Model note.** Onboarding creates **only the RM4** — add an appliance first (RM4 → Settings
> → type + name → Save; a **TV** is easiest since it ships with the Samsung seed codes). §6a–6b
> assume you've added one. Learn codes in-app via Learn mode (`USER_GUIDE.md` §4).
> §6.5 validates the Samsung TV seeds on a real device.

### 6a. Login happens on init
When the RM4 parent initializes (right after onboarding, and on every driver restart) it logs
in. **Expect in logcat:**
```
[BroadLink] login (0x65) to 192.168.1.50 mac=aabbccddeeff devtype=649b
[BroadLink] TX cmd=0x65 136 bytes: 5aa5aa55...
[BroadLink] -> 192.168.1.50:80 cmd=0x65 len=136 (try 1/3)
[BroadLink] <- 192.168.1.50 reply len=88 errcode=0
[BroadLink] login OK, device id=1a2b3c4d
[BroadLink] logged in to RM4 192.168.1.50
```
**`login OK` is a milestone** — the packet framing, checksums, MAC byte order, and
AES-with-the-INITIAL-key are all correct against your actual unit. Note it does **not** prove
the IR-send format (login uses a fixed public key); a clean send with `errcode=0` (§6b) is what
confirms that.

### 6b. Turn the appliance on/off from the app
1. In the SmartThings app, open the appliance you added (e.g. your **TV**).
2. Tap the **switch** control to **On**.
   - **In the room:** the appliance should physically react.
   - **In the app:** the tile flips to **On** immediately (optimistic — it flips because the
     code was sent, not because the appliance confirmed anything; IR has no feedback).
   - **In logcat:**
     ```
     [BroadLink] send_ir: 74 IR bytes -> 192.168.68.113 : 2600460093931237...000d05
     [BroadLink] TX cmd=0x6a 136 bytes: 5aa5aa55...
     [BroadLink] -> 192.168.68.113:80 cmd=0x6a len=136 (try 1/3)
     [BroadLink] <- 192.168.68.113 reply len=72 errcode=0
     ```
     **`errcode=0` is the pass signal** — it means the RM4 accepted the datagram and emitted
     the IR. A rejection instead shows `reply len=72 errcode=65531  <<< DEVICE REPORTED ERROR`
     then `send_ir REJECTED by RM4 (errcode=65531) — received but not emitted` (the RM4 got the
     packet but did not blast it — see [§9](#9-troubleshooting-by-log-symptom)).
3. Tap the switch to **Off** — this fires `power_off` (or, if you only captured a toggle,
   re-fires the same toggle code). Confirm the appliance reacts.

**Pass criteria:** the send logs **`errcode=0`** and the appliance responds to On/Off from the
app. If logcat shows a clean `send_ir` + `errcode=0` reply but the appliance does nothing, that's
an **IR-level** issue (wrong code, line-of-sight, or a toggle code fired against the wrong assumed
state), not a driver bug — see [§7](#7-troubleshooting-by-log-symptom). An `errcode` other than 0
(e.g. 65531) means the RM4 rejected the payload framing itself.

### 6c. Test from a dashboard tile / favorites
Add the appliance tile to **Favorites** (device → ⋮ → add to Favorites, or the home
dashboard). Toggling it from the dashboard fires the same codes — this is the everyday path a
user takes and is worth confirming once.

### 6d. Voice / automation (optional)
The child is an ordinary switch, so it works in **Routines** ("Goodnight → turn off Living
Room TV") and with **Alexa / Google / Bixby** ("turn on Living Room TV"). Same optimistic
caveat: "on" blindly fires the on-code and assumes it landed.

---

## 6.5 Validating the bundled Samsung TV seed codes (e.g. M5 monitor)

The `tv` codeset in `src/codes.lua` is **generated from the standard Samsung IR protocol and
UNVERIFIED**. This validates it against a real Samsung IR device. It applies automatically to
any **TV-type** appliance that has nothing learned yet (learned codes override the seeds).

**Prerequisites:** the device is confirmed to accept IR, and the driver is deployed with the
current `codes.lua`.

**Steps:**
1. Deploy: `smartthings edge:drivers:package . --install -C <channelId> -H <hubId>`
2. App → **Add device → Scan nearby** → the **BroadLink RM4** appears.
3. RM4 tile → **Settings** → Appliance type = **TV**, name = "M5 Monitor" → **Save**. After a
   short moment (~1–2 min) a "M5 Monitor" TV tile appears (logcat: `add appliance: type=tv`).
4. **Verify Power style.** On the "M5 Monitor" tile → **Settings** → **Power style** should be
   **Toggle** (the default). Toggle sends a single power-flip code (Samsung `0xE0E040BF`) for
   both On and Off — most Samsung smart monitors (incl. the M5) ignore discrete on/off codes, so
   Toggle is the mode that actually works. **If power doesn't respond**, switch **Power style →
   Discrete On/Off** and retry the power buttons; note which mode worked.
5. **Aim the RM4 at the monitor.** On the "M5 Monitor" tile, tap in turn:
   **Power (switch On/Off)**, **Volume Up/Down**, **Mute**, **Channel Up/Down**, and the
   playback controls **Play/Pause/Stop/Fast-Forward/Rewind**. (Each uses `codes.tv.*` since
   nothing is learned yet — the seed set now covers **all** TV-card controls, including the newly
   added `ff` and `rew`.)

In `logcat`, each tap should show `send_ir: N IR bytes` → `TX cmd=0x6a` → `-> ...:80 cmd=0x6a` →
`<- reply ... errcode=0`, confirming the blaster fired and the RM4 **accepted** it
(`errcode=0`) — regardless of whether the monitor reacts.

**Interpretation:**

| What happens | Meaning |
|---|---|
| All buttons make the monitor react | ✅ Seed codes correct — done. Learn only extra buttons you want. |
| Power doesn't react (other buttons do) | Wrong **Power style** — switch Toggle ↔ Discrete On/Off (step 4) and retry. |
| Some react, some don't | Partial codeset match (often power: discrete vs **toggle**). Note which failed. |
| Nothing reacts, but logcat shows `send_ir` + `reply errcode=0` | Blaster fired and the RM4 **accepted** it; the **codeset or bit-order is wrong** — regenerate (see below). |
| logcat shows `reply errcode=65531` (or any non-zero) | RM4 **rejected the payload** — a framing bug, not a codeset issue. Confirm the driver builds the rmminib length-prefixed payload (see §9). |
| No `send_ir` / no `reply` at all | Driver/network issue, not the codes — see §9. |

> **Learn-source catch (M5-specific):** the M5's bundled remote is **Bluetooth**, so you can't
> Learn from it. If some codes don't work, use the **IR remote you used to verify IR reception**
> (a universal or other Samsung IR remote) with **Learn mode** to capture the rest.

**What to record (so we can pick the right fix) — fill this in during the test:**

**Power style used:** ☐ Toggle (default)  ☐ Discrete On/Off

| Button tapped | Monitor reacted? (Y/N) | `send_ir` + `<- reply` in logcat? (Y/N) | reply `errcode` (0 = accepted) |
|---|---|---|---|
| Power → On | | | |
| Power → Off | | | |
| Volume Up | | | |
| Volume Down | | | |
| Mute | | | |
| Channel Up | | | |
| Channel Down | | | |
| Fast-Forward | | | |
| Rewind | | | |

Plus one line of notes: anything odd (e.g. "power toggled on but Off did nothing", "all silent",
"tile flipped but no reaction"). These three signals — **did it send** (logcat), **did it react**
(monitor), and **how Power behaved** — are enough to decide between: ✅ done, flip bit-order,
swap to power-toggle, or try a different codeset.

**Fixes ready if it fails (based on what you record):**
1. **Power toggle** variant (`0xE0E040BF`) — now shipped as the **Power style = Toggle** default;
   flip to **Discrete On/Off** in Settings if this device wants discrete power instead.
2. **Reversed bit-order** variant — the one genuine uncertainty in the generated encoding; a
   quick regen flips it if everything is silent-but-sending.
3. **More buttons** (source, menu, arrows, enter, home) added to the seed set.

---

## 6.6 State seeding on init (cards populate, no IR)

IR is one-way, so nothing reports state back and child attributes stayed null — the app rendered
them as **"NaN"** (numbers) or **"–"** (text) (e.g. Volume=NaN, AC mode/temp/fan all dashes). On
the `init` lifecycle each child now runs `seed_child_state`, emitting optimistic placeholder
values **for display only** — it calls emit_event (hub→cloud→app) and **never** sends IR.

**Steps:**
1. Redeploy: `smartthings edge:drivers:package . --install -C <channelId> -H <hubId>`.
2. **Restart the driver** (toggle it off/on, or re-install) so every child re-inits.
3. Watch logcat and the child cards.

**Pass criteria:**
- Each child logs exactly one seed line, e.g.
  `[BroadLink] seeded initial state for tv child 'Living room 3' (app display only, no IR sent)`.
- The cards show real values instead of **NaN / dashes** (TV: switch off, volume 30, mute
  unmuted, channel 1, playback stopped; AC: off, cool/heat/auto modes, setpoint 24 C, fan auto;
  FAN: off, speed 0, oscillation fixed; MEDIA: off, playback stopped; GENERIC: off).
- **Zero** `send_ir` / `TX cmd=0x6a` lines appear on the restart. If any do, the seed is broken —
  it must never transmit IR.

> These are **optimistic placeholders, not real readings.** A value is seeded only if the
> attribute is currently null, so a restart never overwrites user-set values; the `supported*`
> lists (which gate the app's transport buttons / dropdowns) are always re-emitted.

## 6.7 Teaching an AC (Learn mode) — state-per-press remotes

Only the **TV** type ships bundled codes. `ac`/`generic` are empty `{}` and `fan`/`media` have no
seed table, so `no code for ac/cool_24_auto`, `no code for fan/speed_1`, etc. are **expected until
taught** — not bugs. AC is deliberately empty because an AC remote transmits its **entire state**
per press (e.g. Samsung's 14-byte, two-section frame with per-section checksums), and a wrong AC
code is indistinguishable from a right one in the logs. Teach one code per
`"<mode>_<setpoint>_<fan>"` combo plus `power_off` for Off.

> **⚠️ Which button you press on the remote is not arbitrary.** An AC remote transmits the state
> it will be in **after** the press, not the state shown before it. Remote at 24 C + press
> *temp-up* ⇒ it emits **25 C**, and `learn_slot` happily saves that frame under the slot
> `cool_24_auto`. The capture succeeds (`LEARN OK`), the code is wrong, and the only symptom is
> the AC landing one degree off. **Press a button that leaves the remote displaying the target
> combination.**

**Commit semantics (`ac_apply`).** The `ac_mode`/`ac_setpoint`/`ac_fan` fields model the *selected*
combination and must never drift from the card. The slot is derived from the **proposed** values;
the fields are committed (and the attribute emitted) **only if the operation took effect**:

| Mode | Outcome | Fields | Card |
|---|---|---|---|
| Learn ON | selection defines the slot being taught | **committed** | **updates** (AC-only exception) |
| Learn OFF, send OK | code went out | **committed** | updates |
| Learn OFF, no code | `no code for ac/<slot>` | **not committed** | snaps back |

That last row is the fix for the old desync bug: previously the field was persisted *before* the
send, so selecting an untaught temperature stranded the driver on a slot nobody taught, and every
later AC command failed too.

**Workflow (Learn mode ON *first* — an untaught combo will not stick otherwise):**
1. Turn **Learn mode ON**.
2. Turn the **AC off** with its own remote and set that remote to the target (Cool / 24 C / Auto).
   The RM4 isn't listening yet, so these presses don't matter.
3. On the card, tap the **one control** that reaches the target — on a fresh AC just tap
   **Mode → Cool** (`ac_key` already defaults to `cool_24_auto`). The tile updates and the RM4
   listens ~15 s. Changing several controls opens a learn window per tap and teaches several
   different combos — change one thing at a time.
4. Within ~15 s, hold the remote ~10 cm from the RM4 and press **Power** (turning the AC on). It
   transmits the full target state. Expect `LEARN OK: 'cool_24_auto' (N bytes) : 2600...0d05`
   (the captured blob is logged after the `:` — see the verification note below).
   *No usable Power press? Sit the remote one step away (25 C) and press temp-down so the frame it
   emits is 24 C.*
5. Next combo: AC off, remote to 26 C, drag **Temperature → 26** on the card, press **Power**.
6. Teach **Off**: with the AC **on**, tap the switch **Off** (or set Mode = Off) and press the
   remote's **Power** to turn it off — captures slot `power_off`.

Turn **Learn mode OFF** when done; the taught combos now replay on selection.

**Verify the capture, don't just trust `LEARN OK`.** A wrong-state capture still logs `LEARN OK`.
Two ways to check:
1. **Decode the logged blob.** The captured code is printed after the `:` —
   `LEARN OK: 'cool_24_auto' (N bytes) : 2600b400...0d05` — so you can decode it or diff it
   against a known-good capture of the same press.
2. **Watch the appliance.** Turn Learn mode off, tap **Mode → Cool**, and confirm the AC lands on
   **exactly** 24 C — not 23 or 25. That off-by-one is the signature of pressing a state-changing
   button during the learn window. See EXPECTED_LOGS **F14**.

**Regression check for the desync fix:** with Learn mode OFF and only `cool_24_auto` taught, drag
Temperature to an untaught 25 C. Expect `no code for ac/cool_25_auto`, the slider to **spring back
to 24**, and a following **Mode → Cool** tap to still send successfully (`errcode=0`) — proving the
setpoint did not drift to 25.

---

## 7. Robustness checks

- **RM4 reboot / session expiry:** power-cycle the RM4, then send a command. Expect the
  first send to fail and the driver to re-login automatically:
  ```
  [BroadLink] no reply from 192.168.1.50 (try 1/3)
  ...
  [BroadLink] login (0x65) to 192.168.1.50 ...
  [BroadLink] login OK, device id=...
  ```
  The command should ultimately succeed.
- **IP change (DHCP):** open the **BroadLink RM4** parent tile and run **Refresh**. Expect:
  ```
  [BroadLink] refreshed RM4 ip=192.168.1.51
  ```
  (For stability, give the RM4 a fixed DHCP reservation.)

---

## 8. Log reference (what each line means)

| Log line | Where | Meaning |
|---|---|---|
| `Starting driver` | init | Driver package loaded and ran (no Lua error). |
| `===== starting discovery =====` | discovery | A Scan-nearby began. |
| `scan pass: no RM4 replied yet` | discovery | One scan window elapsed with no reply. |
| `found <devtype> at <ip> (mac <mac>)` | discovery | An RM4 replied to the broadcast. |
| `creating/updating RM4 parent dni=... ip=...` | discovery | Parent device being created. |
| `discovery loop ended (N RM4 seen)` | discovery | Scan finished; N distinct units found. |
| `stored network fields for <dni>` | init | ip/mac/devtype persisted onto the parent. |
| `login (0x65) to <ip> mac=... devtype=...` | broadlink | Login handshake starting. |
| `TX cmd=0xNN N bytes: <hex>` | broadlink | Full outgoing datagram (hex) about to leave the hub. |
| `-> <ip>:80 cmd=0xNN len=N (try a/b)` | broadlink | A packet was sent (retry a of b). |
| `<- <ip> reply len=N errcode=M` | broadlink | The RM4 replied; **`errcode=0` = accepted**, non-zero = rejected. |
| `send_ir REJECTED by RM4 (errcode=N) — received but not emitted` | broadlink | RM4 got the packet but refused to blast it (payload/framing). |
| `no reply from <ip> (try a/b)` | broadlink | A send timed out; will retry. |
| `login OK, device id=<hex>` | broadlink | Handshake succeeded — crypto/framing/MAC all correct. |
| `login rejected, error code N` | broadlink | Device answered but refused login (see §7). |
| `logged in to RM4 <ip>` | init | Session cached for use. |
| `send_ir: N IR bytes -> <ip> : <hex>` | broadlink | About to blast an IR code (with a hex preview of the code). |
| `enter_learning` / `check_learned: captured N IR bytes` | broadlink | Learning mode (not yet exposed as a capability). |
| `LEARN: capturing '<slot>' — point the remote at the RM4 and press now` | init | The ~15 s learn window just opened for that slot. |
| `LEARN OK: '<slot>' (N bytes) : <hex>` | init | Some IR was captured and stored, and the blob is printed. **Not proof it's the *right* code** — decode/diff the hex (EXPECTED_LOGS F14). |
| `LEARN store failed for '<slot>': <err> — captured code was: <hex>` | init | Couldn't store it (e.g. 40-code limit); the capture is preserved in the log. |
| `LEARN timeout for '<slot>' (no IR received)` | init | Nothing arrived within ~15 s; aim closer and retry. |
| `seeded initial state for <type> child '...' (app display only, no IR sent)` | init | Child emitted optimistic display values so the card shows values not NaN/dashes; **no IR sent**. |
| `no code for <kind>/<name>` | init | No learned/seeded code for that control. **Only `tv` ships seeds**, so `ac`/`fan`/`media`/`generic` log this until taught (Learn mode) — expected, not a bug. |
| `RM4 missing network fields; re-run discovery` | init | Parent lost its ip/mac/devtype; run Refresh or re-scan. |
| `send-lock wait exceeded 5s; proceeding` | init | Another send held the per-RM4 lock too long. |

---

## 9. Troubleshooting by log symptom

| Symptom in logs | Likely cause | What to do |
|---|---|---|
| `starting discovery` … `discovery loop ended (0 RM4 seen)` | Broadcast blocked (AP isolation / IoT VLAN), or RM4 on a different subnet | Confirm laptop `python-broadlink` discovery works on the hub's subnet. If blocked, give the RM4 a fixed IP and use the unicast path: `discovery.scan(driver, 4, "<rm4-ip>")`. |
| `found` shows `devtype=0000` or garbage mac | Reply offsets differ on this firmware | Capture the discovery reply with Wireshark (`udp port 80`) and compare offsets `0x34` (devtype) / `0x3a` (mac). |
| `login ... ` then `no reply` every try | RM4 unreachable, or packet malformed so the RM4 silently drops it | Verify `python-broadlink` can reach it; confirm the offline crypto test passes; if crypto is fine, suspect **MAC byte order** — reverse the `0x2a` copy in `broadlink.lua`. |
| `login rejected, error code N` | Device answered but refused — often cloud-locked, or a payload mismatch | Turn off "Lock device" in the BroadLink app; re-confirm with `python-broadlink`'s `auth()`. |
| `login OK` but sends get `no reply` | Session expired or IP changed | Should auto-relogin; if not, run Refresh on the parent, or set a fixed IP. |
| `send_ir` then `reply ... errcode=65531` + `REJECTED by RM4` | RM4 refused the payload framing — the old RM-Mini `{0x02,0x00,0x00,0x00}+ir` format is rejected by the RM4 (devtype `0x520c`, rmminib) | The send path must prepend the 2-byte little-endian length (`{len_lo,len_hi,0x02,0x00,0x00,0x00}+ir`, len=#ir+4, padded to 16) like python-broadlink's `rmminib._send`. A correct send returns `errcode=0`. |
| clean `send_ir` + `reply errcode=0` but appliance ignores it | Wrong IR code, blaster not in line-of-sight, or the wrong **Power style** (discrete vs toggle) for this device | Re-capture the code (§3b); aim the RM4 at the appliance; for power, switch **Power style** (Toggle ↔ Discrete On/Off) in the appliance Settings. |
| `no code for generic/power_on` (or `ac/cool_24_auto`, `fan/speed_1`, …) | Expected — only the `tv` type ships seed codes | Teach it in-app with **Learn mode** (§6.7). For dev seeding, capture with `python-broadlink` and paste under that type in `codes.lua` (AC excepted — see §6.7). |
| App "Scan for nearby devices" shows nothing, no discovery logs at all | Driver not installed on the hub | `smartthings edge:drivers:installed`; re-run §4 if missing. |

---

## 10. If you need to file a diagnostic

Capture and attach:
1. The relevant `[BroadLink]` log window from `logcat`.
2. The device's **devtype** and **mac** (from §3a).
3. A Wireshark capture of the failing exchange (`udp port 80`) — the request and any reply.
   This is the single most useful artifact for a protocol/offset problem.

---

## 11. Uninstall / reinstall

```bash
smartthings edge:drivers:uninstall     # pick the driver + hub
# then re-run the §4 package/publish/install flow
```
Note: uninstalling removes the devices and their persisted fields; you'll re-run discovery
after reinstalling.

To remove just a device (not the driver): in the app, open the device → **⋮ → Delete**.
Deleting an appliance removes its learned codes with it. Deleting the **BroadLink RM4** parent
removes **all** its appliance children; re-run Scan-nearby to recreate the RM4, then re-add
appliances.
