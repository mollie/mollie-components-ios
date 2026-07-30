#if canImport(UIKit)
    import UIKit
    import XCTest
    @testable import MolliePaymentsUI

    @MainActor
    final class MollieAppearanceApplierTests: XCTestCase {
        func test_colorValue_convertsToUIColor() {
            let value = MollieAppearance.ColorValue(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
            // Round-trip through UIColor's getRed(...) — UIColor stores in the
            // device colour space and may renormalise; assert with tolerance.
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            value.uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            XCTAssertEqual(red, 1.0, accuracy: 0.001)
            XCTAssertEqual(green, 0.0, accuracy: 0.001)
            XCTAssertEqual(blue, 0.0, accuracy: 0.001)
            XCTAssertEqual(alpha, 1.0, accuracy: 0.001)
        }

        func test_apply_setsBackgroundColor() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            MollieAppearanceApplier.apply(MollieAppearance(), to: form)
            XCTAssertEqual(form.view.backgroundColor, MollieAppearance.Colors.default.background.uiColor)
        }

        func test_apply_setsPayButtonPrimaryColor() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            MollieAppearanceApplier.apply(MollieAppearance(), to: form)
            XCTAssertEqual(form.payButton.buttonBackgroundColor, MollieAppearance.Colors.default.primary.uiColor)
        }

        func test_apply_setsFieldBackgroundOnAllFields() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            MollieAppearanceApplier.apply(MollieAppearance(), to: form)
            let expected = MollieAppearance.Colors.default.field.uiColor
            for field in form.cardFields {
                XCTAssertEqual(field.backgroundColor, expected, "Field \(type(of: field)) missed theme")
            }
        }

        func test_apply_customTheme_overridesDefaults() {
            // Regression target: a merchant supplying their own colors must
            // see them on the form, not the Mollie defaults.
            let custom = MollieAppearance(
                colors: MollieAppearance.Colors(
                    primary: .init(red: 0.5, green: 0.0, blue: 0.5, alpha: 1.0),
                    background: .init(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0),
                    field: .init(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0),
                    fieldBorder: .init(red: 0.3, green: 0.3, blue: 0.3, alpha: 1.0),
                    text: .init(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
                    error: .init(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
                )
            )
            let form = MollieCardFormViewController(theme: custom)
            form.loadViewIfNeeded()
            MollieAppearanceApplier.apply(custom, to: form)
            XCTAssertEqual(form.view.backgroundColor, custom.colors.background.uiColor)
            XCTAssertEqual(form.payButton.buttonBackgroundColor, custom.colors.primary.uiColor)
            XCTAssertNotEqual(form.view.backgroundColor, MollieAppearance.Colors.default.background.uiColor)
        }

        func test_apply_payButton_usesOnPrimaryForTitle() {
            // Regression target: pay-button title colour must come from
            // `Colors.onPrimary`, not a hardcoded `.white`. A merchant
            // configuring a light primary needs a dark title; without
            // this assertion, a future "simplification" could re-hardcode
            // the title to white and silently regress contrast.
            let custom = MollieAppearance(
                colors: MollieAppearance.Colors(
                    primary: .init(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0),
                    onPrimary: .init(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0),
                    background: .init(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
                    field: .init(red: 0.96, green: 0.96, blue: 0.98, alpha: 1.0),
                    fieldBorder: .init(red: 0.8, green: 0.8, blue: 0.85, alpha: 1.0),
                    text: .init(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0),
                    error: .init(red: 0.85, green: 0.18, blue: 0.18, alpha: 1.0)
                )
            )
            let form = MollieCardFormViewController(theme: custom)
            form.loadViewIfNeeded()
            MollieAppearanceApplier.apply(custom, to: form)
            XCTAssertEqual(
                form.payButton.titleColorForTesting(state: .normal),
                custom.colors.onPrimary.uiColor
            )
            XCTAssertNotEqual(
                form.payButton.titleColorForTesting(state: .normal),
                UIColor.white,
                "Title should track the merchant's onPrimary, not the old hardcoded white"
            )
        }

        func test_apply_payButton_updatesProcessingLabelFontAndColor() {
            // `applyTheme(_:)` used to set the processing-label font once at
            // init and never re-apply it; that silently ignored
            // `typography.buttonFontSize` overrides. Verify both font size
            // and colour now track the theme.
            let custom = MollieAppearance(
                colors: MollieAppearance.Colors(
                    primary: .init(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0),
                    onPrimary: .init(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0),
                    background: .init(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
                    field: .init(red: 0.96, green: 0.96, blue: 0.98, alpha: 1.0),
                    fieldBorder: .init(red: 0.8, green: 0.8, blue: 0.85, alpha: 1.0),
                    text: .init(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0),
                    error: .init(red: 0.85, green: 0.18, blue: 0.18, alpha: 1.0)
                ),
                typography: MollieAppearance.Typography(
                    titleFontSize: 22,
                    bodyFontSize: 15,
                    fieldFontSize: 17,
                    buttonFontSize: 23
                )
            )
            let form = MollieCardFormViewController(theme: custom)
            form.loadViewIfNeeded()
            MollieAppearanceApplier.apply(custom, to: form)
            XCTAssertEqual(
                form.payButton.processingLabelFontForTesting.pointSize,
                23,
                accuracy: 0.001
            )
            XCTAssertEqual(
                form.payButton.processingLabelTextColorForTesting,
                custom.colors.onPrimary.uiColor
            )
        }

        func test_viewWillAppear_appliesTheme() {
            // End-to-end: the form's own lifecycle hooks the applier without
            // any explicit caller invocation. Drives the same UI path a
            // merchant integration would.
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.beginAppearanceTransition(true, animated: false)
            form.endAppearanceTransition()
            XCTAssertEqual(form.view.backgroundColor, MollieAppearance.Colors.default.background.uiColor)
        }

        // MARK: - Placeholder colour

        func test_apply_setsThemedPlaceholderColorOnAllFields() {
            // Regression target: placeholder text previously rendered in
            // UIKit's system default grey, ignoring the theme entirely.
            // `Colors.placeholder` (design token `--mc-color-typography-placeholder`)
            // must now drive `attributedPlaceholder` on every field.
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            MollieAppearanceApplier.apply(MollieAppearance(), to: form)
            let expected = MollieAppearance.Colors.default.placeholder.uiColor
            for field in form.cardFields {
                let color = field.attributedPlaceholder?.attribute(
                    .foregroundColor,
                    at: 0,
                    effectiveRange: nil
                ) as? UIColor
                XCTAssertEqual(color, expected, "Field \(type(of: field)) missed placeholder theming")
            }
        }

        func test_apply_customPlaceholderColor_overridesDefault() {
            let custom = MollieAppearance(
                colors: MollieAppearance.Colors(
                    primary: .init(red: 0.5, green: 0.0, blue: 0.5, alpha: 1.0),
                    background: .init(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0),
                    field: .init(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0),
                    fieldBorder: .init(red: 0.3, green: 0.3, blue: 0.3, alpha: 1.0),
                    text: .init(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
                    error: .init(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0),
                    placeholder: .init(red: 0.9, green: 0.9, blue: 0.1, alpha: 1.0)
                )
            )
            let form = MollieCardFormViewController(theme: custom)
            form.loadViewIfNeeded()
            MollieAppearanceApplier.apply(custom, to: form)
            let expected = custom.colors.placeholder.uiColor
            for field in form.cardFields {
                let color = field.attributedPlaceholder?.attribute(
                    .foregroundColor,
                    at: 0,
                    effectiveRange: nil
                ) as? UIColor
                XCTAssertEqual(color, expected)
            }
        }

        // MARK: - Field border width

        func test_apply_setsFieldBorderWidthFromTheme() {
            // Regression target: the grouped containers' `borderWidth` was
            // hardcoded to `1` in `setupLayout()` and never revisited by
            // `applyTheme(_:)` — a merchant supplying a custom
            // `fieldBorderWidth` saw no effect. `MollieGroupedCardFormView`
            // has no public accessor for the border views, so this is
            // exercised through the grouped form's public API instead.
            let custom = MollieAppearance(fieldBorderWidth: 2.5)
            let form = MollieCardFormViewController(theme: custom)
            form.loadViewIfNeeded()
            MollieAppearanceApplier.apply(custom, to: form)
            XCTAssertEqual(form.groupedFormView?.fieldBorderWidthForTesting, 2.5)
        }

        // MARK: - Field min height

        func test_apply_setsFieldMinHeightFromTheme_default() {
            // Regression target: `MollieAppearance.fieldMinHeight` was never
            // wired into layout — the grouped form's row
            // height constraints stayed hardcoded at 44pt regardless of the
            // theme. Default theme must render the 56pt token.
            let theme = MollieAppearance()
            let form = MollieCardFormViewController(theme: theme)
            form.loadViewIfNeeded()
            MollieAppearanceApplier.apply(theme, to: form)
            XCTAssertEqual(form.groupedFormView?.fieldMinHeightForTesting, theme.fieldMinHeight)
            XCTAssertEqual(form.groupedFormView?.fieldMinHeightForTesting, 56)
        }

        func test_apply_customFieldMinHeight_overridesDefault() {
            let custom = MollieAppearance(fieldMinHeight: 64)
            let form = MollieCardFormViewController(theme: custom)
            form.loadViewIfNeeded()
            MollieAppearanceApplier.apply(custom, to: form)
            XCTAssertEqual(form.groupedFormView?.fieldMinHeightForTesting, 64)
        }
    }
#endif
