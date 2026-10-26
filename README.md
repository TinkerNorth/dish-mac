# Dish Mac

The native macOS client for the Satellite wireless-gamepad server, one of the
four Dish clients beside [dish-android], [dish-windows] and [dish-linux]. It
finds a Satellite on the LAN (mDNS, with the legacy UDP beacon as fallback),
pairs with a PIN over TOFU-pinned TLS, declares its controllers to the server
over REST, and streams their input over encrypted UDP (ChaCha20-Poly1305 under
per-session HKDF keys), with rumble, the light bar, adaptive triggers and
player LEDs flowing back. It offers **protocol 3** and still works with a
protocol-1 satellite; see [Protocol](#protocol).

[dish-android]: https://github.com/TinkerNorth/dish-android
[dish-windows]: https://github.com/TinkerNorth/dish-windows
[dish-linux]: https://github.com/TinkerNorth/dish-linux

## What it does

- Finds satellites over mDNS (`_satellite._udp`) and the legacy `:9879`
  beacon, or takes an address typed in when both are blocked.
- Pairs by asking the satellite's operator first: the satellite's row opens
  into a pairing card that shows a four-digit code and files it with the
  satellite, whose operator accepts it there (the request waits about two
  minutes; a decline or an expiry offers a new code). The satellite's own
  rotating four-digit PIN can be typed into the same card at the same time,
  and whichever lands first pairs. Dish remembers the satellite by its stable
  identity so a DHCP change keeps it paired.
- Keeps several satellites paired at once and binds each controller to one
  of them, up to four controllers on one satellite, each on its own slot
  there. Bindings survive a restart: a remembered binding is made again as
  soon as its controller is plugged in and its satellite or host is known.
  The Connections page scans as it opens (once macOS's Local Network prompt
  has been explained) and lists what it found, with Pair… on each row, above
  a card per paired satellite that shows its address, latency, link chips
  and every pad it carries, with Disconnect, Pair… or Connect and a Forget
  that asks first and names the bindings it drops; a typed address reaches a
  satellite discovery misses.
- Finds Moonlight hosts (Sunshine, Apollo, Wolf) over mDNS (`_nvstream._tcp`)
  or by a typed address on their own page, pairs with the PIN the dish shows
  inside the host's row for you to type into the host, and streams
  controller input into the host's own game-streaming session: up to four
  controllers on one host, each plugged in as the Xbox, PlayStation or
  Nintendo pad you pick or the one that fits it, with rumble and the light
  bar coming back. The first controller bound to a host starts the app you
  picked for it, or the first the host lists; no video or audio is received.
- Forwards buttons (Guide included), sticks and triggers from every pad
  GameController vends, including the ones it vends without the extended
  profile, such as the Nintendo Switch Online N64 and SNES pads (the N64's C
  buttons drive the right stick, Z and ZR the triggers, as on Android), and
  keeps forwarding them while another app is in front. A game device macOS
  does not hand to GameController is listed under Other input devices in
  Diagnostics with its hardware ID and connection. Plus motion (gyro and
  accelerometer) and the touchpad from DualSense and DualShock 4 pads, and
  the battery level; the touchpad reaches the host as the pad's own or,
  picked per controller, as the host's mouse.
- Plays rumble and sets the light bar as the host game asks, each gated by
  its own switch in Settings and, for motion, rumble and the touchpad, by
  the controller's own; on a DualSense it also plays the game's
  adaptive-trigger effects and lights the player indicator.
- Carries a DualSense's or DualShock 4's own audio over its USB audio
  function: the pad's microphone to the host, off until you turn it on and
  muted from one chip, and the host's voice chat and HD haptics to the pad's
  speaker and actuators.
- Keeps the Mac awake while a controller is being used or connected, your
  choice in Settings with the display optional. When the Mac sleeps it
  releases every held button and closes every session cleanly; when it wakes
  it reopens them and scans the network again. A closed lid still puts the
  Mac to sleep: `IOPMLib.h` calls `kIOPMAssertionTypePreventSystemSleep` "not
  supported in any OS X releases", the idle-sleep assertions Dish holds do
  not reach the lid, and Apple's clamshell mode needs a display and power
  connected; when the lid closes mid-stream, Dish says so once on the wake.
- Opens one window, the desktops' shell: a rail on the left (Home,
  Controllers and Connections at the top, Support Dish and Settings at the
  foot, collapsible to an icon strip that stays collapsed across launches)
  and a content column whose header carries the page title, a back chevron
  on a pushed page, the streaming pill with the keep-awake reach, the
  app-wide microphone chip and the status line. Settings, Diagnostics, the
  inspector, the crash report and the licenses are pages in that window,
  not sheets or extra windows, so the window always moves; ⌘, opens
  Settings, ⌘1 to ⌘3 the top destinations and ⌘[ goes back.
- Keeps streaming when the window is closed, from a menu-bar item whose
  Diagnostics item opens the window on that page; follows the system
  appearance or a chosen light or dark theme.
- Checks GitHub for a newer release at startup and every few hours, says so
  once per version, and lets one switch turn the check off.
- Draws Home as the signal path, the desktops' wiring diagram: a boxed row
  per controller from the pad, along a wire captioned with its measured
  report rate and the link's latency, to the host and the slot it holds
  there ("slot 2 of 4"), with the binding printed underneath as chips (the emulated type,
  then motion, touchpad, rumble, microphone, speaker and light bar, the
  controller's own switches clickable in place) and an Edit button; a pad
  with nowhere to go is a "Bind…" card, and the live events, sends and total
  sit under the diagram. Controllers lists a card per pad with its family
  and rate, its capability chips, the microphone's mute, its motion rate,
  "Bound · host ›" and its dead zones.
- Configures each binding on its own page: where the pad goes (paired
  satellites and Moonlight hosts with their link chips), its motion,
  rumble, touchpad, microphone and speaker switches, the type it is emulated
  as (the satellite's catalog, or Auto / Xbox / PlayStation / Nintendo on a
  Moonlight host) and what carries end to end, feature by feature, all held
  as a draft until one Apply, which shows its steps and asks before you
  leave with changes unapplied. Each pad's stick and trigger dead zones are
  sliders of their own, kept per pad under the desktops' key.
- Shows a Diagnostics page with each session's own account of itself, each
  controller down to the wire, and a log of what changed; inspects one
  controller live (its input as the host sees it, motion and touch, a drift
  and a range test on the raw sticks, a rumble bench, a test tone and a
  microphone meter); keeps a local crash log you review, redacted, before
  choosing to send it, and, with "Share crash reports" on, sends an
  anonymous crash report to Sentry like the other clients (official builds
  only; the policy says what it holds).
- Speaks English, Bosnian, German, Spanish, French and Brazilian Portuguese.

What the other clients have that this one does not yet is tracked, row by
row, in [`Tests/PARITY.md`](Tests/PARITY.md).

## Requirements

- macOS 13 (Ventura) or newer to run.
- Xcode 26 (the Swift 6.2 toolchain) to build; CI builds on `macos-26`.
- A compatible gamepad (Xbox, PlayStation, Nintendo Switch Pro, Joy-Con, the
  Switch Online N64 and SNES pads, or any MFi controller). Its input
  keeps flowing when another app is in front; macOS 15.4 broke that for every
  app and macOS 15.5 fixed it.
- A Satellite server reachable on your LAN.

## Build and run

```bash
swift build
swift run Dish
```

For a signed-looking `.app` with its icon, `Info.plist` (versions from
`VERSION`) and the compiled String Catalog:

```bash
./bundle.sh release
open Dish.app
```

## Getting started

The first launch opens a short welcome: what Dish is, how it reaches the host,
and where to get Satellite for the host PC. Finish starts **Set up Dish**, a
walk through the controller, the PC it drives, the type it plugs in as and how
it feels, with nothing sent until its last step's Bind. Before the first scan
for satellites, Dish says that macOS is about to ask for Local Network access,
then asks; if the permission was refused, the empty list and its notice open
Privacy & Security › Local Network. Set up is in the rail any time, in Settings
▸ Setup & help beside Help & FAQ, and behind a controller's "Bind…" on Home.

Releases are not yet signed with an Apple Developer ID, so the first launch of
a downloaded `Dish.app` meets Gatekeeper: on macOS 15 and later click Done on
the "Apple could not verify" dialog, then open System Settings › Privacy &
Security and choose Open Anyway; on macOS 13 and 14, Control-click `Dish.app`
and choose Open. Check the download against the release's `SHA256SUMS` first.
Releases sign and notarize themselves as soon as the Developer ID exists.

## Architecture

Four SwiftPM modules carry the layering, so the compiler enforces it:

```
DishCore      the pure protocol core: wire codecs, HKDF/AEAD/proof, protocol
              constants, policy reducers           (Foundation + CryptoKit)
DishKernel    the dataflow primitives shared with the other Dish clients:
              StateSource, Composer, Controller, Repository, AsyncState
                                                     (Foundation + Combine)
DishEngine    everything that does IO or owns state: discovery, pairing, the
              REST control plane, the UDP data plane, the stores, the
              GameController bridge, the hot-path routers and AppModel, the
              one composition root            (depends on Core and Kernel;
                                               no SwiftUI, no AppKit)
Dish          the SwiftUI views, the theme tokens, the localized words, the
              notification queue and the AppKit lifecycle glue
                                                     (depends on all three)
```

The rules behind it, and why each exists, are in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md); `Tests/ArchitectureTests`
fails the build when a file imports outside its module's allowlist, a
dependency points the wrong way, a view holds a raw colour or an English
literal, or a mutable static appears.

The hot path never leaves the controller's input queue: it builds a
`GamepadReport`, applies the dead zones under a lock, reads the slot's route
(its satellite and the controller index it holds there, or its pad on a
Moonlight host) under one `os_unfair_lock`, seals the frame and calls
`sendto()`. No queue, no Combine, no async hop, no main-actor hop; the
raw POSIX socket carries `IP_TOS = 0xB8` (DSCP EF) and `SO_NOSIGPIPE`.
CryptoKit's `ChaChaPoly` produces the exact bytes libsodium produces on the
server, pinned byte-for-byte by the cross-repo vectors in
`Tests/DishCoreTests/SessionCryptoVectorTests.swift`.

## Project layout

```
dish-mac/
├── Package.swift                 # four modules + five test targets; warnings are errors
├── Sources/DishCore/             # ProtocolConstants, Wire/ (codecs, crypto), Reducers/
├── Sources/DishKernel/           # StateSource, Composer, Controller, Repository, AsyncState
├── Sources/DishCrashUpload/      # the Sentry SDK behind the crash-reporting switch, the one third-party import
├── Sources/DishEngine/
│   ├── AppModel.swift            # the composition root
│   ├── Models/                   # the value types the UI binds
│   ├── Network/                  # discovery, pairing, REST, UDP, TOFU, stores
│   ├── Input/                    # the GameController bridge and the hot path
│   ├── Audio/                    # the pad's own audio: routes, the engine, the codec, the HAL units
│   ├── Update/                   # the release manifest check
│   ├── Diagnostics/              # the session facts, the flight recorder, the page's source
│   └── Util/                     # leaf helpers (the keep-awake pipeline, the crash handler, hex, locks)
├── Sources/Dish/
│   ├── DishApp.swift             # @main
│   ├── L10n/                     # every word, and the one reader of the catalog
│   ├── Resources/Localizable.xcstrings
│   ├── Navigation/               # the navigation machine, its store, the keyboard commands
│   ├── Notifications/            # the toast queue, the background notice
│   └── UI/                       # Shell/ (rail, window), Pages/, Kit/, Mappers/, Theme.swift
├── Tests/DishCoreTests/          # pinned interop vectors, reducer suites
├── Tests/DishKernelTests/        # every kernel primitive
├── Tests/DishEngineTests/        # unit and live suites; Support/FakeSatellite/
├── Tests/DishTests/              # the funnel, the mappers, the AppKit glue
├── Tests/ArchitectureTests/      # the rules a compiler cannot read
├── Tests/Support/                # DishKernelProbes, LegacyFileKeychain
├── Tests/PARITY.md               # what the other clients have, and what is decided
├── Resources/Dish.svg            # the fleet's app mark; Dish.icns is rendered from it
├── packaging/update-policy.json  # the oldest build the update check still supports
├── .github/workflows/            # macos-ci, e2e (the real satellite), release, the security gates
├── docs/ARCHITECTURE.md          # the module map and the dataflow rules
├── docs/UI_CONTRACT.md           # the shell header, the pages, the kit rules
├── docs/contract.md              # contract concept → file
├── scripts/ci-local.sh           # the CI gate, locally
├── scripts/e2e_local.sh          # loopback e2e against the real satellite binary
└── scripts/render-icon.sh        # Resources/Dish.icns from Resources/Dish.svg (needs librsvg)
```

## Return paths

Rumble and the light bar flow the opposite way to input. The satellite
forwards what the host game writes to the virtual pad as `MSG_RUMBLE`
(`0x0009`, 7 bytes: `ctrlIdx(1) + strong(2 BE) + weak(2 BE) + durationMs(2
BE)`) and `MSG_LIGHTBAR` (`0x000D`, 4 bytes: `ctrlIdx(1) + R + G + B`) over
the encrypted UDP socket. `DishCore` parses them as pure decoders;
`ReturnPathRouter` resolves the connection and the command's controller
index to the slot bound there, and so to the device; the GameController
bridge actuates `GCController.haptics` (one `CHHapticEngine` per handle) and
sets `GCController.light`. The two are gated and routed independently, so
Rumble off in Settings leaves the light bar alone, and a pad without the
hardware ignores the packet.

Controller audio rides the same socket. `MSG_SPEAKER_AUDIO` (`0x0013`) and
`MSG_HAPTIC_AUDIO` (`0x0015`) carry 20 ms Opus frames down to the pad's USB
audio function, the haptics on channels 3–4 of a DualSense's four-channel
stream; `MSG_MIC_AUDIO` (`0x0012`) carries the pad's microphone up while its
switch is on and it is not muted; and `MSG_MIC_LED` (`0x0014`) reports the
lamp the game asked for, shown as a chip. Each of these names its pad by
controller index, so two pads on one satellite keep their own lanes. `ControllerAudioEngine` decodes
through the fleet's jitter window and plays on a Core Audio HAL unit.

## Protocol

This client offers **protocol 3** on every pairing and session request and
settles each session on what the satellite speaks: an older satellite gets a
working session at its own version and a soft "update recommended" chip; a
satellite whose range does not overlap this client's gets a plain word about
which end must update. A session settled on version 2 or later streams the
19-byte pointer frame and receives the trigger-effect and player-LED return
paths it advertised. The client-server contract (REST surface, UDP streams,
crypto, liveness, identity, versioning) lives in one place,
[`satellite/docs/contract.md`][contract]; nothing here restates it, and when
in doubt the contract wins. [`docs/contract.md`](docs/contract.md) maps each
contract concept to the Swift file that implements it.

- **Control plane**: HTTPS REST on `:9443` behind TOFU cert pinning. PIN
  pairing mints a per-device 32-byte pairing key; every authenticated route
  carries `X-Device-Id` and `X-Hmac-Proof`; topology is declarative, the
  client PUTs its complete controller set and the server converges.
- **Data plane**: UDP on `:9876`, ChaCha20-Poly1305-IETF under
  `HKDF-SHA256(pairingKey, sessionSalt, token)`, minted per session PUT.
  Streams only: input, heartbeat, motion, battery and touchpad up; heartbeat
  ack, rumble, light bar and close-notify down.

[contract]: https://github.com/TinkerNorth/satellite/blob/main/docs/contract.md

## Languages

Every word the app shows is a property of `L10n`
(`Sources/Dish/L10n/`), read from the String Catalog
`Sources/Dish/Resources/Localizable.xcstrings` in six languages. A new word
is one property and one catalog entry with all five translations;
`LocalizationTests` fails the build on a key the catalog lacks, an entry no
code uses, a language missing a translation, a placeholder lost in
translation, or an English literal in a view, and `L10nTests` reads every
entry back from the compiled tables. The dashboard counts carry plural
forms, Bosnian's paucal included.

## Testing

```bash
swift test --parallel
```

| Target | What it pins |
|---|---|
| `DishCoreTests` | The cross-repo interop vectors (HKDF, HMAC proof, AEAD, hex-exact with the satellite and the other clients) and every reducer: reconcile, backoff, close-notify, TOFU verdicts, latency window, REST outcomes. |
| `DishKernelTests` | Every kernel primitive, with the shared `RepositoryContract`. |
| `DishEngineTests` | Input mapping, dead zones, the return paths against satellite-sealed datagrams, pairing classification, the keep-awake pipeline, the preference stores, the update checker; and the live suites, which drive the real manager, connection and client against `Support/FakeSatellite/`, an in-process satellite over loopback sockets with its own independently written crypto, a configurable protocol range and every return path. |
| `DishTests` | The funnel and the catalog in every language, every mapper flow, the AppKit signal mapping, the close-to-background rule. |
| `ArchitectureTests` | Import boundaries, the package graph, license headers, no suppressions, no mutable statics, the lint thresholds, the version mirrors, the catalog and the tokens. |

For an end-to-end run against the **real** satellite binary (build headless,
pair, stream, tear down over loopback), see
[`scripts/e2e_local.sh`](scripts/e2e_local.sh); the suite it drives skips
unless `DISH_E2E_LIVE=1`. CI runs the same script on every push and pull
request (`e2e.yml`), against the satellite release the workflow pins.

## Development

The whole CI gate, locally, with SwiftFormat and SwiftLint fetched once at
the pinned versions and checksums CI uses:

```bash
./scripts/ci-local.sh           # format, lint strict, build, tests, release build, bundle
./scripts/ci-local.sh --quick   # skip the release build and the bundle
./scripts/setup-hooks.sh        # pre-commit: format + lint on staged Swift files
```

[`CONTRIBUTING.md`](CONTRIBUTING.md) holds the rules: zero warnings, the
shape of the code, test-driven for every flow, where code goes, and how a
release is cut. [`DESIGN.md`](DESIGN.md) lists the design tokens.

## Contributing

Changes land on `main` through a pull request. `macOS CI` runs the format
check, strict lint, the debug build, the tests, the release build and the
bundle on every PR; `version-consistency` checks that `VERSION`, the
changelog heading and the bundle script agree; the `Security` and `CodeQL`
workflows run alongside (action-pin lint, OSV-Scanner, gitleaks, dependency
review, CodeQL `swift`). The PR template asks for the shape rules, the tests
and the bookkeeping.

> Branch protection is not available for private repositories on the free
> org plan this repo lives under, so direct pushes to `main` are not blocked
> at the platform level. The PR flow is a convention, and the CI workflows
> are the gate.

## Security

Vulnerability disclosure: [`SECURITY.md`](SECURITY.md). Every release ships
cosign keyless signatures, SHA256SUMS, SBOMs (SPDX and CycloneDX) and SLSA L3
provenance; the verification recipe is in
[`CONTRIBUTING.md#security`](CONTRIBUTING.md#security).

## Code signing policy

Releases are not yet signed with an Apple Developer ID: the Apple Developer
Program is a yearly fee the project has not taken on. Until it does,
`dish-mac.zip` carries only an ad-hoc signature (identifier
`com.tinkernorth.dish.mac`, no team) and is not notarized, so the first launch
meets Gatekeeper; the steps are under *Getting started*. Verify a download
against `SHA256SUMS`, its cosign signature and the SLSA provenance
([CONTRIBUTING, "Verifying a release artifact"](CONTRIBUTING.md#verifying-a-release-artifact)).

**Team.** Committers, reviewers and approvers: Emir Hasanbegovic
([@emir-hasanbegovic](https://github.com/emir-hasanbegovic)), owner of the
TinkerNorth organisation
([organisation owners](https://github.com/orgs/TinkerNorth/people?query=role%3Aowner)).

**What is signed, and when.** Only the release workflow,
[`release.yml`](.github/workflows/release.yml), signs, only when it runs from
a tagged commit of this repository, and only once the five Apple secrets exist:
`Dish.app` is then signed with the Developer ID under the hardened runtime with
[`packaging/Dish.entitlements`](packaging/Dish.entitlements) and notarized, with
no change to the workflow. Nothing built locally, on a pull request or from a
fork is ever signed with it. The artifact is the `Dish.app` bundle alone: one
executable, its resource bundle and the icon.

**Privacy.** [`PRIVACY.md`](PRIVACY.md) is the policy. Two things can leave
the Mac: an update check against GitHub (one request for `latest.json` on this
project's releases page, with no identifier attached) and, when the app
crashes and *Share crash reports* is on, one crash report to Sentry from an
official build (a locally built app carries no address). Both can be turned
off in Settings. There is no analytics, no telemetry and no account. macOS
asks for Local Network access on the first scan and for the microphone the
first time a controller's microphone is switched on.

**Third-party components in the bundle.** sentry-cocoa (MIT), linked
statically for the crash reporter, which sends nothing unless *Share crash
reports* is on and the build carries a Sentry address. The Moonlight protocol
follows Wolf's reference (MIT) and the ENet client is a port of the fork
Moonlight uses (MIT), both re-implemented in first-party Swift; everything else
is Apple's frameworks. Versions and licences are in
[`THIRD_PARTY.md`](THIRD_PARTY.md), which also ships inside the app under
Settings › About › Licenses.

## License

GNU Lesser General Public License v3.0 or later. See [`LICENSE`](LICENSE)
(the LGPL) and [`COPYING.GPL3`](COPYING.GPL3) (the GPL v3 it incorporates).
