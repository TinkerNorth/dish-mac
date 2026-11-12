# Architecture

A map of the codebase aimed at people working in it. It says which primitive to
reach for, where the code goes, and what the layering rules are. The protocol
contract lives in `satellite/docs/contract.md`; the macOS-side mapping is
[`contract.md`](contract.md). The design tokens are in [`../DESIGN.md`](../DESIGN.md); the window's shell,
page and kit rules in [`UI_CONTRACT.md`](UI_CONTRACT.md).

Data flows one way. A source of truth owns state, pure reducers and composers
derive from it, the UI binds and renders it, and the UI sends commands back to
the source. The UI never owns domain state, and nothing below the app module
imports SwiftUI or AppKit.

## The prime directive: the engine is independent of the UI

You could delete `Sources/Dish/` and write a different front end (a menu-bar
item, a command-line tool) without touching a file under `Sources/DishEngine/`,
`Sources/DishKernel/` or `Sources/DishCore/`. That is the test for every change,
and the compiler runs it: the four modules are SwiftPM targets whose dependency
arrows point one way, and `Tests/ArchitectureTests` pins which system
frameworks each one may import.

```
        ┌──────────────────────────────────────────────────────────────┐
        │  Dish          SwiftUI projection + AppKit glue               │
        │                binds state ▲             │ calls intents      │
        └────────────────────┼───────────────────────┼─────────────────┘
                             │                       ▼
        ┌────────────────────┴─────────────────────────────────────────┐
        │  DishEngine    sockets · REST · stores · the controller bridge │
        │                the composition root (AppModel)               │
        └────────────────────┬──────────────────────┬──────────────────┘
                             │ built on             │ built on
        ┌────────────────────┴──────────┐ ┌─────────┴──────────────────┐
        │  DishKernel                   │ │  DishCore                  │
        │  StateSource · Composer ·     │ │  wire codecs · session     │
        │  Controller · Repository ·    │ │  crypto · protocol         │
        │  AsyncState (Foundation +     │ │  constants · policy        │
        │  Combine)                     │ │  reducers (Foundation +    │
        │                               │ │  CryptoKit)                │
        └───────────────────────────────┘ └────────────────────────────┘
```

## The module map

| Module | Role | Depends on | May import |
|---|---|---|---|
| `DishCore` | The pure protocol core: wire codecs, HKDF and AEAD, the protocol constants, the policy reducers (reconcile, backoff, close-notify, TOFU verdicts, the latency window, REST outcomes, the operator-approval verdicts and the approval poll's next step, the binding draft and its apply, a pad's dead zones), and under `Moonlight/` the Moonlight host protocol's pure half: the wire formats and the control seal, the PIN pairing, the host's XML replies and the RTSP text, and the session's rules: controller numbers, what a pad's arrival declares, the pad table the hot path reads (frames, the click's replay, touches, motion, battery), the session reducer and the telemetry conversions; under `Moonlight/Enet/` the ENet client the control stream rides on, a pure state machine with an injected clock; and under `DirectInput/` the pads Dish reads itself: the Switch report decoders, the generic HID descriptor parser and its per-report decode, the Direct model table, the input-source machine (which path a pad is forwarded from, its proof and the "Not responding?" check), the disconnect-burst rule, the player numbers, the per-model remap with its press-to-assign walk and the fixed table the reader applies, and the support capture's sequence and report | nothing | Foundation, CryptoKit |
| `DishKernel` | The dataflow primitives (below) | nothing | Foundation, Combine |
| `DishEngine` | Everything that does IO or owns state: discovery (one `BonjourScan` behind the satellite and Moonlight browsers), pairing, the REST control plane, the UDP data plane, the stores, the GameController bridge, the hot-path routers, under `Moonlight/` the host side's edges (the keychain identity, one-connection HTTP with mutual TLS, the pinning gateway, the host store, the one-connection-per-message RTSP handshake, the UDP control socket and media pinger, the control session that seals input onto the ENet link, the connection object that holds a host's pads and live session, the feedback router, and the host manager that probes, pairs, converges the bindings onto one session per host and forgets), the hub whose rows carry satellites and Moonlight hosts alike, and `AppModel`, the one composition root, which folds the bindings into what each host is asked to carry | `DishCore`, `DishKernel` | Foundation, Combine, CryptoKit, Darwin, Network, dnssd, SystemConfiguration, GameController, CoreHaptics, IOKit, Security, os, AudioToolbox, CoreAudio, AVFoundation |
| `DishCrashUpload` | The Sentry SDK behind the Share crash reports switch, armed only by a build that carries an address; the one third-party import in the tree, kept out of the engine, which sees only the `CrashUploader` seam | `DishEngine`, `DishCore`, `Sentry` | Foundation, Sentry |
| `Dish` | The shell (the navigation machine and its store, the rail, the header, the pages), the SwiftUI views and kit, the theme, the localized words, the notification queue, and the AppKit lifecycle glue | all three and `DishCrashUpload` | Foundation, Combine, SwiftUI, AppKit, UserNotifications |

