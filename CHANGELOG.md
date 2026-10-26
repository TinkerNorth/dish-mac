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

- **Home draws the signal path.** A boxed row per controller: the pad, a wire
  captioned with the measured report rate and the link's latency (dashed and
  idle until the link is live, crawling while it comes up), and the host with
  its address, its link chip and "slot n of 4" (a satellite's "slot 1 of 1");
  under it the binding as chips, the emulated type first and the controller's
  own switches clickable in place, and an Edit button into Configure binding.
  A pad with nowhere to go is a ghost "Bind…" card, "Set up a controller"
  opens the first such pad, and the events, sends and total sent per second
  are pinned under the page, as on the desktops.
- **Controllers get their cards.** A card per pad: its dot and name, its
  family and measured rate (GameController keeps the transport to itself),
  "Bound · host ›" or "not bound · Bind…", the Gyro, Touchpad, Lightbar and
  battery chips, the microphone's live or muted button, the motion rate and
  "Dead zones…".
- **A binding is configured on its own page.** Configure binding holds every
  answer as a draft (the destination among the paired satellites and
  Moonlight hosts, the motion, rumble, touchpad, microphone and speaker
  switches, the type it is emulated as, and "What carries" for that choice)
  until one Apply writes them together. "Applying binding…" shows its steps
  over the page ("Binding", "Applying on the host", then done or why not),
  may be cancelled while the host's link is still coming up, and gives the
  host eight seconds to answer, as the desktops do. Leaving with changes
  unapplied asks "Leave without applying?" first; Unbind is on the same bar.
- **Dead zones are per pad.** "Dead zones & motion" sets a pad's stick and
  trigger dead zones on sliders with live readouts, applied to the pad at
  once and kept under the desktops' key (`deadzone:<id>`, their
  `{"s":…,"t":…}` shape), with "Reset to defaults" and the pad's own motion
  switch. The 10 % stick and 5 % trigger floors stay the defaults.

- **Pairing asks the satellite's operator first; the PIN stays typeable.**
  Pairing a satellite opens its row into a pairing card instead of a PIN
  sheet. The card shows a four-digit code and files it with the satellite at
  once, and the satellite's operator approves it there; the card says
  "Waiting for approval on the satellite…" for about two minutes, then
  "Approved — connecting…", "The operator declined the pairing." or "No
  approval — the code expired.", and after a decline or an expiry offers a
  new code. The satellite's own rotating four-digit PIN can be typed into
  four cells on the same card at the same time (a pasted PIN lands whole);
  whichever lands first opens the session and stops the other. A refused
  PIN is explained on the card, and from the third refusal on it adds that
  the code changes when the satellite's screen is refreshed. A row that
  needs pairing gets a Pair button. Cancel, or leaving the Connections
  page, stops the request.
- **Guide reaches the host.** A pad's Home button now presses the XUSB Guide
  button (`0x0400`) on a satellite and on a Moonlight host. XUSB has no Share
  button and no paddles, so those stay unmapped, as on the other clients.
- **Input keeps flowing while Dish is in the background.** GameController's
  background monitoring is on from the first controller connect, so a pad
  keeps driving the host while another app is in front, and Dish no longer
  releases every button when it stops being the active app. Diagnostics shows
  it on each controller as "Background input: On". Dish reads the pad
  alongside the frontmost app; taking it away from that app is not possible
  through public API. macOS 15.4 broke background monitoring for every app;
  macOS 15.5 fixed it.
- **A closed lid is said, once.** When the lid closed on a stream and put the
  Mac to sleep, the wake shows "Streaming paused while the lid was closed",
  and Settings ▸ Power says that closing the lid still sleeps the Mac unless a
  display and power are connected: macOS has no API that keeps a lidded Mac
  awake.

- **Moonlight hosts get their own page.** A "Moonlight hosts ›" row on
  Connections opens it. Each host says its trust in words (Paired,
  Remembered, Not paired), how many controllers it carries and its tier,
  the app its session starts, and the way out of where its session stands,
  with Forget behind ⋯. A host mDNS misses is added in an inline "Add a host
  by address" form, and the PIN a host asks for shows as a card inside that
  host's row ("Type 0451 into the Moonlight or Sunshine page on PC.", with
  Cancel and New code) instead of a sheet.
- **Forgetting asks first.** Forget on a satellite or a Moonlight host asks
  "Forget Den?", says the pairing key goes (a Moonlight host also keeps its
  own record of this device until it is removed there), and names every
  binding it drops.

