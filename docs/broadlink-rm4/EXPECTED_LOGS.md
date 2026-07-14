# BroadLink RM4 — Expected Logs

What the hub logs should look like when things work, and the signature of each failure.
Use this side-by-side with a live `smartthings edge:drivers:logcat --hub-address <hub-ip>`.

**How to read the samples.** In real `logcat`/hub logs each line is prefixed with a
timestamp and the driver name, e.g.:

```
2026-07-07T10:15:32.104Z  BroadLink RM4  INFO   [BroadLink] Starting driver (stock-caps)
```

Below, that prefix is trimmed to just the **LEVEL** for readability. Every line this driver
emits is `INFO`, `WARN`, or `ERROR` (all visible at the default log level) and is tagged
`[BroadLink]`. Byte lengths shown (`len=136`, `148 IR bytes`, …) are **illustrative** — the
exact numbers vary by IR code and firmware.

> **Diagnostics.** Each packet is preceded by a `TX cmd=0xNN N bytes: <hex>` dump of the full
> outgoing (encrypted) datagram, and every reply line ends with `errcode=N` — **`errcode=0`
> means the device accepted the packet**; a non-zero value is a device-side rejection
> (`<<< DEVICE REPORTED ERROR` is appended). For an IR send, `errcode=0` is the pass signal.

---

## Part 1 — Ideal success case

This is the full happy path from install → discovery → login → first button press. In
practice the `added`/`init` lines can interleave slightly with the discovery loop (device
creation is asynchronous); the grouping below is logical, not strictly ordered to the ms.

### 1.1 Driver loads
```
INFO   [BroadLink] Starting driver (stock-caps)
```
> Just this line = the package compiled and ran with no Lua error. If you don't see it, see
> failure **F1**.

### 1.2 Discovery (app → Add device → Scan nearby)
```
INFO   [BroadLink] ===== starting discovery =====
INFO   [BroadLink] found 649b at 192.168.1.50 (mac aabbccddeeff)
INFO   [BroadLink] creating/updating RM4 parent dni=broadlink-aabbccddeeff ip=192.168.1.50
INFO   [BroadLink] discovery loop ended (1 RM4 seen)
```
> `found ...` = an RM4 replied to the broadcast. `1 RM4 seen` at the end confirms the scan
> succeeded. The parent device "BroadLink RM4" now appears in the app.

### 1.3 Parent is created → fields stored (no child)
```
INFO   [BroadLink] stored network fields for broadlink-aabbccddeeff
```
> The parent's `ip`/`mac`/`devtype` were persisted from the discovery stash. **No child is
> auto-created** — you add appliances explicitly (see 1.7).

### 1.4 Parent init → login handshake (the key milestone)
```
INFO   [BroadLink] login (0x65) to 192.168.1.50 mac=aabbccddeeff devtype=649b
INFO   [BroadLink] TX cmd=0x65 136 bytes: 5aa5aa55...
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x65 len=136 (try 1/3)
INFO   [BroadLink] <- 192.168.1.50 reply len=88 errcode=0
INFO   [BroadLink] login OK, device id=1a2b3c4d
INFO   [BroadLink] logged in to RM4 192.168.1.50
```
> **`login OK, device id=...` is a milestone, but not the whole story.** It proves the packet
> framing, both checksums, the MAC byte order, and the AES-with-the-INITIAL-key are correct —
> but it does **not** exercise the session key or the `0x6a` send format (login uses a fixed
> public key). The first *send* is what proves those (see 1.5 / F5b). The session is cached;
> later presses reuse it (no re-login per press).

### 1.5 Sending a code (tap a TV/appliance child's switch On)
```
INFO   [BroadLink] SEND: tv/power_on (74 bytes) : 2600460093931237...000d05
INFO   [BroadLink] send_ir: 74 IR bytes -> 192.168.1.50 : 2600460093931237...000d05
INFO   [BroadLink] TX cmd=0x6a 136 bytes: 5aa5aa55...
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x6a len=136 (try 1/3)
INFO   [BroadLink] <- 192.168.1.50 reply len=16 errcode=0
```
> **`SEND: <appliance_type>/<slot> (<size> bytes) : <hex>`** is the new IR audit line — it
> identifies **which button** (slot) on **which appliance** (type) was tapped, plus the full IR
> hex being blasted. Every IR send now starts with this line.
>
> **`errcode=0` is the pass signal** — the RM4 accepted the packet and blasted the IR. The
> appliance should physically react, and the switch tile flips to On (optimistic — it flips
> because the code was sent, not because the appliance confirmed anything). A non-zero errcode
> here means the RM4 refused to emit — see **F5b**.

