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
| Satellite host, protocol 3 | ✅ | ✅ | ✅ | ❌ protocol 1 (🔜) |
| Moonlight host (Sunshine / Apollo / Wolf) | ✅ | ✅ | ✅ | ❌ |
| Mouse mode on the host | ✅ | ❌ | ❌ (deferred) | ❌ (deferred, as the desktops) |
| Controller audio (mic + speaker) | ✅ | ✅ | ✅ | ❌ |
| DualSense HD haptics | ⚠️ | ⚠️ | ⚠️ | ❌ |
| Adaptive triggers, player LEDs, mic lamp | ✅ | ✅ | ✅ | ❌ |
| Lightbar, motion, touchpad, battery | ✅ | ✅ | ✅ | ✅ lightbar, motion, touchpad · ✅ battery (pad, else the host Mac's) |
| Crash reports (opt-out) | ✅ Crashlytics | ✅ Sentry | ✅ Sentry | ❌ |
| Update notice | – Play · ✅ GitHub build | ✅ | ✅ | ❌ |
| Runs in the background / window closed | ⚠️ | ✅ tray | ✅ tray | ❌ (closing the window quits) |
| Survives PC sleep and resume | – | ✅ Satellite | ✅ Satellite | ✅ Satellite (release-all on sleep, reconnect on wake) |
| Keep-awake is user-configurable | ❌ | ✅ | ✅ | ❌ (display kept awake while streaming, no setting) |
| Diagnostics screen | ✅ | ✅ | ✅ | ❌ |
| Link-tier cue on host rows | ✅ | ✅ | ✅ | ❌ |
| Protocol chip | ✅ | ✅ | ✅ | ❌ |
| App-wide microphone chip with mute-all | ✅ | ✅ | ✅ | – no controller audio yet |
| Capability verdict word "Supported" | ✅ | ✅ | ✅ | ❌ (capability chips only) |
| Pairing secrets stored encrypted | ✅ Moonlight key · ❌ Satellite key | ✅ DPAPI | ✅ Secret Service | ✅ Keychain |
| Six languages (en, bs, de, es, fr, pt-BR) | ✅ | ✅ | ✅ | ✅ every word, plural forms included |
| Light, dark and system theme | ✅ | ✅ | ✅ | ❌ dark only |
| Emulate-as type picker (from the catalog) | ✅ | ✅ | ✅ | ❌ (first catalog type, no picker) |

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
| Adaptive triggers | ✅ · ❌ | ✅ · ⚠️ | ✅ · ⚠️ | ❌ · ❌ |
| Player LEDs | ✅ · ❌ | ✅ · ⚠️ | ✅ · ⚠️ | ❌ · ❌ |
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

1. Protocol 3: the v2/v3 constants and frames, the 409 range negotiation and
   re-offer, the settled version gating the pointer frame, the protocol chip,
   the capabilities probe, the catalog's `catalogVersion` and `emulates`,
   honest caps (motion only when the pad has an IMU and the switch is on),
   trigger effects through `GCDualSenseAdaptiveTrigger`, player LEDs through
   `playerIndex`, the 1500 ms rumble cap.
2. Desktop UX: light/dark/system theme, the menu-bar item and background
   mode, keep-awake modes, the type picker, per-slot switches, the
   capability table with "Supported", the link-tier cue, Diagnostics, the
   update check, local crash logs with an opt-out report, Help, Support,
   Licenses and About.
3. Controller audio and HD haptics over the DualSense's USB audio function,
   where Core Audio exposes it.
4. Moonlight hosts.
