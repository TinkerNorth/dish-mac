# dish-mac — Design tokens

All theme values live in [Sources/Dish/UI/Theme.swift](Sources/Dish/UI/Theme.swift).

Token names follow the cross-repo schema documented in
`d:\TinkerNorth\BRAND.md` (TinkerNorth design system). When updating a value,
keep it in sync with the matching token in dish-android, dish-linux, and the
Satellite local web UI.

## Available tokens

Palette: **cyan / deep-space** — mirrors dish-website.

| Token | Value | Role |
|---|---|---|
| `DishTheme.background` | `0x060818` | Body (`--tn-ink`) |
| `DishTheme.surface` | `0x0C1027` | Card (`--tn-night`) |
| `DishTheme.surfaceDim` | `0x131A3A` | Recessed (`--tn-deep`) |
| `DishTheme.primary` | `0x4FE3FF` | Main accent — cyan (`--tn-signal`) |
| `DishTheme.primaryDark` | `0x2C93AD` | Pressed / disabled (`--tn-signal-dim`) |
| `DishTheme.onPrimary` | `0x060818` | Text on primary |
| `DishTheme.onSurface` | `0xE6ECFF` | Body text (`--body-color`) |
| `DishTheme.muted` | `0x93A0C8` | Secondary text (`--muted`) |
| `DishTheme.outline` | cyan @ 18% α | Borders — `Color(hex: 0x4FE3FF, alpha: 0.18)` |
| `DishTheme.success` | `0x22C55E` | Status — success |
| `DishTheme.error` | `0xE74C3C` | Status — error |
| `DishTheme.warning` | `0xF59E0B` | Status — warning |
| `DishTheme.cardStroke` | primary @ 12% α | Card stroke — `Color(hex: 0x4FE3FF, alpha: 0.12)` |

## How to use

```swift
import SwiftUI

struct MyCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(DishTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DishTheme.cardStroke, lineWidth: 1)
            )
    }
}
```

Pre-built component styles in [Theme.swift](Sources/Dish/UI/Theme.swift):

- `SectionHeader(title:)` — monospace section labels in primary
- `StatusDot(color:)` — small colored dot
- `DishOutlinedButtonStyle` — outlined button style

## Outliers

None. All theme color references go through `DishTheme.*`; no `Color(hex:)`
literals exist outside `Theme.swift`.