### 1.6 Refreshing the RM4's IP (parent tile → Refresh, after a DHCP change)
```
INFO   [BroadLink] ===== starting discovery =====   (scan() reused by refresh)
INFO   [BroadLink] found 649b at 192.168.1.51 (mac aabbccddeeff)
INFO   [BroadLink] refreshed RM4 ip=192.168.1.51
```

### 1.7 Adding a typed appliance (RM4 → Settings → set type + name → Save)
```
INFO   [BroadLink] add appliance: type=tv name=Living Room TV
```
> Saving a new `applianceName` fires `info_changed`, which creates the typed child (here a TV
> with the `ir-tv` profile). No button, no auto-created child. Add another by Saving a
> different name. The child card can take ~1–2 min to appear.

### 1.7b Child init seeds display state (no IR sent)
```
INFO   [BroadLink] seeded initial state for tv child 'Living room 3' (app display only, no IR sent)
```
> On the `init` lifecycle every **child** runs `seed_child_state`, which emits optimistic
> placeholder attributes so the card renders values instead of "NaN" (numbers) / "–" (text) —
> IR is one-way, so nothing ever reports real state back and the attributes would otherwise stay
> null. It calls **only** emit_event (hub→cloud→app) and **never** sends IR. One line per child.
> Seeded by type: **TV** switch=off, volume=30, mute=unmuted, tvChannel="1",
> supportedPlaybackCommands=[play,pause,stop,fastForward,rewind], playbackStatus=stopped;
> **AC** switch=off, supportedThermostatModes=[off,cool,heat,auto], thermostatMode=off,
> coolingSetpoint=24 C, supportedAcFanModes=[auto,low,medium,high], fanMode=auto; **FAN**
> switch=off, fanSpeed=0, supportedFanOscillationModes=[fixed,all], fanOscillationMode=fixed;
> **MEDIA** switch=off, playbackStatus=stopped, supportedPlaybackCommands,
> supportedTrackControlCommands=[nextTrack,previousTrack], tvChannel="1"; **GENERIC** switch=off.
> A real value is seeded only if the attribute is currently null (via `get_latest_state`), so a
> restart never clobbers user-set values; the `supported*` lists are always re-emitted (metadata
> that gates which transport buttons / dropdown entries the app enables). These are **optimistic
> placeholders, not real readings** — IR gives no feedback.
> **Restart acceptance check:** after a driver restart you should see one `seeded initial state`
> line per child and the cards populate, with **zero** `send_ir` / `TX cmd=0x6a` lines. If any
> appear, the seed is broken (it must never transmit).

### 1.8 Learning a code (Learn mode ON → tap a control → press the remote)
```
INFO   [BroadLink] LEARN START: tv/vol_up
INFO   [BroadLink] LEARN: capturing 'vol_up' — point the remote at the RM4 and press now
INFO   [BroadLink] enter_learning on 192.168.1.50
INFO   [BroadLink] TX cmd=0x6a 16 bytes: 5aa5aa55...
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x6a len=16 (try 1/3)     (enter-learning, then repeated check polls)
INFO   [BroadLink] <- 192.168.1.50 reply len=... errcode=0
INFO   [BroadLink] check_learned: captured 148 IR bytes : 2600b40093931237...0d05
INFO   [BroadLink] LEARN OK: 'vol_up' (148 bytes) : 2600b40093931237...0d05
```
> **`LEARN START: <appliance_type>/<slot>`** is the new learn audit line — it identifies which
> appliance type and slot is about to be captured, before the learning begins.
>
> **`check_learned: captured N IR bytes : <hex>`** now includes the full IR hex at the protocol
> layer, not just the byte count. This ensures every captured code is visible even if the caller
> doesn't log it, and mirrors the `send_ir` hex-dump format.
> No status shows in the app — `LEARN OK` in the log (or the control working afterward) is your
> confirmation. Nothing captured within ~15 s logs `WARN [BroadLink] LEARN timeout for 'vol_up'
> (no IR received)`. While learning, the driver polls `check_learned` (~1/s), so you'll see
> several `cmd=0x6a` send/reply pairs before `LEARN OK`.
>
> **The captured blob is logged after the `:`** — same shape as the `send_ir` line, so it can be
> decoded, diffed against a known-good code, or pasted straight into `src/codes.lua` as a seed.
> This matters because **`LEARN OK` is a weak signal**: the capture succeeds no matter *what* the
> remote sent, so a mis-timed press stores the wrong code under the right slot name (see F14).
>
> If the code can't be stored (e.g. the 40-code-per-device limit), the blob is still printed so
> the capture isn't lost:
> ```
> WARN   [BroadLink] LEARN store failed for 'vol_up': code limit reached (40) — captured code was: 2600b400...0d05
> ```

