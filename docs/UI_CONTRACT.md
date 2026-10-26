# The UI contract

The macOS twin of the desktops' `docs/QML_CONTRACT.md` and
`docs/QML_UI_KIT.md` (dish-windows, dish-linux): how the window is put
together, what a page may and may not do, and the rules a kit component
keeps. The tokens are in [`../DESIGN.md`](../DESIGN.md); the dataflow rules
behind all of it are in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## The shell

[`ShellView`](../Sources/Dish/UI/Shell/ShellView.swift) is the one window's
content: a `NavigationSplitView` whose sidebar is the rail and whose detail is
the shell header over a `NavigationStack`. It opens at 980×640 and goes no
smaller than 900×620, the desktops' numbers. There is no second window and no
`Settings {}` scene.

Navigation is data. [`NavigationMachine.swift`](../Sources/Dish/Navigation/NavigationMachine.swift)
is a pure reducer; [`NavigationStore`](../Sources/Dish/Navigation/NavigationStore.swift)
applies its events, runs its effects and hands the split view and the stack
their bindings. Pages reach it as the `NavigationStore` environment object
and send it events; nothing else moves the window.

| Event | Effect |
|---|---|
| `select(Destination)` | Switch the rail destination. This **replaces** the stack, clearing any pushed page. |
| `push(Page)` | Push a page onto the destination on screen. |
| `pop`, `popToRoot` | Unwind the stack. The header chevron and ⌘[ send `pop`. |
| `toggleRail` | Collapse the rail to its icon strip or expand it; persisted under `ui_rail_collapsed`. The split view's own sidebar button sends it, so the rail never hides. |
| `guardLeave(Bool)` | The page on screen arms or releases its leave guard. |
| `leaveGuard(.stay / .leave)` | The page's answer about the move its guard is holding. |
| `external(.showDestination / .showPage)` | The menu-bar item and the keyboard commands: the window comes forward on what was asked for. A page shown from outside lands on the destination it lives in. |
| `openSetup(seedSlotId:)` | Select Home, then push the setup walk (`AppShell.qml`'s `openSetupWizard`), so its result lands on a Home row. A move like `select`: a guarded page is asked first. |
| `welcome(.skip / .finish)` | Lower the welcome; both complete it (`markWelcomeComplete`), and Finish goes on as `openSetup(nil)`. Ignored while no welcome is up. |
| `setupEnded(.applied / .exited)` | The walk ends on Home's root with its guard released: after its apply landed (also `markWelcomeComplete`), or by a blocker's Exit, which asks nothing. |
| `pairingCardOpened` | A satellite's pairing card opened: Connections comes up, unless the walk is on screen, which draws the card in its Destination step. |

The five destinations, in rail order, are Home, Controllers and Connections at
the top, then Support Dish and Settings pinned to the footer over the version
label. Between the two groups is the **Set up** action (`RailAction`, the
desktops' outlined accent button, a bare plus when the rail is collapsed); it
is an action, not a destination, and sends `openSetup(nil)`. Pushed pages today: Diagnostics, the
controller inspector (pushed from Diagnostics), the crash report and the open
source licenses (pushed from Settings), Moonlight hosts (pushed from
Connections; a PIN a host mints elsewhere shows it with `external(.showPage)`),
Configure binding (`Page.configureBinding(slotId:)`, pushed from a Home row
or a Controllers card onto the destination that asked, home `Home`), Dead
zones & motion (`Page.deadZones(slotId:)`, pushed from a Controllers card),
Set up Dish (`Page.setup(seedSlotId:)`, always on Home's stack through
`openSetup`) and Help & FAQ (`Page.help`, pushed from Settings ▸ Setup &
help).

### The welcome

On a first run (`onboarding_welcome_completed` unset, read through
`OnboardingPreferenceStore` when the `NavigationStore` is built) the state's
`showingWelcome` is up and the shell draws `WelcomeView` over everything in
a `ZStack`, full-window, not a sheet: the desktops' four pages
(`WelcomeMappers`), their step dots, Back / Skip / Next, Finish on the last,
and Esc as Skip. The page index is the view's own; every word, the dots and
which way Next and Back turn come from `welcomeState(page:)`. Skip and
Finish send `welcome(.skip / .finish)`; the store's effect persists the
flag, so the welcome shows once.

### The header

The shell draws the header over every page from one `ShellState`
([`ShellMappers.swift`](../Sources/Dish/UI/Mappers/ShellMappers.swift)); a page
never draws its own title bar.

- **Back chevron** while a page is pushed, never at a destination's root.
- **Title**: the pushed page's, else the destination's.
- **Streaming pill**: the shell's own, present on every page while a
  controller streams, worded from the keep-awake reach ("Streaming · computer
  kept awake", "Streaming · display kept awake", or "Streaming" when the
  preferences hold nothing), with a **Configure** button that selects
  Settings. Do not add a second one.
- **Microphone chip**: the app-wide word for every armed microphone, live in
  the error tone, muted calm; one click mutes or unmutes them all.
- **Status line**: the dashboard's headline and summary under their dot, or
  the page's own line where the desktops give it one (Support Dish, Open
  source licenses).

### The leave guard

A page with a draft arms the guard (`guardLeave(true)`) while it shows:
Configure binding, whenever its draft differs from what it opened with,
asking "Leave without applying?" (Discard / Keep editing), and the setup
walk once it is past its first page (`setupLeaveGuarded`), asking "Leave
setup?" (Discard / Keep setting up). Any
move that would replace or unwind the stack from outside the page (a rail
click, the chevron, ⌘[, the menu-bar item) is then held as
`pendingLeaveGuard` until the page answers `.stay` or `.leave`; a request
from the menu bar still brings the window forward so the question is seen.
The page's own `push` is never held, and any move that runs releases the
guard: a page re-arms it when it shows again.

### One toast host

`NotificationOverlay` is registered once, at the shell, above every page. A
page never adds its own.

### Modals and inline cards

Only short confirmations macOS expects as alert sheets may be modal, raised
with `confirmationDialog` from a view state the model drives: today, Forget
(`requestForget` / `confirmForget` / `cancelForget`, the dialog's words from
`forgetDialog`) and the leave guards' "Leave without applying?" and "Leave
setup?", shown while `pendingLeaveGuard` holds a move. The setup walk's two
blockers (Connection lost, Controller unplugged) are not modal: a
`BlockerCard` stands in for the step until Start over or Exit. There is no `.sheet` anywhere under
`Sources/Dish`; "Applying binding…" is an in-page overlay (`ApplyOverlay`),
not a modal.

Everything else that would have been a sheet is an **inline card inside the
row that started it**: the satellite pairing card under its FOUND row or
PAIRED card, the Moonlight PIN card inside its host's row, the "Add a host by
address" form under the Moonlight hosts header. A card is drawn from the
row's state (the row carries its card's state, or nil), and closes when that
state goes; leaving the page ends what the card waits on
(`pageDisappeared(.connections)` closes the pairing card,
`pageDisappeared(.moonlightHosts)` ends the Moonlight pairing).

## Pages

A page is `Sources/Dish/UI/Pages/<Name>Page.swift`, at most 200 effective
lines, with its sections as further `View` types in the same folder.

1. **One view state per page**, a struct of rendered values (localized
   strings, `DishTheme` tokens, flags, chip models) with an explicit case
   for every condition it draws: empty, content, missing. It is built by a
   pure mapper in `Sources/Dish/UI/Mappers/<Name>Mappers.swift` that takes
   `words: L10n = .app` last, tested in
   `Tests/DishTests/Mappers/<Name>MappersTests.swift`, one test per flow.
2. **A body is layout.** Layout, a `switch` over the view state, and intent
   calls. No string formatting, no `Date()`, no `NSPasteboard`, `NSWorkspace`,
   `UserDefaults`, `URLSession`, `Task.sleep` or Combine subscriptions, no
   engine lookups. Links open through SwiftUI's `openURL`; copies go through
   the scene's `pasteboard` environment value
   ([`Pasteboard.swift`](../Sources/Dish/Services/Pasteboard.swift)).
3. **Intents only.** A user action is a call on `AppModel` or an event to the
   `NavigationStore`.
4. **Lifecycle hooks forward.** `onAppear` / `onDisappear` call
   `model.pageAppeared(…)` / `model.pageDisappeared(…)` and nothing else: the
   Diagnostics source ticks, the inspector is armed, Settings re-reads the
   crash log and ticks the update clock, and the crash report reads the log
   there, not in the view.
5. **Every word is an `L10n` property**, the desktops' words and
   translations where they have one.

## View purity

A view is layout. The scene root hands the window three objects,
`AppModel`, `NavigationStore` and `DishNotificationCenter`, and no engine
object besides; everything else a page draws is a published fact of the
model (`slots`, `connections`, `micIndicator`, `micPermitted`,
`pairingTarget`, `moonlightPin`, `shellFacts`, and what the model's
extensions derive from them), turned into the page's state by its mapper.
`ShellFacts` carries, beyond the shell's own: the preferences Settings
draws (`preferences`, with the global switches in `forwarding`), the
update clock (`updateClock`, re-read every 60 s while Settings shows, so
"last checked 5 minutes ago" ticks with no clock in a view), the crash
log's text, the Diagnostics source's snapshot, the flight recorder's lines
and the inspector's reading. Every setter a page reaches is an intent:
Settings' are in `AppModel+Preferences.swift` (`setThemeMode`,
`setRumbleForwarded`, `setKeepAwakeMode`, `checkForUpdatesNow`,
`skipAvailableUpdate`, …). A copy goes through the `pasteboard` environment
value, a link through `openURL`.

[`ViewPurityTests`](../Tests/ArchitectureTests/ViewPurityTests.swift) holds
every file under `Sources/Dish` that declares a `View` to these rules, line
by line (a whole-line comment is not code):

| # | Rule | Caught by | Where |
|---|---|---|---|
| V1 | No clock | `Date()`, `TimelineView` | every view |
| V2 | No IO | `NSPasteboard`, `NSWorkspace`, `UserDefaults`, `URLSession` | every view |
| V3 | No waiting | `Task.sleep`, `Timer.`, `DispatchQueue.` | every view |
| V4 | No subscriptions | `.sink(` | every view |
| V5 | No formatting | `String(format:`, `.formatted(`, any `…Formatter` | every view |
| V6 | Three objects observed | an `@EnvironmentObject`, `@ObservedObject` or `@StateObject` of any type but `AppModel`, `NavigationStore`, `DishNotificationCenter` | every view |
| V7 | No engine objects | `wifi.`, `moonlight.`, `updates.`, `crashLog.`, `diagnostics.`, `diagnosticsLog.`, `inspector.`, `settings.`, `keepAwake.`, `theme.`, `background.`, `updatePreferences.`, `crashReporting.`, `input.`, `hub.` | every view |
| V8 | The model is facts and intents | `model.<name>` where `<name>` is neither a fact (an `@Published` or computed `var` of an `AppModel` file) nor an intent (a `func` of one) | every view |
| V9 | No decision on the model | `if` / `guard` / `switch` over a fact, a ternary on `model.…`, a lookup (`.first`, `.filter`, `.contains`, `.isEmpty`, `.count`, `.map`) on a fact; an intent's answer (`if model.addByAddress(…)`) is the model's decision and passes | every view |
| V10 | No token picked | a ternary between `DishTheme` / `DishFont` tokens or `Color.clear` | pages |
| V11 | No boolean rules | `&&`, `\|\|` | pages |
| V12 | No fallback words | `??`, `.isEmpty ?` | pages |

"Pages" are every view but the components, which own their states (K2):
the kit, the brand glyphs (`BrandIcon*.swift`), the loaders
(`DishLoaders.swift`) and the theme's button styles (`Theme.swift`). A
choice a page would have made is a mapper's: a colour or a font is a
function returning the token (`selectionLook`, `signalRowFill`,
`licenseHeadingFont`), an enablement rule a flag in the state
(`InspectorBenchState`, `UpdateRowState.canCheck`), a fallback word the
state's string.

The allowlist is one entry: `DishLoaders.swift` may use `TimelineView` (V1),
because the loaders and `DishCrawl` (the wire's crawling dashes) animate on
the display's clock, which says nothing about the domain; the test fails if
the allowance is no longer needed. `DishApp.swift`, `AppKitLifecycle.swift`
and `Sources/Dish/Services` are the scene and its seams, not views: the
sweep checks they declare none, and they may read the clock, the pasteboard
and the engine's publishers directly. The scene drives
`.preferredColorScheme` from `shellFacts.preferences.theme`, so a theme
change republishes the model and the scene follows it.

[`NavigationCoverageTests`](../Tests/ArchitectureTests/NavigationCoverageTests.swift)
keeps the map whole: every `Destination` and `Page` case has its title
worded in `ShellMappers` (`destinationTitle`, `pushedPageTitle`), its
`Sources/Dish/UI/Pages/<Name>Page.swift`, its
`Tests/DishTests/Mappers/<Name>MappersTests.swift`, and a branch of the
shell's root or pushed switch.

## The Connections pages

Both pages are drawn from `ShellFacts.connections` (`ConnectionsFacts`: what
the last scans heard and whether one runs, the pairings in flight, the
Moonlight hosts' phases, apps and picks, the Forget waiting for its answer
and the address field that last refused), the model's connection rows and
slots, and the open pairing card or PIN. The engine vends a connection's
name, address and port as data; `connectionTitle` and
`connectionAddressLine` word them.

- **Connections** ([`ConnectionsMappers.swift`](../Sources/Dish/UI/Mappers/ConnectionsMappers.swift)):
  `pageAppeared(.connections)` runs the page-open scan once the Local Network
  prompt has been explained (`ConnectionsFacts.localNetworkPrimed`, the
  `local_network_primed` key): before the first scan ever, FOUND is
  Android's explain-then-ask card, "macOS will ask to let Dish find
  satellites on your network" with "Show me the prompt"
  (`primeLocalNetwork`, which runs the scan that makes macOS ask; the Scan
  button primes too). The page-open scan is quiet: the empty state says what
  a scan did not find (the local-network refusal as its hint, with "Open
  System Settings" on Privacy & Security › Local Network through `openURL`),
  and only the Scan button's sweep raises the toast, whose refusal carries
  the same button. FOUND is
  looking, nothing found (Get Satellite ↗, Scan again) or rows with Pair…;
  a "Moonlight hosts ›" row pushes `Page.moonlightHosts`; PAIRED is a card
  per remembered satellite with its chips (tier, protocol, link), the
  read-only CARRYING manifest, one action by the link's state
  (`satelliteActions`, dispatched by `perform(_:on:)`) and Forget behind ⋯;
  the add-by-address field is `addByAddress(.satellite, _)`.
- **Moonlight hosts** ([`MoonlightHostsMappers.swift`](../Sources/Dish/UI/Mappers/MoonlightHostsMappers.swift)):
  its own scan, the trust word (Paired, Remembered, Not paired), the
  controllers count and the tier, the app picker (`pickMoonlightApp`), the
  session's way out (`moonlightRowActions`, dispatched by
  `perform(_:onHost:)`), Forget behind ⋯ for a host the records know, the
  inline add form (`addByAddress(.moonlight, _)`) and the PIN card.

## The controller pages

Home, Controllers, Configure binding and Dead zones are drawn from the
model's slots and connections and from four parts of `ShellFacts`: the
global switches (`forwarding`), the stored dead zones (`deadzones`), the
live rates (`telemetry`, a `TelemetrySource` that ticks while Home or
Controllers shows: `pageAppeared(.home / .controllers)`) and the binding
being configured (`binding`). No page holds an engine environment object.

- **Home** ([`HomeMappers.swift`](../Sources/Dish/UI/Mappers/HomeMappers.swift)):
  the desktops' signal-path diagram. A boxed row per pad: the pad node (its
  name; its family, battery and "Unbound"), the `WireLine` (live only on a
  session that is up, captioned with the pad's measured rate and the link's
  latency, else "live"; "idle" and dashed otherwise; crawling while the link
  comes up or an apply runs for it), and the host node (name, address, "slot n
  of 4" on a satellite and a Moonlight host alike, the link chip); under it the
  `BindingStrip`: the emulated type as a fact, then the controller's chips,
  the switches among them clickable in place (`SlotChipAction`), the mic's
  word and lamp, and Edit › into `Page.configureBinding`. A pad with no
  binding is a ghost "Bind…" card that opens the setup walk answered with
  that pad (`openSetup(seedSlotId:)`); "Set up a controller", under the rows
  whenever there are any, and the empty state's "Set up Dish ›" open it from
  its first page. The `TelemetryFooter` carries events/s, sends/s and the total.
- **Controllers** ([`ControllersMappers.swift`](../Sources/Dish/UI/Mappers/ControllersMappers.swift)):
  a card per pad with its dot, name, family and measured rate (GameController
  keeps the transport to itself, so there is no Bluetooth / USB word and no
  Poll Hz, which is the Direct path's), "Bound · host ›" or "not bound" with
  Bind…, the Gyro / Touchpad / Lightbar / battery chips, the mic's live or
  muted button, the motion rate, and Dead zones… into `Page.deadZones`.
- **Configure binding** ([`ConfigureBindingMappers.swift`](../Sources/Dish/UI/Mappers/ConfigureBindingMappers.swift)):
  `pageAppeared(.configureBinding(slotId:))` opens a `BindingDraft` (DishCore)
  seeded from the binding, the type pick and the controller's switches, and
  the engine keeps the *candidate*, the pad as the draft would bind it, which
  the type picker and "What carries" read. Every control sends
  `editBinding(_:)`; nothing is written until `applyBinding(draft)`, which
  writes the switches, the type and the binding together and follows the run
  as `ApplyProgress`: a Moonlight binding is a durable intent and is done at
  once; a satellite in session takes the PUT at once ("Applying on the
  host"); one without a session is reached for and waits ("Binding",
  cancellable with `cancelApply()`, which writes back what was there); the
  host has 8 s to confirm or refuse. The overlay's Done pops the page; a
  failure stays with the draft intact. `pageDisappeared` drops the draft.
- **Dead zones & motion** ([`DeadZonesMappers.swift`](../Sources/Dish/UI/Mappers/DeadZonesMappers.swift)):
  the pad's stick and trigger flats as `SliderRow`s over 0 to 30 % with
  their readouts, `setStickDeadzone` / `setTriggerDeadzone` on every move,
  `resetDeadzones` back to the defaults, and the pad's own motion switch.

## The setup walk

Set up Dish ([`SetupPage`](../Sources/Dish/UI/Pages/SetupPage.swift),
[`SetupMappers.swift`](../Sources/Dish/UI/Mappers/SetupMappers.swift)) is the
desktops' wizard, "the one way a binding is created", as a pushed page and
never a dialog. Its state is a pure `SetupWizardMachine`
([`SetupWizard.swift`](../Sources/DishCore/Reducers/SetupWizard.swift), in
DishCore): the step (Input · Destination · Type · Session · Feel · Review),
the three stages its pips draw, the draft (a `BindingDraft`), the chosen
host's kind (Session is stepped over, both ways, for a satellite), whether
that host was ever live, the blocker and whether the apply landed; events in
(`pickPad`, `pickDestination`, `edit`, `next`, `back`, `padPresent`,
`hostLive`, `startOver`, `applied`), effects out as data (`scan` as
Destination comes up, `apply` on Review's next). The model keeps it in
`ShellFacts.setup` (`AppModel+Setup.swift`: `startSetup(seed:)` on
`pageAppeared(.setup)`, `pickSetupPad`, `pickSetupDestination`, `editSetup`,
`setupNext`, `setupBack`, `startSetupOver`, `endSetup` on leaving) and mirrors
its draft into the binding facts, so the type picker, "What carries" and the
one write are Configure binding's own: Review's Bind is `applyBinding`, shown
by the same `ApplyOverlay`, whose Done sends `setupEnded(.applied)`.

- The pips (`StepPips`) are pinned above, the footer below: ‹ Back, Cancel
  (and Esc), the step's position ("Step 2 of 3 · Destination") and Continue ›
  or Bind; the header's line is "Nothing is changed until the last step".
- **Input** lists the attached pads, or waits with "Plug your controller in".
  **Destination** lists the paired satellites and Moonlight hosts to pick
  and the satellites a sweep heard, each with Pair… and its pairing card in
  the row, exactly as Connections draws them; before the first scan ever it
  is the priming card, with nothing to pick it is "No PCs found yet" with Get
  Satellite ↗, Rescan and, after a refusal, Open System Settings. **Type** is
  the Emulate picker; **Session** the Moonlight app picker; **Feel** the
  pad's switches on the draft; **Review** the binding drawn and "What
  carries".
- A pad unplugged or a host that was live and dropped raises a blocker in
  the page; Start over sends `startOver`, Exit `setupEnded(.exited)`.

## Kit rules

A kit component lives in `Sources/Dish/UI/Kit/` and is drawn from any page's
state. The desktops' C1 to C8, adapted:

| # | Rule |
|---|---|
| K1 | **Two pages that would draw the same thing use a kit component.** One that has a variant is still a kit component. |
| K2 | **A kit component owns its own states.** A page never sets an opacity to say disabled, paints a hover wash or draws a focus ring around one. |
| K3 | **A kit component never reads the domain.** It imports SwiftUI and Foundation only and observes no model (`ImportBoundariesTests.testAKitComponentReadsNoDomain`); it takes values, tokens and closures, and the page hands it its state. |
| K4 | **One name per colour.** A tinted colour is its own `DishTheme` token, never a token times an alpha (`ThemeTokenTests`). |
| K5 | **Colours stay tokens.** A component passes `Color` tokens through and never builds one from components or hex. |
| K6 | **Every state a component can be in is reachable from a mapper test.** A state no test builds is not shipped. |
| K7 | **Tokens only.** A kit component sets no raw spacing, padding, corner, frame or glyph size; each is a `DishSize` or `DishSpace` token (`ThemeTokenTests.testAKitComponentSetsNoRawSize`). |
| K8 | **Glyphs are never recoloured by state.** `BrandIcon` tints by the brand palette; state colour lives in the dot and the chip. |

Today's kit: `ShellHeader` (with `StreamingPill` and `MicChip`), `RailItem`,
`EmptyStateCard` (with an optional hint and actions), `TwoColumnLayout`,
`PairingCard`, `PinCells`, `ScanHeader`, `StateChip`, `CapabilityChip`,
`FlowLayout`, `WireLine`, `BindingStrip`, `ApplyOverlay`, `SliderRow`,
`TelemetryFooter`, `StepPips` (the welcome's dots and the walk's pips),
`BlockerCard` and `RailAction`.

## Keyboard

| Keys | Action |
|---|---|
| ⌘, | Settings |
| ⌘1, ⌘2, ⌘3 | Home, Controllers, Connections |
| ⌘[ | Back, enabled exactly while a page is pushed |
| Esc | Skip on the welcome; Cancel in the setup walk, through its leave guard |
| Return | Next or Finish on the welcome; Continue › or Bind in the setup walk |
