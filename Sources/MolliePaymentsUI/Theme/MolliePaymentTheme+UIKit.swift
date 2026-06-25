#if canImport(UIKit)
    import UIKit

    /// UIKit bridge for `MolliePaymentTheme.ColorValue`. The theme stores
    /// RGBA as `Double` components so it can be `Sendable` and cross actor
    /// boundaries; UIKit needs the values as `UIColor`.
    ///
    /// One variant per token today — light + dark variants land when the
    /// theme grows a `Colors.dark` companion. The form already re-applies
    /// the theme on `traitCollectionDidChange(_:)` so the hook is in place
    /// for that addition.
    package extension MolliePaymentTheme.ColorValue {
        var uiColor: UIColor {
            // Snapshot RGBA into locals so the dynamic provider closure does
            // not capture `self` (the struct) across the boundary — keeps the
            // resolver allocation-light and avoids any retain on a wrapper.
            let lightR = CGFloat(red), lightG = CGFloat(green)
            let lightB = CGFloat(blue), lightA = CGFloat(alpha)
            guard let dark else {
                return UIColor(red: lightR, green: lightG, blue: lightB, alpha: lightA)
            }
            let darkR = CGFloat(dark.red), darkG = CGFloat(dark.green)
            let darkB = CGFloat(dark.blue), darkA = CGFloat(dark.alpha)
            return UIColor { traitCollection in
                if traitCollection.userInterfaceStyle == .dark {
                    return UIColor(red: darkR, green: darkG, blue: darkB, alpha: darkA)
                }
                return UIColor(red: lightR, green: lightG, blue: lightB, alpha: lightA)
            }
        }
    }

    /// Apply a theme's colours and typography to the standard form chrome.
    /// Centralised here so the form view-controller stays focused on layout
    /// and tests can drive a single function rather than poking the VC's
    /// view hierarchy.
    package enum MolliePaymentThemeApplier {
        @MainActor
        package static func apply(
            _ theme: MolliePaymentTheme,
            to form: MollieCardFormViewController
        ) {
            form.view.backgroundColor = theme.colors.background.uiColor

            for field in form.cardFields {
                field.backgroundColor = theme.colors.field.uiColor
                field.textColor = theme.colors.text.uiColor
                field.tintColor = theme.colors.primary.uiColor
                field.font = UIFont.systemFont(ofSize: CGFloat(theme.typography.fieldFontSize))
            }

            // Grouped form view owns the rounded border + dividers; let it
            // re-theme itself so the chrome stays in sync with the per-field
            // colours above.
            if let grouped = form.groupedFormView {
                grouped.applyTheme(theme)
            }

            form.payButton.applyTheme(theme)
        }
    }
#endif