**Full success trace, condensed:**
```
INFO   [BroadLink] Starting driver (stock-caps)
INFO   [BroadLink] ===== starting discovery =====
INFO   [BroadLink] found 649b at 192.168.1.50 (mac aabbccddeeff)
INFO   [BroadLink] creating/updating RM4 parent dni=broadlink-aabbccddeeff ip=192.168.1.50
INFO   [BroadLink] discovery loop ended (1 RM4 seen)
INFO   [BroadLink] stored network fields for broadlink-aabbccddeeff
INFO   [BroadLink] login (0x65) to 192.168.1.50 mac=aabbccddeeff devtype=649b
INFO   [BroadLink] TX cmd=0x65 136 bytes: 5aa5aa55...
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x65 len=136 (try 1/3)
INFO   [BroadLink] <- 192.168.1.50 reply len=88 errcode=0
INFO   [BroadLink] login OK, device id=1a2b3c4d
INFO   [BroadLink] logged in to RM4 192.168.1.50
INFO   [BroadLink] SEND: tv/power_on (74 bytes) : 260046009393...000d05
INFO   [BroadLink] send_ir: 74 IR bytes -> 192.168.1.50 : 260046009393...000d05
INFO   [BroadLink] TX cmd=0x6a 136 bytes: 5aa5aa55...
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x6a len=136 (try 1/3)
INFO   [BroadLink] <- 192.168.1.50 reply len=16 errcode=0
```

---

## Part 2 — Key failure cases

Each case shows the trigger, the log signature, and the fix. Ordered roughly by where they
occur in the flow.

### F1 — Driver won't start (Lua load error)
**Trigger:** a syntax/require error in the driver code.
**Signature:** the `Starting driver` line is **absent**; instead a Lua traceback appears at
driver load:
```
ERROR  BroadLink RM4  Error requiring module 'init': ...init.lua:NN: <message>
```
**Fix:** read the file:line in the traceback. Locally: `luac -p src/init.lua` (and the other
files) catches syntax errors before you package.

### F2 — Discovery finds nothing
**Trigger:** the RM4 doesn't reply to the broadcast (AP/client isolation, separate IoT
Wi-Fi/VLAN, or the RM4 is on a different subnet than the hub).
**Signature:** `starting discovery` and `scan pass: no RM4 replied yet`, then the loop ends
with **0 seen** — no `found` line:
```
INFO   [BroadLink] ===== starting discovery =====
INFO   [BroadLink] scan pass: no RM4 replied yet
INFO   [BroadLink] scan pass: no RM4 replied yet
INFO   [BroadLink] discovery loop ended (0 RM4 seen)
```
**Fix:** confirm `python-broadlink` discovery works from a machine on the **hub's** subnet.
If broadcast is blocked, give the RM4 a fixed IP and use the unicast path
(`discovery.scan(driver, 4, "<rm4-ip>")`).

### F3 — Discovery finds a device but the fields look wrong
**Trigger:** reply offsets differ on this firmware revision.
**Signature:** a `found` line with an implausible devtype/mac:
```
INFO   [BroadLink] found 0000 at 192.168.1.50 (mac 000000000000)
```
**Fix:** capture the reply with Wireshark (`udp port 80`) and check offsets `0x34` (devtype)
and `0x3a` (mac) in `discovery.lua`.

