# Changelog

All notable changes to the Dish macOS client are documented in this file. The
format is loosely based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version number has one source, the [`VERSION`](VERSION) file, which
`bundle.sh` writes into the app's `Info.plist`. `version-consistency.yml` fails
a pull request whose `VERSION` and `CHANGELOG.md` heading disagree, and
`release.yml` fails the tag build when the tag and `VERSION` disagree.

Cross-repo coordination: changes to the wire protocol or the pairing flow that
need matching updates in `satellite`, `dish-android`, `dish-windows` or
`dish-linux` are marked `[wire-coordinated]`. Releases tagged in lockstep across
the repos share a version number.

---

## [Unreleased]

### Added

- **Protocol 3.** Every pairing and session request offers version 3 and
  settles on what the satellite speaks (contract §Versioning): an older
  satellite still gets a working session at its own version with a soft
  "Satellite update recommended" chip on its row, and a satellite that is too
  new or too old says so in plain words instead of a bare mismatch. A session
  settled on version 2 or later streams the 19-byte pointer frame.
- **Adaptive triggers and player LEDs on a DualSense.** The host game's
  trigger effects (feedback, weapon, vibration, bow and machine shapes) play
  through GameController's adaptive-trigger API, and the player indicator
  follows the game's assignment. Modes the API has no shape for reset the
  trigger.
- **The pad is emulated as itself.** A DualSense, DualShock 4 or Xbox pad binds
  as the catalog type that emulates its family; anything else takes the first
  type the satellite offers.
- **The capabilities probe.** `GET /api/server/capabilities` is read at
  session open and kept per satellite, ready for the capability table.
- **Light, dark and system appearance.** Settings gets a Theme picker; every
  `DishTheme` token carries a light value taken from the Linux client's
  palette, and System follows the desktop.
- **Runs in the background.** Closing the window keeps controllers streaming
  behind a menu-bar item that shows the dashboard headline, reopens the
  window and quits; the first close says so once, in a system notification.
  Switching it off in Settings restores quit-on-close.
- **Keep-awake modes.** Off, While playing (held only while a bound
  controller is being used, with a stillness window of 1 to 180 minutes) and
  While connected, each with an optional display hold. The default is While
  playing with the display left alone, the fleet's keys and defaults.
- **The update check.** At startup and every few hours Dish reads the release
  permalink's `latest.json` (schema 1, product `dish-mac`), says once per
  version when a newer build exists, lets you skip a version, and warns when
  the running build is below the supported floor. One switch turns it off;
  the manual check stays. `release.yml` produces the manifest and
  `packaging/update-policy.json` holds the floor.
- **About.** Settings links the help pages, the support page, the privacy
  policy and the license note, and prints the running version.
- **The Emulate picker.** A bound slot shows the types its satellite offers
  and the one the pad is emulated as. Auto is the family's own type; a pick
  re-sends the descriptor over the per-slot route and holds for this run,
  as on the other clients. The catalog is read before the first PUT, so a
  DualSense is a DualSense from the first contact, not the second.
- **"What carries".** Every bound slot folds the pad, this Mac, the emulated
  type and the satellite's probe into the fleet's eleven capability rows,
  each Supported, Off, Not available (naming the first layer that refuses)
  or Pending while the host is unread.
- **The satellite's word on motion.** The apply result's motion sink and
  backend status drive the gyro chip: streaming, host can't receive, server
  can't deliver.
- **The link tier.** Satellite rows wear the fleet's "Fastest" cue.
- **Diagnostics.** A window, from Settings or the menu bar, with each
  satellite session's own account of itself (the settled and offered
  protocol, the epoch and the controller bitmap against what this client
  applied, the backend, the round trips, the missed heartbeats, the mouse
  grant), each controller down to the wire (the emulated type, the index,
  the confirmation, the advertised caps word, the touchpad mode) and a
  flight recorder of what changed, copyable whole. Read-only: every figure
  is one the app already acts on.
- **A local crash log.** A fatal signal appends a backtrace to
  `~/Library/Logs/Dish/crash.log`; the next launch offers the report in
  Settings with the home folder, network addresses and key-like values
  removed, to copy, to open as a prefilled GitHub issue in the browser, or
  to discard. Nothing is sent on its own.

### Changed

