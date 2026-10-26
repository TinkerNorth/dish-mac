# dish-mac — Design tokens

Every design value lives in [Sources/Dish/UI/Theme.swift](Sources/Dish/UI/Theme.swift):
the palette as `DishTheme`, the type scale as `DishFont`, the shell's measures
as `DishSize` and the spacing scale as `DishSpace`. A view outside that file
writes no raw colour, derives no colour from a token, and sets no raw font
size; a kit component (`Sources/Dish/UI/Kit`) sets no raw size either.
`Tests/ArchitectureTests/ThemeTokenTests.swift` fails the build on any of
them, and fails it again when a token below is missing from this page.

Palette names follow the cross-repo schema (the TinkerNorth `BRAND.md`).
When a value changes, change the matching token in dish-android, dish-linux,
dish-windows and the Satellite web UI in the same breath.

## Palette (`DishTheme`)

Cyan on deep space in the dark, the Linux client's light palette in the
light. Every colour token is one `Color(dark:light:alpha:)`, resolved through
`NSColor(name:dynamicProvider:)` at draw time, so a view never asks which
appearance is on: the Theme setting (System, Light, Dark) sets the window's
colour scheme with `preferredColorScheme`, and the tokens follow it.

| Token | Dark | Light | Role |
|---|---|---|---|
| `DishTheme.background` | `0x060818` | `0xF5F7FC` | Window body (`--tn-ink`) |
| `DishTheme.surface` | `0x0C1027` | `0xFFFFFF` | Cards and rows (`--tn-night`) |
| `DishTheme.surfaceDim` | `0x131A3A` | `0xE7ECF6` | Recessed picker rows (`--tn-deep`) |
| `DishTheme.primary` | `0x4FE3FF` | `0x0E7C97` | The accent (`--tn-signal`) |
| `DishTheme.primaryDark` | `0x2C93AD` | `0x0A5E73` | Pressed and disabled accent (`--tn-signal-dim`) |
| `DishTheme.onPrimary` | `0x060818` | `0xFFFFFF` | Text on the accent |
| `DishTheme.onSurface` | `0xE6ECFF` | `0x0C1430` | Body text (`--body-color`) |
| `DishTheme.muted` | `0x93A0C8` | `0x5A6680` | Secondary text and resting dots (`--muted`) |
| `DishTheme.outline` | accent @ 18 % | accent @ 18 % | Dividers and outlined chips |
| `DishTheme.success` | `0x22C55E` | `0x1B873F` | Live, charging, success toasts |
| `DishTheme.error` | `0xE74C3C` | `0xC0392B` | Errors, a near-empty battery |
| `DishTheme.warning` | `0xF59E0B` | `0xB7791F` | Warnings, a low battery |
| `DishTheme.cardStroke` | accent @ 12 % | accent @ 12 % | Card borders |