### F4 — Login gets no reply
**Trigger:** the RM4 is unreachable, OR the packet is malformed so the device silently drops
it (wrong checksum, or **wrong MAC byte order** at `0x2a`).
**Signature:** the send retries all time out, then login gives up:
```
INFO   [BroadLink] login (0x65) to 192.168.1.50 mac=aabbccddeeff devtype=649b
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x65 len=136 (try 1/3)
WARN   [BroadLink] no reply from 192.168.1.50 (try 1/3)
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x65 len=136 (try 2/3)
WARN   [BroadLink] no reply from 192.168.1.50 (try 2/3)
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x65 len=136 (try 3/3)
WARN   [BroadLink] no reply from 192.168.1.50 (try 3/3)
ERROR  [BroadLink] login: no reply (no reply after 3 attempts)
ERROR  [BroadLink] login failed: no reply after 3 attempts
```
**Fix:** confirm `python-broadlink` reaches the unit and the offline crypto test passes. If
both are fine but login still gets no reply, suspect **MAC order** — reverse the `0x2a` copy
in `broadlink.lua` (see the comment there). A Wireshark diff of your packet vs
`python-broadlink`'s settles it.

### F5 — Login rejected with an error code
**Trigger:** the device answered but refused the handshake — commonly cloud-locked, or a
payload mismatch.
**Signature:** you get a reply, but a non-zero error code:
```
INFO   [BroadLink] login (0x65) to 192.168.1.50 mac=aabbccddeeff devtype=649b
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x65 len=136 (try 1/3)
INFO   [BroadLink] <- 192.168.1.50 reply len=56 errcode=65529  <<< DEVICE REPORTED ERROR
ERROR  [BroadLink] login rejected, error code 65529
ERROR  [BroadLink] login failed: login error 65529
ERROR  [BroadLink] device replied but REJECTED login — it may be CLOUD-LOCKED. Open the BroadLink app -> this RM4 -> settings -> turn OFF 'Lock device'.
```
> The driver marks the RM4 (and its children) **offline** in this case, so the app shows it as
> unreachable rather than silently doing nothing.
**Fix:** in the BroadLink app, turn **"Lock device" OFF**; re-confirm with
`python-broadlink`'s `auth()`. If it works in python but not here, the payload/offsets need
checking against a capture.

### F5b — Send rejected with an errcode (RM4 received it but refused to emit)
**Trigger:** the RM4 answered a `0x6a` send with a **non-zero error code**. The classic cause
is the **wrong payload framing** — sending the older RM-Mini format (no 2-byte length prefix)
to an RM4, which rejects it with **`-5`** (shown as `errcode=65531`). Other device-side
refusals (e.g. a locked device) also surface here.
**Signature:** login succeeds, but every send comes back non-zero:
```
INFO   [BroadLink] send_ir: 74 IR bytes -> 192.168.68.113 : 2600460093931237...000d05
INFO   [BroadLink] TX cmd=0x6a 136 bytes: 5aa5aa55...
INFO   [BroadLink] -> 192.168.68.113:80 cmd=0x6a len=136 (try 1/3)
INFO   [BroadLink] <- 192.168.68.113 reply len=72 errcode=65531  <<< DEVICE REPORTED ERROR
ERROR  [BroadLink] send_ir REJECTED by RM4 (errcode=65531) — received but not emitted
```
> `65531` = `0xFFFB` = **-5**. `send_ir` fails, so the driver drops the session, re-logs in once
> (F6-style), retries, and — if still failing — gives up. The tile does **not** flip.
**Fix:** this driver now uses the RM4 (`rmminib`) length-prefixed framing that eliminated the
`-5` (see PROTOCOL_FLOW §3.3), so a healthy RM4 should return `errcode=0`. If a non-zero errcode
persists, diff the `TX ...` dump byte-for-byte against `python-broadlink`'s packet for the same
command; a persistent authorization error such as `-7` (`errcode=65529`, "control key expired")
points at a **locked device** — turn **"Lock device" OFF** in the BroadLink app and power-cycle
the RM4.

