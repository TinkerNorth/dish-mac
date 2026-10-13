# Parity: dish-mac against the other Dish clients

> **What this is.** The feature-parity ledger for this client, kept as a small
> matrix. **A pull request that changes a row updates this file in the same
> change**, and a reviewer checks the row. Coverage is not mapped here: the
> suites under `Tests/` are the coverage truth and CI runs them on every push.
>
> Legend: ✅ works · ⚠️ shipped, not yet verified on real hardware · ❌ not
> available · – not applicable · 🔜 decided and in progress. Verified against
> the code on 2026-10-12.

## 1. What works, per client

| Feature | Android | Windows | Linux | macOS (this) |
|---|---|---|---|---|
| Satellite host, protocol 3 | ✅ | ✅ | ✅ | ✅ offers 3, settles on the satellite's range, re-offers on an overlapping 409 |
| Moonlight host (Sunshine / Apollo / Wolf) | ✅ | ✅ | ✅ | ❌ |
| Mouse mode on the host | ✅ | ❌ | ❌ (deferred) | ❌ (deferred, as the desktops) |
| Controller audio (mic + speaker) | ✅ | ✅ | ✅ | ❌ |
| DualSense HD haptics | ⚠️ | ⚠️ | ⚠️ | ❌ |
| Adaptive triggers, player LEDs, mic lamp | ✅ | ✅ | ✅ | ⚠️ triggers through GameController's adaptive-trigger shapes (feedback, weapon, vibration; galloping resets) · ✅ player LEDs on a DualSense · ❌ mic lamp (no controller audio) |
| Lightbar, motion, touchpad, battery | ✅ | ✅ | ✅ | ✅ lightbar, motion, touchpad · ✅ battery (pad, else the host Mac's) |
| Crash reports (opt-out) | ✅ Crashlytics | ✅ Sentry | ✅ Sentry | ❌ |
| Update notice | – Play · ✅ GitHub build | ✅ | ✅ | ✅ `latest.json` from the release permalink; once per version, skippable, floor warning |
| Runs in the background / window closed | ⚠️ | ✅ tray | ✅ tray | ✅ menu-bar item (closing the window keeps streaming; off in Settings quits) |
| Survives PC sleep and resume | – | ✅ Satellite | ✅ Satellite | ✅ Satellite (release-all on sleep, reconnect on wake) |
| Keep-awake is user-configurable | ❌ | ✅ | ✅ | ✅ off · while playing (stillness window) · while connected; display optional |
| Diagnostics screen | ✅ | ✅ | ✅ | ❌ |
| Link-tier cue on host rows | ✅ | ✅ | ✅ | ✅ every host is a satellite, so every row reads Fastest |
| Protocol chip | ✅ | ✅ | ✅ | ✅ |
| App-wide microphone chip with mute-all | ✅ | ✅ | ✅ | – no controller audio yet |
| Capability verdict word "Supported" | ✅ | ✅ | ✅ | ✅ "What carries" on every bound slot: pad ∩ Mac ∩ type ∩ host, Off and Pending distinct |
| Pairing secrets stored encrypted | ✅ Moonlight key · ❌ Satellite key | ✅ DPAPI | ✅ Secret Service | ✅ Keychain |
| Six languages (en, bs, de, es, fr, pt-BR) | ✅ | ✅ | ✅ | ✅ every word, plural forms included |
| Light, dark and system theme | ✅ | ✅ | ✅ | ✅ |
| Emulate-as type picker (from the catalog) | ✅ | ✅ | ✅ | ✅ Auto (the family's type from `emulates`) or a pick, held for the run |

## 2. Input, pad to host, by path (cell = USB · Bluetooth)

| | Android | Windows | Linux | macOS (this) |
|---|---|---|---|---|
| Buttons, sticks, triggers | ✅ · ✅ | ✅ · ✅ | ✅ · ✅ | ✅ · ✅ |
| Motion | ✅ · ✅ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (GCMotion on DualSense and DualShock 4) |
| Touchpad | ✅ · ⚠️ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (DualSense and DualShock 4 profiles) |
| Battery | ⚠️ · ✅ | ⚠️ · ⚠️ | ⚠️ · ⚠️ | ⚠️ · ⚠️ |
| Controller mic | ✅ · ❌ | ✅ · ❌ | ✅ · ❌ | ❌ · ❌ |

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
| Mic lamp | ✅ · ❌ | ✅ · ❌ | ✅ · ❌ | ❌ · ❌ |
| Controller speaker | ✅ · ❌ | ✅ · ❌ | ✅ · ❌ | ❌ · ❌ |
| HD haptics | ⚠️ · ❌ | ⚠️ · ❌ | ⚠️ · ❌ | ❌ · ❌ |

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

## 5. Decided and in progress

The waves below are planned in this order. Each lands with its tests and
updates the rows above.

1. Desktop UX, the rest: Diagnostics (session facts, slot wire facts, the
   flight recorder), a local crash log the user sends as an issue, and
   per-slot switches. (Theme, background mode, keep-awake modes, the update
   check, About, the Emulate picker, "What carries", the motion word and the
   link tier shipped.)
2. Controller audio and HD haptics over the DualSense's USB audio function,
   where Core Audio exposes it; the mic lamp rides the same work.
3. Moonlight hosts.