### Changed

- **Views are layout only, and a test keeps them that way.** Every page
  draws one state built by a pure mapper from the model's published facts
  and acts only through `AppModel` intents: Settings writes its preferences
  through `AppModel+Preferences.swift` instead of binding the stores, the
  Diagnostics and inspector pages read the source, the flight recorder and
  the inspector through the model, the crash report reads the log the model
  read, and the colours, fonts, enablement rules and fallback words the
  pages chose are the mappers'. The window's scene hands its pages the
  model, the navigation store and the toast centre and no engine object.
  "Last checked …" under Updates now ticks every minute while Settings
  shows.
  `ViewPurityTests` and `NavigationCoverageTests` pin the rules
  (`docs/UI_CONTRACT.md`, "View purity").
- The Emulate picker, the touchpad picker and the inline Bind list leave the
  controller cards: the type and the destination are chosen on Configure
  binding, and the strip's chips stay the controller's own switches.

- **Connections is the desktops' page.** It scans as it opens, quietly: an
  empty network is said by the page ("No satellites found", with the
  local-network refusal when macOS is the reason, Get Satellite ↗ and Scan
  again), and only the Scan button's sweep still says "No servers found" as
  a toast. FOUND lists what the sweep heard with a Pair… button whose
  pairing card opens under the row. PAIRED holds a card per remembered
  satellite: its name, `ip • UDP port`, latency, the tier, protocol and link
  chips, what it carries ("DualSense — as DS4"), Disconnect, Pair… or
  Connect by the link's state, and Forget behind ⋯. The add-by-address field
  stays at the foot. The engine now vends a connection's name, address and
  port as data, and the app words them.
- **One window with a rail and pages replaces the sheets.** The window is
  the desktops' shell: a rail (Home, Controllers, Connections; Support Dish
  and Settings at the foot, with a dot on Settings while an update waits,
  and the version) that collapses to an icon strip and stays collapsed
  across launches, and a content column whose header carries the page
  title, a back chevron on a pushed page, the streaming pill ("Streaming ·
  computer kept awake" or "… display kept awake") with a Configure button,
  the app-wide microphone chip and the status line. Connections, Settings,
  the crash report and the input inspector were sheets, nested up to three
  deep, and Diagnostics was a second window; they are now pages of the one
  window, so it moves wherever a page is open. Settings follows the
  desktops' order (Appearance, Forwarded features, Controller tuning,
  Window, Power, Diagnostics, Updates, About) in two columns on a wide
  window. Support Dish lists GitHub Sponsors, Ko-fi and Buy Me a Coffee, and
  Open source licenses shows the bundled third-party notice. The window
  opens at 980×640 (at least 900×620); ⌘, opens Settings, ⌘1 to ⌘3 the top
  destinations and ⌘[ goes back; the menu-bar item's Diagnostics opens the
  window on that page. Every toast shows in one place above every page, and
  the Home copy no longer says "Tap Manage".
- **The controller hot path leaves the main thread.** Every controller's
  handlers run on one serial, user-interactive input queue handed to the pad
  before any handler is installed, so a busy window never delays a report.
- **Sleep closes every session cleanly and wake reopens it.** Going to sleep
  releases every held input, closes each satellite session with its `DELETE`
  and stops each Moonlight session with its pads kept; waking reopens both
  and scans the network again, because a laptop may wake on another one. The
  scan after a wake stays quiet when it hears nothing.

### Fixed

- **Failures are no longer hidden while pairing.** Every failure used to be
  held back while the PIN sheet was up, including ones about other
  satellites. Now only the pairing card's own failures stay on the card;
  everything else still shows as a toast.
- **A stick pushed all the way up reads as up, not down, on both links.**
  GameController reports a stick pushed up as positive, like the XUSB report
  every client sends, and Dish negated it, so both sticks read upside down on
  a satellite and on a Moonlight host. The sign now passes through, and a
  sweep over the whole travel pins it.

## [1.0.0] - 2026-10-26

### Added

- **Moonlight hosts.** Sunshine, Apollo and Wolf as hosts beside the
  satellites, as the other three clients have them: found over mDNS
  (`_nvstream._tcp`) or added by address under their own header on the
  Connections sheet; paired with the PIN the dish mints and the user types
  into the host's page (five phases, mutual TLS after, the host's
  certificate pinned, a host that already trusts this device recorded
  without a PIN, a cancel or a forget mid-flight writing nothing); and one
  session per host owned by the bindings: the first controller bound opens
  it (the probe, `/launch` or `/resume`, the RTSP handshake, the media
  pings, the ENet control stream), later ones announce their own pad, up to
  four, and the last leaving closes an app the host started for us. Each pad
  is plugged in as the Xbox, PlayStation or Nintendo type picked for it, or
  the one that fits (a pad with motion is a PlayStation pad); buttons,
  sticks, triggers, motion at the rate the host asks, touches and the
  battery go up, rumble (body and triggers, folded per motor) and the light
  bar come back under the controller's switches. The rows read the trust
  the records hold and the session's standing, with the way out of where it
  stands (pair, re-pair, reconnect, retry, close the app the host holds),
  the app picker per host, and every refusal in the host's own words as a
  banner, and in Diagnostics each host's session, the app it runs, the
  control link's round trip and every pad's reports. The identity is an RSA
  key born in the keychain; the protocol pieces are pinned byte for byte
  against Wolf's captures. Not yet verified against a live host (see PARITY).
