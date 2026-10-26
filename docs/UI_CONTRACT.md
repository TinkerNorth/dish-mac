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
source licenses (pushed from Settings).

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

### Modals

Only short confirmations macOS expects as alert sheets may be modal. The
Moonlight PIN is the one remaining sheet, registered once at the shell, until
it moves inline onto its host's row. Pairing, Settings, Connections, the crash
report and the inspector are never sheets.

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
`EmptyStateCard`, `TwoColumnLayout`, `PairingCard`, `PinCells`.

## Keyboard

| Keys | Action |
|---|---|
| ⌘, | Settings |
| ⌘1, ⌘2, ⌘3 | Home, Controllers, Connections |
| ⌘[ | Back, enabled exactly while a page is pushed |