Fills derived from the palette, named so no view multiplies an alpha itself
("accent" and "error" mean that appearance's own value):

| Token | Dark | Light | Role |
|---|---|---|---|
| `DishTheme.pressedFill` | accent @ 12 % | accent @ 12 % | A pressed outlined button |
| `DishTheme.chipFill` | accent @ 14 % | accent @ 14 % | A capability chip whose feature is on; every `StateChip` |
| `DishTheme.errorFill` | error @ 12 % | error @ 12 % | The inline error strip |
| `DishTheme.spinnerTrack` | accent @ 25 % | accent @ 25 % | The spinner's resting ring |
| `DishTheme.barTrack` | accent @ 22 % | accent @ 22 % | The indeterminate bar's track |
| `DishTheme.shadow` | black @ 35 % | `0x0C1430` @ 35 % | A toast's drop shadow |
| `DishTheme.railActiveFill` | accent @ 14 % | accent @ 14 % | The rail item of the destination on screen |
| `DishTheme.pillFill` | accent @ 14 % | accent @ 14 % | The shell's streaming pill |

The one hue beyond the accent, kept for donations (the desktops' `pulse`):

| Token | Dark | Light | Role |
|---|---|---|---|
| `DishTheme.pulse` | `0xFF6FB5` | `0xC2417F` | The rail's Support Dish heart, the Support page's call to action and eyebrows |

The brand glyphs (`BrandIcon`) use the brand book's colours, not the accent:

| Token | Dark | Light | Role |
|---|---|---|---|
| `DishTheme.brandGlyph` | `0x8FCFE3` | `0x2F7E96` | Glyph fill |
| `DishTheme.brandGlyphOff` | `0x8FCFE3` @ 40 % | `0x2F7E96` @ 40 % | Glyph fill in the "off" state |
| `DishTheme.brandRuneOff` | `0x8FCFE3` @ 45 % | `0x2F7E96` @ 45 % | The Bluetooth rune in the "off" state |
| `DishTheme.brandGlyphHighlight` | white @ 55 % | white @ 55 % | Glyph highlight |
| `DishTheme.brandGlyphHighlightOff` | white @ 22 % | white @ 22 % | Glyph highlight in the "off" state |
| `DishTheme.brandSlashCut` | `0x0F1620` | `0xF5F7FC` | The cut under an "off" slash, the window body's colour |

## Type scale (`DishFont`)

| Token | Size / weight / design | Role |
|---|---|---|
| `DishFont.pinDigit` | 22 semibold monospaced | A PIN cell's digit on the pairing card |
| `DishFont.pageTitle` | 20 bold | The shell header's page title |
| `DishFont.title` | 17 semibold | The Support page's headline, a notice's first heading |
| `DishFont.body` | 14 medium | A row's name, a toggle's title |
| `DishFont.icon` | 14 | An icon-only button's glyph |
| `DishFont.toastGlyph` | 14 semibold | A toast's leading glyph |
| `DishFont.toastTitle` | 13 semibold | A toast's headline |
| `DishFont.railLabel` | 13 | A rail item's label |
| `DishFont.railLabelActive` | 13 semibold | The label of the rail item on screen |
| `DishFont.detail` | 12 | Secondary copy, hints, text fields |
| `DishFont.control` | 12 medium | Button labels, the bind picker's row names |
| `DishFont.caption` | 11 | A row's second line, a toggle's explanation |
| `DishFont.mono` | 11 monospaced | Section eyebrows, a toast's body |
| `DishFont.micro` | 10 medium | Chip labels, the battery percentage |
| `DishFont.microRegular` | 10 | The battery glyph, the bind picker's detail line |
| `DishFont.monoChip` | 10 monospaced | A row's status chip |
| `DishFont.closeGlyph` | 10 bold | The close cross on a banner |

## Measures (`DishSize`)

The window's sizes and the rail's are the desktops' (`AppShell.qml`,
`TokensBridge.h`), so the three desktop clients open the same shape.

| Token | Value | Role |
|---|---|---|
| `DishSize.railExpanded` | 236 | The labelled rail |
| `DishSize.railCompact` | 52 | The collapsed rail, an icon strip |
| `DishSize.railGlyph` | 18 | A rail glyph's cell |
| `DishSize.railItemHeight` | 34 | A rail item's height |
| `DishSize.railAccentBar` | 3 | The bar beside the rail item on screen |
| `DishSize.badge` | 7 | The update dot on the Settings glyph |
| `DishSize.windowDefaultWidth` | 980 | The window as it first opens |
| `DishSize.windowDefaultHeight` | 640 | The window as it first opens |
| `DishSize.windowMinWidth` | 900 | The smallest the window goes |
| `DishSize.windowMinHeight` | 620 | The smallest the window goes |
| `DishSize.wideBreakpoint` | 980 | Settings goes to two columns from this page width |
| `DishSize.hairline` | 1 | A divider or a kit component's stroke |
| `DishSize.buttonSpinner` | 12 | A spinner inside a button or beside an eyebrow |
| `DishSize.chipRadius` | 6 | A chip's, the pill's and a rail item's corner |
| `DishSize.cardRadius` | 8 | A card's corner |

## Spacing (`DishSpace`)

| Token | Value |
|---|---|
| `DishSpace.s1` | 2 |
| `DishSpace.s2` | 4 |
| `DishSpace.s3` | 6 |
| `DishSpace.s4` | 8 |
| `DishSpace.s5` | 10 |
| `DishSpace.s6` | 12 |
| `DishSpace.s8` | 16 |
| `DishSpace.page` | 24, a page's inset from the content column's edges |

## Components

Also in `Theme.swift`:

- `SectionHeader(title:)`, the tracked, upper-cased monospace eyebrow in the accent.
- `StatusDot(color:)`, the 8 pt dot beside a glyph.
- `DishOutlinedButtonStyle`, the outlined button; disabled drops to 0.4 opacity.

The shell's own pieces live in `Sources/Dish/UI/Kit` and follow the kit
rules in [docs/UI_CONTRACT.md](docs/UI_CONTRACT.md): `ShellHeader` (with
`StreamingPill` and `MicChip`), `RailItem`, `EmptyStateCard`,
`TwoColumnLayout`, `PairingCard`, `PinCells`, `ScanHeader` and `StateChip`
(a word on the chip tint, coloured by its state's token).

Words are not design values but follow the same rule: a view reads them from
`L10n` ([Sources/Dish/L10n](Sources/Dish/L10n)), never from a
literal, and the derivations between model and view (a chip's text, a dot's
colour, a battery glyph) are pure functions under
[Sources/Dish/UI/Mappers](Sources/Dish/UI/Mappers), tested in `Tests/DishTests`.

## How to use

```swift
import SwiftUI

struct MyCard: View {
    var body: some View {
        Text(L10n.app.home)
            .font(DishFont.body)
            .foregroundColor(DishTheme.onSurface)
            .padding(12)
            .background(DishTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1))
    }
}
```
