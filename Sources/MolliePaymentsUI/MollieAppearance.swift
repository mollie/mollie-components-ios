import CoreGraphics
#if canImport(UIKit)
    import UIKit
#endif

/// Visual configuration applied to the Mollie payment sheet.
///
/// `package`-scoped: there is no public way to override the sheet's
/// appearance. The public surface always renders with
/// `MollieAppearance.default`; this type stays visible across
/// `MolliePaymentsUI`/`MollieComponents` target boundaries within the
/// package for the SDK's own internal theming plumbing.
package struct MollieAppearance {
    /// Colour tokens applied across the sheet — pay button, field
    /// backgrounds, borders, body text, and error states.
    package var colors: Colors
    /// Font sizes for the sheet's title, body copy, field text, button
    /// title, and grouped section headers.
    package var typography: Typography
    /// Corner radius (in points) applied to the pay button and the
    /// grouped field containers. Defaults to `8`, matching the Web SDK's
    /// `--mc-border-radius-md` token.
    package var cornerRadius: CGFloat
    /// Stroke width (in points) drawn around each grouped field container.
    /// Defaults to `1`, matching the Web SDK's field border.
    package var fieldBorderWidth: CGFloat
    /// Minimum height (in points) of an individual input field. Defaults
    /// to `56`, matching the Web SDK's field min-height.
    package var fieldMinHeight: CGFloat

    /// Creates a theme. Omit any argument to take the Mollie-branded
    /// defaults for that group; pass overrides to restyle the sheet.
    package init(
        colors: Colors = .default,
        typography: Typography = .default,
        cornerRadius: CGFloat = 8,
        fieldBorderWidth: CGFloat = 1,
        fieldMinHeight: CGFloat = 56
    ) {
        self.colors = colors
        self.typography = typography
        self.cornerRadius = cornerRadius
        self.fieldBorderWidth = fieldBorderWidth
        self.fieldMinHeight = fieldMinHeight
    }

    /// The Mollie-branded default theme — what every public entry point
    /// renders with, since appearance has no public override point.
    package static let `default` = MollieAppearance()
}

