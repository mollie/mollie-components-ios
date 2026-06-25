# Theming

Restyle the payment sheet to match your brand.

## Overview

Every entry point — ``MolliePaymentSheet``, ``MolliePaymentCardFormView``, and the `molliePaymentSheet(isPresented:clientToken:theme:endpoints:onResult:)` modifier — accepts a `theme` parameter. Omit it and the sheet renders with Mollie-branded defaults; pass a customized `MolliePaymentTheme` to recolor surfaces, retune type sizes, and adjust corner radius.

`MolliePaymentTheme` is `Sendable`, so a theme value can be constructed once and handed across actor boundaries safely.

```swift
let theme = MolliePaymentTheme()                 // Mollie-branded defaults

let result = await MolliePaymentSheet.present(
    from: viewController,
    clientToken: clientToken,
    theme: theme
)
```

A theme has three groups: colors, typography, and corner radius. Each group defaults independently, so you can override just one and inherit the rest.

```swift
let theme = MolliePaymentTheme(
    colors: brandColors,
    typography: .default,
    cornerRadius: 12
)
```

## Colors

`MolliePaymentTheme.Colors` carries the color tokens applied across the sheet — the pay button, field backgrounds and borders, body text, and the error state. Colors are stored as a `Sendable` `ColorValue` (RGBA components) rather than `UIColor`, so the theme needs no `@MainActor` constraint.

| Token | Where it appears |
| --- | --- |
| `primary` | Pay-button fill and focused-field highlight (defaults to Mollie blue) |
| `onPrimary` | Foreground on top of `primary` — pay-button title, inline spinner label (defaults to white) |
| `background` | Fill behind the whole sheet content area |
| `field` | Fill inside each input field (card number, expiry, CVC, cardholder name) |
| `fieldBorder` | Stroke around each input field and grouped container |
| `text` | Primary text color for field input and body copy |
| `error` | Validation error messages and the error state of an invalid field |

`primary`, `background`, `field`, `fieldBorder`, `text`, and `error` are required when you build a `Colors` set; `onPrimary` defaults to white so a Mollie-blue button renders correctly out of the box. Lifting `onPrimary` out as its own token lets you supply a light or pastel `primary` and switch the title to a dark color without forking the button view.

```swift
let brandColors = MolliePaymentTheme.Colors(
    primary: MolliePaymentTheme.ColorValue(red: 0.10, green: 0.12, blue: 0.88, alpha: 1.0),
    background: MolliePaymentTheme.ColorValue(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
    field: MolliePaymentTheme.ColorValue(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
    fieldBorder: MolliePaymentTheme.ColorValue(red: 0.8, green: 0.8, blue: 0.85, alpha: 1.0),
    text: MolliePaymentTheme.ColorValue(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0),
    error: MolliePaymentTheme.ColorValue(red: 0.85, green: 0.18, blue: 0.18, alpha: 1.0)
)
```

### ColorValue and dark mode

`MolliePaymentTheme.ColorValue` stores `red`, `green`, `blue`, and `alpha` as `Double` components in the `0`–`1` range. `alpha` defaults to `1` (opaque).

Each `ColorValue` carries an optional `dark` variant. Supply one and the token resolves to the dark values automatically when the interface is in dark mode; leave it `nil` and the same values are used in both light and dark.

```swift
let adaptiveText = MolliePaymentTheme.ColorValue(
    red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0,
    dark: MolliePaymentTheme.ColorValue(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0)
)
```

## Typography

`MolliePaymentTheme.Typography` sets the point sizes used across the sheet. All sizes are required except `sectionLabelFontSize`, which defaults to `15`.

| Size | Applies to |
| --- | --- |
| `titleFontSize` | The sheet's title |
| `bodyFontSize` | Body and explanatory copy |
| `fieldFontSize` | Text typed into the input fields |
| `buttonFontSize` | The pay-button title |
| `sectionLabelFontSize` | The "Card information" / "Card holder" section headers above each grouped field container |

```swift
let typography = MolliePaymentTheme.Typography(
    titleFontSize: 22,
    bodyFontSize: 15,
    fieldFontSize: 17,
    buttonFontSize: 17
)
```

## Corner radius

`cornerRadius` is the radius, in points, applied to the pay button and the grouped field containers. It defaults to `10`.

```swift
let theme = MolliePaymentTheme(cornerRadius: 16)
```
