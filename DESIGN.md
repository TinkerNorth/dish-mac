# dish-mac — Design tokens

Every design value lives in [Sources/Dish/UI/Theme.swift](Sources/Dish/UI/Theme.swift):
the palette as `DishTheme`, the type scale as `DishFont`. A view outside that
file writes no raw colour, derives no colour from a token, and sets no raw
font size; `Tests/ArchitectureTests/ThemeTokenTests.swift` fails the build on
any of the three, and fails it again when a token below is missing from this
page.

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
| `DishTheme.chipFill` | accent @ 14 % | accent @ 14 % | A capability chip whose feature is on |
| `DishTheme.errorFill` | error @ 12 % | error @ 12 % | The inline error strip |
| `DishTheme.spinnerTrack` | accent @ 25 % | accent @ 25 % | The spinner's resting ring |
| `DishTheme.barTrack` | accent @ 22 % | accent @ 22 % | The indeterminate bar's track |
| `DishTheme.shadow` | black @ 35 % | `0x0C1430` @ 35 % | A toast's drop shadow |

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
| `DishFont.windowTitle` | 18 semibold | The Connections sheet's headline |
| `DishFont.title` | 17 semibold | The dashboard status line, the Settings headline |
| `DishFont.sheetTitle` | 16 semibold | The Moonlight PIN sheet's headline |
| `DishFont.body` | 14 medium | A row's name, a toggle's title |
| `DishFont.icon` | 14 | An icon-only button's glyph |
| `DishFont.toastGlyph` | 14 semibold | A toast's leading glyph |
| `DishFont.toastTitle` | 13 semibold | A toast's headline |
| `DishFont.detail` | 12 | Secondary copy, hints, text fields |
| `DishFont.control` | 12 medium | Button labels, the bind picker's row names |
| `DishFont.caption` | 11 | A row's second line, a toggle's explanation |
| `DishFont.mono` | 11 monospaced | Section eyebrows, a toast's body |
| `DishFont.micro` | 10 medium | Chip labels, the battery percentage |
| `DishFont.microRegular` | 10 | The battery glyph, the bind picker's detail line |
| `DishFont.monoChip` | 10 monospaced | A row's status chip |
| `DishFont.closeGlyph` | 10 bold | The close cross on a banner |

## Components

Also in `Theme.swift`:

- `SectionHeader(title:)`, the tracked monospace eyebrow in the accent.
- `StatusDot(color:)`, the 8 pt dot beside a glyph.
- `DishOutlinedButtonStyle`, the outlined button; disabled drops to 0.4 opacity.

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
        Text(L10n.app.manage)
            .font(DishFont.body)
            .foregroundColor(DishTheme.onSurface)
            .padding(12)
            .background(DishTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1))
    }
}
```