- **Controller audio.** A DualSense's or DualShock 4's own audio over its USB
  audio function through Core Audio (contract §Controller audio, §Controller
  haptics): the host's speaker and haptics lanes decoded from Opus
  (AudioToolbox) through the fleet's jitter window and played on the pad at
  its own width, the haptics on channels 3–4; the pad's microphone captured
  in 20 ms windows, encoded and sent while the controller's mic switch is on,
  the session live, the host granting it and the system permitting it, with
  one sequence that never restarts within a session. Mic and speaker switches
  on the slot card (the mic off until asked), a mic chip per controller and
  one in the header that mutes or unmutes every armed mic at once, the game's
  mic lamp as a chip, the microphone permission in the chip's warning, and
  the Diagnostics lines for the host's grant and each pad's route, lanes and
  counters. Not yet verified on a pad.
- **The descriptor's audio claims** (`mic`, `speaker`, `hapticAudio`) follow
  the pad's route and switches, and re-send while live when the route changes.
- **"What carries" knows the pad's audio**: the pad layer is the pad's
  family, the link layer its USB audio function, and the row says why this
  Mac routes none (Bluetooth, two pads of a name, two devices of a name).
- **Crash reports, opt-out, like the other clients.** An official release
  build that crashes sends one anonymous report to Sentry with "Share crash
  reports" on (the default, under the fleet's key); the switch closes the
  SDK at once and restores Dish's own handlers, so the next crash writes
  only the local log, which is written either way and still reviewed,
  redacted, before any issue is filed by hand. The SDK (sentry-cocoa,
  pinned) lives in its own module behind the engine's `CrashUploader` seam,
  arms only with the address `bundle.sh` writes from the release secret,
  tracks no sessions, breadcrumbs or network, and names no user or host.
  Settings says beneath the switch when a build cannot send anything.
  PRIVACY.md and THIRD_PARTY.md say the rest.
- **The controller inspector.** From a controller's Diagnostics card: its
  input as the host sees it (the buttons held, the sticks and triggers after
  the dead zones, the report rate), motion in degrees per second and g and
  the touchpad's fingers, the two stick tests the other clients run (a
  3 second drift test and an 8 second range test, read from the sticks as
  the pad sends them, before the dead zones, with the suggested dead zone
  and the gate's circularity error), a rumble bench that buzzes the motors
  whatever the rumble switch says, and the two audio tests: a test tone on
  the pad's speaker and a microphone meter that listens for eight seconds
  and sends nothing.
- **Mouse mode on the host.** The touchpad's per-controller pick, Off, Pad
  or Mouse, on the slot card; the descriptor declares `touchpadMode` through
  the fleet's ladder (the pad render needs a type that offers `ds4`, the
  mouse a host that advertises mouse control, a blocked pick declares off
  and never the other routing); the session PUT asks for
  `hostFeatures.mouseControl` whenever a bound pad is picked as the mouse,
  the probe is read before the first PUT so the first descriptor is right,
  and a pick flipped mid-session converges the grant through the re-key
  path without a teardown. The pick is kept beside the older on/off row, so
  an upgrade keeps every switch. "What carries" routes the touchpad to one
  of its two rows.

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
- **Per-controller switches.** Each controller's motion, rumble and touchpad
  chips are its own switches, beneath the global ones in Settings, kept in
  the fleet's keys (`motion_preferences`, `rumble_preferences`,
  `touchpad_preferences`); the light bar stays global, as on the other
  desktop clients. The switches in force fold both and reach the descriptor,
  the hot path and the rumble return path through one routing table.
