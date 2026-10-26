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

The five destinations, in rail order, are Home, Controllers and Connections at
the top, then Support Dish and Settings pinned to the footer over the version
label. The space between the two groups is where the Set up action goes; it
is an action, not a destination. Pushed pages today: Diagnostics, the
controller inspector (pushed from Diagnostics), the crash report and the open
source licenses (pushed from Settings), and Moonlight hosts (pushed from
Connections; a PIN a host mints elsewhere shows it with `external(.showPage)`).

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

A page with a draft arms the guard (`guardLeave(true)`) while it shows. Any
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
`forgetDialog`). There is no `.sheet` anywhere under `Sources/Dish`.

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
   Diagnostics source ticks, the inspector is armed and Settings re-reads the
   crash log there, not in the view.
5. **Every word is an `L10n` property**, the desktops' words and
   translations where they have one.

## The Connections pages

Both pages are drawn from `ShellFacts.connections` (`ConnectionsFacts`: what
the last scans heard and whether one runs, the pairings in flight, the
Moonlight hosts' phases, apps and picks, the Forget waiting for its answer
and the address field that last refused), the model's connection rows and
slots, and the open pairing card or PIN. The engine vends a connection's
name, address and port as data; `connectionTitle` and
`connectionAddressLine` word them.

- **Connections** ([`ConnectionsMappers.swift`](../Sources/Dish/UI/Mappers/ConnectionsMappers.swift)):
  `pageAppeared(.connections)` runs the page-open scan, which is quiet: the
  empty state says what a scan did not find (the local-network refusal as
  its hint), and only the Scan button's sweep raises the toast. FOUND is
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
`PairingCard`, `PinCells`, `ScanHeader`, `StateChip`.

## Keyboard

| Keys | Action |
|---|---|
| ⌘, | Settings |
| ⌘1, ⌘2, ⌘3 | Home, Controllers, Connections |
| ⌘[ | Back, enabled exactly while a page is pushed |
