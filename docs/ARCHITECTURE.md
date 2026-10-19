# Architecture

A map of the codebase aimed at people working in it. It says which primitive to
reach for, where the code goes, and what the layering rules are. The protocol
contract lives in `satellite/docs/contract.md`; the macOS-side mapping is
[`contract.md`](contract.md). The design tokens are in [`../DESIGN.md`](../DESIGN.md).

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
| `DishCore` | The pure protocol core: wire codecs, HKDF and AEAD, the protocol constants, the policy reducers (reconcile, backoff, close-notify, TOFU verdicts, the latency window, REST outcomes), and under `Moonlight/` the Moonlight host protocol's pure half: the wire formats and the control seal, the PIN pairing, the host's XML replies and the RTSP text, and the session's rules: controller numbers, what a pad's arrival declares, the session reducer and the telemetry conversions; under `Moonlight/Enet/` the ENet client the control stream rides on, a pure state machine with an injected clock | nothing | Foundation, CryptoKit |
| `DishKernel` | The dataflow primitives (below) | nothing | Foundation, Combine |
| `DishEngine` | Everything that does IO or owns state: discovery (one `BonjourScan` behind the satellite and Moonlight browsers), pairing, the REST control plane, the UDP data plane, the stores, the GameController bridge, the hot-path routers, under `Moonlight/` the host side's edges (the keychain identity, one-connection HTTP with mutual TLS, the pinning gateway, the host store, the one-connection-per-message RTSP handshake, the UDP control socket and media pinger, and the control session that seals input onto the ENet link), and `AppModel`, the one composition root | `DishCore`, `DishKernel` | Foundation, Combine, CryptoKit, Darwin, Network, GameController, CoreHaptics, IOKit, Security, os, AudioToolbox, CoreAudio, AVFoundation |
| `DishCrashUpload` | The Sentry SDK behind the Share crash reports switch, armed only by a build that carries an address; the one third-party import in the tree, kept out of the engine, which sees only the `CrashUploader` seam | `DishEngine`, `DishCore`, `Sentry` | Foundation, Sentry |
| `Dish` | The SwiftUI views, the theme, the localized words, the notification queue, and the AppKit lifecycle glue | all three and `DishCrashUpload` | Foundation, Combine, SwiftUI, AppKit, UserNotifications |

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
`UpdatePreferenceStore`) are `StateSource`s over `UserDefaults` under the
fleet's keys; `ControllerTypeStore` and `MotionBackendStatusStore` are
`StateSource`s keyed by binding, the first written by the Emulate picker and
read as each descriptor is built, the second written from every apply result;
`UpdateChecker` is a `StateSource<UpdateState>` that runs the
pure `UpdateMachine` reducer and performs the effects it returns; the
notification queue is a `StateSource<[DishNotification]>`; `DiagnosticsSource`
is a `StateSource<DiagnosticsSnapshot>` that re-reads the session facts at
1 Hz while the Diagnostics window is open, and `DiagnosticsLogStore` keeps the
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
   `AppModel`; the resulting state flows back out.
7. **The engine vends data, the app vends words.** A failure is a
   `ConnectionFailure` case; `failureText` in the app is the one place it is
   worded, `L10n` is the one place a key becomes a word, and the String
   Catalog is the one place it is translated. The derivations between a
   model value and what a view draws (a chip's text, a dot's colour, a
   battery glyph) are pure functions under `Sources/Dish/UI/Mappers`. A
   decision the fleet shares, such as the capability solver's verdicts or
   the motion indicator's fold, is a reducer in `DishCore`; the mapper only
   builds its inputs from the slot's facts and the user's switches and words
   its output.

## Threading and the hot path

Every controller event takes one path: the GameController callback thread
builds a `GamepadReport`, the processor applies the dead zones under its lock,
`InputRouting` reads the slot's route (its live connection and the switches
in force for that controller, global and per-controller already folded on
the main actor) under one `os_unfair_lock`, and `SatelliteClient` seals and
sends under its own lock. No `Task`, no `await`, no main-actor hop, no
Combine on that path. Session material lives in one `LockedBox`, so a re-key
swaps key, token and counter as one generation.

The return paths hop the other way: a `RumbleCommand` or `LightbarCommand`
arrives on the receive queue, the gate decision is pure and runs there (the
rumble switch read off the same routing table by connection, the light bar's
off the global gate), and `ReturnPathRouter` hops to the main actor for the
actuation, coalesced per controller by `ReturnPathApplier`.

The main actor owns every published property. `LifecycleSignals` carries the
host's focus, sleep and wake events into the engine as publishers, so the
engine never imports AppKit.

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
- **Diagnostics shows the facts, not the bench.** The input inspector, the
  stick drift test and the rumble bench the Linux client has are pending; the
  window reads the facts the engine already holds.
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
- **The rules are tested.** `Tests/ArchitectureTests` reads the tree: import
  boundaries, the dependency graph, license headers, suppressions, mutable
  statics, the lint thresholds and the version mirrors.
- **The app layer is tested where it decides.** `Tests/DishTests` covers the
  AppKit signal mapping, the close-to-background rule (with a recording
  announcer in place of the notification centre), the mappers (the slot card,
  the capability table, the Diagnostics lines, the crash report) and the
  notification queue.