- **Diagnostics.** A window, from Settings or the menu bar, with each
  satellite session's own account of itself (the settled and offered
  protocol, the epoch and the controller bitmap against what this client
  applied, the backend, the round trips, the missed heartbeats, the mouse
  grant), each controller down to the wire (the emulated type, the index,
  the confirmation, the advertised caps word, the touchpad mode) and a
  flight recorder of what changed, copyable whole. Read-only: every figure
  is one the app already acts on.
- **An end-to-end lane against the real satellite.** CI builds satellite
  2.1.3 from source on every push and pull request and drives pairing, the
  TOFU pin, the session PUT, encrypted UDP both ways, the latency window,
  the graceful close and the self-unpair through `scripts/e2e_local.sh`;
  the unentitled runner asserts the honest `backendUnavailable` path.
  `E2EWorkflowTests` pins the lane to the script and the script to the
  driver's environment contract.
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

- **A signed build keeps the controller's microphone.** The release signature
  runs under the hardened runtime, which denies every audio-input API without
  the `com.apple.security.device.audio-input` entitlement; the signature now
  carries `packaging/Dish.entitlements`, so a Developer ID build captures the
  pad's mic exactly as a local build does.
- **A satellite on a dual-stack host is found.** The Bonjour browse resolved
  each satellite with a connection that took whichever address the host's name
  answered with. A Windows host also answers its own name over IPv6, so the
  satellite resolved to a link-local IPv6 address, was dropped as one the data
  plane cannot dial, and the scan reported nothing. The resolving connection
  now asks for IPv4 only, the address the data plane dials.
- **Local builds are no longer blocked from the network, and a blocked one
  says so.** macOS enforces the Local Network permission in the kernel, flow
  by flow, against the app's signing identifier. `bundle.sh` left the
  executable with the linker's ad hoc signature, whose identifier is `Dish`, so
  the rule granted to `com.tinkernorth.dish.mac` never matched a local build:
  every satellite resolved to nothing and every beacon went unheard, which
  read as "No servers found" while Privacy & Security listed Dish as allowed.
  The bundle is now signed as a whole (ad hoc), with the bundle identifier as
  its signing identifier as in a release build; on the same Mac the next scan
  heard the satellite on both paths. For a Mac whose switch is off, a scan
  also opens one flow to the default gateway, and a refusal there is reported
  as macOS blocking Dish from the local network, with the pane to check and
  the add-by-address fallback. `NSBonjourServices` names `_nvstream._tcp`
  beside `_satellite._udp`.
- **A failure says itself once.** A scan that found nothing showed its message
  three times: inline in the Connections sheet, inline at the bottom of the
  window, and as a toast under them that stretched to the window's full
  height. The toast is now the one place a failure or a notice appears, over
  the sheet's bottom while the sheet is open and at the window's bottom
  otherwise, and it is as tall as its text. The pairing sheet keeps its
  message under the PIN field, with no toast behind it.


- **A slot plugged again starts its audio lanes fresh.** The satellite starts
  a pad's speaker and haptics sequence numbers over each time it plugs the
  slot, and a new session is a new pad too; the receiver's jitter windows kept
  the old playhead, so every frame of the new stream read as late and was
  dropped for as long as the old count ran ahead, up to ten minutes. The
  windows and decoders now start over on each confirmation that the slot is
  plugged (`WifiConnection.slotApplyCount`) and when the binding moves to
  another connection; the lanes stay as the plan set them.
- **The e2e lane's satellite is hermetic.** `scripts/e2e_local.sh` seeds the
  satellite's isolated home with `autoCheck: false` before launch, so a test
  lane never phones GitHub for updates. Satellite 2.1.3 also segfaults 31 s
  after launch when that check runs (its updater's reply pointers are
  released before the worker thread reads them; fixed upstream on a branch),
  which turned the lane red whenever the driver's build outlasted the settle.
- **A full-size audio frame no longer fails the AEAD.** The UDP receive
  buffer was the pre-audio 256 bytes, so every speaker frame was truncated
  and dropped; it is now the contract's 1500-byte datagram ceiling.

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

[1.0.0]: https://github.com/TinkerNorth/dish-mac/releases/tag/1.0.0
