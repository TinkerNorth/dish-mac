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

Cyan on deep space, as the website.

| Token | Value | Role |
|---|---|---|
| `DishTheme.background` | `0x060818` | Window body (`--tn-ink`) |
| `DishTheme.surface` | `0x0C1027` | Cards and rows (`--tn-night`) |
| `DishTheme.surfaceDim` | `0x131A3A` | Recessed picker rows (`--tn-deep`) |
| `DishTheme.primary` | `0x4FE3FF` | The accent (`--tn-signal`) |
| `DishTheme.primaryDark` | `0x2C93AD` | Pressed and disabled accent (`--tn-signal-dim`) |
| `DishTheme.onPrimary` | `0x060818` | Text on the accent |
| `DishTheme.onSurface` | `0xE6ECFF` | Body text (`--body-color`) |
| `DishTheme.muted` | `0x93A0C8` | Secondary text and resting dots (`--muted`) |
| `DishTheme.outline` | accent @ 18 % | Dividers and outlined chips |
| `DishTheme.success` | `0x22C55E` | Live, charging, success toasts |
| `DishTheme.error` | `0xE74C3C` | Errors, a near-empty battery |
| `DishTheme.warning` | `0xF59E0B` | Warnings, a low battery |
| `DishTheme.cardStroke` | accent @ 12 % | Card borders |

Fills derived from the palette, named so no view multiplies an alpha itself:

| Token | Value | Role |
|---|---|---|
| `DishTheme.pressedFill` | accent @ 12 % | A pressed outlined button |
| `DishTheme.chipFill` | accent @ 14 % | A capability chip whose feature is on |
| `DishTheme.errorFill` | error @ 12 % | The inline error strip |
| `DishTheme.spinnerTrack` | accent @ 25 % | The spinner's resting ring |
| `DishTheme.barTrack` | accent @ 22 % | The indeterminate bar's track |
| `DishTheme.shadow` | black @ 35 % | A toast's drop shadow |

The brand glyphs (`BrandIcon`) use the brand book's colours, not the accent:

| Token | Value | Role |
|---|---|---|
| `DishTheme.brandGlyph` | `0x8FCFE3` | Glyph fill |
| `DishTheme.brandGlyphOff` | `0x8FCFE3` @ 40 % | Glyph fill in the "off" state |
| `DishTheme.brandRuneOff` | `0x8FCFE3` @ 45 % | The Bluetooth rune in the "off" state |
| `DishTheme.brandGlyphHighlight` | white @ 55 % | Glyph highlight |
| `DishTheme.brandGlyphHighlightOff` | white @ 22 % | Glyph highlight in the "off" state |
| `DishTheme.brandSlashCut` | `0x0F1620` | The dark cut under an "off" slash |

## Type scale (`DishFont`)

| Token | Size / weight / design | Role |
|---|---|---|
| `DishFont.windowTitle` | 18 semibold | The Connections sheet's headline |
| `DishFont.title` | 17 semibold | The dashboard status line, the Settings headline |
| `DishFont.sheetTitle` | 16 semibold | The pairing sheet's headline |
| `DishFont.body` | 14 medium | A row's name, a toggle's title |
| `DishFont.icon` | 14 | An icon-only button's glyph |
| `DishFont.monoField` | 14 monospaced | The PIN field |
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