### F6 — Session expired, then auto-recovers (this is a *success* path)
**Trigger:** the RM4 rebooted (or dropped the session); the first send fails, the driver
logs in again and retries once.
**Signature:** send fails → re-login → send succeeds:
```
INFO   [BroadLink] send_ir: 148 IR bytes -> 192.168.1.50
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x6a len=216 (try 1/3)
WARN   [BroadLink] no reply from 192.168.1.50 (try 1/3)
...
WARN   [BroadLink] no reply from 192.168.1.50 (try 3/3)
INFO   [BroadLink] login (0x65) to 192.168.1.50 mac=aabbccddeeff devtype=649b
INFO   [BroadLink] <- 192.168.1.50 reply len=88 errcode=0
INFO   [BroadLink] login OK, device id=1a2b3c4d
INFO   [BroadLink] send_ir: 148 IR bytes -> 192.168.1.50 : 2600b400...0d05
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x6a len=216 (try 1/3)
INFO   [BroadLink] <- 192.168.1.50 reply len=16 errcode=0
```
**Fix:** none — this is the intended recovery. If it recurs constantly, the RM4's IP may be
changing; set a DHCP reservation.

### F7 — Command fails even after re-login
**Trigger:** the RM4 is genuinely offline (unplugged, off-network) and re-login also fails.
**Signature:** send retries fail, re-login fails, and `fire` reports the command failed:
```
INFO   [BroadLink] send_ir: 148 IR bytes -> 192.168.1.50
WARN   [BroadLink] no reply from 192.168.1.50 (try 3/3)
INFO   [BroadLink] login (0x65) to 192.168.1.50 ...
WARN   [BroadLink] no reply from 192.168.1.50 (try 3/3)
ERROR  [BroadLink] login: no reply (no reply after 3 attempts)
ERROR  [BroadLink] send failed for power_on
```
**Fix:** the switch tile does **not** flip (events are emitted only on success). Check the
RM4 is powered and on the LAN; run Refresh on the parent to re-discover its IP.

### F8 — No code for that button/slot
**Trigger:** the tapped control has no **learned** code and no `codes.lua` **seed** for that
appliance type + slot.
**Signature:** (`<type>/<slot>` — e.g. a TV volume with nothing learned)
```
WARN   [BroadLink] no code for tv/vol_up
```
> No packet is sent and the tile does not flip.
> **Only the `tv` type ships bundled seed codes.** `codes.ac` and `codes.generic` are empty `{}`,
> and `fan`/`media` have no seed table at all — so `no code for ac/cool_24_auto`, `no code for
> fan/speed_1`, etc. **before learning are EXPECTED, not a bug.** (AC is intentionally empty: a TV
> sends one 32-bit NEC code per button, but an AC transmits its **entire state** per press — e.g.
> Samsung's 14-byte frame, two 7-byte sections with per-section checksum and different timings —
> and the layout varies by AC generation, so a wrong AC code is indistinguishable from a right one
> in the logs. AC must be taught via Learn mode, one code per `"<mode>_<setpoint>_<fan>"` combo
> plus `power_off` for Off.)
**Fix (primary):** teach it in the app — **Learn mode ON → tap the control → press the remote**
(USER_GUIDE.md §4). For a bundled seed instead, add hex under the matching type in
`src/codes.lua` and re-deploy.

### F9 — Parent is missing its network fields
**Trigger:** the discovery stash was lost (e.g. driver restarted between discovery and
device add), so the parent has no `ip`/`mac`/`devtype`.
**Signature:** on a command or init:
```
ERROR  [BroadLink] RM4 missing network fields; re-run discovery
```
**Fix:** run **Refresh** on the parent tile, or re-run Scan nearby. (On init the driver also
auto-attempts a re-discovery to self-heal.)

### F10 — Child can't find its parent
**Trigger:** a child device exists but its parent RM4 was deleted.
**Signature:**
```
ERROR  [BroadLink] child has no parent RM4
```
**Fix:** delete the orphaned child; re-run discovery to recreate the parent (and a fresh
child).

### F11 — Two sends collide on one blaster
**Trigger:** two children of the same RM4 fire at nearly the same instant; the second waits
on the per-RM4 lock. If the first hangs for >20 s (e.g. a learn in progress), the second
proceeds anyway.
**Signature:**
```
WARN   [BroadLink] send-lock wait exceeded 20s; proceeding
```
**Fix:** usually benign (a slow/stuck send). If frequent, the RM4 is timing out repeatedly —
investigate reachability.