`ImportBoundariesTests` fails the build when a file imports outside its row;
`PackageGraphTests` fails it when a dependency points the wrong way.

Inside the engine the folders are the contract: `Network/` is the control and
data planes and the stores, `Input/` is the controller bridge and the hot path,
`Models/` is the value types the UI binds, `Audio/` is the pad's own audio
(the routes, the engine, the codec and the HAL units), `Util/` is leaf helpers with no
domain state. The engine's UI-facing surface is `package`-visible; everything
else stays `internal`, and the tests reach it with `@testable import`.

## The kernel primitives

Five primitives in `Sources/DishKernel`, the Swift form of the set
dish-android, dish-linux and dish-windows share.

| You have… | Use |
|---|---|
| state owned from a socket, timer, cache or setting | `StateSource<S>`: exposes `state` read-only, mutates through `setState`, drops equal values, opt-in `start`/`stop` |
| one value purely derived from other state | `Composer<Out>` over one to four publishers: computes eagerly, recomputes on change, drops equal results; keep the transform a free function |
| a side effect driven by a state | `Controller<S>`: `start()` applies the current value and every change, idempotent; `stop()` tears down; implement `apply` |
| durable keyed storage | `Repository<K, V>` / `KeyedRepository`; `InMemoryRepository` is the reference, and every repository passes `RepositoryContract` |
| a request with a clear in-flight and terminal shape | `AsyncState<T, E>`: idle, loading, success or error, with the last good value kept as stale and a typed reason |

Notifications fire on the thread that called `setState`. The UI binds on the
main actor; the hot path never routes through the kernel.

Three more conventions are classes written per feature. A **Coordinator** owns
imperative, cross-cutting commands over several sources and re-exposes a
child's state by reference, never as a copy: `WifiConnectionManager` and
`ConnectionHub` are the coordinators here, and they predate the kernel. A
**Gateway** is an IO boundary with no domain state: `HTTPClient`,
`PairingClient`, `SatelliteClient`. A **reducer** is a pure free function in
`DishCore` for a `(state, event) -> result` decision.

