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

### Changed

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
  and Brazilian Portuguese: 92 entries, with plural forms for the dashboard
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
