#if canImport(UIKit)
    import Foundation
    import XCTest
    @testable import MollieComponents
    @testable import MollieCore
    @testable import MolliePayments

    /// Pins the terminal/non-terminal classification of
    /// `MollieCheckoutEvent` to `SessionEventMapper.isTerminal(_:)` — the
    /// sole source of truth this task must not fork a second classification
    /// from — plus the mapping functions in `CardCheckoutRunner` that bridge
    /// the engine's types onto the checkout's session-shaped event.
    final class MollieCheckoutEventTests: XCTestCase {
        private func decodeSession(_ json: String) throws -> SessionResponse {
            try MollieJSONDecoder().decode(SessionResponse.self, from: Data(json.utf8))
        }

        // MARK: - isTerminal parity with SessionEventMapper.isTerminal

        /// `CardCheckoutRunner.mapNonTerminalEvent(_:)` must return `nil`
        /// exactly for the `ChannelEvent` cases `SessionEventMapper.isTerminal`
        /// calls terminal, and for every other case must produce a
        /// `MollieCheckoutEvent` whose own `isTerminal` reports `false`. This
        /// is the load-bearing check that the two classifications can never
        /// drift apart — `SessionEventMapper.isTerminal` stays the only place
        /// that decides terminal/non-terminal at the wire level.
        func test_isTerminal_matchesSessionEventMapper_forEveryChannelEvent() throws {
            let session = try decodeSession("""
            {
              "sessionToken": "sess_abc",
              "status": "open",
              "nextAction": {"actionType": "await"},
              "paymentAmount": {"amount": "10.00", "currency": "EUR"}
            }
            """)
            let challengeURL = try XCTUnwrap(URL(string: "https://3ds.example.com/challenge"))
            let redirectURL = try XCTUnwrap(URL(string: "https://pay.mollie.com/redirect"))

            let events: [ChannelEvent] = [
                .sessionUpdated(session),
                .threeDSChallengeReady(challengeURL),
                .redirectRequired(redirectURL),
                .sessionCompleted(session),
                .sessionFailed(ProblemDetails(title: "failed", detail: "reason")),
            ]

            for event in events {
                let mapped = CardCheckoutRunner.mapNonTerminalEvent(event)
                let expectedTerminal = SessionEventMapper.isTerminal(event)
                if expectedTerminal {
                    XCTAssertNil(
                        mapped,
                        "\(event) is terminal per SessionEventMapper — mapNonTerminalEvent must return nil for it"
                    )
                } else {
                    let unwrapped = try XCTUnwrap(
                        mapped,
                        "\(event) is non-terminal per SessionEventMapper — mapNonTerminalEvent must produce an event"
                    )
                    XCTAssertFalse(
                        unwrapped.isTerminal,
                        "\(unwrapped) must not report isTerminal for a non-terminal ChannelEvent"
                    )
                }
            }
        }

        // MARK: - mapEvent(from:) — MolliePaymentResult -> MollieCheckoutEvent

        func test_mapEvent_completed_roundTripsThroughMolliePaymentResult() {
            let payment = MolliePayment(sessionToken: "sess_abc", amount: "10.00", currency: "EUR")
            let event = CardCheckoutRunner.mapEvent(from: .completed(payment))
            guard case let .completed(mappedPayment) = event else {
                return XCTFail("Expected .completed, got \(event)")
            }
            XCTAssertEqual(mappedPayment, payment)
            XCTAssertTrue(event.isTerminal)

            guard case let .completed(roundTripped) = MolliePaymentResult(checkoutEvent: event) else {
                return XCTFail("Expected .completed round trip")
            }
            XCTAssertEqual(roundTripped, payment)
        }

        func test_mapEvent_failed_roundTripsThroughMolliePaymentResult() {
            let event = CardCheckoutRunner.mapEvent(from: .failed(.invalidConfiguration(field: "x", reason: "y")))
            guard case let .failed(error) = event, case let .invalidConfiguration(field, _) = error else {
                return XCTFail("Expected .failed(.invalidConfiguration), got \(event)")
            }
            XCTAssertEqual(field, "x")
            XCTAssertTrue(event.isTerminal)

            guard case let .failed(roundTripped) = MolliePaymentResult(checkoutEvent: event),
                  case .invalidConfiguration = roundTripped
            else {
                return XCTFail("Expected .failed round trip")
            }
        }

        func test_mapEvent_cancelled_roundTripsThroughMolliePaymentResult() {
            let event = CardCheckoutRunner.mapEvent(from: .cancelled)
            guard case .cancelled = event else {
                return XCTFail("Expected .cancelled, got \(event)")
            }
            XCTAssertFalse(event.isTerminal, "A cancelled attempt leaves the session open")

            guard case .cancelled = MolliePaymentResult(checkoutEvent: event) else {
                return XCTFail("Expected .cancelled round trip")
            }
        }

        // MARK: - Group C scope boundary: no fabricated soft-decline retry

        /// Rule 12 pin: the current engine has no wire-level signal to
        /// distinguish a retryable soft decline from a genuinely terminal
        /// failure (see the pending-work note in
        /// `CardCheckoutRunner.mapFinalEvent`), so
        /// every `CardPaymentResult.failed` must surface as the terminal
        /// `.failed(error)` — never as `.attemptFailed`. This test exists
        /// specifically to fail loudly if a future change starts fabricating
        /// `.attemptFailed` before the Group C backend contract is confirmed.
        func test_mapFinalEvent_failedCardResult_neverProducesAttemptFailed() {
            let event = CardCheckoutRunner.mapFinalEvent(
                cardResult: .failed(.sessionFailed(ProblemDetails(title: "declined", detail: "insufficient funds")))
            )
            switch event {
            case .failed:
                break
            case .attemptFailed:
                XCTFail("mapFinalEvent must not fabricate .attemptFailed — Group C work is not scoped in yet")
            default:
                XCTFail("Expected .failed, got \(event)")
            }
            XCTAssertTrue(event.isTerminal)
        }

        // MARK: - mapFinalEvent(cardResult:) — retryable soft decline

        /// The interim fold is gone: a retryable soft decline
        /// (`CardPaymentResult.attemptFailed`) must now surface as the real,
        /// non-terminal `MollieCheckoutEvent.attemptFailed(retryable: true,
        /// error:)`, with the `MollieError` built the same way every other
        /// engine-error arm in `CardCheckoutRunner` builds one from
        /// `ProblemDetails` — `.sessionFailed(details)`.
        func test_mapFinalEvent_attemptFailedCardResult_producesRetryableAttemptFailed() {
            let details = ProblemDetails(title: "declined", detail: "insufficient funds")
            let event = CardCheckoutRunner.mapFinalEvent(cardResult: .attemptFailed(details))
            guard case let .attemptFailed(retryable, error) = event else {
                XCTFail("Expected .attemptFailed, got \(event)")
                return
            }
            XCTAssertTrue(retryable, "Only the retryable branch produces CardPaymentResult.attemptFailed")
            guard case let .sessionFailed(problemDetails) = error else {
                XCTFail("Expected .sessionFailed(details), got \(error)")
                return
            }
            XCTAssertEqual(problemDetails?.title, "declined")
            XCTAssertFalse(event.isTerminal, "A retryable soft decline must leave the session open for a fresh attempt")
        }
    }
#endif