Where the kernel is wired today: `WakePipeline` composes the streaming count
(a `Composer<Int>` over the hub's bindings and summaries), the pad activity
(`ControllerActivitySource`, a ticking `StateSource<Bool>`) and the keep-awake
preference into a `Composer<WakeState>` that `WakeStateController`, a
`Controller<WakeState>`, follows with IOKit assertions; the preference stores
(`ThemePreferenceStore`, `BackgroundPreferenceStore`, `KeepAwakePreferenceStore`,
`UpdatePreferenceStore`, and `DeadzonePreferenceStore` under the desktops'
`deadzone:<id>`) are `StateSource`s over `UserDefaults` under the
fleet's keys, and each attached pad gets its stored dead zones as it
attaches (`observeDeadzones`); `TelemetrySource` turns the processor's
per-pad tally and the router's send count into the rates Home and
Controllers show, ticking while one of them is on screen; the Configure
binding page's draft is the pure `BindingDraft` reducer and its one apply
the pure `reduceApply` over `ApplyProgress`, fed by `BindingApplyWatch` (the
host's words and the 8 s budget); `ControllerTypeStore` and `MotionBackendStatusStore` are
`StateSource`s keyed by binding, the first written by the Emulate picker and
read as each descriptor is built (and kept across restarts in the binding
memory, below), the second written from every apply result;
`PairingAttempts` is a `StateSource` keyed by satellite that holds what the
pairing card shows (the client PIN, the approval phase, the typed PIN's
rejections), written by the two pairing paths and ended when a session takes
over or the user cancels;
`UpdateChecker` is a `StateSource<UpdateState>` that runs the
pure `UpdateMachine` reducer and performs the effects it returns; the
notification queue is a `StateSource<[DishNotification]>`; `DiagnosticsSource`
is a `StateSource<DiagnosticsSnapshot>` that re-reads the session facts at
1 Hz while the Diagnostics page shows, and `DiagnosticsLogStore` keeps the
flight recorder's lines that `DiagnosticsRecorder` derives by diffing the
rows and the slots; `composeSlots` and `routeSnapshot` are the pure transforms
behind the slot list and the hot-path table. The coordinators still publish several properties each; moving them
onto single-state sources is listed under limitations.

## Capturing a request: `AsyncState<T, E>`

A `bool busy` or an optional that drops failures cannot tell empty from still
loading, and cannot say why something failed. `AsyncState` keeps the last good
value through a refresh (`toLoading`) and a failure (`toError`), flags it
`stale`, and carries a typed reason the UI localizes. Use it for a catalog
fetch, a scan or a one-shot connect; a lifecycle with more than four states is
a reducer FSM instead.

## Capturing a lifecycle: the reducer FSM

A session is Idle, Linking, Live, Faltering or Stale. The rules that make that
robust: the decision is a pure function of state and event, every pair is
handled (an exhaustive `switch` with no `default`), effects come back as data
and the coordinator performs them, and one notify follows every change. The
reducers in `DishCore/Reducers` are the pure half; `WifiConnection` holds the
state and `WifiConnectionManager` performs the effects.

## Unidirectional flow: the rules

1. **One owner per piece of state.** It lives in exactly one source and is
   exposed read-only. Nobody else stores a copy.
2. **Derive, do not mutate.** Downstream values come from a pure transform.
3. **Effects as data, executed at the edge.** A reducer returns what to do; a
   coordinator or a `Controller` does it.
4. **One notify, then rebuild.** The UI rebuilds from the snapshot; no
   per-field back channels that can miss a transition.
5. **Distinct-until-changed everywhere.** Every state value is `Equatable`.
6. **Commands flow the other way, explicitly.** The UI calls an intent on
   `AppModel` (`AppModel+<Topic>.swift`; Settings' store setters are
   `AppModel+Preferences.swift`); the resulting state flows back out as a
   published fact (`slots`, `connections`, `shellFacts`, …), which a page's
   mapper turns into its view state. A view holds no engine object: the
   scene root hands its pages `AppModel`, `NavigationStore` and the toast
   centre and nothing else, and the preferences, the update clock, the crash
   log, the Diagnostics source, the flight recorder and the inspector reach
   a page through `ShellFacts`. `ViewPurityTests` enforces it, rule by rule
   ([UI_CONTRACT.md](UI_CONTRACT.md), "View purity"); the scene
   (`DishApp.swift`) and its seams (`Sources/Dish/Services`) are not views
   and wire the engine's publishers to the notifiers directly.
7. **The engine vends data, the app vends words.** A failure is a
   `ConnectionFailure` case; `failureText` in the app is the one place it is
   worded, `L10n` is the one place a key becomes a word, and the String
   Catalog is the one place it is translated. The derivations between a
   model value and what a view draws (a chip's text, a dot's colour, a
   battery glyph, a connection's title and its `ip • UDP port` line, which
   the engine vends as name, address and port) are pure functions under
   `Sources/Dish/UI/Mappers`. A
   decision the fleet shares, such as the capability solver's verdicts or
   the motion indicator's fold, is a reducer in `DishCore`; the mapper only
   builds its inputs from the slot's facts and the user's switches and words
   its output.
8. **A kit component reads no domain.** Anything under `Sources/Dish/UI/Kit`
   (the pairing card, the PIN cells) takes only its view state, tokens and
   closures; a host view beside the page maps the engine's value into that
   state and forwards the closures as intents. `ImportBoundariesTests` pins
   it: a kit file imports only SwiftUI and Foundation and observes no model.
9. **Navigation is data.** `Sources/Dish/Navigation/NavigationMachine.swift`
   is a pure `reduceNavigation(state, event)` over the rail's destination,
   the pushed pages, the rail's collapse, the leave guard and the welcome
   gate; it returns its effects (`persistRail`, `activateWindow`) as data and
   `NavigationStore` runs them and hands `NavigationSplitView` and
   `NavigationStack` their bindings. A rail selection replaces the stack, a
   page pushes onto it, and a page that arms the leave guard gets first
   refusal of every move that would take it off screen. The window, the
   menu-bar item and the keyboard commands all go through it.
10. **A page's lifecycle is an intent.** A page's `onAppear` and
   `onDisappear` forward `pageAppeared` / `pageDisappeared` to `AppModel`
   (`AppModel+Diagnostics.swift`), which starts and stops the Diagnostics
   source, arms and disarms the inspector, re-reads the crash log, and
   ticks the update clock while Settings shows; the view does nothing else
   there.
11. **A failure is told in one place.** A pairing attempt's failure is keyed
   to its satellite (`ConnectionEvent.pairingFailed`); while that
   satellite's pairing card is open the card shows it, and `AppModel` hands
   only the others to the toast.

## Threading and the hot path

Every controller event takes one path, and takes no lock on it.
GameController calls a pad's handlers on that controller's own serial
`userInteractive` queue (`com.tinkernorth.dish.input.<slot id>`, one per slot,
kept across a re-attach), handed to it as its `handlerQueue` before any
handler is installed, so no event waits behind the main thread or another
pad. The handler samples the pad into the core's `PadSample`
(a pad GameController vends without the extended profile is read through
`physicalInputProfile` instead: `GameControllerInput+Profile` resolves the
core's `ProfileLayout`, the generic table of Apple's `GCInput…` names or the
N64's, against the pad's elements once at attach, so the handler walks fixed
arrays into a `ProfileSample` whose C buttons rail the right stick; no set,
array or string is built per report), `wireReport` turns it into a `GamepadReport` (up-positive sticks, as XUSB and
every other client have them), and the pad's `PadFeed` takes it: a report
that repeats the last one published is dropped there, the dead zones come
from an atomic word, the record the inspector and the telemetry read is
written under a seqlock, and the report goes to the route the feed holds
(a `SatelliteClientSink` with the connection's live client and the pad's
controller index, or a `MoonlightPadSink`, and the switches in force, all
resolved on the main actor and handed over through a mailbox). The client
then encodes, seals and sends from a stack buffer under its send gate, a
compare-exchange flag held from the counter's claim to the `sendto`, so the
session's datagrams leave in counter order; CryptoKit's sealed box is the one
allocation. The routes are built on the main actor whenever the table is,
and again when a connection's client comes or goes, never per report. No
`Task`, no `await`, no main-actor hop, no
Combine on that path. The handler installs are `nonisolated`, so the compiler
refuses a handler that reaches for main-actor state; the slot bookkeeping
(attach, detach, the published slot list) stays on the main actor. Session material is one `SessionGeneration`
that senders read under the session's send gate, so a re-key swaps key and token and restarts the counter in
one hold.

A pad bound to a Moonlight host leaves its feed for a `MoonlightPadSink`, the
host's `MoonlightPadLink` builds its frame under the link's lock, and the
`MoonlightControlSession` seals it under the next control sequence, claimed
from an atomic counter, before it takes the session's lock, which covers
only the ENet framing and tracking; the host's packets come out under that
lock and are opened after it. `LockLawTests` pins the locks this path takes.

The return paths run the other way in one hop: a `RumbleCommand` or
`LightbarCommand` arrives on the receive queue, which resolves and gates it
against the `FeedbackRoutes` its handlers captured when the routing last
changed (the slot bound to the connection's controller index,
`SatellitePadKey`, behind that controller's rumble switch, and the global
light-bar switch) and posts it to the pad's `FeedbackPad`, where the newest
command of each kind waits. One serial queue, `dish.feedback`, at the input
queue's quality, takes it and drives the actuators it owns (`PadActuators`:
each slot's controller, its haptic engines and their players, its light, its
triggers and its player index); the main actor is not on the way. The audio
messages find their pad the same way, through the connection's
`PadAudioTable`, one locked lookup per frame by the frame's index.

## Direct input: the HID reader beside GameController

Nintendo's Switch Pro (057e:2009), N64 (057e:2019) and SNES (057e:2017)
pads are read by Dish itself, by model: macOS lists the N64 pad and
delivers none of its input. A gamepad GameController does not support
(`GCController.supportsHIDDevice` still no after four checks over about
30 ms, as SDL waits) and whose report descriptor the core can decode is
read the same way. Valve's Steam Controllers (2015: 28de:1102, receiver
1142; 2026: 1302, receivers 1304 and 1305) are read by their own decoders,
but only once the user picks Direct (`DirectRule.optIn`). Everything else
stays on GameController.