### F12 — Everything logs clean, but the appliance doesn't react (no failure line!)
**Trigger:** wrong IR code, the RM4 isn't aimed at the appliance, or a power **toggle** code
fired against the wrong assumed state.
**Signature:** a perfect send — `errcode=0`, **no error line**:
```
INFO   [BroadLink] send_ir: 148 IR bytes -> 192.168.1.50 : 2600b400...0d05
INFO   [BroadLink] -> 192.168.1.50:80 cmd=0x6a len=216 (try 1/3)
INFO   [BroadLink] <- 192.168.1.50 reply len=16 errcode=0
```
> This is the fundamental IR limitation: **`errcode=0` confirms the blaster emitted** the code,
> never that the **appliance obeyed**. The tile flips On regardless. (Contrast **F5b**, where a
> non-zero errcode means the RM4 refused to emit.)
**Fix:** re-capture the exact code (T6), aim the RM4 at the appliance, and — for a TV — try the
other **Power style** (Toggle vs Discrete) in Settings. No log will ever catch this — it's
diagnosed by looking at the appliance, not the logs.

### F13 — Socket couldn't be created
**Trigger:** the hub couldn't allocate a UDP socket (rare; resource pressure).
**Signature:**
```
WARN   [BroadLink] udp() failed: <error>
```
**Fix:** transient — retry discovery. If persistent, reboot the hub.

### F14 — `LEARN OK`, but the *wrong* code was captured (no failure line!)
**Trigger:** during the ~15 s window the remote transmitted something other than what you meant.
Most common on an **AC**: pressing a state-changing button (temperature-up) makes the remote emit
the state it moves **to** (25 °C), not the one it was displaying (24 °C).
**Signature:** a perfect-looking capture — there is **no error line**:
```
INFO   [BroadLink] LEARN OK: 'cool_24_auto' (148 bytes) : 2600b400...0d05
```
> The driver stores whatever bytes arrived, under whatever slot the tile implied. It has no way to
> know the frame encodes 25 °C. `LEARN OK` only means "some IR was received and saved."
**Fix:** this is exactly why the blob is logged — **decode it**, or diff it against a known-good
capture of the same button. Then re-teach, pressing a button that leaves the remote **displaying
the target combination** (see USER_GUIDE → "Teaching an air conditioner"; for a TV, press the same
button you tapped). Confirm by watching the appliance, never the log: on an AC the symptom is
landing one degree off.

---

## Quick signature index

| You see… | It means | Case |
|---|---|---|
| `login OK, device id=...` | Framing/checksums/MAC/AES-with-initial-key correct (not yet the send format) | success 1.4 |
| `SEND: <type>/<slot> (N bytes) : <hex>` | A button was tapped; this IR code is about to be blasted | success 1.5 |
| `send_ir ...` + `<- reply ... errcode=0` | Blaster emitted the code (appliance not confirmed) | success 1.5 / F12 |
| `send_ir REJECTED ... errcode=65531` (-5) | RM4 refused the send — wrong payload framing (or locked) | F5b |
| `discovery loop ended (0 RM4 seen)` | Nothing replied to the broadcast | F2 |
| `no reply from ... (try 3/3)` → `login failed` | Unreachable or malformed packet (MAC order?) | F4 |
| `login rejected, error code N` (+ CLOUD-LOCKED line) | Device refused login (cloud-lock?) | F5 |
| `add appliance: type=... name=...` | A typed child (TV/AC/…) was created | success 1.7 |
| `seeded initial state for <type> child '...'` | Child init emitted optimistic display values (no IR) | success 1.7b |
| `LEARN START: <type>/<slot>` | Learn mode capture begins for this appliance type + slot | success 1.8 |
| `check_learned: captured N IR bytes : <hex>` | IR code captured at the protocol layer (full hex now logged) | success 1.8 |
| `LEARN OK: '<slot>' (N bytes) : <hex>` | Some IR was captured & stored — **not** proof it's the *right* code | success 1.8 / F14 |
| `LEARN store failed for '<slot>' … captured code was: <hex>` | Couldn't store it (e.g. 40-code limit); blob preserved in the log | success 1.8 |
| `LEARN timeout for '<slot>'` | Nothing captured in ~15 s | success 1.8 |
| `no code for <type>/<slot>` | Nothing learned/seeded for that control | F8 |
| `RM4 missing network fields` | Parent lost its ip/mac/devtype | F9 |
| no `Starting driver (stock-caps)` at all | Driver failed to load | F1 |
