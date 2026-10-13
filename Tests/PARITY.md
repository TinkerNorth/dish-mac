# Parity: dish-mac against the other Dish clients

> **What this is.** The feature-parity ledger for this client, kept as a small
> matrix. **A pull request that changes a row updates this file in the same
> change**, and a reviewer checks the row. Coverage is not mapped here: the
> suites under `Tests/` are the coverage truth and CI runs them on every push.
>
> Legend: ✅ works · ⚠️ shipped, not yet verified on real hardware · ❌ not
> available · – not applicable · 🔜 decided and in progress. Verified against
> the code on 2026-10-13.

## 1. What works, per client

| Feature | Android | Windows | Linux | macOS (this) |
|---|---|---|---|---|
| Satellite host, protocol 3 | ✅ | ✅ | ✅ | ✅ offers 3, settles on the satellite's range, re-offers on an overlapping 409 |
| Moonlight host (Sunshine / Apollo / Wolf) | ✅ | ✅ | ✅ | ❌ |
| Mouse mode on the host | ✅ | ❌ | ❌ (deferred) | ❌ (deferred, as the desktops) |
| Controller audio (mic + speaker) | ✅ | ✅ | ✅ | ⚠️ over the DualSense's and DualShock 4's USB audio function through Core Audio, Opus through AudioToolbox; mic and speaker switches per controller, the mic off until asked; not yet verified on a pad |
| DualSense HD haptics | ⚠️ | ⚠️ | ⚠️ | ⚠️ the haptics lanes on channels 3–4 of the DualSense's four-channel USB stream, under the speaker switch; not yet verified on a pad |
| Adaptive triggers, player LEDs, mic lamp | ✅ | ✅ | ✅ | ⚠️ triggers through GameController's adaptive-trigger shapes (feedback, weapon, vibration; galloping resets) · ✅ player LEDs on a DualSense · ⚠️ mic lamp as a chip on the slot card (GameController reaches no DualSense lamp) |
| Lightbar, motion, touchpad, battery | ✅ | ✅ | ✅ | ✅ lightbar, motion, touchpad · ✅ battery (pad, else the host Mac's) |
| Crash reports (opt-out) | ✅ Crashlytics | ✅ Sentry | ✅ Sentry | ⚠️ a local crash log the user reviews, redacted, and sends as a GitHub issue; nothing uploads |
| Update notice | – Play · ✅ GitHub build | ✅ | ✅ | ✅ `latest.json` from the release permalink; once per version, skippable, floor warning |
| Runs in the background / window closed | ⚠️ | ✅ tray | ✅ tray | ✅ menu-bar item (closing the window keeps streaming; off in Settings quits) |
| Survives PC sleep and resume | – | ✅ Satellite | ✅ Satellite | ✅ Satellite (release-all on sleep, reconnect on wake) |
| Keep-awake is user-configurable | ❌ | ✅ | ✅ | ✅ off · while playing (stillness window) · while connected; display optional |
| Diagnostics screen | ✅ | ✅ | ✅ | ✅ window: session facts, each controller down to the wire, the flight recorder |
| Link-tier cue on host rows | ✅ | ✅ | ✅ | ✅ every host is a satellite, so every row reads Fastest |
| Protocol chip | ✅ | ✅ | ✅ | ✅ |
| App-wide microphone chip with mute-all | ✅ | ✅ | ✅ | ✅ header chip: live, muted or hidden; one click mutes or unmutes every armed mic |
| Capability verdict word "Supported" | ✅ | ✅ | ✅ | ✅ "What carries" on every bound slot: pad ∩ Mac ∩ type ∩ host, Off and Pending distinct |
| Pairing secrets stored encrypted | ✅ Moonlight key · ❌ Satellite key | ✅ DPAPI | ✅ Secret Service | ✅ Keychain |
| Six languages (en, bs, de, es, fr, pt-BR) | ✅ | ✅ | ✅ | ✅ every word, plural forms included |
| Per-controller motion, rumble and touchpad switches | ✅ | ✅ | ✅ | ✅ the chips on the slot card; the light bar stays global, as on the desktops |
| Light, dark and system theme | ✅ | ✅ | ✅ | ✅ |
| Emulate-as type picker (from the catalog) | ✅ | ✅ | ✅ | ✅ Auto (the family's type from `emulates`) or a pick, held for the run |

## 2. Input, pad to host, by path (cell = USB · Bluetooth)

| | Android | Windows | Linux | macOS (this) |
|---|---|---|---|---|
| Buttons, sticks, triggers | ✅ · ✅ | ✅ · ✅ | ✅ · ✅ | ✅ · ✅ |
| Motion | ✅ · ✅ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (GCMotion on DualSense and DualShock 4) |
| Touchpad | ✅ · ⚠️ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (DualSense and DualShock 4 profiles) |
| Battery | ⚠️ · ✅ | ⚠️ · ⚠️ | ⚠️ · ⚠️ | ⚠️ · ⚠️ |
| Controller mic | ✅ · ❌ | ✅ · ❌ | ✅ · ❌ | ⚠️ · ❌ (the USB audio function; unverified on a pad) |

The macOS client has one input path: GameController.framework. There is no
raw-HID "Direct" claim, so the "USB Direct" column the other clients carry
does not apply here.

## 3. Receiving, host to pad, by path (cell = USB · Bluetooth)

| | Android | Windows | Linux | macOS (this) |
|---|---|---|---|---|
| Rumble | ✅ · ✅ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (CoreHaptics engines per handle) |
| Lightbar | ✅ · ⚠️ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (`GCController.light`) |
| Adaptive triggers | ✅ · ❌ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (the API's shapes; GameController carries them over both links) |
| Player LEDs | ✅ · ❌ | ✅ · ⚠️ | ✅ · ⚠️ | ✅ · ✅ (DualSense, by player index) |
| Mic lamp | ✅ · ❌ | ✅ · ❌ | ✅ · ❌ | ⚠️ · ⚠️ (a chip on the slot card, not the pad's lamp) |
| Controller speaker | ✅ · ❌ | ✅ · ❌ | ✅ · ❌ | ⚠️ · ❌ (unverified on a pad) |
| HD haptics | ⚠️ · ❌ | ⚠️ · ❌ | ⚠️ · ❌ | ⚠️ · ❌ (channels 3–4 of the DualSense stream; unverified on a pad) |

## 4. Decisions, not gaps

- **One input path.** GameController.framework is the only way an unsigned,
  unentitled macOS app reads a pad, so there is no Direct claim, no per-model
  report parser and no "Layout guessed" chip. What the framework exposes is
  what Dish forwards.
- **Mouse mode on the host is a recorded deferral**, as on the desktops.
- **Controller identity is the vendor name and product category**, because
  GameController vends a fresh object on every reconnect and exposes no
  per-unit identifier. Two identical pads take ordinals.
- **The Android-only surfaces** (on-screen pad, skins, Bluetooth HID host
  mode, Play billing, store screenshots) do not apply.
- **Battery over USB is the host Mac's** when the pad reports none, which is
  what the other desktop clients send too.
- **Controller audio is the pad's USB audio function**, matched to the pad
  by family and only when unambiguous (one pad of the family, one function
  of it), as dish-android matches; two pads of a family route nothing and
  Diagnostics says why. The mic is off until the user turns it on, mute sends
  nothing, the mic sequence never restarts within a session, and the host's
  `controllerAudio` verdict gates every lane per session. Opus is
  AudioToolbox's codec, so a concealed window is silence. No pad was attached
  to the Mac this shipped from: the path is proven through fake ports and the
  fake satellite, and stays ⚠️ until a run on a DualSense confirms it.

## 5. Decided and in progress

The waves below are planned in this order. Each lands with its tests and
updates the rows above.

1. The Diagnostics extras the Linux client has: the input inspector, the
   stick drift test and the rumble bench. (Theme, background mode,
   keep-awake modes, the update check, About, the Emulate picker, "What
   carries", the motion word, the link tier, Diagnostics, the crash log and
   the per-controller switches shipped.)
2. Moonlight hosts.
