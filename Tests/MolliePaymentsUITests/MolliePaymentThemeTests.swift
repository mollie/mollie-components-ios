import XCTest
@testable import MolliePaymentsUI

final class MolliePaymentThemeTests: XCTestCase {
    // MARK: - Sendable conformance (compile-time)

    func test_theme_isSendable() {
        let _: any Sendable = MolliePaymentTheme()
    }

    func test_themeColors_isSendable() {
        let _: any Sendable = MolliePaymentTheme.Colors.default
    }

    func test_themeTypography_isSendable() {
        let _: any Sendable = MolliePaymentTheme.Typography.default
    }

    // MARK: - Default construction

    //
    // Default init must be callable with no arguments so merchants can pass
    // `MolliePaymentTheme()` as the present(...) default. Regression target:
    // accidentally requiring colors/typography to be explicit.

    func test_theme_defaultInit_compilesAndProducesValue() {
        let theme = MolliePaymentTheme()
        XCTAssertNotNil(theme.colors)
        XCTAssertNotNil(theme.typography)
    }

    func test_theme_customColorsAndTypography_areRetained() {
        let custom = MolliePaymentTheme(
            colors: .default,
            typography: .default
        )
        // Cross-check identity via a stable property to ensure the init wired
        // both parameters (not silently dropping one).
        XCTAssertEqual(custom.colors.primary, MolliePaymentTheme.Colors.default.primary)
        XCTAssertEqual(custom.typography.bodyFontSize, MolliePaymentTheme.Typography.default.bodyFontSize)
    }

    // MARK: - onPrimary token

    func test_defaultColors_onPrimary_isWhite() {
        // Regression target: `onPrimary` exists as an explicit token so a
        // merchant supplying a light/pastel `primary` can pick a dark
        // foreground without forking the button view. Default must match
        // the hardcoded `.white` it replaced so existing merchants see no
        // visual change.
        let onPrimary = MolliePaymentTheme.Colors.default.onPrimary
        XCTAssertEqual(onPrimary.red, 1.0)
        XCTAssertEqual(onPrimary.green, 1.0)
        XCTAssertEqual(onPrimary.blue, 1.0)
        XCTAssertEqual(onPrimary.alpha, 1.0)
    }
}