package extension MollieAppearance {
    struct Colors: Equatable {
        /// Brand accent colour: the pay-button fill and the focused-field
        /// highlight. Defaults to Mollie blue.
        package var primary: ColorValue
        /// Foreground colour rendered on top of `primary` (pay-button title,
        /// inline spinner label). Lifted out as a separate token so a
        /// merchant supplying a light/pastel `primary` can switch the
        /// title to a dark colour without forking the button view.
        package var onPrimary: ColorValue
        /// Fill behind the whole sheet content area.
        package var background: ColorValue
        /// Fill inside each input field (card number, expiry, CVC,
        /// cardholder name).
        package var field: ColorValue
        /// Stroke drawn around each input field and grouped container.
        package var fieldBorder: ColorValue
        /// Primary text colour for field input and body copy.
        package var text: ColorValue
        /// Colour for validation error messages and the error state of an
        /// invalid field.
        package var error: ColorValue
        /// Colour for a field's placeholder text (e.g. "1234 1234 1234
        /// 1234"). Previously unstyled — fields fell back to UIKit's
        /// system placeholder grey. Defaults to the Web SDK's
        /// `--mc-color-typography-placeholder`.
        package var placeholder: ColorValue

        /// Creates a colour set. `primary`, `background`, `field`,
        /// `fieldBorder`, `text`, and `error` are required; `onPrimary`
        /// defaults to white for use on the Mollie-blue pay button, and
        /// `placeholder` defaults to the Mollie-branded placeholder grey.
        package init(
            primary: ColorValue,
            onPrimary: ColorValue = ColorValue(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            background: ColorValue,
            field: ColorValue,
            fieldBorder: ColorValue,
            text: ColorValue,
            error: ColorValue,
            placeholder: ColorValue = ColorValue(red: 0.698, green: 0.682, blue: 0.667, alpha: 1.0)
        ) {
            self.primary = primary
            self.onPrimary = onPrimary
            self.background = background
            self.field = field
            self.fieldBorder = fieldBorder
            self.text = text
            self.error = error
            self.placeholder = placeholder
        }

        /// Mollie-branded default palette, ported from the Web SDK's
        /// resolved field tokens: blue accent, white surfaces, a
        /// light-grey field border, near-black
        /// text, a warm-grey placeholder, and a red error tone.
        package static let `default` = Colors(
            primary: ColorValue(red: 0.102, green: 0.122, blue: 0.878, alpha: 1.0),
            onPrimary: ColorValue(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            background: ColorValue(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            field: ColorValue(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            fieldBorder: ColorValue(red: 0.890, green: 0.894, blue: 0.918, alpha: 1.0),
            text: ColorValue(red: 0.071, green: 0.067, blue: 0.063, alpha: 1.0),
            error: ColorValue(red: 0.902, green: 0.0, blue: 0.161, alpha: 1.0),
            placeholder: ColorValue(red: 0.698, green: 0.682, blue: 0.667, alpha: 1.0)
        )
    }

    struct Typography: Equatable {
        /// Point size of the sheet's title.
        package var titleFontSize: Double
        /// Point size of body / explanatory copy in the sheet.
        package var bodyFontSize: Double
        /// Point size of text typed into the input fields.
        package var fieldFontSize: Double
        /// Point size of the pay-button title.
        package var buttonFontSize: Double
        /// Font size for the "Card information" / "Card holder" section
        /// headers above each grouped field container. Theme-driven so
        /// merchants can scale the form header weight without forking
        /// the grouped view.
        package var sectionLabelFontSize: Double

        /// Creates a typography set. All sizes are required except
        /// `sectionLabelFontSize`, which defaults to `15`.
        package init(
            titleFontSize: Double,
            bodyFontSize: Double,
            fieldFontSize: Double,
            buttonFontSize: Double,
            sectionLabelFontSize: Double = 15
        ) {
            self.titleFontSize = titleFontSize
            self.bodyFontSize = bodyFontSize
            self.fieldFontSize = fieldFontSize
            self.buttonFontSize = buttonFontSize
            self.sectionLabelFontSize = sectionLabelFontSize
        }

        /// Default type scale tuned for the stock sheet layout.
        package static let `default` = Typography(
            titleFontSize: 22,
            bodyFontSize: 15,
            fieldFontSize: 17,
            buttonFontSize: 17,
            sectionLabelFontSize: 15
        )
    }

    /// Sendable colour token. Stored as RGBA components rather than `UIColor`
    /// so the theme can cross actor boundaries without a `@MainActor`
    /// constraint. An optional `dark` variant resolves at render time in
    /// `uiColor` via `UIColor(dynamicProvider:)`; `nil` means "use the same
    /// values in light and dark".
    struct ColorValue: Equatable {
        /// Red component, `0`–`1`.
        package var red: Double
        /// Green component, `0`–`1`.
        package var green: Double
        /// Blue component, `0`–`1`.
        package var blue: Double
        /// Opacity, `0` (transparent) to `1` (opaque).
        package var alpha: Double

        /// Dark variant is stored in a single-element array because Swift
        /// value types cannot directly contain themselves (even through
        /// `Optional`); the array provides the necessary indirection while
        /// keeping the type `Sendable` + `Equatable`.
        private var darkStorage: [ColorValue]

        package var dark: ColorValue? {
            get { darkStorage.first }
            set { darkStorage = newValue.map { [$0] } ?? [] }
        }

        /// Creates a colour from RGBA components (`0`–`1`). Pass `dark` to
        /// supply a separate value resolved automatically in dark mode;
        /// omit it to reuse the same components in both appearances.
        package init(red: Double, green: Double, blue: Double, alpha: Double = 1, dark: ColorValue? = nil) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
            darkStorage = dark.map { [$0] } ?? []
        }
    }
}