- **The reader.** `IOKitHidPadReader` owns one `IOHIDManager`, matching the
  Nintendo and Valve models by identity and every game usage, all with
  `GCSyntheticDevice` false, scheduled on the run loop of a thread of its own
  (`com.tinkernorth.dish.hid`), never the main one. Each candidate
  (`hidPadCandidate`, decided from the device's properties alone) is opened
  with `kIOHIDOptionsTypeNone` as it arrives, a Steam Controller only once
  claimed: Dish reads the reports alongside macOS and never seizes the
  device. What is ever sent: the Switch start sequence, and a claimed Steam
  Controller's own reports (both below). Gamepad usages need no Input
  Monitoring permission and no entitlement. A device whose collections
  include a keyboard, a mouse or a touchpad does: IOHIDFamily marks it
  `RequiresTCCAuthorization` and `IOHIDDeviceOpen` asks for Input Monitoring
  before it opens, which is why the 2026 Steam Controller, whose one
  interface carries its keyboard and mouse, is opened only on the user's
  pick. Asking blocks until the user answers (`IOHIDRequestAccess` waits on
  TCC with no timeout), so the reader reads the standing with
  `IOHIDCheckAccess` first (`claimStep` in DishCore), opens only when no
  prompt can come of it and asks on a queue of its own, never on its
  thread. Arrival and removal hop to the main actor; a pad GameController
  turns out to read is released again.
- **The Switch start sequence.** A Switch-family pad on USB streams its full
  0x30 reports only once its link runs at 3 Mbit with its timeout off: the
  USB handshake (`80 02`), the switch to 3 Mbit (`80 03`), the handshake
  again (`80 02`), the timeout disable (`80 04`), then subcommand `03 30`,
  full report mode, and subcommand `40 01`, the IMU enable, the order
  Linux's hid-nintendo and SDL send. A Pro sent dish-android's three packets
  (the handshake, the timeout disable and the report mode) stays silent, and
  a Pro never sent the IMU enable streams every IMU word as zero. macOS's
  driver leaves the Pro and the N64 silent (a pad that streamed before was
  most likely started by Chrome's own Nintendo support), so a lane that
  reads Switch reports marks the time of each full report, and
  `SwitchStreamWatch` (DishCore) decides on a 250 ms tick on the reader's
  thread: a pad that streams is never started; a silent one waits out a
  one-second grace for Apple's own handshake, then gets the six packets, one
  per tick, so starting one pad never stalls another's reports, and a
  sequence once started is finished, since the Pro streams from its fourth
  packet and the two subcommands after it configure that stream; a stream
  that stops for two seconds gets them again; sequences that bring nothing
  repeat every three seconds, then every ten. Rumble over HID goes only to
  the 2026 Steam Controller.
- **Steam Controllers, on the user's word.** Reading one turns its keyboard
  and mouse emulation ("lizard mode") off, so its machine settles on
  `.offered`, the lane stays closed and Controllers shows its model's offer
  card (`DirectOffer`, one per model, so a receiver's four slots make one).
  Use Direct picks Direct for the model (stored in `usb_path_choices`, so
  the next connect is claimed at once); the paths `claim` each lane and the
  reader opens it there. A refused open (`ClaimRefusal`: Input Monitoring,
  or busy) goes back to the main actor and the offer says why; Standard is
  the hand-back, which `unclaim`s. Each lane's writes run on a
  `SteamOutput` queue of their own, never the reader's thread, from the
  core's `SteamPlan`: the 2015 pad is quieted (the desktops' clear mappings
  and settings) and restored on every release (default mappings, default
  settings, the right pad's mouse), since its settings persist until it
  reboots, and `willTerminate` restores every claimed pad before the app
  exits; the 2026 pad gets lizard mode off and its IMU on, lizard mode off
  again every three seconds while it is read (its firmware's watchdog turns
  it back on, which is also how it is restored), and its haptic rumble
  report, re-sent every 40 ms inside the firmware's safety stop until the
  host's hold ends. A receiver's slot is a pad only while its controller is
  there: the lane marks it on the first state report or connect event (the
  2015 receiver is asked with `ID_DONGLE_GET_WIRELESS_STATE`), the output
  configures a controller fresh from a boot, and a disconnect releases what
  it held before the slot hides.
- **One device, one lane.** IOHIDManager hands back a separate device
  reference for every matching rule a device satisfies, so a Nintendo pad,
  which matches its model rule and the game-usage rule, arrives twice and
  leaves twice. `HidEntryRegistry` keys the reader's devices by IORegistry
  entry ID: the first reference opens the lane, a second is ignored (also
  after the pad was released to GameController), and the device ends once
  whichever reference reports the removal. Once a second the reader also
  checks its lanes against the devices the manager still lists and ends any
  whose device is gone, so a missed removal cannot leave a ghost pad.
- **A lane per device.** `HidPadLane` holds the report buffer IOKit writes
  into, sized from `kIOHIDMaxInputReportSizeKey`, the decoder and its state
  (the Switch sticks' reach, or the descriptor's `HidGamepadLayout`), the
  last report seen and published, and a lock-guarded raw counter. The
  callback decodes in place (no `Data`, `Array` or `String` per report) and
  publishes through the processor under the pad's slot id (`hid:057e:2019`,
  `#n` for identical pads) only when the report changed something and only
  while the pad's source is Direct; motion every report that carries it,
  and the pad's battery posted to the main actor on change, which sends the
  lower of it and the Mac's (`lowestBattery`) at once and on the 30 s
  heartbeat, the Mac's alone for a pad that reports none. The first second's count
  is logged once per attach as `DEVCAPS DIRECT`.
- **One machine per pad.** `InputPaths` runs the core's input-source machine
  on the main actor for every pad, Direct lanes and GameController pads
  alike, and runs its effects: the gate's route, the slot list, the stored
  pick (`usb_path_choices`, `UsbPathChoiceStore`), the flight recorder. Its
  per-slot `SlotInputPath` facts (path, reason, proof, check, picks, raw
  rate, layout guessed, whether it can be remapped, rumble carriage, player
  number, disconnect burst) reach the UI through `ShellFacts.inputPaths`;
  the intents are `startInputCheck` and `pickInputPath`. The button walk
  (`ButtonCheck`) and the support capture (`SupportCaptureService`) are the
  paths' own objects too, so the composition root gains no property: they
  publish into `ShellFacts.buttonCheck` and `ShellFacts.supportCapture`,
  start and end with their pages (`pageAppeared`), and take their intents
  in `AppModel+ControllerSupport.swift`.
- **The hot path never hops per report.** Each pad's `PadGate` is the one
  word its hot path reads: which source is published, and a "tell me" bit
  per source. The main actor raises both bits while the machine needs an
  event (the pad is unproven, or a "Not responding?" check runs). A change
  that finds its source's bit raised lowers it and posts one event to the
  main actor, so a check hears each source at most once however fast the
  pad sends; nothing else on the path touches the main actor. The word is
  under an unfair lock: Swift's `Atomic` needs macOS 15.
- **A stored remap is a fixed table on the hot path.** "Check the buttons"
  writes a generic pad's remap per model under `joystick_remaps`
  (`JoystickRemapStore`, the desktops' `JoystickRemapStore` fields, with
  Guide as one extra field they ignore). `InputPaths` turns the model's
  entry into a `HidRemapTable` (DishCore: each declared button's wire bits
  in a `SIMD16`, the hat flag, the trigger sources, the stick axes and their
  Y inversion, no collection) and swaps it into each lane of the model
  whole, behind a lock, when the store changes and at arrival. The lane's
  decode reads the declared sources (`HidRawState`: the button bits by
  declared index, the d-pad, the six axes) and the table maps them to the
  wire; with no table the lane reads the model's own button order as
  before. Nothing is allocated per report on either road. The walk itself
  (`RemapAssign` in DishCore, the desktops' `withAssignment` and their
  capture gates) listens through the same `PadGate`: while its page shows
  the gate is open, the lane keeps the pad's rest, and a raised wish posts
  the next raw change once (a button newly held, the d-pad moved off
  centre, an axis crossing out past 16000 from rest); the walk raises the
  next wish as each control lands, and nothing else hops to the main actor.
- **"Help support this controller" opens the device, never seizes it.**
  `SupportCaptureService` (main actor, owned by `InputPaths`) drives the
  core's `SupportCapture` sequence. Its `IOKitHidReportCapture` runs one
  session at a time on a thread of its own
  (`com.tinkernorth.dish.hid-capture`): an `IOHIDManager` matching the
  device the page names (its USB identity, or the product name
  GameController shows, among the game usages), `GCSyntheticDevice` false,
  the first match opened with `kIOHIDOptionsTypeNone` alongside macOS and
  Dish's own reader. The report callback copies each report into a
  `HidReportRing` of 64 preallocated 128-byte slots (a repeat of the last
  report is not written), so the hot path builds nothing; the service drains
  the ring every 100 ms on its own timer, not a view's. The descriptor
  (`kIOHIDReportDescriptorKey`), product, manufacturer and transport are
  read once as the device opens. The result is text on the page: nothing is
  sent, and the issue link opens with only its title filled in.
- **R7: a Nintendo controller GameController lists is a carrier.** A
  `GCController` whose product category names a Direct-by-model pad ("Switch
  Pro Controller", "Switch N64 Controller", the SNES pad's) gets no input slot
  and publishes nothing, so no pad is read twice; its handlers stay
  installed and only tell its pad's machine of a change during a check. When
  exactly one such controller and exactly one HID device of the model are
  connected it carries the Direct pad's rumble and player lights: it is
  filed under the Direct pad's slot id in `controllersById`, so the return
  paths reach it unchanged; otherwise the slot's facts say why rumble is
  unavailable. A Standard pick (offered only for a Pro GameController shows)
  hides the Direct slot and attaches the carrier again as an ordinary pad.
- **A carrier with no lane falls back to Standard.** R7 must never leave a
  pad silent: when Dish's reader has no lane of a carrier's product ID (it
  missed the device, a Switch Pro over Bluetooth that did not match) the
  pad would get input nowhere. Each carrier has a `CarrierStanding`
  (DishCore, `standCarrier`): `waiting` from its arrival, publishing
  nothing; `followsLanes` once a lane of its model is there (R7 as above);
  `fellBack` when the 2 s settle window (`CarrierFallbackRule.settleMs`, on
  the paths' injected scheduler) closes with no lane. A fallen-back carrier
  is read through GameController under a stand-in machine of its own, whose
  decision (`PadPathFacts.fellBackToStandard`) is Standard with the reason
  "Dish couldn't read it directly, so macOS reads it" (or "Your pick" for a
  stored Standard), so it is proven, checked and numbered like any pad. The
  standing is sticky for the connection: a lane of the model that arrives
  later joins on Standard too (its machine takes over from the stand-in,
  the carrier keeps publishing, the lane publishes nothing), so nothing
  flaps and nothing is read twice; only a reconnect or the user's pick
  ("Use Direct", now that a lane decodes it) moves it.

## Several pads on one satellite

A satellite session carries up to four pads (`SatelliteSlots.maxPerSatellite`
in the core, the desktops' "slot n of 4"). `WifiConnection` holds them as one
value, `SatelliteSlotTable`: per slot id the controller index it holds (the
lowest free one when it attached, `SatelliteSlots.lowestFreeIndex`, kept for
as long as it stays bound), its type, capabilities and family, the switches
in force for it and whether the satellite confirmed it. Every edit goes
through `WifiConnection.editSlots`, which publishes once and queues exactly
the indices whose descriptor appeared, went or changed; while live the
manager's `syncSlots` PUTs each queued index's descriptor to
`/api/connections/{id}/controllers/{idx}`, or DELETEs an index no pad holds,
and the session PUT (open, re-key, reconcile) always carries the whole set in
index order. The heartbeat's bitmap is checked against every confirmed index,
and a drift is healed by the GET and the whole re-PUT. `ConnectionHub.bind`
lets the satellite take the pad before the binding table publishes, so the
routing table, the audio bindings and the return paths that follow the table
already know the pad's index; a fifth pad is refused. What is keyed by slot:
the descriptor, the switches, the route, the return paths and the audio lanes
(handlers and the mic sequence by index). What stays per connection: the
session itself, its token and counters, the host-feature grant (the session
asks for the mouse when any pad picks it) and the host's audio verdict.

## Bindings across restarts

The hub remembers every binding, one record per pad and of one kind: a
satellite binding under `wifi_binding_list` (`BindingMemoryStore`, the
satellite's id and the type picked, nil for the pad's own), a Moonlight one
under the fleet's `moonlight_binding_list`. A bind and a type change write
it; the user's Unbind and a Forget of the host drop it; a pad that leaves, or
that its satellite refuses, keeps it. `AppModel+BindingMemory` follows the
pads, the satellite pool and the Moonlight records, and asks the hub for the
bindings due (`takeDueStandingBindings`): a remembered binding whose pad is
attached and unbound and whose destination is known here, tried once while
its pad stays attached, then again when it returns. Each is bound through the
same `bind` intent a page uses, its pick written first.

The main actor owns every published property. `LifecycleSignals` carries the
host's sleep and wake into the engine as publishers, so the engine never
imports AppKit. Losing focus is not a signal: `GCController.shouldMonitorBackgroundEvents`
is set at the first connect, so input keeps arriving while another app is in
front and nothing is released when Dish stops being frontmost.

The HID census (`Input/HidDeviceCensus.swift`) is the one IOHIDManager in
the app, behind the `HidCensusReading` seam: it matches usage page Generic
Desktop with Joystick, GamePad and MultiAxisController and
`GCSyntheticDevice = false` (Apple's only supported way to leave out the
devices macOS 14 and later synthesise), is never opened, and is scheduled on
the main run loop only while the Diagnostics page shows, re-read on its 1 Hz
tick and on every match and removal. It reports each device's name, ids,
transport and `GCController.supportsHIDDevice` (cached per device, as
GameController.h asks); a test hands `DiagnosticsSource` a fake.

## How to add a feature

1. **Name the state.** A request takes `AsyncState`; a lifecycle takes a
   reducer in `DishCore` with an exhaustive test.
2. **Write the pure core first**, red then green, in `DishCore` or as a free
   function in the engine. No IO.
3. **Own it in a `StateSource`** in the engine, or a coordinator method for a
   cross-cutting command. Feed world signals in; expose state out.
4. **Derive the UI shape in a `Composer`** when more than one upstream
   contributes; a side effect becomes a `Controller`.
5. **Project it in `AppModel`** as a `package` published property plus the
   intents, and bind it in SwiftUI with every state rendered: loading, error,
   empty and content.
6. **Localize at the edge.** A new word is an `L10n` property with its
   catalog entry and five translations; the engine gets a case, not a
   sentence, and the view gets the property, not a literal.
7. **Wire it once in `AppModel`**, the only composition root, and update
   [`../Tests/PARITY.md`](../Tests/PARITY.md) in the same change.

## Known limitations and not yet implemented

Each entry names the decided shape, so a change lands on it.

- **Dish reads the pad alongside the frontmost app, never instead of it.**
  Background monitoring lets input reach Dish while another app is in front,
  and that app still sees the pad too. Taking the pad for Dish alone is not
  possible through public API: an Apple frameworks engineer confirms an app
  cannot take a controller away from the OS's game controller support
  (Apple Developer Forums thread 775975), and seizing the HID device
  (`kIOHIDOptionsTypeSeizeDevice`) would blind GameController; the Direct
  reader opens its pads without seizing them for the same reason. macOS 15.4 broke background monitoring for every
  app; 15.5 fixed it.
- **A closed lid still sleeps the Mac.** `IOPMLib.h` says
  `kIOPMAssertionTypePreventSystemSleep` is deprecated and "not supported in
  any OS X releases"; the user-idle assertions keep-awake holds do not reach
  the lid, and Apple's clamshell mode needs external power and a display.
  Sleep releases every held input and closes every session cleanly (a
  satellite's with its `DELETE`, a Moonlight host's through the session's own
  stop with its pads kept); wake reopens them, scans again, and, when the lid
  closed on a stream, says so once.

- **Controller audio is unverified on a pad.** `Audio/` is the route:
  `PadAudioFunctionSource` reads the HAL's USB devices, `padAudioRoutes`
  matches them to pads by family, `ControllerAudioEngine` decodes the
  speaker and haptics lanes through the core's `AudioJitterWindow` and plays
  them on a HAL output unit at the device's own width, and `MicCapture`
  encodes the pad's microphone in 20 ms windows. Opus is AudioToolbox's
  codec, so there is no FEC, DTX or PLC control: a concealed window is
  silence. The engine is proven over fake ports and the fake satellite; no
  DualSense was attached where this shipped from.
- **The coordinators publish several properties each.** `WifiConnectionManager`
  and `ConnectionHub` should become single-state sources with composers over
  them; the hot-path tables stay as they are.
- **The crash log is local and the handler is process state.** `CrashHandler`
  holds its buffers in one process-wide `let`, because a C signal handler
  takes no context; the install step is its only writer. The report is
  redacted by `CrashReport` in the core and sent only by the user's browser.
- **Diagnostics shows the facts it holds.** The page reads what the engine
  already acts on; the input inspector (pushed from a controller's card)
  adds the live input, the stick drift and range tests, the rumble bench and
  the audio tests, and the HID census lists the game devices GameController
  does not claim. The radios section the desktops show is not there yet.
- **A pad neither path can read is listed, not read.** The census shows it
  in Diagnostics, with "Help support this controller" to record what it
  sends for an issue. A pad GameController does not vend is read Direct when
  its descriptor decodes, with its layout marked guessed unless the model is
  in the verified table, and "Check the buttons" to correct it. The N64 profile table's names for the C
  buttons, Z, ZR and Capture are Apple's undocumented ones, so each row
  tries the plausible names and the attach logs (`DEVCAPS PROFILE`) what
  bound, what is missing and what no row claims.
- **The update check downloads nothing.** It reads the release manifest,
  says so once per version and opens the release page; installing stays
  manual, as on the other desktop clients.
- **Trigger effects play the API's shapes.** GameController exposes feedback,
  weapon, vibration and slope shapes; the firmware's galloping mode has none
  and resets the trigger, and the bow and machine modes play their nearest
  shape.

## Testing

- **The pure core is the contract.** Every reducer and codec has a test that
  pins the decision space with no mocks, in `Tests/DishCoreTests`; the
  cross-repo interop vectors are hex-exact with the sibling suites.
- **The kernel is tested as a kernel.** `Tests/DishKernelTests` pins each
  primitive; the probes and `RepositoryContract` under
  `Tests/Support/DishKernelProbes` are shared by every test target.
- **The engine is tested against a real listener.** `FakeSatellite` is an
  in-process satellite with its own independently written crypto, asserted
  against the same vectors; the control-plane, data-plane and `Integration*`
  suites drive the real manager and client over loopback with bounded waits,
  never sleeps. `IntegrationLiveSatelliteE2ETests` runs against the real
  satellite binary through `scripts/e2e_local.sh`, locally and in CI's
  `e2e.yml` lane, which builds the satellite from its pinned release tag.
  `IntegrationMoonlightFakeHostTests` drives the Moonlight manager over the
  real sockets against `FakeMoonlightHost`, a loopback host that answers the
  probe and the five pairing phases as Sunshine and Wolf do, hands out its
  ports over RTSP, and opens every sealed control packet with the launch's
  key, so the suite reads what a host would have read.
- **The rules are tested.** `Tests/ArchitectureTests` reads the tree: import
  boundaries, the dependency graph, license headers, suppressions, mutable
  statics, the lint thresholds, the version mirrors, the view purity rules
  (`ViewPurityTests`) and the navigation's coverage (`NavigationCoverageTests`:
  every destination and page has its title, its page file, its mapper tests
  and its branch of the shell's switch).
- **The app layer is tested where it decides.** `Tests/DishTests` covers the
  AppKit signal mapping, the close-to-background rule (with a recording
  announcer in place of the notification centre), the mappers (Home's rows,
  Controllers' cards, Configure binding and its apply overlay, the dead
  zones, the capability table, the Diagnostics lines, the crash report) and the
  notification queue.
