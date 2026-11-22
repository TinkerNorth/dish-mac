# Parity: dish-mac against the other Dish clients

> **What this is.** The feature-parity ledger for this client, kept as a small
> matrix. **A pull request that changes a row updates this file in the same
> change**, and a reviewer checks the row. Coverage is not mapped here: the
> suites under `Tests/` are the coverage truth and CI runs them on every push.
>
> Legend: ✅ works · ⚠️ shipped, not yet verified on real hardware · ❌ not
> available · – not applicable · 🔜 decided and in progress. Verified against
> the code on 2026-10-27; section 6 on 2026-11-22.

## 1. What works, per client

| Feature | Android | Windows | Linux | macOS (this) |
|---|---|---|---|---|
| Satellite host, protocol 4 | ✅ (#278) | ✅ (#121) | ✅ (#104) | ✅ offers 4, settles on the satellite's range, re-offers on an overlapping 409; a session settled on 4 sends the 17-byte input frame with the extended-buttons word, 13 bytes below; the `extendedButtons` cap is claimed for a pad that fills the word (both Steam Controllers and the Switch Pro read Direct, and an Xbox Elite Series 2 through GameController; see section 2's "Extra buttons" row) |
| Satellite pairing: the operator's approval and the typed PIN | ✅ request on open, 2 s poll for 120 s | ⚠️ both at once (1 s poll), but the typed PIN waits for six digits on `main` (S-W1) | ⚠️ the same (S-L2) | ✅ both at once on the row's card: a four-digit request the operator approves on the satellite (2 s poll for 120 s; a decline or expiry offers a new code) beside the satellite's PIN typed into four cells; the first to land opens the session and stops the other; closing the card or leaving the Connections page cancels the poll |
| Pads per satellite | ✅ each on the lowest free index | ✅ four ("slot n of 4") | ✅ the same | ✅ four (`SatelliteSlots.maxPerSatellite`), each on the lowest free controller index for as long as it stays bound: its own descriptor in the session PUT and its own `PUT` / `DELETE /api/connections/{id}/controllers/{idx}` while live, its own route on the hot path, its rumble, light bar, trigger effects, player LEDs, speaker, haptics and mic lanes by that index, and both ends of the heartbeat bitmap reconcile over every index; Home says "slot n of 4", the satellite's card lists every pad, Diagnostics shows each pad's index; a fifth is not offered |
| Bindings survive a restart | ✅ Moonlight bindings (2.3.0); satellite bindings from the remembered satellites | ✅ standing bindings (2.2.0) | ✅ the same | ✅ satellite bindings under `wifi_binding_list` (the satellite and the type picked), Moonlight bindings read back from `moonlight_binding_list`; bound again once the pad is attached and its satellite is in the pool or its host on record, whichever is later, and again whenever the pad returns; Unbind and Forget end them, a satellite's refusal does not |
| Moonlight host (Sunshine / Apollo / Wolf) | ✅ | ✅ | ✅ | ⚠️ discovery, PIN pairing with mutual TLS after, one session per host for up to four pads (launch or resume, RTSP, media pings, the ENet control stream), motion / touch / battery up and rumble / light bar back, the app picker and the Emulate pick per pad; every wire piece pinned against Wolf's captures and the whole path run against a loopback host (`IntegrationMoonlightFakeHostTests`), not yet against a live one |
| Mouse mode on the host | ✅ | ❌ | ❌ (deferred) | ✅ per-controller pick Off / Pad / Mouse; the request rides the session PUT and a flip mid-session converges through the re-key path |
| Controller audio (mic + speaker) | ✅ (the caps follow the host's grant and a refused output since #292) | ✅ | ✅ | ⚠️ over the DualSense's and DualShock 4's USB audio function through Core Audio, Opus through AudioToolbox; mic and speaker switches per controller, the mic off until asked, each pad's lanes on its own controller index; the `mic` and `speaker` caps ride the descriptor only while the pad's function is reachable, the switch is on, the satellite's probe grants the direction and the system opened the endpoint, and a refused output or microphone withdraws them until the endpoint changes (`audioPlan` is the one rule the voices and the descriptor read); not yet verified on a pad |
| DualSense HD haptics | ⚠️ (the cap follows the host's grant and a refused output since #292) | ⚠️ | ⚠️ | ⚠️ the haptics lanes on channels 3–4 of the DualSense's four-channel USB stream, under the speaker switch; the `hapticAudio` cap follows the same rule as the speaker's, so a lane the Mac will not open is never promised and the satellite reduces the haptics to rumble instead; the inspector plays its test tone on the lanes (`haptics.play`); none over Bluetooth (section 6); not yet verified on a pad |
| Adaptive triggers, player LEDs, mic lamp | ✅ | ✅ | ✅ | ⚠️ triggers through GameController's adaptive-trigger shapes (feedback, weapon, vibration; galloping resets) · ✅ player LEDs on a DualSense · ⚠️ mic lamp as a chip on Home's binding strip (GameController reaches no DualSense lamp) |
| Lightbar, motion, touchpad, battery | ✅ | ✅ | ✅ | ✅ lightbar, motion, touchpad · ✅ battery: the wire carries the lower of the pad's own and the Mac's on both paths (a pad with none sends the Mac's), the card shows the pad's own |
| Crash reports (opt-out) | ✅ Crashlytics | ✅ Sentry | ✅ Sentry | ✅ Sentry (sentry-cocoa) behind "Share crash reports", on by default, armed only by an official build; the local redacted log and its report card stay |
| Update notice | – Play · ✅ GitHub build | ✅ | ✅ | ✅ `latest.json` from the release permalink; once per version, skippable, floor warning |
| The window: the desktops' shell | – (Activities, two panes on sw600dp) | ✅ rail (labelled 236 px, 48 px icons, persisted) + per-page header + pushed pages, one toast host | ✅ the same | ✅ the same in SwiftUI: `NavigationSplitView` rail (236 pt labelled, icon strip collapsed, persisted as `ui_rail_collapsed`), per-page header (back chevron, title, streaming pill with Configure, mic chip, status line), a `NavigationStack` of pages, one toast host, 980×640 (min 900×620); no sheets at all (the pairing card and the Moonlight PIN are inline cards in their rows); ⌘, · ⌘1-3 · ⌘[ ; the Set up action between the rail's groups |
| Runs in the background / window closed | ⚠️ | ✅ tray | ✅ tray | ✅ menu-bar item (closing the window keeps streaming; off in Settings quits) |
| Survives PC sleep and resume | – | ✅ Satellite | ✅ Satellite | ✅ Satellite and Moonlight (sleep releases held input and closes every session, a satellite's with its `DELETE`; wake reopens them and rescans; a lid that closed on a stream is said once) |
| Keep-awake is user-configurable | ❌ | ✅ | ✅ | ✅ off · while playing (stillness window) · while connected; display optional; a closed lid still sleeps the Mac (no API keeps a lidded Mac awake: `IOPMLib.h` calls `kIOPMAssertionTypePreventSystemSleep` "not supported in any OS X releases"; clamshell mode needs power and a display) |
| Input while another app is in front | – (stops by design) | ✅ | ✅ | ✅ GameController's background monitoring, on from the first connect (broken in macOS 15.4, fixed in 15.5) |
| Diagnostics screen | ✅ | ✅ | ✅ | ✅ page (pushed from Settings, or opened by the menu-bar item): session facts for satellites and Moonlight hosts (the session's standing, the app, the control round trip, each pad's reports), each controller down to the wire, the flight recorder, and the controller inspector (live input, motion and touch, the drift and range stick tests on the raw sticks, and the bench: every feedback and audio item the pad's path carries, section 6) |
| Inspector: the extended buttons, the pointer's right button and its wheel | ✅ (#282) | ✅ (#129) | ✅ (#112) | ✅ the Pressed line names the extended buttons after the XUSB ones, in wire-bit order ("Pressed: A · Left paddle 1 · Misc 1", SDL's "Misc 1" in every language), and a line under the touchpad readout shows the pointer's right click and a wheel turn ("Right click · Wheel -120"), hidden with neither; the pad's record keeps each pointer frame's wheel step beside its touch, so the line shows the last frame's turn; the pads that fill the word are section 2's "Extra buttons" row, the frame's right button and wheel the Mouse pick's ("Steam Controller trackpads") |
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
| Emulate-as type picker (from the catalog) | ✅ (#280: the DualSense Edge, type 4, last and never the default) | ✅ (#123: the DualSense Edge, type 4, listed last; only a real Edge's `emulates` hint or the user's pick lands on it) | ✅ (#106: the same) | ✅ on Configure binding: Auto (the family's type from `emulates`) or a pick, kept with the binding across restarts; a catalog's DualSense Edge (type 4) is offered last and Auto never lands on it (the DualSense is the first `ps5` type); "What carries" has an Extra buttons row (the pad sources the word ∩ the type renders some of it, no switch, no host say) whose type-layer reason points at the Edge; not yet tried against a host that offers the type |
| Layout guessed | – | ✅ (the Direct card's badge) | ✅ (the same) | ⚠️ the desktops' "Layout guessed" chip on a generic Direct pad whose model is not in the verified table (by vendor, as `isKnownFastLaneModel`), on its Controllers card (a click opens Check the buttons) and as its Diagnostics card's chip; unverified on hardware here |
| Check the buttons (per-model remap) | – | ✅ Configure controls (click a row, press the input) | ✅ (the same) | ⚠️ a guided press-to-assign walk over A B X Y LB RB Back Start Guide L3 R3, the d-pad, both triggers and each stick's Y direction ("Press the button you want as A"; Skip, Reset to defaults, Check again), each landing stored at once under `joystick_remaps` in the desktops' fields (Guide in one extra field `gd` the desktops ignore) and applied from the next report through a fixed table on the reader's thread; only for pads read through their descriptor; sticks are read by usage and not walked; unverified on hardware here |
| Help support this controller | ❌ | ❌ | ❌ | ⚠️ a guided 14-step capture (at rest, A B X Y, the shoulders and triggers, Select, Start, d-pad up, each stick up; Skip per step) over a Direct pad, a check's "no input Dish can decode" finding or a Diagnostics "Other input devices" card, the device opened alongside macOS (never seized); VID:PID, product, manufacturer, transport, the HID report descriptor and each step's distinct reports as hex, copied by the user and pasted into a GitHub issue the app opens with its title; nothing is sent from the page; the first twenty reports, repeats included, are kept with their arrival times for the diagnostics file's `usb-descriptors-v1` capture; not yet run against a device |
| Controller database (`/controllers/v1/`, dbVersion 1) | 🔜 | 🔜 | 🔜 | ✅ bundled byte for byte in DishCore's resources with its manifest (272 records, verified against the manifest at launch); the index from `vid:pid` to record, the cached download in force only when its `dbVersion` is greater; the check ten seconds after launch and every six hours, manifest with `If-None-Match`, each file's SHA-256 and size verified, parsed, schema 1, swapped whole; results `upToDate`, `updated`, `offline`, `invalid`, `off`; Settings' "Check for controller updates automatically" (on by default; off, no request is made, proven over a recording gateway) and "Check now" (sends nothing while the switch is off) |
| The Direct table generated from the data (contract §6.1) | 🔜 | 🔜 | 🔜 | ❌ the Mac's Direct policy is its own table (`directModels`) until the data's `platforms.mac` override is populated: no record carries one in dbVersion 1, and the data's `auto` / `optIn` rules are Android's. `BundledControllerDbTests` checks the table against the data instead: every row has a record of the same identity whose family is the row's decoder (and whose mapping is a HID row's order), and every record of a family the table reads whole is a row or an identity the Mac declines (the Joy-Cons, their charging grip, the PDP Afterglow) |
| Served rows on the Direct path | 🔜 | 🔜 | 🔜 | ⚠️ both readers read the table first, then the data in force as each pad attaches, so a row that arrives while the app runs applies at the pad's next attach (contract §6.5): the HID reader for the families it decodes (`switchProUsb`, `switchN64Usb`, `hid`, the three Steam families), its matching, set as it starts, meeting the game usages and every device of the vendors the table reads by identity (Nintendo's, Valve's); the XUSB reader for `xinput360`, its bus watching every USB device and asking the reader, as each arrives, whether to configure it. A served rule still waits for GameController's answer (`auto` and `whenOsCannot` read as `whenMacOSCannot`, `optIn` as opt-in); an opt-in Xbox 360 row is not applied, since the XUSB reader opens a pad as it arrives and has no claim to wait for (80 imported rows in dbVersion 1); Microsoft's own Xbox 360 Controller (045e:028e) is declined, since macOS's XboxGamepad.dext has personalities for its device and its XUSB interface (read on macOS 27.2); an inert record (a family or op this build lacks) shows its name and issues only. An opt-in row the game usages do not meet, of another vendor, is matched by identity only from the next launch; dbVersion 1 has none. No served row has been run on hardware |
| Expect check at attach | 🔜 | 🔜 | 🔜 | ⚠️ IOHID shows report sizes, not endpoints: `endpoints.in` / `endpoints.out` are compared as "an input / output report path exists" (`kIOHIDMaxInputReportSizeKey`, `kIOHIDMaxOutputReportSizeKey` above 0), so a pad whose output goes by SET_REPORT over the control pipe reads as having one; the XUSB reader compares its real interrupt pipes; a size IOKit does not give is not compared. Mismatches in the contract's form on the Diagnostics card and in the bundle |
| Last write (client to pad) | 🔜 | 🔜 | 🔜 | ✅ every Direct write's verdict (the Switch start sequence, a Steam Controller's feature and output reports, an XUSB pad's rumble): route, report id, IOKit's answer by name, time; posted through a lock-free mailbox, taken on the Diagnostics tick, a "Last write" row on the card and `lastWrite` in the bundle |
| Last feedback (host to client) | 🔜 | 🔜 | 🔜 | ❌ no "Last feedback" row yet; the bundle's `lastFeedback` is absent |
| "Did it work?" after each test | 🔜 | 🔜 | 🔜 | ✅ after every bench test, asked once the test has ended and answered with the time it ended (`PadTestLedger`, the contract's rule 4); answers `worked` / `didNotWork` on the contract's test names (`rumble.weak`, `rumble.strong`, `rumble.both`, `triggerRumble.left`, `triggerRumble.right`, `triggerRumble.both`, `lightbar.cycle`, `playerLeds.cycle`, `trigger.pulse`, `tone.play`, `haptics.play`, `mic.level`, `stick.drift`, `stick.range`; never `lamp.on` or `lamp.pulse`, section 6), twenty per pad for the run, in the bundle; a run another run replaced, or one cut short by the pad's audio going away, asks nothing |
| The bench: every item the path carries (contract "The bench") | 🔜 | 🔜 | 🔜 | ⚠️ the inspector offers each item only where the pad's composed capabilities carry it (`benchItems`), section 6 by path: rumble, trigger rumble, the light bar cycle, the player LED cycle, the adaptive-trigger pulse, the test tone on the speaker and on the haptics lanes, the microphone meter, the stick tests; dish-android's strengths and times (48000 for 400 ms, 400 ms a step, 2 s of rigid resistance, the two-note tone with 10 ms fades). A test drives the pad from this Mac alone, bound or not; while it holds the light bar, the player LEDs or the triggers, the game's values for that surface are remembered on the pad's feedback queue instead of written, and its end writes back the game's newest value, or what the surface showed when the test took it (the triggers: no effect); the other surfaces keep following the game. Not yet run on a pad |
| Report a problem (`dish-diagnostics.v1`, second cut) | 🔜 | 🔜 | 🔜 | ⚠️ "Report a problem" and "Ask a question" on Diagnostics open one page (Contact support): the category, the person's words, the controller it concerns (the first attached pad suggested), what the file holds and never holds, Preview file, Continue in Mail (`NSSharingService(named: .composeEmail)`, words first, subject `Dish support: <category> · Dish for macOS <version> on <model>` with only the category translated); "Save diagnostics" saves the first cut's file without a report, a host's own view or the Mac's conditions. Each controller's hardware, rate and audio function and its capture are the rows below. Not yet tried with Mail.app on a Mac |
| A host's own view (`satellite-connection-diagnostics.v1`) | 🔜 | 🔜 | 🔜 | ✅ opening the report asks every live satellite whose probe names 2.3.0 or later for `GET /api/connections/{id}/diagnostics` with the session's proof, all at once, two seconds each; an older one is never asked and gets the `satellite-capabilities` stand-in (its probe's version, protocol, `backends` as listed, `controllerAudio`, the catalog's version) with `olderSatellite`; `unknownConnection` (404), `unauthorized`, `badReply` (a 5xx, or a body that is not the document), `timeout`, `offline` otherwise, each with the stand-in; a refusal never touches the pairing. A Moonlight host gets `moonlight-serverinfo` with its app version only (`state` and `pairStatus` null: the plaintext serverinfo reports every host free and every caller unpaired), never its name. Every string and key of a host's document is aliased like a log line |
| The client's view of each session | 🔜 | 🔜 | 🔜 | ⚠️ a satellite's slots (index, record, requested and applied type by the catalog's slug, backend, result, touchpad mode), the last enriched ack, the RTT window's p50, p99 and samples, and every message kind counted each way (`WireTally`, relaxed); a Moonlight host's pads and its control round trip, with its message kinds not counted (`sent` and `received` null) |
| Every controller path, input and output | 🔜 | 🔜 | 🔜 | ⚠️ `path` is `direct` or `gameController`; `input` the frames the pad's record counts, the rate the telemetry or the Direct reader measured (null while neither has) and the last report published; `output` each lane's count, newest value and time where the pad's feedback lands (`FeedbackTally`, relaxed), rumble's target from its carriage and the last Direct write; `triggerRumble` and `micLed` counts are null (a Moonlight host's trigger rumble is folded into the motors first, and the mic lamp is audio's), `micLed.last` is the lamp the game asked for; `speaker` and `haptics` from the audio plan, a refused endpoint as `refused`; `bluetooth` is `{ "profile": "hid", "transportLayer": … }` with the link IOKit's `kIOHIDTransportKey` names (`hidTransport` keeps it in the transport's value): `Bluetooth` is `classic`, `BluetoothLowEnergy` (the SDK's `kIOHIDTransportBluetoothLowEnergyValue`) and the spaced `Bluetooth Low Energy` hidapi's `mac/hid.c` matches are `le`, any other Bluetooth word is null; a GameController pad takes the transport of the census devices `hardwareId(forPadNamed:)` matches to it, and twins on different links carry the name with no transport; not yet seen with a pad paired to a Mac |
| The Mac's conditions in the bundle | 🔜 | 🔜 | 🔜 | ✅ battery level and charging (null on a Mac without one), `ProcessInfo.thermalState`, Low Power Mode, the Wi-Fi band, RSSI and transmit rate through CoreWLAN (null when not associated), read once off the main actor as the report opens; never the network name or BSSID; `usbHost` measured, never assumed: true when IOKit lists a service of class `AppleUSBHostController`, the class every Mac xHCI controller derives from (3 on the M1 Max this was run on, beside 3 `AppleUSBXHCI`), false when it lists none (a virtual machine without a USB controller; no test asserts true, since CI's runners are such machines), null when IOKit gives no answer; the app ships for Apple silicon only (the published zip's binary is arm64), so the class chain on an Intel Mac is unmeasured and no shipped build runs there |
| A controller's hardware in the file (`bcdDevice`, `descriptorSha256`, `interfaces`, `endpoints`) | 🔜 | 🔜 | 🔜 | ⚠️ read without opening the pad: `bcdDevice` is `kIOHIDVersionNumberKey` (an XUSB pad's, its interface's `bcdDevice`); `interfaces` the IORegistry's `IOUSBHostInterface` entries under the `IOUSBHostDevice` at most three parents above a USB pad (`bInterfaceNumber`, `bInterfaceClass`, `bInterfaceSubClass`, `bInterfaceProtocol`, the SDK's `IOUSBHostFamilyDefinitions.h` keys; null off USB and when no USB device is above, such as the Mac's own "Keyboard Backlight" that calls itself USB); `descriptorSha256` the SHA-256 of the raw USB descriptors, the device descriptor then every configuration descriptor in index order: the configurations come from IOUSBLib's device interface, never opened (IOUSBLib.h: the data "as received from the USB bus", and "the device does not have to be open to use this function"), and the device descriptor is rebuilt from the `IOUSBHostDevice`'s registry fields, each the descriptor's own, so no request goes to the pad; null off USB and where IOKit hands none over; `endpoints` an XUSB pad's pipes as the reader opened them, and a HID pad's first interrupt IN and OUT of its interface (alternate setting 0) in the configuration in force, read from that configuration descriptor. The interfaces and the USB device's entry are read by the census once per device for a GameController pad (taken only when the devices matched to it by name agree), by the HID reader as it attaches a Direct pad, by the XUSB bus as an interface arrives; the descriptors on the main actor once per USB device, as Diagnostics or the report composes. Proven on the Mac's internal SPI keyboard (`VersionNumber` 0352, interface 1); for a service that is no USB device IOKit refuses IOUSBLib's user client (`kIOReturnUnsupported`, measured here); the USB path is unmeasured until a pad is attached, since the Mac it was written on had no USB device (`IOUSBHostDevice` 0) |
| The capture in `usb-descriptors-v1` | 🔜 | 🔜 | 🔜 | ⚠️ the last "Help support this controller" capture rides the pad it was taken of: `device` is the 18-byte device descriptor as hex and `configuration` every configuration descriptor in index order as hex, the pad's USB device's own as the fingerprint reads them (the device descriptor rebuilt from the registry's fields, the configurations from IOUSBLib, never opened), null off USB and where IOKit hands none over; `strings` the manufacturer and product as text keyed by role, null for one the pad does not report, never the serial number; `guided` the guided capture's text as the page formats it for an issue (each step's reports, A, B, X, Y, the shoulders, the triggers, Select, Start, d-pad up, each stick up); `hidReportDescriptors` `kIOHIDReportDescriptorKey` with `source` `os`, the operating system's copy, and its `bInterfaceNumber` (null where IOKit names none, as over Bluetooth); `restReports` the capture's first twenty input reports, repeats included, each with its arrival on the wall clock, taken as the person moves on from "At rest" (a skip takes none). Proven on the Mac's internal keyboard's properties, never opened (interface 1, a 90-byte report descriptor, no USB device); not yet run against a pad |
| `rateHz` and `audio` in the file | 🔜 | 🔜 | 🔜 | ✅ `rateHz` is the rate `input.rateHz` carries, the telemetry's or the Direct reader's count of the reports the app received, null before one is measured; `audio` is the pad's routed USB audio function as Core Audio lists it (`outputChannels`) and whether macOS refused its playback or capture endpoint, null while none is routed |
| `hardware.firmware` | 🔜 | 🔜 | 🔜 | ❌ always null: IOKit names no firmware for a third-party pad (`IOHIDDeviceKeys.h` has `VersionNumber`, which is the `bcdDevice` above, and no firmware key), and a DualSense's firmware lives in its feature report 0x20, which dish-android reads at its own Direct claim; the Mac reads a DualSense through GameController and never opens it to ask |
| `probe` | 🔜 | 🔜 | 🔜 | ❌ always null: the probe that gates a pad on the Mac is GameController's answer (`GCController.supportsHIDDevice`, asked about 30 ms), not a decode of the pad's first reports, and the contract names one value (`decoded`) and no word for a framework's answer |
| A record's issues on the card | 🔜 | 🔜 | 🔜 | ✅ an issue shows while its `status` is `open`, its transport is the pad's or none, its `device` is this Mac's model identifier (`hw.model`) or none, and its `os` is empty or names `macos` (the contract's Mac key) with this major version; its words, like a record's name, come from the strings file of the language the app's pages show (the bundle's pick for the person's preferred language), English for a key that file leaves out: `de-AT` reads `de`, `bs-Latn-BA` `bs`, `pt-PT` and `pt-BR` `pt-BR`, `fr-CA` `fr`, `es-419` `es`, `en-GB` and `ja-JP` `en` (`ControllerStringsLanguageTests`) |

## 2. Input, pad to host, by path (cell = USB · Bluetooth)

| | Android | Windows | Linux | macOS (this) |
|---|---|---|---|---|
| Buttons, sticks, triggers | ✅ · ✅ | ✅ · ✅ | ✅ · ✅ | ✅ · ✅ (sticks up-positive like XUSB; Guide from the pad's Home button) |
| Nintendo Switch Online N64 pad | ✅ · ✅ (2.4.0, #244: the N64 table, C buttons rail the right stick) | ⚠️ · ⚠️ (Switch Pro decoder, or SDL in Standard) | ⚠️ · ⚠️ (the same) | ⚠️ · ⚠️ read Direct from its 0x30 reports (`hid:057e:2019`) under Android's N64 table (Z / ZR → LT / RT 255, Home → Guide, Capture → Back, C buttons → RY / RX ±32767), because GameController lists it and delivers none of its input; run on a Mac over USB on 2026-10-27: macOS's driver leaves the pad silent, and after dish-android's start sequence (handshake, timeout disable, full report mode) the pad streamed ~80 reports/s, its presses reaching the satellite; since 2026-11-11 it gets the Pro's start (the handshake at 3 Mbit before the timeout disable, then full report mode and the IMU enable, as Linux's hid-nintendo and SDL send every Switch pad), not yet run on an N64; Bluetooth unverified (same layout); its GameController controller gets no input slot (R7) and carries rumble and the player lights when it is the only one; never offered Standard |
| Nintendo Switch Pro and SNES Online pads | ✅ · ✅ | ⚠️ · ⚠️ | ⚠️ · ⚠️ | ⚠️ · ⚠️ read Direct by model under Android's Pro table (Home → Guide, ZL / ZR → LT / RT 255), the Pro's motion from its three IMU frames (Android's axis rotation; roll and the accel signs unverified on hardware); the Pro may be sent back to Standard when GameController shows it (`usb_path_choices`); a Pro run on a Mac over USB on 2026-11-11: macOS's driver leaves it silent, dish-android's start sequence leaves it silent too, and the handshake, the switch to 3 Mbit, the handshake again and the timeout disable bring ~75 full reports/s (`SwitchProLiveTests`, `DISH_LIVE_SWITCH_PRO=1`), its idle report decoding to nothing held, the extended-buttons word included (the live harness gained that check too, but no Pro was on this Mac's USB when it ran on 2026-11-13); presses not yet run, so Capture as `misc1` (shared byte 0x20, SDL's SWITCH_SHARE) rests on the byte fixture; its IMU frames read zero until the IMU enable (subcommand 0x40) follows full report mode, which Dish sends since 2026-11-12: at rest the accelerometer then reads about 1 g (`SwitchProLiveTests`), the axis signs still unverified; the SNES pad unverified on hardware |
| A second identical Nintendo pad | ✅ · ✅ | ⚠️ · ⚠️ (each device on USB Direct its own claim and slot since #128; not yet tried with two) | ⚠️ · ⚠️ (the same, #111) | ⚠️ · ⚠️ its own lane and slot (`hid:057e:2019#1`) and player number; GameController keeps one controller for pads that share a USB serial (the Pro and the N64 both say `000000000001`), so with two pads of a kind which carrier drives which is unknown and rumble is unavailable, said so on the card |
| Pads GameController does not support (generic HID) | ✅ · ✅ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ read Direct when `supportsHIDDevice` stays no over ~30 ms and the report descriptor decodes (the desktops' parser, button orders and known-models table); "Layout guessed" unless the model is in the verified table; unverified on hardware here |
| 8BitDo Ultimate 2 Wireless in X-input mode (2dc8:310b, an Xbox 360 XUSB interface) | ✅ · – (Direct: its `XINPUT_360` row) | ✅ · – (Standard: Windows' XInput driver) | ✅ · – (Standard: `xpad`) | ⚠️ · – read Direct by Dish's XUSB reader, since macOS has no driver for it and neither GameController nor IOHIDManager sees it ("macOS does not read it, so Dish does"): IOUSBHost selects the device's first configuration when none is selected (a vendor-class device arrives unconfigured), opens the vendor interface (FF/5D/01) of a model the table names, reads its first interrupt IN endpoint a report at a time under dish-android's XINPUT_360 table (the XUSB button word, 8-bit triggers, up-positive sticks; the word's unassigned bit dropped) and writes its rumble report (each motor's high byte) to the first interrupt OUT endpoint, then the stop once the host's hold ends and before Dish quits, since the pad holds a level until it is sent another; no motion, no extended buttons, no player lights, no support capture; an interface another client holds is refused and the paths hear a `busy` refusal (no slot, logged); `LockLawTests` runs its read loop on its queue in the HID reader's role; unverified on hardware: the configuration, the pipe reads and the rumble (`XusbLiveTests` with `DISH_LIVE_XUSB=1` checks the first two) |
| Other wired Xbox 360 pads (the data's `auto` `xinput360` rows) | ✅ · – (Direct: its `XINPUT_360` rows) | ✅ · – (Standard: Windows' XInput driver) | ✅ · – (Standard: `xpad`) | ⚠️ · – read Direct by the XUSB reader as the Ultimate 2 is, from the data: the 43 `auto` rows of dbVersion 1 beyond the table's (Logitech's F310, F510 and F710 in XInput mode, Mad Catz, PDP, Hori, PowerA, Razer, SteelSeries and the Amazon Luna pads among them); Microsoft's 045e:028e stays with macOS's own driver, and the 80 `optIn` rows are not applied; none has been run on a Mac |
| Steam Controller (2015: 28de:1102, receiver 1142) | ✅ · ⚠️ (USB verified on a wired pad; Bluetooth as a Direct pad since #284, not yet tried on one) | ⚠️ (never verified) | ⚠️ (never verified) | ⚠️ · ⚠️ opt-in Direct: offered on Controllers and opened only on Use Direct (stored per model); the vendor interface, no permission needed; the desktops' decoder (sticks, triggers, buttons, gyro and accel), both trackpads raw through SDL's ±15° shell rotation to the trackpad router (the Trackpads row below; a left-pad click with no finger on it stays the stick's click), the grips as `leftPaddle1` / `rightPaddle1` and the full-pull trigger bits as the trigger clicks on the extended-buttons word, the quiet sequence on claim and the restore on every release and on quit; the receiver's slots asked for their controller and each a pad while it is there; no rumble (no motors) and no battery of its own (the Mac's is sent); over Bluetooth LE (1106) a model of its own, read as SDL reads it on macOS, through IOHIDManager on macOS's HID-over-GATT device (no CoreBluetooth): report 3's 18-byte segments assembled into SDL's chunked state packets (a chunk a packet leaves out keeps its last value; a packet that names more than it carries is dropped) and read through the same mappings, the stick and the left pad each a chunk of its own (the stick's click is its own bit only, as SDL reads it), Input Monitoring asked before the open (its keyboard and mouse share the device), SDL's reset (mappings cleared, defaults loaded, wireless packet version 2, both trackpads off, no smoothed mouse) and raw IMU at claim and the wired restore on release, each one segment on feature report 3, its own slot (`hid:28de:1106`) and stored pick; SDL's attributes query and its `ValveInReport_t` packets over Bluetooth left out, and no rumble or battery there, as in SDL; unverified on hardware here |
| Steam Controller (2026: 28de:1302, receivers 1304 and 1305) | ⚠️ (opt-in Direct from SDL's driver, on its cable and adapters since #269 and over Bluetooth since #284; not yet tried on a pad) | ⚠️ (opt-in Direct from SDL's driver since #119, never verified; its Bluetooth 1303 is never Direct) | ⚠️ (the same, #102) | ⚠️ · ⚠️ opt-in Direct as the 2015 pad, from SDL's driver: the state reports (0x42, 0x45, 0x47) with QAM as `misc1`, R4 / L4 / R5 / L5 as the four paddles, the trigger clicks and the stick and grip touches on the extended-buttons word (the pad touches have no slot in it), both trackpads (18 / 24 on 0x42 and 0x45, 20 / 26 on 0x47, each live on its touch bit) and their clicks to the trackpad router (the Trackpads row below), the battery report into the battery rule, the receiver's wireless status (0x79, 0x46), lizard mode off and the IMU on at claim and lizard mode off again every 3 s, its haptic rumble report; macOS asks for Input Monitoring before the open; the receiver's slots 2–5, never its pogo pins; over Bluetooth LE (1303) a model of its own read as on its cable, as SDL's driver reads it on macOS through IOHIDManager: the state report 0x45, the same settings, lizard refresh and rumble reports, and the battery report should it arrive there (unverified; until one does the Mac's is sent), its own slot (`hid:28de:1303`) and stored pick; unverified on hardware here |
| Pads without the extended profile (SNES, micro-profile pads) | ✅ · ✅ | ✅ · ✅ | ✅ · ✅ | ⚠️ · ⚠️ the generic table of Apple's `GCInput…` names; the family is Nintendo (emulated as the Switch Pro by `emulates`) when the framework's words name one |
| Motion | ✅ · ✅ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (GCMotion on DualSense and DualShock 4) |
| Touchpad | ✅ · ⚠️ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (DualSense and DualShock 4 profiles) |
| Steam Controller trackpads: the per-slot pick `stick` / `pad` / `mouse` / `off` | ⚠️ · ⚠️ (#281, Bluetooth since #284; not yet tried on a pad) | ⚠️ · ❌ (#125: `stick`, `pad` and `off`; `mouse` is not offered while the client's mouse routing, `reducer::kClientRoutesTouchpadAsMouse`, is deferred; a Bluetooth pad is never Direct) | ⚠️ · ❌ (#108: the same) | ⚠️ · ⚠️ the Trackpads picker on Configure binding and the chip on Home, on the existing per-controller touchpad pick (`touchpad_mode_preferences`, `stick` beside the wire's words, written only once chosen): `stick`, the 2015 pad's default, the right pad as the right stick with its click as R3 and the left pad's click as `leftPadClick`; `pad`, the 2026 pad's default where the emulated type has a touchpad, the left pad on the surface's left half as finger 0 and the right on the right half as finger 1, either click the surface's click; `mouse`, chosen only and held to the host's `mouseControl`, the right pad as the cursor and left button, the left pad's click as the right button and its vertical travel as the wheel (4096 pad units per notch, the remainder carried; the 16-byte frame of a protocol-1 session carries neither); `off`, both clicks on the extended-buttons word; `stick` and `off` declare `touchpadMode` off, `pad` `ds4`, `mouse` `mouse`; the 2026 pad is never offered `stick` (it has a real right stick) and a stored pick the model does not offer falls to its default; `SteamTrackpadsTests` pins that every pad position lands in at most one wire field and every click in exactly one; the lane reads the pick off an atomic word per report and `LockLawTests` runs a Steam lane beside the Switch Pro's; over Bluetooth LE the same, from both pads' Bluetooth lanes; unverified on hardware here |
| Battery | ⚠️ · ✅ | ⚠️ · ⚠️ | ⚠️ · ⚠️ | ⚠️ · ⚠️ |
| Controller mic | ✅ · ❌ | ✅ · ❌ | ✅ · ❌ | ⚠️ · ❌ (the USB audio function; unverified on a pad) |
| Extra buttons (protocol 4: paddles, Capture, the Steam clicks and touches) | ⚠️ · ⚠️ (#279: both Steam Controllers, the Switch Pro, a Direct DualSense Edge; over Bluetooth the Steam Controllers, #284; not yet tried on a Steam Controller or an Edge) | ⚠️ · ⚠️ (#121, #122: both Steam Controllers, the Switch Pro and a Direct DualSense Edge, and SDL's paddles and `misc1` on Standard; none tried on hardware) | ⚠️ · ⚠️ (#104, #105: the same) | ⚠️ · ⚠️ Direct from the Steam Controllers and the Switch Pro (the rows above: USB, and the Steam Controllers over Bluetooth too), and through GameController, on whichever link macOS vends it, an Xbox Elite Wireless Controller Series 2's four paddles: `GCXboxGamepad.paddleButton1` to `paddleButton4`, found once at attach and read with each report, go into the word as SDL3's Apple backend maps them (`SDL_mfijoystick.m`: P1 and P2, the right hand's upper and lower paddles, are `rightPaddle1` and `rightPaddle2`, P3 and P4 the left hand's `leftPaddle1` and `leftPaddle2`), as GameController's own aliases have them (`Paddle 1` and `Paddle 2` are `Back Right Button 0` and `1`, `Paddle 3` and `Paddle 4` `Back Left Button 0` and `1`); the pad claims `extendedButtons` only when its Xbox profile names all four, and the presence test is the typed property, since every Xbox profile lists `Paddle 1` to `Paddle 4`, an Xbox Wireless Controller's included (`GameControllerPaddlesTests`); Apple's header: the paddles are addressable only while the controller is on its default mapping profile; not yet tried with an Elite. A DualSense Edge's two back buttons and two Fn buttons are not read yet: the Edge is read through GameController, `GCDualSenseGamepad` exposes no back-button or Fn property in the macOS 27.2 SDK (`GCInputLeftPaddle` / `GCInputRightPaddle` are racing-wheel names), and the generic `GCInputBackLeftButton(_:)` / `GCInputBackRightButton(_:)` (macOS 14.4) name no documented pad's buttons and are listed on every extended profile, so reading them, and a claim for the Edge, wait for a probe on an Edge; Dish reads no DualSense directly, so SDL's input byte 10 bits do not apply |

The macOS client has two input paths, one per pad: Standard
(GameController.framework) and Direct (Dish's own HID reader, and its XUSB
reader for an Xbox 360 vendor interface macOS has no driver for). Direct
reads the HID reports alongside macOS, opened without seizing the device
(seizing a game controller is not possible through public API and would
blind GameController), and sends a pad nothing but the Switch start sequence,
a claimed Steam Controller's own configuration and rumble, and an XUSB pad's
configuration and rumble: rumble and the player lights of any other Direct
pad ride GameController's controller for it when the pairing is unambiguous. Nintendo's pads are Direct by model;
Valve's Steam Controllers only on the user's pick; any other pad is Direct
only when GameController does not support it. A Nintendo controller
GameController lists while Dish's reader has no lane of its model (a pad
the reader missed, a Bluetooth pad that did not match) is read through
GameController after a 2 s settle window, "Dish couldn't read it directly,
so macOS reads it", and stays so for the connection.

## 3. Receiving, host to pad, by path (cell = USB · Bluetooth)

| | Android | Windows | Linux | macOS (this) |
|---|---|---|---|---|
| Rumble | ✅ · ✅ | ✅ · ⚠️ | ✅ · ⚠️ | ⚠️ · ⚠️ (CoreHaptics engines per handle; the 2026 Steam Controller's own haptic rumble report, re-sent every 40 ms until the host's hold ends; an XUSB pad's own rumble report on its interrupt OUT pipe, and the stop when the host's hold ends and before Dish quits; none for the 2015 one, which has no motors) |
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
  start sequence only to a pad that stays silent, the Steam Controllers'
  configuration and the 2026 pad's rumble only to Valve's own interfaces,
  and an XUSB pad's configuration and rumble only to a vendor-class device
  no Apple driver claims. Rumble on any other Direct pad rides
  GameController.
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
- **An 8BitDo pad in X-input mode is read through its USB interface.** In
  that mode the Ultimate 2 (2dc8:310b) speaks the Xbox 360 protocol on a
  vendor-class USB interface. macOS's own driver for it, `XboxGamepad.dext`,
  binds only Microsoft's 045e:028e (and three Xbox One and Series pads) by
  exact identity, through a device-level personality that configures the
  device and an interface-level one that reads it, so the 8BitDo gets no
  driver, no HID device and no GameController controller. Dish's XUSB reader
  does both halves in user space with IOUSBHost, which an unsandboxed app
  needs no entitlement for: it selects the device's configuration when none
  is selected and opens the interface for itself alone, so a pad another
  client already holds (a third-party 360 driver, another app) is refused
  rather than taken. Only models in the table are read, by identity and
  interface triple, as dish-android reads them. Its D-input mode
  (2dc8:6012) is a HID gamepad both paths can read.
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
- **XUSB carries no Share button and no paddles**, so on the GameController
  path a pad's Share button stays unmapped; an Xbox Elite's paddles read
  through GameController, a Direct pad's paddles and the Switch Pro's
  Capture ride protocol 4's extended-buttons word instead (section 2's
  "Extra buttons" row). Guide is the pad's Home button.
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
   battery and rumble, and a receiver's controller turned off and on; then
   both pads paired to the Mac over Bluetooth: Input Monitoring's prompt,
   the 2015 pad's segments and its quiet and restore, the 2026 pad's 0x45
   reports and rumble, and whether it sends its battery report there. The
   2015 pad's own battery (its status packet) comes after it.
4. A run on an 8BitDo Ultimate 2 in X-input mode, wired and on its
   adapter (`XusbLiveTests`, `DISH_LIVE_XUSB=1`): the configuration Dish
   selects, the pipe reads, the rumble and its stop, an unplug, and an open
   another app holds. After it: its player lights (the 360's LED report),
   dish-android's other XUSB rows (the Ultimate 2C, the SN30 Pro and the
   third-party 360 pads), and a refused XUSB pad on the Controllers page,
   which today only the log shows.
5. A run of the bench on pads (section 6): an Xbox Wireless Controller's
   trigger motors, a DualSense on USB through every item it carries (the
   light bar, the player LEDs, the triggers, the speaker, the haptics lanes
   and the microphone, each put back as the game left it), and a Switch
   Pro's player LEDs through its carrier. After it: a Moonlight host's
   trigger rumble onto the trigger motors where the framework names them,
   instead of folded into the body motors.

## 6. The Diagnostics bench, item by path

What the inspector can test on each path a Mac reads a pad through, the
same facts the game's own writes are gated on (`ControllerCapabilities`,
read by `benchItems`). A cell that cannot carry its item has no button on
the page; the evidence for each is below the table. The audio items ride
the pad's USB audio function (Core Audio), whichever path reads its input.

| Item (tests) | GameController | Direct: the Switch family, through its carrier | Direct: XUSB | Direct: the Steam Controllers |
|---|---|---|---|---|
| Rumble (`rumble.weak`, `.strong`, `.both`) | ✅ the handles' engines where `GCController.haptics` exists | ✅ the carrier's engines, when the pairing is sure | ✅ the pad's own rumble report | ✅ the 2026 pad's haptic rumble report · ❌ the 2015 pad (a) |
| Trigger rumble (`triggerRumble.left`, `.right`, `.both`) | ✅ where `GCDeviceHaptics.supportedLocalities` names `leftTrigger` and `rightTrigger` (an Xbox Wireless Controller's impulse triggers) · ❌ elsewhere | ❌ (b) | ❌ (b) | ❌ (b) |
| Light bar (`lightbar.cycle`) | ✅ where `GCController.light` exists | ❌ (c) | ❌ (c) | ❌ (c) |
| Player LEDs (`playerLeds.cycle`) | ✅ a DualSense, by player index (d) | ✅ the carrier's player index (d) | ❌ (e) | ❌ (c) |
| Adaptive triggers (`trigger.pulse`) | ✅ a DualSense (`GCDualSenseAdaptiveTrigger`) | ❌ (f) | ❌ (f) | ❌ (f) |
| Mic lamp (`lamp.on`, `lamp.pulse`) | ❌ (g) | ❌ (g) | ❌ (g) | ❌ (g) |
| Speaker (`tone.play`) | ✅ a DualSense or DualShock 4 on USB · ❌ over Bluetooth (h) | – | – | – |
| HD haptics (`haptics.play`) | ✅ a DualSense on USB, channels 3–4 · ❌ over Bluetooth and on a DualShock 4 (h) | – | – | – |
| Microphone (`mic.level`) | ✅ a DualSense or DualShock 4 on USB · ❌ over Bluetooth (h) | – | – | – |
| Sticks (`stick.drift`, `stick.range`) | ✅ | ✅ | ✅ | ✅ |

- (a) The 2015 Steam Controller has trackpad voice coils and no motors:
  `SteamPlan.rumbles` is false for it, so no rumble reaches it from a game
  or a test.
- (b) No Direct pad has a trigger motor the Mac can address. The XUSB
  rumble report holds two motor levels (`xusbRumbleReport`, `00 08 00 LL SS
  00 00 00`, the layout SDL's `SDL_hidapi_xbox360.c` and Linux's xpad
  write); the 2026 Steam Controller's `ID_OUT_REPORT_HAPTIC_RUMBLE` holds a
  left and a right motor (`tritonRumbleReport`); a Switch pad's carrier moves
  its rumble and player lights only (`InputPathHost.carryOutput`), and the
  Switch family has no trigger motors. No host sends this Mac trigger rumble
  of its own either: the satellite's protocol has no such message, and a
  Moonlight host's `RUMBLE_TRIGGERS` is folded into the body motors
  (`MoonlightRumbleMix`); the bench drives the trigger motors themselves
  (section 5, item 5).
- (c) No Direct model has an RGB light bar, and no Direct writer sends a
  light: the Switch family's lights are its player LEDs, an XUSB pad's is
  its player ring (e), and the Steam Controllers' writers send their
  configuration and rumble only (`SteamPlan.onClaim`, `onConnect`,
  `refresh`, `onRelease`; `SteamOutput`).
- (d) GameController lights a pattern per player, never a single LED
  (`GCController.playerIndex`: `GCControllerPlayerIndexUnset` and 1–4), and
  every Mac path lights player LEDs that way: the game's mask is folded to
  a player (`PlayerLedsCommand.playerNumber`, the lit count). The contract's
  single-LED masks would all read as player one, so the Mac's cycle walks
  players one to four, 400 ms each (`playerCycle`), under the same test
  name.
- (e) An Xbox 360 pad's LED ring takes the LED report `01 03 <pattern>` on
  the interrupt OUT pipe the rumble rides (SDL's `SetSlotLED` in
  `SDL_hidapi_xbox360.c`, xpad's `xpad_send_led_command`), but the Mac's
  XUSB writer sends only the rumble report (`XusbOutput`), so the slot
  claims no player LEDs and neither a game nor a test reaches the ring:
  deferred with the Ultimate 2 run (section 5, item 4).
- (f) Adaptive triggers are a DualSense's, and the Mac reads a DualSense
  through GameController alone: no Direct model is a DualSense
  (`directModels`).
- (g) GameController has no mic lamp API: in the macOS 27.2 SDK,
  `GCDualSenseGamepad.h` declares the touchpad and the two
  `GCDualSenseAdaptiveTrigger`s and nothing else, and no GameController
  header names a mute or microphone light. The lamp is a field of the
  DualSense's own output report, which on a Mac only the framework writes:
  the Mac never opens a DualSense's HID device. The game's lamp state shows
  as the chip on Home's binding strip (section 3's "Mic lamp" row).
- (h) The pad's audio is its USB audio function: over Bluetooth neither the
  DualSense nor the DualShock 4 shows one to Core Audio, and
  `padAudioFunctions` takes USB devices only (`PadAudioDevices.swift`). The
  haptics lanes are channels 3–4 of a DualSense's four-channel output
  (`PadAudioFunction.hasHapticLanes`); a DualShock 4's headset output is two
  channels. Where the lanes are absent the `hapticAudio` cap is not claimed,
  so the satellite reduces a game's haptics to rumble for that pad (contract
  §UDP messages, `HAPTIC_AUDIO`), which the rumble tests cover.
