#if canImport(UIKit)
    import Combine
    import Foundation
    import XCTest
    @testable import MollieComponents
    @testable import MollieCore
    #if canImport(SwiftUI)
        import SwiftUI
    #endif
    #if canImport(UIKit)
        import UIKit
    #endif

    /// `MollieCheckout` is a minimal factory that owns session
    /// context (client token + decoded ClientToken + endpoints) and vends
    /// the card component both ways — SwiftUI's `makeCardComponent` and
    /// UIKit's `presentCard(from:)`. Both paths must delegate to the
    /// existing coordinators/runner rather than duplicate logic, and
    /// construction must fail fast on a malformed client token instead of
    /// deferring the failure to present-time.
    @MainActor
    final class MollieCheckoutTests: XCTestCase {
        private static let validClientTokenJSON = """
        {
          "sessionToken": "sess_checkout",
          "secret": "shh",
          "availablePaymentMethods": ["creditcard"],
          "testmode": true,
          "profileToken": "pfl_checkout",
          "merchantProfileName": "CheckoutCo",
          "organizationCountryCode": "NL"
        }
        """

        private func makeValidToken() throws -> String {
            try XCTUnwrap(Self.validClientTokenJSON.data(using: .utf8)?.base64EncodedString())
        }

        // MARK: - Construction

        func test_init_validClientToken_succeeds() throws {
            let token = try makeValidToken()
            XCTAssertNoThrow(try MollieCheckout(clientToken: token))
        }

        func test_init_malformedClientToken_throwsInvalidClientToken() {
            XCTAssertThrowsError(try MollieCheckout(clientToken: "definitely-not-a-token")) { error in
                guard let mollieError = error as? MollieError, case .invalidClientToken = mollieError else {
                    XCTFail("Expected .invalidClientToken, got \(error)")
                    return
                }
            }
        }

        func test_init_defaultsToProductionEndpoints() throws {
            let token = try makeValidToken()
            let checkout = try MollieCheckout(clientToken: token)
            XCTAssertEqual(checkout.endpoints.sessionsBaseURL, MollieEndpoints.production.sessionsBaseURL)
            XCTAssertEqual(checkout.endpoints.tokenizerBaseURL, MollieEndpoints.production.tokenizerBaseURL)
        }

        // MARK: - locale (reserved for future localization)

        //
        // `locale` has no wiring to any user-facing string yet; this only
        // guards that the storage/default contract the public init promises
        // (defaults to `.current`) actually holds.

        func test_init_defaultsToCurrentLocale() throws {
            let token = try makeValidToken()
            let checkout = try MollieCheckout(clientToken: token)
            XCTAssertEqual(checkout.locale, Locale.current)
        }

        func test_init_customLocale_isStored() throws {
            let token = try makeValidToken()
            let custom = Locale(identifier: "nl_NL")
            let checkout = try MollieCheckout(clientToken: token, locale: custom)
            XCTAssertEqual(checkout.locale, custom)
        }

        // MARK: - custom endpoints (testing-only SPI override)

        // MARK: - SwiftUI vending

        #if canImport(SwiftUI)
            func test_makeCardComponent_returnsUsableComponent() throws {
                let token = try makeValidToken()
                let checkout = try MollieCheckout(clientToken: token)
                var received: [MolliePaymentResult] = []
                let component = checkout.makeCardComponent(onResult: { received.append($0) })
                // Load-bearing: the returned value type-checks as `MollieCardComponent`
                // and its `body` is accessible — proving `makeCardComponent` actually
                // vends a usable SwiftUI view rather than an opaque/erased type.
                let _: MollieCardComponent = component
                _ = component.body
                XCTAssertTrue(received.isEmpty, "Constructing the view must not fire onResult")
            }
        #endif

        // MARK: - UIKit vending

        ///
        /// Compile-time assertion: `presentCard(from:)` is reachable with the
        /// signature the task calls for, scoped to this checkout's already-
        /// decoded session context, and takes ONLY a host — no `theme:`
        /// (appearance has no public override point).
        @MainActor
        func test_presentCardSignature_isAccessible() {
            let signature: (MollieCheckout) -> (UIViewController) async
                -> MolliePaymentResult = { checkout in
                    { host in await checkout.presentCard(from: host) }
                }
            XCTAssertNotNil(signature as Any)
        }

        func test_presentCard_malformedHostState_returnsFailedWithoutCrashing() async throws {
            // Mirrors CardCheckoutModalCoordinatorTests' short-circuit
            // coverage: an unattached host (no window) must resolve `.failed`
            // rather than hang or crash — proving `presentCard` really
            // delegates to `CardCheckoutModalCoordinator.present` and
            // inherits its guards.
            let token = try makeValidToken()
            let checkout = try MollieCheckout(clientToken: token)
            let host = UIViewController()
            let result = await checkout.presentCard(from: host)
            guard case let .failed(error) = result,
                  case .invalidConfiguration = error
            else {
                XCTFail("Expected .failed(.invalidConfiguration) for unattached host, got \(result)")
                return
            }
        }

        // MARK: - events / eventsPublisher

        /// The unattached-host guard in `CardCheckoutModalCoordinator.present`
        /// never reaches the network engine, so this is the fastest
        /// deterministic way to prove `presentCard` pushes its terminal
        /// event into `events` from the outer `MollieCheckout` choke point
        /// rather than relying on an internal coordinator method that this
        /// scenario would bypass entirely.
        ///
        /// `checkout.events` is read BEFORE `presentCard` is called: the
        /// `AsyncStream` build closure registers its continuation
        /// synchronously and eagerly on construction (not lazily on first
        /// `for await`), so registering first avoids a race against the
        /// emit.
        func test_events_asyncStream_deliversTerminalFailedEvent() async throws {
            let token = try makeValidToken()
            let checkout = try MollieCheckout(clientToken: token)
            let stream = checkout.events
            let host = UIViewController()

            async let result = checkout.presentCard(from: host)

            var received: [MollieCheckoutEvent] = []
            for await event in stream {
                received.append(event)
            }
            _ = await result

            XCTAssertEqual(received.count, 1, "Only the terminal event should be delivered")
            guard case let .failed(error) = received[0], case .invalidConfiguration = error else {
                XCTFail("Expected .failed(.invalidConfiguration), got \(received)")
                return
            }
        }

        /// Combine counterpart of the AsyncStream test above: same
        /// unattached-host scenario, subscribed before triggering
        /// `presentCard` so the sink can't miss the single terminal emit.
        func test_eventsPublisher_deliversTerminalFailedEvent() async throws {
            let token = try makeValidToken()
            let checkout = try MollieCheckout(clientToken: token)
            var received: [MollieCheckoutEvent] = []
            var didComplete = false
            let cancellable = checkout.eventsPublisher.sink(
                receiveCompletion: { _ in didComplete = true },
                receiveValue: { received.append($0) }
            )
            let host = UIViewController()

            _ = await checkout.presentCard(from: host)
            cancellable.cancel()

            XCTAssertEqual(received.count, 1, "Only the terminal event should be delivered")
            XCTAssertTrue(didComplete, "The publisher must complete once the terminal event fires")
            guard case let .failed(error) = received[0], case .invalidConfiguration = error else {
                XCTFail("Expected .failed(.invalidConfiguration), got \(received)")
                return
            }
        }
    }
#endif
