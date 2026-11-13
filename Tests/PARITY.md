# Parity: dish-mac against the other Dish clients

> **What this is.** The feature-parity ledger for this client, kept as a small
> matrix. **A pull request that changes a row updates this file in the same
> change**, and a reviewer checks the row. Coverage is not mapped here: the
> suites under `Tests/` are the coverage truth and CI runs them on every push.
>
> Legend: ✅ works · ⚠️ shipped, not yet verified on real hardware · ❌ not
> available · – not applicable · 🔜 decided and in progress. Verified against
> the code on 2026-10-27.

## 1. What works, per client

| Feature | Android | Windows | Linux | macOS (this) |
|---|---|---|---|---|
| Satellite host, protocol 4 | ✅ (#278) | 🔜 (#121) | 🔜 (#104) | ✅ offers 4, settles on the satellite's range, re-offers on an overlapping 409; a session settled on 4 sends the 17-byte input frame with the extended-buttons word, 13 bytes below; the `extendedButtons` cap is claimed for a pad whose decoder fills the word (both Steam Controllers and the Switch Pro, see section 2's "Extra buttons" row) |
| Satellite pairing: the operator's approval and the typed PIN | ✅ request on open, 2 s poll for 120 s | ⚠️ both at once (1 s poll), but the typed PIN waits for six digits on `main` (S-W1) | ⚠️ the same (S-L2) | ✅ both at once on the row's card: a four-digit request the operator approves on the satellite (2 s poll for 120 s; a decline or expiry offers a new code) beside the satellite's PIN typed into four cells; the first to land opens the session and stops the other; closing the card or leaving the Connections page cancels the poll |
| Pads per satellite | ✅ each on the lowest free index | ✅ four ("slot n of 4") | ✅ the same | ✅ four (`SatelliteSlots.maxPerSatellite`), each on the lowest free controller index for as long as it stays bound: its own descriptor in the session PUT and its own `PUT` / `DELETE /api/connections/{id}/controllers/{idx}` while live, its own route on the hot path, its rumble, light bar, trigger effects, player LEDs, speaker, haptics and mic lanes by that index, and both ends of the heartbeat bitmap reconcile over every index; Home says "slot n of 4", the satellite's card lists every pad, Diagnostics shows each pad's index; a fifth is not offered |
| Bindings survive a restart | ✅ Moonlight bindings (2.3.0); satellite bindings from the remembered satellites | ✅ standing bindings (2.2.0) | ✅ the same | ✅ satellite bindings under `wifi_binding_list` (the satellite and the type picked), Moonlight bindings read back from `moonlight_binding_list`; bound again once the pad is attached and its satellite is in the pool or its host on record, whichever is later, and again whenever the pad returns; Unbind and Forget end them, a satellite's refusal does not |
| Moonlight host (Sunshine / Apollo / Wolf) | ✅ | ✅ | ✅ | ⚠️ discovery, PIN pairing with mutual TLS after, one session per host for up to four pads (launch or resume, RTSP, media pings, the ENet control stream), motion / touch / battery up and rumble / light bar back, the app picker and the Emulate pick per pad; every wire piece pinned against Wolf's captures and the whole path run against a loopback host (`IntegrationMoonlightFakeHostTests`), not yet against a live one |
| Mouse mode on the host | ✅ | ❌ | ❌ (deferred) | ✅ per-controller pick Off / Pad / Mouse; the request rides the session PUT and a flip mid-session converges through the re-key path |
| Controller audio (mic + speaker) | ✅ | ✅ | ✅ | ⚠️ over the DualSense's and DualShock 4's USB audio function through Core Audio, Opus through AudioToolbox; mic and speaker switches per controller, the mic off until asked, each pad's lanes on its own controller index; not yet verified on a pad |
| DualSense HD haptics | ⚠️ | ⚠️ | ⚠️ | ⚠️ the haptics lanes on channels 3–4 of the DualSense's four-channel USB stream, under the speaker switch; not yet verified on a pad |
| Adaptive triggers, player LEDs, mic lamp | ✅ | ✅ | ✅ | ⚠️ triggers through GameController's adaptive-trigger shapes (feedback, weapon, vibration; galloping resets) · ✅ player LEDs on a DualSense · ⚠️ mic lamp as a chip on Home's binding strip (GameController reaches no DualSense lamp) |
| Lightbar, motion, touchpad, battery | ✅ | ✅ | ✅ | ✅ lightbar, motion, touchpad · ✅ battery: the wire carries the lower of the pad's own and the Mac's on both paths (a pad with none sends the Mac's), the card shows the pad's own |
| Crash reports (opt-out) | ✅ Crashlytics | ✅ Sentry | ✅ Sentry | ✅ Sentry (sentry-cocoa) behind "Share crash reports", on by default, armed only by an official build; the local redacted log and its report card stay |
| Update notice | – Play · ✅ GitHub build | ✅ | ✅ | ✅ `latest.json` from the release permalink; once per version, skippable, floor warning |
| The window: the desktops' shell | – (Activities, two panes on sw600dp) | ✅ rail (labelled 236 px, 48 px icons, persisted) + per-page header + pushed pages, one toast host | ✅ the same | ✅ the same in SwiftUI: `NavigationSplitView` rail (236 pt labelled, icon strip collapsed, persisted as `ui_rail_collapsed`), per-page header (back chevron, title, streaming pill with Configure, mic chip, status line), a `NavigationStack` of pages, one toast host, 980×640 (min 900×620); no sheets at all (the pairing card and the Moonlight PIN are inline cards in their rows); ⌘, · ⌘1-3 · ⌘[ ; the Set up action between the rail's groups |
| Runs in the background / window closed | ⚠️ | ✅ tray | ✅ tray | ✅ menu-bar item (closing the window keeps streaming; off in Settings quits) |
| Survives PC sleep and resume | – | ✅ Satellite | ✅ Satellite | ✅ Satellite and Moonlight (sleep releases held input and closes every session, a satellite's with its `DELETE`; wake reopens them and rescans; a lid that closed on a stream is said once) |
| Keep-awake is user-configurable | ❌ | ✅ | ✅ | ✅ off · while playing (stillness window) · while connected; display optional; a closed lid still sleeps the Mac (no API keeps a lidded Mac awake: `IOPMLib.h` calls `kIOPMAssertionTypePreventSystemSleep` "not supported in any OS X releases"; clamshell mode needs power and a display) |
| Input while another app is in front | – (stops by design) | ✅ | ✅ | ✅ GameController's background monitoring, on from the first connect (broken in macOS 15.4, fixed in 15.5) |
| Diagnostics screen | ✅ | ✅ | ✅ | ✅ page (pushed from Settings, or opened by the menu-bar item): session facts for satellites and Moonlight hosts (the session's standing, the app, the control round trip, each pad's reports), each controller down to the wire, the flight recorder, and the controller inspector (live input, motion and touch, the drift and range stick tests on the raw sticks, the rumble bench, the test tone and the microphone meter) |
| Diagnostics: other input devices | ✅ "Other input devices" cards (2.4.1, #258) | – (SDL takes every device) | – (the same) | ✅ the HID census (IOHIDManager over Joystick / GamePad / MultiAxisController, synthetic devices excluded, watched while the page shows): a card per game device GameController does not claim, with "Not a controller: not claimed by GameController", its hardware ID, its connection and Help support this controller |
| Diagnostics: a controller's USB ID | ❌ | ✅ "USB ID" (2.4.0) | ✅ the same | ✅ "USB ID" on a controller's card when the census finds exactly one claimed device under the pad's name |
| Link-tier cue on host rows | ✅ | ✅ | ✅ | ✅ a satellite reads Fastest, a Moonlight host Fast |
| Connections list: found and paired | ✅ | ✅ | ✅ | ✅ the desktops' page: a scan as it opens once the Local Network prompt has been explained (quiet; the Scan button's says when nothing answered), FOUND with its empty states (the local-network refusal as the hint, with Open System Settings) and Pair… rows whose card opens under the row, a "Moonlight hosts ›" row, PAIRED cards (glyph, dot, name, `ip • UDP port`, latency, tier / protocol / link chips, the read-only CARRYING manifest, Disconnect / Pair… / Connect by state, Forget behind ⋯), the add-by-address field |
| Moonlight hosts page | ✅ | ✅ | ✅ | ✅ pushed from Connections: Paired / Remembered / Not paired, the controllers count and the tier, the app picker, the session's way out (Pair now, Re-pair, Reconnect, Retry, Close the app) and Forget behind ⋯, an inline "Add a host by address" form, and the PIN as an inline card in the host's row (Cancel, New code) |
| Forget asks first | ✅ | ✅ | ✅ | ✅ "Forget %@?" as the one alert sheet, naming every binding it drops, the remembered ones of pads that are unplugged included; for a Moonlight host it says the host keeps its own record of this device |
| Protocol chip | ✅ | ✅ | ✅ | ✅ |
| App-wide microphone chip with mute-all | ✅ | ✅ | ✅ | ✅ header chip: live, muted or hidden; one click mutes or unmutes every armed mic |
| Capability verdict word "Supported" | ✅ | ✅ | ✅ | ✅ "What carries" on every bound slot: pad ∩ Mac ∩ type ∩ host, Off and Pending distinct |
| Pairing secrets stored encrypted | ✅ Moonlight key · ❌ Satellite key | ✅ DPAPI | ✅ Secret Service | ✅ Keychain |
| Six languages (en, bs, de, es, fr, pt-BR) | ✅ | ✅ | ✅ | ✅ every word, plural forms included |
| Per-controller motion, rumble and touchpad switches | ✅ | ✅ | ✅ | ✅ the chips on Home's binding strip, clickable in place, and the switches on Configure binding; the light bar stays global, as on the desktops |
| Home: the signal-path diagram | – | ✅ | ✅ | ✅ a boxed row per pad (pad node, a wire captioned with the measured rate and latency, the host node with its address, link chip and "slot n of 4"), the binding strip with Edit ›, ghost "Bind…" cards that open Set up on the pad, "Set up a controller" and the empty state's "Set up Dish ›" into the walk, and the events / sends / total footer; no row menu yet |
| Controllers: a card per pad | – | ✅ | ✅ | ✅ dot, name, player number, family and rate (GameController hides the transport, so no Bluetooth / USB word), "Bound · host ›", Gyro / Touchpad / Lightbar / battery chips, the mic's live / muted button, the motion rate, the input path ("Standard" / "Direct") with its one reason, "Press any button on this controller" until a real change proves the path, "Not responding?" (a 5 s check, "Press A now", then a finding with Use Direct, Help support this controller or the connection hint), the desktops' Input path segmented control only where both paths work (never for the N64), an outline that lights while the pad reports input, a Direct pad's menu (Check the buttons, Help support this controller) and the "Layout guessed" chip, Dead zones…; no Poll Hz (that is the Direct path's figure); after the pads, a card per Steam Controller model Dish could read directly (what reading it does, Use Direct, macOS's refusal with Open System Settings, a receiver waiting for its controller, Stop reading directly) |
| Configure binding: a draft and one apply | – | ✅ | ✅ | ✅ Input · Destination (satellites and Moonlight hosts with link chips) · Functions · Emulate as · What carries, Unbind / Cancel / Apply; the in-page "Applying binding…" overlay (Binding, Applying on the host, done or why not), cancellable until the host's link is up, 8 s for the host to answer; "Leave without applying?" on a dirty draft |
| Per-pad dead zones | – | ✅ | ✅ | ✅ stick and trigger sliders (0–30 %) with live readouts under `deadzone:<id>` in the desktops' `{"s","t"}` shape, applied as the pad attaches and as they move; Reset to defaults (10 % · 5 %) |
| Light, dark and system theme | ✅ | ✅ | ✅ | ✅ |
| Views are layout: one state per page from a pure mapper, intents only | ✅ composers / ViewModels, never an Activity | ✅ the QML contract ("AppViewModel is a thin adapter") | ✅ the same | ✅ enforced by `ViewPurityTests` (no clock, IO, formatting, subscription, engine object or domain decision in a view; only `AppModel`, `NavigationStore` and the toast centre observed) and `NavigationCoverageTests` (every destination and page titled, drawn and mapper-tested) |
| First-run welcome | – (replaced by the guided setup) | ✅ four pages, dots, Back / Skip / Next / Finish, Esc = Skip | ✅ the same | ✅ the same, full-window over the shell; Skip and Finish set `onboarding_welcome_completed`, Finish opens Set up |
| Setup wizard: the one way a binding is created from scratch | ✅ guided setup (Input / Destination / Binding) | ✅ Input · Destination · Type · Session · Feel · Review, three stages, one apply | ✅ the same | ✅ the same as a page on Home (`SetupWizardMachine` in DishCore): Session for Moonlight only, Pair… with the inline card on Destination, one Bind through the apply overlay, "Leave setup?" past page 1, Connection lost / Controller unplugged in the page with Start over / Exit; from the rail's Set up, Settings, Home's empty state and invitation, a pad's ghost Bind…; no Direct path question (each pad's path is decided by its model and GameController's support) |
| Help & FAQ | ✅ | ✅ | ✅ | ✅ the desktops' sections and answers word for word, folded until opened, "Walk me through setup", the privacy policy and the source |
| Permission priming before the system asks | ✅ USB, Bluetooth, local network, microphone | – | – | ✅ local network: "Show me the prompt" on Connections and in Set up before the first scan ever (`local_network_primed`); a refusal offers Open System Settings in the empty state and the toast; the microphone is still asked at its first use · ⚠️ Input Monitoring: the 2026 Steam Controller's offer says macOS asks first (its one interface carries its keyboard and mouse), macOS's prompt comes with the Use Direct click, and a refusal shows on its card with Open System Settings (Privacy & Security › Input Monitoring) |
| Emulate-as type picker (from the catalog) | ✅ (#280: the DualSense Edge, type 4, last and never the default) | 🔜 | 🔜 | ✅ on Configure binding: Auto (the family's type from `emulates`) or a pick, kept with the binding across restarts; a catalog's DualSense Edge (type 4) is offered last and Auto never lands on it (the DualSense is the first `ps5` type); "What carries" has an Extra buttons row (the pad sources the word ∩ the type renders some of it, no switch, no host say) whose type-layer reason points at the Edge; not yet tried against a host that offers the type |
| Layout guessed | – | ✅ (the Direct card's badge) | ✅ (the same) | ⚠️ the desktops' "Layout guessed" chip on a generic Direct pad whose model is not in the verified table (by vendor, as `isKnownFastLaneModel`), on its Controllers card (a click opens Check the buttons) and as its Diagnostics card's chip; unverified on hardware here |
| Check the buttons (per-model remap) | – | ✅ Configure controls (click a row, press the input) | ✅ (the same) | ⚠️ a guided press-to-assign walk over A B X Y LB RB Back Start Guide L3 R3, the d-pad, both triggers and each stick's Y direction ("Press the button you want as A"; Skip, Reset to defaults, Check again), each landing stored at once under `joystick_remaps` in the desktops' fields (Guide in one extra field `gd` the desktops ignore) and applied from the next report through a fixed table on the reader's thread; only for pads read through their descriptor; sticks are read by usage and not walked; unverified on hardware here |
| Help support this controller | ❌ | ❌ | ❌ | ⚠️ a guided 14-step capture (at rest, A B X Y, the shoulders and triggers, Select, Start, d-pad up, each stick up; Skip per step) over a Direct pad, a check's "no input Dish can decode" finding or a Diagnostics "Other input devices" card, the device opened alongside macOS (never seized); VID:PID, product, manufacturer, transport, the HID report descriptor and each step's distinct reports as hex, copied by the user and pasted into a GitHub issue the app opens with its title; nothing is sent; not yet run against a device |

## 2. Input, pad to host, by path (cell = USB · Bluetooth)

| | Android | Windows | Linux | macOS (this) |
|---|---|---|---|---|
| Buttons, sticks, triggers | ✅ · ✅ | ✅ · ✅ | ✅ · ✅ | ✅ · ✅ (sticks up-positive like XUSB; Guide from the pad's Home button) |
| Nintendo Switch Online N64 pad | ✅ · ✅ (2.4.0, #244: the N64 table, C buttons rail the right stick) | ⚠️ · ⚠️ (Switch Pro decoder, or SDL in Standard) | ⚠️ · ⚠️ (the same) | ⚠️ · ⚠️ read Direct from its 0x30 reports (`hid:057e:2019`) under Android's N64 table (Z / ZR → LT / RT 255, Home → Guide, Capture → Back, C buttons → RY / RX ±32767), because GameController lists it and delivers none of its input; run on a Mac over USB on 2026-10-27: macOS's driver leaves the pad silent, and after dish-android's start sequence (handshake, timeout disable, full report mode) the pad streamed ~80 reports/s, its presses reaching the satellite; since 2026-11-11 it gets the Pro's start (the handshake at 3 Mbit before the timeout disable, then full report mode and the IMU enable, as Linux's hid-nintendo and SDL send every Switch pad), not yet run on an N64; Bluetooth unverified (same layout); its GameController controller gets no input slot (R7) and carries rumble and the player lights when it is the only one; never offered Standard |
| Nintendo Switch Pro and SNES Online pads | ✅ · ✅ | ⚠️ · ⚠️ | ⚠️ · ⚠️ | ⚠️ · ⚠️ read Direct by model under Android's Pro table (Home → Guide, ZL / ZR → LT / RT 255), the Pro's motion from its three IMU frames (Android's axis rotation; roll and the accel signs unverified on hardware); the Pro may be sent back to Standard when GameController shows it (`usb_path_choices`); a Pro run on a Mac over USB on 2026-11-11: macOS's driver leaves it silent, dish-android's start sequence leaves it silent too, and the handshake, the switch to 3 Mbit, the handshake again and the timeout disable bring ~75 full reports/s (`SwitchProLiveTests`, `DISH_LIVE_SWITCH_PRO=1`), its idle report decoding to nothing held, the extended-buttons word included (the live harness gained that check too, but no Pro was on this Mac's USB when it ran on 2026-11-13); presses not yet run, so Capture as `misc1` (shared byte 0x20, SDL's SWITCH_SHARE) rests on the byte fixture; its IMU frames read zero until the IMU enable (subcommand 0x40) follows full report mode, which Dish sends since 2026-11-12: at rest the accelerometer then reads about 1 g (`SwitchProLiveTests`), the axis signs still unverified; the SNES pad unverified on hardware |
| A second identical Nintendo pad | ✅ · ✅ | ⚠️ · ⚠️ | ⚠️ · ⚠️ | ⚠️ · ⚠️ its own lane and slot (`hid:057e:2019#1`) and player number; GameController keeps one controller for pads that share a USB serial (the Pro and the N64 both say `000000000001`), so with two pads of a kind which carrier drives which is unknown and rumble is unavailable, said so on the card |
| Pads GameController does not support (generic HID) | ✅ · ✅ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ read Direct when `supportsHIDDevice` stays no over ~30 ms and the report descriptor decodes (the desktops' parser, button orders and known-models table); "Layout guessed" unless the model is in the verified table; unverified on hardware here |
| Steam Controller (2015: 28de:1102, receiver 1142) | ✅ (USB, verified on a wired pad) | ⚠️ (never verified) | ⚠️ (never verified) | ⚠️ · ❌ opt-in Direct: offered on Controllers and opened only on Use Direct (stored per model); the vendor interface, no permission needed; the desktops' decoder (sticks, triggers, buttons, gyro and accel), both trackpads raw through SDL's ±15° shell rotation to the trackpad router (the Trackpads row below; a left-pad click with no finger on it stays the stick's click), the grips as `leftPaddle1` / `rightPaddle1` and the full-pull trigger bits as the trigger clicks on the extended-buttons word, the quiet sequence on claim and the restore on every release and on quit; the receiver's slots asked for their controller and each a pad while it is there; no rumble (no motors) and no battery of its own (the Mac's is sent); BLE pads not read; unverified on hardware here |
| Steam Controller (2026: 28de:1302, receivers 1304 and 1305) | 🔜 (this cycle) | 🔜 (this cycle) | 🔜 (this cycle) | ⚠️ · ❌ opt-in Direct as the 2015 pad, from SDL's driver: the state reports (0x42, 0x45, 0x47) with QAM as `misc1`, R4 / L4 / R5 / L5 as the four paddles, the trigger clicks and the stick and grip touches on the extended-buttons word (the pad touches have no slot in it), both trackpads (18 / 24 on 0x42 and 0x45, 20 / 26 on 0x47, each live on its touch bit) and their clicks to the trackpad router (the Trackpads row below), the battery report into the battery rule, the receiver's wireless status (0x79, 0x46), lizard mode off and the IMU on at claim and lizard mode off again every 3 s, its haptic rumble report; macOS asks for Input Monitoring before the open; the receiver's slots 2–5, never its pogo pins; BLE (1303) not read; unverified on hardware here |
| Pads without the extended profile (SNES, micro-profile pads) | ✅ · ✅ | ✅ · ✅ | ✅ · ✅ | ⚠️ · ⚠️ the generic table of Apple's `GCInput…` names; the family is Nintendo (emulated as the Switch Pro by `emulates`) when the framework's words name one |
| Motion | ✅ · ✅ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (GCMotion on DualSense and DualShock 4) |
| Touchpad | ✅ · ⚠️ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (DualSense and DualShock 4 profiles) |
| Steam Controller trackpads: the per-slot pick `stick` / `pad` / `mouse` / `off` | ✅ · – (#281) | 🔜 · 🔜 (branch `steam-trackpad-pick`) | 🔜 · 🔜 (branch `steam-trackpad-pick`) | ⚠️ · ❌ the Trackpads picker on Configure binding and the chip on Home, on the existing per-controller touchpad pick (`touchpad_mode_preferences`, `stick` beside the wire's words, written only once chosen): `stick`, the 2015 pad's default, the right pad as the right stick with its click as R3 and the left pad's click as `leftPadClick`; `pad`, the 2026 pad's default where the emulated type has a touchpad, the left pad on the surface's left half as finger 0 and the right on the right half as finger 1, either click the surface's click; `mouse`, chosen only and held to the host's `mouseControl`, the right pad as the cursor and left button, the left pad's click as the right button and its vertical travel as the wheel (4096 pad units per notch, the remainder carried; the 16-byte frame of a protocol-1 session carries neither); `off`, both clicks on the extended-buttons word; `stick` and `off` declare `touchpadMode` off, `pad` `ds4`, `mouse` `mouse`; the 2026 pad is never offered `stick` (it has a real right stick) and a stored pick the model does not offer falls to its default; `SteamTrackpadsTests` pins that every pad position lands in at most one wire field and every click in exactly one; the lane reads the pick off an atomic word per report and `LockLawTests` runs a Steam lane beside the Switch Pro's; unverified on hardware here |
| Battery | ⚠️ · ✅ | ⚠️ · ⚠️ | ⚠️ · ⚠️ | ⚠️ · ⚠️ |
| Controller mic | ✅ · ❌ | ✅ · ❌ | ✅ · ❌ | ⚠️ · ❌ (the USB audio function; unverified on a pad) |
| Extra buttons (protocol 4: paddles, Capture, the Steam clicks and touches) | ✅ · – (#279: both Steam Controllers, the Switch Pro, a Direct DualSense Edge) | 🔜 · 🔜 | 🔜 · 🔜 | ⚠️ · ❌ Direct only, from the Steam Controllers and the Switch Pro (the rows above); a DualSense Edge is read through GameController, and `GCDualSenseGamepad` exposes no paddle or Fn button in the macOS 27.2 SDK (`GCInputLeftPaddle` / `GCInputRightPaddle` are racing-wheel names, the Xbox paddles `GCInputXboxPaddleOne…Four`), so an Edge's back buttons are not sourced; Dish reads no DualSense directly, so SDL's input byte 10 bits do not apply; an Xbox Elite's paddles through `physicalInputProfile` are a follow-up |

The macOS client has two input paths, one per pad: Standard
(GameController.framework) and Direct (Dish's own HID reader). Direct reads
the HID reports alongside macOS, opened without seizing the device (seizing a
game controller is not possible through public API and would blind
GameController), and sends a pad nothing but the Switch start sequence and
a claimed Steam Controller's own configuration and rumble: rumble and the
player lights of any other Direct pad ride GameController's controller for
it when the pairing is unambiguous. Nintendo's pads are Direct by model;
Valve's Steam Controllers only on the user's pick; any other pad is Direct
only when GameController does not support it. A Nintendo controller
GameController lists while Dish's reader has no lane of its model (a pad
the reader missed, a Bluetooth pad that did not match) is read through
GameController after a 2 s settle window, "Dish couldn't read it directly,
so macOS reads it", and stays so for the connection.

## 3. Receiving, host to pad, by path (cell = USB · Bluetooth)

| | Android | Windows | Linux | macOS (this) |
|---|---|---|---|---|
| Rumble | ✅ · ✅ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (CoreHaptics engines per handle; the 2026 Steam Controller's own haptic rumble report, re-sent every 40 ms until the host's hold ends; none for the 2015 one, which has no motors) |
| Lightbar | ✅ · ⚠️ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (`GCController.light`) |
| Adaptive triggers | ✅ · ❌ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (the API's shapes; GameController carries them over both links) |
| Player LEDs | ✅ · ❌ | ✅ · ⚠️ | ✅ · ⚠️ | ✅ · ✅ (DualSense, by player index) |
| Mic lamp | ✅ · ❌ | ✅ · ❌ | ✅ · ❌ | ⚠️ · ⚠️ (a chip on Home's binding strip, not the pad's lamp) |
| Controller speaker | ✅ · ❌ | ✅ · ❌ | ✅ · ❌ | ⚠️ · ❌ (unverified on a pad) |
| HD haptics | ⚠️ · ❌ | ⚠️ · ❌ | ⚠️ · ❌ | ⚠️ · ❌ (channels 3–4 of the DualSense stream; unverified on a pad) |

## 4. Decisions, not gaps

- **Two input paths, never both for one pad.** GameController is not the
  only way an unsigned, unentitled macOS app reads a pad: an IOHIDManager
  opened with `kIOHIDOptionsTypeNone` reads gamepad usages with no Input
  Monitoring permission and no entitlement. Each pad's source lives in one
  pure machine and is sticky for a connection; a Nintendo controller
  GameController lists gets no input slot of its own while Dish reads the
  pad (R7). Direct sends nothing an Apple driver could trip on: the Switch
  start sequence only to a pad that stays silent, and the Steam
  Controllers' configuration and the 2026 pad's rumble only to Valve's own
  interfaces, which no Apple driver claims. Rumble on any other Direct pad
  rides GameController.
- **Steam Controllers are read only on the user's word.** Reading one turns
  its keyboard and mouse emulation off (the 2015 pad until it reboots), so
  it is never auto-claimed, as on the desktops: Controllers offers the
  model, Use Direct opens it, stores the pick and quiets it, and Stop
  reading directly (Standard, the hand-back) or quitting Dish restores it.
  The 2026 pad's one interface carries its keyboard and mouse, so macOS
  asks for Input Monitoring at that open (IOHIDFamily's
  `RequiresTCCAuthorization`); a refusal stays on the card until the pad is
  picked again or reconnects. No pad of either kind was attached to the Mac
  this shipped from: the decoders are pinned by the desktops' hardware-run
  vectors (2015) and SDL's structs (2026), the rest through fakes.
- **An 8BitDo pad in X-input mode is not readable on a Mac.** In that mode
  the Ultimate 2 (2dc8:310b) speaks the Xbox 360 protocol on a vendor-class
  USB interface. macOS's own driver for it, `XboxGamepad.dext`, binds only
  Microsoft's 045e:028e (and three Xbox One and Series pads) by exact
  identity, so the 8BitDo gets no driver, no HID device and no
  GameController controller, and neither of Dish's paths can see it. Its
  D-input mode (2dc8:6012) is a HID gamepad both paths can read; a reader of
  the raw USB interface is not built.
- **Mouse mode is the pad's own touchpad routed by the host**, as on
  Android: the pick is per controller, the descriptor declares `mouse` only
  when the pad has a touchpad and the host advertises mouse control, the
  session PUT asks for `hostFeatures.mouseControl` whenever a bound pad is
  picked as the mouse, and a pick that changes that desire mid-session
  re-PUTs the whole session through the re-key path (the grant is computed
  only at the session PUT), so the socket and the hot path never blip. A
  Steam Controller picked as the mouse composes its right trackpad as the
  cursor and its left as the wheel and the right button on the version-2
  POINTER frame; the 16-byte frame of a protocol-1 session carries neither.
- **Controller identity is the vendor name and product category**, because
  GameController vends a fresh object on every reconnect and exposes no
  per-unit identifier. Two identical pads take ordinals in the order they
  attach, so a remembered binding returns to the pad that takes its ordinal.
- **The Android-only surfaces** (on-screen pad, skins, Bluetooth HID host
  mode, Play billing, store screenshots) do not apply.
- **XUSB carries no Share button and no paddles**, so a pad's Share and
  paddle buttons stay unmapped, as on the other clients; Guide is the pad's
  Home button.
- **Two batteries, the lower one.** MSG_BATTERY carries the lower of the
  pad's own battery and the Mac's, on the GameController and the Direct
  path alike and whatever the link (`lowestBattery`, the desktops' rule): a
  pad with no battery, or one whose level is unknown, sends the Mac's (a
  desktop Mac on mains reads 100 % wired), an unknown level sorts above
  every known one, a tie goes to the pad and the status travels with the
  reading that wins. The card keeps the pad's own reading, or the Mac's for
  a GameController pad with none; the Mac's IOKit snapshot is read on a
  utility queue, never on the main actor or the HID reader's thread.
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

1. Exclusive capture (decided: not built). Dish reads the pad alongside the
   frontmost app. Seizing it is not possible through public API (an Apple
   frameworks engineer, Apple Developer Forums thread 775975), and seizing
   the HID device would blind GameController, Dish's Standard path; the
   Direct reader and the support capture open pads without seizing them.
2. A run against a live Moonlight host: Sunshine and Wolf, a DualSense and
   an Xbox pad, the resume path and a host that ends the session. (Theme,
   background mode, keep-awake modes, the update check, About, the Emulate
   picker, "What carries", the motion word, the link tier, Diagnostics and
   its inspector, the crash log, the per-controller switches, controller
   audio, mouse mode and the Moonlight host path shipped.)
3. A run on both Steam Controllers: the 2015 pad wired and on its receiver,
   the 2026 pad wired and on its Puck; lizard mode off while Dish reads it
   and back after Stop reading directly and after quitting, macOS's Input
   Monitoring prompt and a refusal, the motion signs, the 2026 pad's
   battery and rumble, and a receiver's controller turned off and on. The
   2015 pad's own battery (its status packet) and the Bluetooth pads of
   both generations come after it.