- **The dish faces its signal.** The brand's dish glyph aimed up and to the
  left while its signal arcs sat at the upper right; as redrawn across the
  fleet, the reflector is mirrored to +28° and the arcs are concentric on
  the feed horn, aimed down the boresight. The app icon is re-rendered from
  the shared mark by `scripts/render-icon.sh`, and the in-app glyph takes
  the same tilt and lock-on point.
- **The machine is held awake, not the display.** The display-sleep assertion
  that followed the streaming count has become the keep-awake pipeline: a
  system-sleep assertion by default, the display only when the switch says
  so, released by the stillness window in While playing.
- **The descriptor claims only what will land.** A feature switched off in
  Settings is no longer advertised to the satellite, a pad without a motor
  claims no rumble, the touchpad is offered as the pad render only when the
  pad has one and the switch is on, and flipping a switch re-sends the
  descriptor whole. A rumble packet runs the motors for at most 1.5 s: the
  satellite refreshes a held level every 200 ms, so anything longer is a dead
  host's rumble.

- **Every warning fails the build.** Each target treats compiler warnings as
  errors, SwiftLint runs strict, and the one deprecated call the test suite
  needs sits alone in its own target with the reason beside it.
- **The code follows the Parchment shape rules.** Immutable by default, one
  flow per function, named steps, named callbacks, no singletons, and a test
  instead of a comment wherever a behaviour can be pinned. `CONTRIBUTING.md`
  carries the rules; the architecture tests under `Tests/ArchitectureTests`
  enforce the ones a compiler can read: import boundaries per module, the
  dependency graph, license headers, no lint suppressions, no mutable
  statics, and the version mirrors.
- **The engine is its own module.** Sockets, REST, stores and the controller
  bridge live in `DishEngine` with no UI framework in reach; the SwiftUI app
  binds to what it publishes and words its failures. A `DishKernel` module
  carries the dataflow primitives the other Dish clients build on
  (`StateSource`, `Composer`, `Controller`, `Repository`, `AsyncState`).
- **Failures are data.** The engine reports a typed `ConnectionFailure`; the
  app localizes it. No English sentence lives below the UI.
- **Every word goes through one funnel.** Views read their words from `L10n`,
  whose `StringCatalog` is the one reader of the compiled catalog; the
  derivations between model and view (chip text, dot colour, battery glyph,
  the dashboard headline) are pure functions under `Sources/Dish/UI/Mappers`
  with a test per flow. `LocalizationTests` fails the build on a key the
  catalog lacks, an entry nothing uses, a language missing a translation, a
  placeholder lost in translation, or an English literal in a view.
- **Every design value is a token.** `DishFont` joins `DishTheme`; the brand
  glyph colours and the derived fills are named; `ThemeTokenTests` fails the
  build on a raw colour or font size outside `Theme.swift` and on a token
  DESIGN.md does not list.
- **The whole interface is translated** into Bosnian, German, Spanish, French
  and Brazilian Portuguese: 147 entries, with plural forms for the dashboard
  counts (Bosnian gets its paucal).

### Fixed

- **The app builds on Swift 6.4.** The hand-maintained `.lproj` string tables
  duplicated what SwiftPM compiles from the String Catalog, and the newer
  build system refused the duplicate outputs. The catalog is the one source.
- **The bundled app can find its localized strings.** `bundle.sh` now copies
  the SwiftPM resource bundle into `Contents/Resources`, where
  `Bundle.module` looks for it.
- **Translations are shown.** Views looked strings up in the main bundle,
  which never holds the compiled catalog, so every language saw English.
  `L10n` reads the resource bundle, and a test reads every entry back from
  the compiled tables in every language. A build made with SwiftPM's native
  build system copied the catalog verbatim, which no macOS reads at run
  time; `bundle.sh` now compiles it into tables, so the shipped app speaks
  every language whichever toolchain built it.
- **Counts inflect.** "1 active connections" is gone; the dashboard counts
  carry plural forms per language.
- **The PIN field takes ASCII digits only.** A fullwidth or Arabic-Indic digit
  no longer enables Pair.
- **Touchpad frames reach the host.** The descriptor declared `touchpadMode:
  off` while the client streamed touchpad frames, so the satellite dropped
  them; a pad with a touchpad now asks for the pad render.

[Unreleased]: https://github.com/TinkerNorth/dish-mac/compare/main...main
