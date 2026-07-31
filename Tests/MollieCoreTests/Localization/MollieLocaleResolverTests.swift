import XCTest
@testable import MollieCore

final class MollieLocaleResolverTests: XCTestCase {
    func test_resolve_prefersExplicitOverride_whenLanguageAvailable() {
        let resolved = MollieLocaleResolver.resolve(
            override: Locale(identifier: "fr"),
            system: Locale(identifier: "en"),
            availableIdentifiers: ["en", "nl", "fr", "de"]
        )
        XCTAssertEqual(resolved.identifier, "fr")
    }

    func test_resolve_stripsRegion_fromExplicitOverride() {
        let resolved = MollieLocaleResolver.resolve(
            override: Locale(identifier: "nl_BE"),
            system: Locale(identifier: "en"),
            availableIdentifiers: ["en", "nl"]
        )
        XCTAssertEqual(resolved.identifier, "nl")
    }

    func test_resolve_stripsRegion_fromSystemLocale_whenNoOverride() {
        let resolved = MollieLocaleResolver.resolve(
            override: nil,
            system: Locale(identifier: "nl_BE"),
            availableIdentifiers: ["en", "nl"]
        )
        XCTAssertEqual(resolved.identifier, "nl")
    }

    func test_resolve_fallsBackToEnglish_whenOverrideUnsupportedAndNoSystemGiven() {
        let resolved = MollieLocaleResolver.resolve(
            override: Locale(identifier: "ja_JP"),
            system: Locale(identifier: "ja_JP"),
            availableIdentifiers: ["en", "nl"]
        )
        XCTAssertEqual(resolved.identifier, "en")
    }

    func test_resolve_usesSystemLocale_whenNoExplicitOverrideProvided() {
        let resolved = MollieLocaleResolver.resolve(
            override: nil,
            system: Locale(identifier: "de"),
            availableIdentifiers: ["en", "de"]
        )
        XCTAssertEqual(resolved.identifier, "de")
    }

    func test_resolve_fallsThroughToSystem_whenOverrideUnsupportedButSystemIs() {
        let resolved = MollieLocaleResolver.resolve(
            override: Locale(identifier: "ja_JP"),
            system: Locale(identifier: "de"),
            availableIdentifiers: ["en", "de"]
        )
        XCTAssertEqual(resolved.identifier, "de")
    }

    func test_resolve_prefersOverride_evenWhenSystemLocaleDiffers() {
        let resolved = MollieLocaleResolver.resolve(
            override: Locale(identifier: "de"),
            system: Locale(identifier: "fr"),
            availableIdentifiers: ["en", "de", "fr"]
        )
        XCTAssertEqual(resolved.identifier, "de")
    }

    func test_resolve_isDeterministic_forSameInjectedInputs() {
        // Proves the pure function has no ambient dependency on
        // `Locale.current` — repeated calls with the same injected `system`
        // must yield identical results.
        let first = MollieLocaleResolver.resolve(
            override: nil,
            system: Locale(identifier: "de"),
            availableIdentifiers: ["en", "de"]
        )
        let second = MollieLocaleResolver.resolve(
            override: nil,
            system: Locale(identifier: "de"),
            availableIdentifiers: ["en", "de"]
        )
        XCTAssertEqual(first, second)
    }

    func test_resolve_fallsBackToEnglish_whenNothingMatches() {
        let resolved = MollieLocaleResolver.resolve(
            override: Locale(identifier: "ja_JP"),
            system: Locale(identifier: "ko_KR"),
            availableIdentifiers: ["en", "nl"]
        )
        XCTAssertEqual(resolved.identifier, "en")
    }
}
