#if canImport(UIKit)
    import MollieCore
    import MolliePayments
    import UIKit
    import XCTest
    @testable import MolliePaymentsUI

    /// Wiring live brand detection into the card form.
    ///
    /// `sendActions(for: .editingChanged)` does not reliably drive
    /// target-action in this repo's headless-sim UIKit test harness, so
    /// these tests drive the directly-callable seams
    /// (`updateBrand(forPAN:)`, `detectedPrimaryScheme(forPAN:)`,
    /// `CardScheme.primary(from:)`) instead of typing into `cardNumberField`
    /// and relying on the real `.editingChanged` target-action dispatch.
    @MainActor
    final class CardFormBrandDetectionTests: XCTestCase {
        // MARK: - CardScheme.primary(from:) — deterministic collapse of a Set

        func test_primaryScheme_emptySet_isNil() {
            XCTAssertNil(CardScheme.primary(from: []))
        }

        func test_primaryScheme_singleElementSet_returnsThatScheme() {
            XCTAssertEqual(CardScheme.primary(from: [.visa]), .visa)
        }

        func test_primaryScheme_coBadgeOverlap_prefersHigherPriorityScheme() {
            // Discover/UnionPay's shared alliance range (BINPrefixTableTests)
            // is the one real multi-element Set `BINPrefixTable` produces
            // today — Discover is deliberately ranked first.
            XCTAssertEqual(CardScheme.primary(from: [.discover, .unionPay]), .discover)
            // Order must not matter — a Set has no inherent element order.
            XCTAssertEqual(CardScheme.primary(from: [.unionPay, .discover]), .discover)
        }

        func test_primaryScheme_schemeOutsidePriorityList_stillReturnsIt() {
            // `.other` never comes out of `BINPrefixTable`, but a future
            // network `IINResult` could carry one — it must never be
            // silently dropped in favour of `nil`.
            let result = CardScheme.primary(from: [.other("unknown-network")])
            XCTAssertEqual(result, .other("unknown-network"))
        }

        // MARK: - detectedPrimaryScheme(forPAN:) — local, synchronous seam

        func test_detectedPrimaryScheme_visaPrefix_returnsVisa() {
            XCTAssertEqual(
                MollieCardFormViewController.detectedPrimaryScheme(forPAN: "4242424242424242"),
                .visa
            )
        }

        func test_detectedPrimaryScheme_stripsFormattingBeforeDetecting() {
            // Users type PANs with spaces (the field's raw text before
            // `CardNumberTextField.sanitize()` catches up); detection must
            // not require pre-sanitised input.
            XCTAssertEqual(
                MollieCardFormViewController.detectedPrimaryScheme(forPAN: "5555 4444 3333 2222"),
                .mastercard
            )
        }

        func test_detectedPrimaryScheme_shortIncrementalPrefix_stillDetects() {
            // Detection must work as the user is still mid-type, not only
            // once a full 16-digit PAN has landed.
            XCTAssertEqual(MollieCardFormViewController.detectedPrimaryScheme(forPAN: "4"), .visa)
        }

        func test_detectedPrimaryScheme_unknownPrefix_returnsNil() {
            XCTAssertNil(MollieCardFormViewController.detectedPrimaryScheme(forPAN: "1234567890"))
        }

        func test_detectedPrimaryScheme_emptyPAN_returnsNil() {
            XCTAssertNil(MollieCardFormViewController.detectedPrimaryScheme(forPAN: ""))
        }

        // MARK: - isReconcileStillApplicable(requestedPrefix:currentPAN:)

        func test_isReconcileStillApplicable_unchangedPrefix_isApplicable() {
            XCTAssertTrue(
                MollieCardFormViewController.isReconcileStillApplicable(
                    requestedPrefix: "424242",
                    currentPAN: "4242424242424242"
                )
            )
        }

        func test_isReconcileStillApplicable_changedPrefix_isStale() {
            // User replaced the PAN before the network response for the
            // earlier prefix landed — that response must never clobber the
            // newer, different guess.
            XCTAssertFalse(
                MollieCardFormViewController.isReconcileStillApplicable(
                    requestedPrefix: "424242",
                    currentPAN: "5555555555554444"
                )
            )
        }

        func test_isReconcileStillApplicable_fieldClearedSinceRequest_isStale() {
            XCTAssertFalse(
                MollieCardFormViewController.isReconcileStillApplicable(
                    requestedPrefix: "424242",
                    currentPAN: ""
                )
            )
        }

        // MARK: - updateBrand(forPAN:) — wiring seam, no network injected

        func test_updateBrand_withNoLookupServiceInjected_appliesLocalGuess() {
            // The default `iinLookupService: nil` path must fully work
            // offline — the local `BINPrefixTable` path is the authority
            // for instant UX, independent of any network dependency.
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()

            form.updateBrand(forPAN: "378282246310005")

            XCTAssertEqual(form.groupedFormView?.currentBrandSchemeForTesting, .amex)
        }

        func test_updateBrand_unknownPrefix_revertsToPlaceholder() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.updateBrand(forPAN: "4242424242424242")
            XCTAssertEqual(form.groupedFormView?.currentBrandSchemeForTesting, .visa)

            form.updateBrand(forPAN: "1234567890")

            XCTAssertNil(
                form.groupedFormView?.currentBrandSchemeForTesting,
                "An unrecognised prefix must fall back to the placeholder, not keep stale state"
            )
        }

        func test_updateBrand_appliesLocalSchemeSynchronously_evenWithSlowLookupServiceInjected() {
            // Proves the local `BINPrefixTable` path never waits on the
            // network: even with a lookup service that won't resolve
            // within this test's lifetime, the brand icon updates the
            // instant `updateBrand(forPAN:)` returns.
            let fakeClient = FakeIINHTTPClient()
            fakeClient.result = IINResult(schemes: [.mastercard], cardType: nil, issuingCountry: nil)
            let service = IINLookupService(httpClient: fakeClient, debounceInterval: 999)
            let form = MollieCardFormViewController(theme: MollieAppearance(), iinLookupService: service)
            form.loadViewIfNeeded()

            form.updateBrand(forPAN: "4242424242424242")

            XCTAssertEqual(form.groupedFormView?.currentBrandSchemeForTesting, .visa)
        }

        // MARK: - updateBrand(forPAN:) — network reconciliation

        func test_updateBrand_networkReconcile_confirmsSchemeBINPrefixTableCannotDetectLocally() async {
            // Cartes Bancaires co-badges onto Visa/Mastercard BINs, so
            // `BINPrefixTable` can never produce it on its own
            // (BINPrefixTableTests.test_detect_neverReturnsCartesBancairesLocally).
            // The network reconcile is the only path that can correct the
            // local Visa guess to the co-badged Cartes Bancaires scheme.
            let fakeClient = FakeIINHTTPClient()
            fakeClient.result = IINResult(schemes: [.cartesBancaires], cardType: nil, issuingCountry: "FR")
            let service = IINLookupService(httpClient: fakeClient, debounceInterval: 0.01)
            let form = MollieCardFormViewController(theme: MollieAppearance(), iinLookupService: service)
            form.loadViewIfNeeded()

            form.updateBrand(forPAN: "4970100000000000")
            XCTAssertEqual(
                form.groupedFormView?.currentBrandSchemeForTesting,
                .visa,
                "the local guess must apply immediately, before the network resolves"
            )

            await form.waitForPendingIINReconcileForTesting()

            XCTAssertEqual(
                form.groupedFormView?.currentBrandSchemeForTesting,
                .cartesBancaires,
                "the network reconcile must be able to correct the local guess"
            )
        }

        func test_updateBrand_networkLookupFails_keepsLocalGuess() async {
            // The HTTP call errors (e.g. host unresolved — the IIN lookup
            // host is unconfirmed); the local BINPrefixTable guess must
            // survive untouched, not be cleared.
            let fakeClient = FakeIINHTTPClient()
            fakeClient.result = nil
            let service = IINLookupService(httpClient: fakeClient, debounceInterval: 0.01)
            let form = MollieCardFormViewController(theme: MollieAppearance(), iinLookupService: service)
            form.loadViewIfNeeded()

            form.updateBrand(forPAN: "4242424242424242")
            await form.waitForPendingIINReconcileForTesting()

            XCTAssertEqual(form.groupedFormView?.currentBrandSchemeForTesting, .visa)
        }

        func test_updateBrand_shortPrefix_neverInvokesNetworkLookup() {
            // Under 6 digits, `IINLookupService.lookup` already no-ops, but
            // the VC also short-circuits before even creating a Task —
            // asserted indirectly via the mock's call count.
            let fakeClient = FakeIINHTTPClient()
            fakeClient.result = IINResult(schemes: [.visa], cardType: nil, issuingCountry: nil)
            let service = IINLookupService(httpClient: fakeClient, debounceInterval: 0.01)
            let form = MollieCardFormViewController(theme: MollieAppearance(), iinLookupService: service)
            form.loadViewIfNeeded()

            form.updateBrand(forPAN: "424")

            XCTAssertEqual(fakeClient.callCount, 0)
        }
    }

    /// Minimal `HTTPClient` test double scoped to this file. Deliberately
    /// not the shared `MockHTTPClient` (queue-based, per-target duplicate
    /// living in `MolliePaymentsTests`/`MollieCoreTests`) — these tests
    /// only ever need one canned IIN response per test.
    private final class FakeIINHTTPClient: HTTPClient, @unchecked Sendable {
        var result: IINResult?
        private(set) var callCount = 0

        func perform<T: Decodable>(_ endpoint: Endpoint<T>) async throws -> T {
            callCount += 1
            guard let result, let typed = result as? T else {
                throw MollieError.network(URLError(.unknown))
            }
            return typed
        }
    }
#endif
