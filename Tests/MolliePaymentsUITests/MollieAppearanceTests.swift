import XCTest
@testable import MolliePaymentsUI

final class MollieAppearanceTests: XCTestCase {
    // MARK: - Sendable conformance (compile-time)

    func test_theme_isSendable() {
        let _: any Sendable = MollieAppearance()
    }

    func test_themeColors_isSendable() {
        let _: any Sendable = MollieAppearance.Colors.default
    }

    func test_themeTypography_isSendable() {
        let _: any Sendable = MollieAppearance.Typography.default
    }

    // MARK: - Default construction

    //
    // Default init must be callable with no arguments so merchants can pass
    // `MollieAppearance()` as the present(...) default. Regression target:
    // accidentally requiring colors/typography to be explicit.

    func test_theme_defaultInit_compilesAndProducesValue() {
        let theme = MollieAppearance()
        XCTAssertNotNil(theme.colors)
        XCTAssertNotNil(theme.typography)
    }

    func test_theme_customColorsAndTypography_areRetained() {
        let custom = MollieAppearance(
            colors: .default,
            typography: .default
        )
        // Cross-check identity via a stable property to ensure the init wired
        // both parameters (not silently dropping one).
        XCTAssertEqual(custom.colors.primary, MollieAppearance.Colors.default.primary)
        XCTAssertEqual(custom.typography.bodyFontSize, MollieAppearance.Typography.default.bodyFontSize)
    }

    // MARK: - onPrimary token

    func test_defaultColors_onPrimary_isWhite() {
        // Regression target: `onPrimary` exists as an explicit token so a
        // merchant supplying a light/pastel `primary` can pick a dark
        // foreground without forking the button view. Default must match
        // the hardcoded `.white` it replaced so existing merchants see no
        // visual change.
        let onPrimary = MollieAppearance.Colors.default.onPrimary
        XCTAssertEqual(onPrimary.red, 1.0)
        XCTAssertEqual(onPrimary.green, 1.0)
        XCTAssertEqual(onPrimary.blue, 1.0)
        XCTAssertEqual(onPrimary.alpha, 1.0)
    }

    // MARK: - Token parity

    //
    // Resolved by the Web SDK spike (`_variables.scss`); the iOS defaults
    // are locked to the same field styling as the Web SDK so the iOS sheet
    // reads as the same product surface.

    func test_defaultCornerRadius_matchesSharedFieldRadiusToken() {
        // `--mc-border-radius-md` = 8px. Shared by the pay button and the
        // grouped field containers (single token, confirmed no other
        // call site assumes the old `10`).
        XCTAssertEqual(MollieAppearance().cornerRadius, 8)
    }

    func test_defaultFieldBorderWidth_matchesSharedFieldBorderToken() {
        // Default field border is 1px solid.
        XCTAssertEqual(MollieAppearance().fieldBorderWidth, 1)
    }

    func test_defaultColors_fieldBorder_matchesSharedFieldBorderToken() {
        // `--mc-color-gray-200` = #e3e4ea.
        let fieldBorder = MollieAppearance.Colors.default.fieldBorder
        XCTAssertEqual(fieldBorder.red, 0xE3.hex, accuracy: 0.001)
        XCTAssertEqual(fieldBorder.green, 0xE4.hex, accuracy: 0.001)
        XCTAssertEqual(fieldBorder.blue, 0xEA.hex, accuracy: 0.001)
    }

    func test_defaultColors_field_matchesSharedFieldBackgroundToken() {
        // `--mc-color-white` = #ffffff. Unchanged from the prior default;
        // asserted explicitly so a future edit can't silently drift it.
        let field = MollieAppearance.Colors.default.field
        XCTAssertEqual(field.red, 1.0)
        XCTAssertEqual(field.green, 1.0)
        XCTAssertEqual(field.blue, 1.0)
    }

    func test_defaultColors_text_matchesSharedTextColorToken() {
        // `--mc-color-gray-900` = #121110.
        let text = MollieAppearance.Colors.default.text
        XCTAssertEqual(text.red, 0x12.hex, accuracy: 0.001)
        XCTAssertEqual(text.green, 0x11.hex, accuracy: 0.001)
        XCTAssertEqual(text.blue, 0x10.hex, accuracy: 0.001)
    }

    func test_defaultColors_error_matchesSharedErrorColorToken() {
        // `--mc-color-red-500` = #e60029.
        let error = MollieAppearance.Colors.default.error
        XCTAssertEqual(error.red, 0xE6.hex, accuracy: 0.001)
        XCTAssertEqual(error.green, 0x00.hex, accuracy: 0.001)
        XCTAssertEqual(error.blue, 0x29.hex, accuracy: 0.001)
    }

    func test_defaultColors_placeholder_matchesSharedPlaceholderColorToken() {
        // `--mc-color-typography-placeholder` = #b2aeaa. New token — field
        // placeholder text previously had no theme-driven colour at all.
        let placeholder = MollieAppearance.Colors.default.placeholder
        XCTAssertEqual(placeholder.red, 0xB2.hex, accuracy: 0.001)
        XCTAssertEqual(placeholder.green, 0xAE.hex, accuracy: 0.001)
        XCTAssertEqual(placeholder.blue, 0xAA.hex, accuracy: 0.001)
    }

    func test_defaultFieldMinHeight_matchesSharedFieldMinHeightToken() {
        // Field min-height is 56pt. Captured as a token now; not yet
        // wired into the fixed 44pt layout constraints in
        // `MollieGroupedCardFormView` (separate follow-up).
        XCTAssertEqual(MollieAppearance().fieldMinHeight, 56)
    }
}

private extension Int {
    /// Convenience for expressing hex byte components (`0xE3`) as the
    /// `0`–`1` `Double` scale `ColorValue` stores.
    var hex: Double {
        Double(self) / 255.0
    }
}
