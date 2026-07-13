# BroadLink RM4 — User Guide

Control your TV, air conditioner, fan, and other infrared (IR) devices from SmartThings,
using a BroadLink RM4 Mini — all on your local network, no BroadLink cloud account needed.

This guide is for everyday users. No coding, no computer required.

---

## What you need

- A **SmartThings hub** (Aeotec, Samsung, or a hub-capable Station).
- A **BroadLink RM4 Mini**, already set up on your **home Wi-Fi (2.4 GHz)** using the
  BroadLink app, and on the **same network as your hub**.
- The physical **remote controls** for the devices you want to control (you'll teach the RM4
  by pointing your remotes at it).

> **Important — "Lock device" must be OFF.** In the BroadLink app, open your RM4 → settings →
> make sure **"Lock device"** (device lock) is **turned off**. If it's on, the RM4 refuses
> local control and this driver can't talk to it.

---

## 1. Install the driver

Open the **invite link** your provider gave you, choose your hub, and install the
**BroadLink RM4** driver. (That's the only setup step done outside the SmartThings app.)

---

## 2. Add the blaster

1. Open the **SmartThings app**.
2. Tap **➕ → Add device → Scan for nearby devices**.
3. After a few seconds, a device named **BroadLink RM4** appears. This is your blaster.
4. That's the only device for now — there are no appliances yet. You add each one yourself
   in the next step.

If nothing is found, see [Troubleshooting](#troubleshooting).

---

## 3. Add your appliances

Each real device (a TV, an AC…) becomes its own tile. To add one:

1. Open the **BroadLink RM4** tile → **⋮ → Settings**.
2. Choose the **Appliance type** (Air Conditioner / TV / Generic — Air Conditioner is the default).
3. Type an **Appliance name** (e.g. "Living Room TV") and **Save**.
4. After a short moment (it can take up to ~1–2 minutes) a new tile with that name appears —
   that's your appliance.

Repeat for each device — just **Save a different name** each time (a different name creates a
new device; the type is whatever the dropdown shows when you Save).

> **Note:** onboarding doesn't create a starter device — you add each appliance yourself with
> the steps above. Saving the **name** is what creates it (there's no separate "Add" button).

---

## 4. Teach it your remotes ("Learn mode")

The RM4 learns your buttons by watching your real remote. Most appliances must be taught once.

### What comes bundled, and what you must teach

| Appliance type | Codes included? |
|---|---|
| **TV** | ✅ A standard **Samsung** codeset — power, volume, mute, channel, play/pause/stop, fast-forward/rewind. Works on many Samsung TVs and smart monitors. If a button does nothing, just teach it. |
| **Air Conditioner** | ❌ None — see [Teaching an air conditioner](#teaching-an-air-conditioner) |
| **Fan** | ❌ None |
| **Media box** | ❌ None |
| **Generic** | ❌ None |

Anything you teach **always overrides** a bundled code, so you can retrain any button that
misbehaves — including the Samsung ones if your TV uses a different codeset.

### How to teach a button

1. Open the appliance tile (e.g. "Living Room TV") → **⋮ → Settings**.
2. Turn **Learn mode = On** → go back.
3. Tap the control you want to teach — for example **Power (the switch)**, **Volume Up**, or
   a **Button 1–4** (on a Generic device). The RM4 now listens for about **15 seconds**.
4. **Immediately** point the real remote at the RM4 (within ~10 cm) and **press that same
   button** on the remote. The RM4 records it.
5. Repeat steps 3–4 for every control you want (volume, channel, mute, power…).
6. When finished, go back to **Settings → Learn mode = Off**.

That's it — now every control **sends** instead of records.

> **The tile won't move while Learn mode is on.** It's recording, not sending, so the switch and
> volume on screen stay where they are. That's normal — it starts tracking again once you turn
> Learn mode off. (**Air conditioners are the exception:** their tile *does* update, because an
> AC's code is named after the combination on screen — you have to be able to see what you're
> teaching.)

> **How do I know it worked?** There's no popup. Turn Learn mode **off**, then tap the control —
> if the device reacts, it learned correctly. If nothing happens, turn Learn mode back on and
> teach that button again (aim carefully, get closer).

> **Deleting an appliance deletes its learned codes.** You'd have to teach them again.

### What each device type can learn/control

| Type | Controls you can teach & use |
|---|---|
| **TV** | Power, Volume Up/Down, Mute, Channel Up/Down, Play/Pause/Stop, Fast-forward/Rewind |
| **Air Conditioner** | Power, Mode (cool/heat/auto/off), Temperature, Fan mode — *no bundled codes; see "Teaching an air conditioner" below* |
| **Generic** | Power on/off + Button 1–4 (teach any four buttons you like) |

> The **Add** menu currently offers only TV, Air Conditioner and Generic. **Generic** covers most
> other appliances — its Power + four buttons can learn any remote's buttons. (The driver also
> contains **Fan** and **Media box** types, kept for the future but not shown in the menu.)

### Teaching an air conditioner

An AC remote sends its **whole state** with every press — so "Cool 24° Auto-fan" is a completely
*different* code from "Cool 23° Auto-fan". There's no such thing as a "temperature up" code.

That's why **no AC codes come bundled** (TVs do). You teach one code per combination you actually
use — teach the two or three settings you care about (e.g. Cool 24, Cool 26, Off), not all of them.

> ### ⚠️ The one thing that trips everyone up
>
> An AC remote transmits the state **it will be in after you press the button** — not the state
> it was showing before. So if the remote reads 24° and you press **temperature-up**, it sends
> **25°**. Teach with that press and the driver files a 25° code under the name "24°", and from
> then on asking for 24° quietly sets your AC to 25°.
>
> **The rule:** press a button that leaves the remote **displaying the combination you want**.

**Teach one combination (e.g. Cool 24° Auto) like this:**

1. Turn **Learn mode = On** (**⋮ → Settings**) and go back to the tile.
2. Turn the **AC off** with its own remote, and set that remote to the combination you want:
   **Cool, 24°, Auto**. (These presses don't matter — the RM4 isn't listening yet.)
3. On the tile, tap the **one control** that reaches your target — for a fresh AC, just tap
   **Mode → Cool** (it already starts at 24° / Auto). The tile updates to show the combination,
   and the RM4 starts listening for ~15 seconds.
4. **Immediately** hold the remote within ~10 cm of the RM4 and press **Power** (turning the AC
   on). The remote sends its whole state — Cool, 24°, Auto, powered on — which is exactly the
   code you want.
5. For the next combination (e.g. Cool 26° Auto): turn the AC off again, set the remote to 26°,
   then drag **Temperature** to **26°** on the tile and press **Power** on the remote.
6. To teach **Off**: with the AC **on**, set **Mode = Off** on the tile, then press **Power** on
   your remote (turning the AC off). That captures the power-off code.
7. When you're done, turn **Learn mode = Off**.

> **No usable Power press?** Then sit the remote **one step away** and press the button that lands
> on the target. To teach 24°, put the remote at 25° and press **temperature-down** — the signal it
> sends *is* 24°.

> **Change one thing at a time.** Every tap teaches the *whole* combination currently shown, so
> tapping Mode, then Temperature, then Fan would open three separate learn windows and teach three
> different combinations. Reach your target with as few taps as possible.

> **Untaught settings spring back.** Once you're out of Learn mode, if you pick a temperature you
> never taught, the slider bounces back to the last one that works. That's the app telling you
> there's no code for that setting — not a fault. Teach it, or pick one you did teach.

> **Check it worked:** turn Learn mode off, then tap **Mode → Cool**. If the AC responds — and
> lands on the temperature you meant, not one degree off — it learned correctly. If not, teach
> that combination again (aim carefully, get closer, and re-check which button you pressed).

### Power style (TV)

Each TV tile has a **Power style** setting (open the tile → **⋮ → Settings**) with two options:

- **Toggle** (the default) — one code that flips power **on/off**. This is what most Samsung
  smart monitors (e.g. the M5) and many TVs expect; they ignore separate on/off codes. In Learn
  mode you teach a single **Power** button.
- **Discrete On/Off** — separate **power-on** and **power-off** codes (some TVs support this).
  In Learn mode you teach the On and Off buttons separately.

> **Heads-up about Toggle:** because Toggle uses one flip code for both On and Off, if the app's
> on/off state ever gets out of sync (e.g. someone used the physical remote), the first tap may
> flip the "wrong" way — just tap again and it corrects itself.

---

## 5. Control your devices

- Tap a device tile and use its controls (switch, volume, temperature…).
- The controls also appear on your **home dashboard** if you add the tile to Favorites.

**A note on how it looks:** when you tap a control, the tile updates immediately — this means
"the command was sent," **not** a guaranteed "the device obeyed." IR is one-way, so SmartThings
can't see whether your TV actually reacted. If the tile ever looks out of sync (e.g. someone
used the physical remote), just tap the control again.

**The numbers on the card are a starting guess, not a reading.** A new appliance shows sensible
defaults (a TV starts at volume 30, an AC at Cool-off, 24 °C, Auto fan) so the card isn't full of
blanks. Those values move as you tap, but they were never read from the appliance — nothing about
IR lets SmartThings ask your TV what volume it's on. Expect the card to drift if you use the
physical remote; tapping a control again brings it back in line.

---

## 6. Use it in Routines and by voice

Because each appliance is a normal SmartThings device, you can:
- **Routines:** "At 11 PM, turn off Living Room TV," or "When I arrive, turn on the AC."
- **Voice:** "Alexa/Google, turn on Living Room TV," "volume up," "set the AC to cool."

Same as above: these send the IR code and assume it landed.

---

## 7. Removing things

- **Remove one appliance:** open its tile → **⋮ → Delete**. Its learned codes are removed with
  it.
- **Remove everything:** delete the **BroadLink RM4** tile — all its appliances go too.

---

## Troubleshooting

| Problem | Likely cause | What to do |
|---|---|---|
| **Scan finds no BroadLink RM4** | Blaster off, or on a different Wi-Fi/network than the hub | Make sure the RM4 is powered and on the **same network** as the hub (a separate "IoT" Wi-Fi or guest network won't work). |
| **The RM4 tile shows Offline** | Hub can't reach the blaster, or it's **cloud-locked** | Check it's powered and on the network. Then open the **BroadLink app → RM4 → settings → turn OFF "Lock device."** |
| **A control does nothing** (no reaction) | That button wasn't taught, or wasn't aimed well | Re-teach it (Section 4): Learn mode on → tap the control → point the remote closely and press. Prefer separate on/off buttons over a single power-toggle. |
| **The Power button does nothing** | TV expects the other power-code style | Open the TV tile → **Settings** → switch **Power style** between **Toggle** and **Discrete On/Off**, then try again. |
| **The device's IP changed** | Your router gave it a new address | Open the **BroadLink RM4** tile → **Refresh**. (Best fix: give the RM4 a fixed/reserved IP in your router.) |
| **Tile state looks wrong** | Someone used the physical remote (IR gives no feedback) | Just tap the control again; the state is a best guess, not a live reading. |

---

## Good to know (limitations)

- **IR is one-way.** The app shows what it *sent*, never confirms what the device *did*.
- **One blaster covers one room / line of sight.** The RM4 must be able to "see" the devices;
  a TV and an AC in different rooms need two RM4s.
- **Two identical devices** (e.g. two same-model TVs) can't be controlled separately — they
  both react to the same code.
- This is a **community driver** using a reverse-engineered protocol; a BroadLink firmware
  update could change how it behaves.
