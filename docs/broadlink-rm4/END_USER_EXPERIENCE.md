# BroadLink RM4 — End-User Experience (after the Shipping Plan is done)

Plain-language description of what a normal user can do once
`SHIPPING_PLAN.md` (all phases) is implemented, and how they do it.

> ⚠️ **Which plan this describes.** This doc describes the target of the **custom-capabilities**
> plan (`SHIPPING_PLAN.md`) — a single generic "IR appliance" with a custom
> learn/send capability. **That is NOT what was built.** The product that was actually
> implemented follows the **stock-capabilities** plan (typed TV/AC/fan devices, Learn-mode
> preference). For the real, current end-user flow see **`USER_GUIDE.md`**.
> This doc is kept as a description of the alternative design.

---

## The whole journey, step by step

### 1. Install it — just a link
The user clicks an **invite link**, which enrolls their hub and installs the driver.
No computer, no CLI, no Python. (Plan Phase 5.)

### 2. Find the blaster
SmartThings app → **Add device → Scan nearby**. The RM4 shows up as **"BroadLink RM4."**
(Plan Phase 0/existing.)

### 3. Add appliances — from the app
Open the **BroadLink RM4** tile → Settings → **"Add appliance"** → type a name:
- `Living Room TV` → creates a **"Living Room TV"** device.
- `ac:Bedroom AC` → creates an **AC** device with temperature controls.

Add as many as wanted; delete any by removing its tile. All in-app, no code editing.
(Plan Phase 1.4.)

### 4. Teach it your remotes — "learning"
For each button the user wants, on the appliance device:
1. Settings → type the button name (e.g. `power_on`, `vol_up`).
2. Back → tap **Start learning**.
3. Point the **real remote** at the RM4 and press that button.
4. App shows **"captured."** The code is saved on the device (survives reboots/updates).

Repeat per button. (Plan Phase 1.1–1.3.)

### 5. Control the appliances
- **On / Off switch** on the tile → fires the learned power codes.
- **Buttons** (volume, channel, mute…) → the mapped button slots. (Plan Phase 2.1.)
- **AC** → pick mode (cool/heat/off) + set temperature → fires the matching learned code.
  (Plan Phase 2.2.)

### 6. Automations & voice
- **Routines:** "At 11 PM, turn off Living Room TV," or fire any named code (e.g. `vol_down`).
- **Voice:** "Alexa/Google, turn on Living Room TV." (Plan Phase 1 — standard capabilities.)

### 7. It looks after itself
- Blaster unplugged / off-network → its tile shows **offline** (not a silent dead tile).
- Router changes the blaster's IP → driver **re-finds it automatically**.
- Blaster is **cloud-locked** → driver detects it and says so, instead of silently failing.
  (Plan Phase 3.)

---

## Full capability summary

| What | How the user does it | Plan phase |
|---|---|---|
| Install driver | Click invite link → enroll hub | 5 |
| Find blaster | Add device → Scan nearby | existing |
| Add appliance | RM4 Settings → "Add appliance" → type name | 1.4 |
| Remove appliance | Delete the appliance tile | 1.4 |
| Learn a code | Appliance Settings → name it → Start learning → press remote | 1.1–1.3 |
| Turn on/off | Switch on the appliance tile | 1 |
| Volume/channel/etc. | Mapped button slots | 2.1 |
| AC mode/temp | Thermostat controls on the AC tile | 2.2 |
| Use in Routines | Fire any named code from a Routine | 1 |
| Voice control | Alexa/Google on/off | 1 |
| See if blaster is down | Offline status on the tile | 3.1 |
| Survive IP changes | Automatic (scheduled re-discovery) | 3.2 |
| Know if cloud-locked | Clear offline + message | 3.3 |

---

## The one limitation that never goes away

IR is **one-way**. The app can confirm the command was *sent*, never that the appliance
*obeyed*. So a tile flipping "On" means "we blasted the on-code," not a guaranteed "the TV is
on." If the TV was blocked or someone used the physical remote, the app's view can drift.
This is a property of infrared, not something any phase can fix — the driver mitigates it by
seeding sensible starting values and updating optimistically, but the card can still drift.

---

## A note on *how* setup works (design choice)

"Add appliance" and "Learn" run through the device **Settings screen** (type a name, then tap
a button) rather than slick custom buttons on the main tile — because Settings/preferences
render reliably in the SmartThings app, while custom tile presentations are the platform's
most fragile surface. Trade-off: a bit more "type-then-tap," but it won't break on an app
update. (Plan Phase 1.1 note.)
