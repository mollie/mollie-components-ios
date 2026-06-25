import CoreGraphics
#if canImport(UIKit)
    import UIKit
#endif

/// Visual configuration applied to the Mollie payment sheet.
///
/// Stub for MR1: exposes the public shape so dependent modules and merchant
/// code can already reference it. Default tokens are intentionally thin;
/// MR6 fleshes out Mollie-branded values and adds the
/// `UIView.applyMollieTheme(_:)` helper.
public struct MolliePaymentTheme: Sendable {
    /// Colour tokens applied across the sheet — pay button, field
    /// backgrounds, borders, body text, and error states.
    public var colors: Colors
    /// Font sizes for the sheet's title, body copy, field text, button
    /// title, and grouped section headers.
    public var typography: Typography
    /// Corner radius (in points) applied to the pay button and the
    /// grouped field containers. Defaults to `10`.
    public var cornerRadius: CGFloat

    /// Creates a theme. Omit any argument to take the Mollie-branded
    /// defaults for that group; pass overrides to restyle the sheet.
    public init(
        colors: Colors = .default,
        typography: Typography = .default,
        cornerRadius: CGFloat = 10
    ) {
        self.colors = colors
        self.typography = typography
        self.cornerRadius = cornerRadius
    }
}

public extension MolliePaymentTheme {
    struct Colors: Sendable, Equatable {
        /// Brand accent colour: the pay-button fill and the focused-field
        /// highlight. Defaults to Mollie blue.
        public var primary: ColorValue
        /// Foreground colour rendered on top of `primary` (pay-button title,
        /// inline spinner label). Lifted out as a separate token so a
        /// merchant supplying a light/pastel `primary` can switch the
        /// title to a dark colour without forking the button view.
        public var onPrimary: ColorValue
        /// Fill behind the whole sheet content area.
        public var background: ColorValue
        /// Fill inside each input field (card number, expiry, CVC,
        /// cardholder name).
        public var field: ColorValue
        /// Stroke drawn around each input field and grouped container.
        public var fieldBorder: ColorValue
        /// Primary text colour for field input and body copy.
        public var text: ColorValue
        /// Colour for validation error messages and the error state of an
        /// invalid field.
        public var error: ColorValue

        /// Creates a colour set. `primary`, `background`, `field`,
        /// `fieldBorder`, `text`, and `error` are required; `onPrimary`
        /// defaults to white for use on the Mollie-blue pay button.
        public init(
            primary: ColorValue,
            onPrimary: ColorValue = ColorValue(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            background: ColorValue,
            field: ColorValue,
            fieldBorder: ColorValue,
            text: ColorValue,
            error: ColorValue
        ) {
            self.primary = primary
            self.onPrimary = onPrimary
            self.background = background
            self.field = field
            self.fieldBorder = fieldBorder
            self.text = text
            self.error = error
        }

        /// Mollie-branded default palette: blue accent, white surfaces, a
        /// light-grey field border, near-black text, and a red error tone.
        public static let `default` = Colors(
            primary: ColorValue(red: 0.102, green: 0.122, blue: 0.878, alpha: 1.0),
            onPrimary: ColorValue(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            background: ColorValue(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            field: ColorValue(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            fieldBorder: ColorValue(red: 0.8, green: 0.8, blue: 0.85, alpha: 1.0),
            text: ColorValue(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0),
            error: ColorValue(red: 0.85, green: 0.18, blue: 0.18, alpha: 1.0)
        )
    }

    struct Typography: Sendable, Equatable {
        /// Point size of the sheet's title.
        public var titleFontSize: Double
        /// Point size of body / explanatory copy in the sheet.
        public var bodyFontSize: Double
        /// Point size of text typed into the input fields.
        public var fieldFontSize: Double
        /// Point size of the pay-button title.
        public var buttonFontSize: Double
        /// Font size for the "Card information" / "Card holder" section
        /// headers above each grouped field container. Theme-driven so
        /// merchants can scale the form header weight without forking
        /// the grouped view.
        public var sectionLabelFontSize: Double

        /// Creates a typography set. All sizes are required except
        /// `sectionLabelFontSize`, which defaults to `15`.
        public init(
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
        public static let `default` = Typography(
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
    struct ColorValue: Sendable, Equatable {
        /// Red component, `0`–`1`.
        public var red: Double
        /// Green component, `0`–`1`.
        public var green: Double
        /// Blue component, `0`–`1`.
        public var blue: Double
        /// Opacity, `0` (transparent) to `1` (opaque).
        public var alpha: Double

        /// Dark variant is stored in a single-element array because Swift
        /// value types cannot directly contain themselves (even through
        /// `Optional`); the array provides the necessary indirection while
        /// keeping the type `Sendable` + `Equatable`.
        private var darkStorage: [ColorValue]

        public var dark: ColorValue? {
            get { darkStorage.first }
            set { darkStorage = newValue.map { [$0] } ?? [] }
        }

        /// Creates a colour from RGBA components (`0`–`1`). Pass `dark` to
        /// supply a separate value resolved automatically in dark mode;
        /// omit it to reuse the same components in both appearances.
        public init(red: Double, green: Double, blue: Double, alpha: Double = 1, dark: ColorValue? = nil) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
            darkStorage = dark.map { [$0] } ?? []
        }
    }
}
