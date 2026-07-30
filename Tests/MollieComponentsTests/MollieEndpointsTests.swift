import Foundation
import MollieCore
import XCTest

// Not @testable — .production and .urlSession are public surface. These
// assertions guard the tuned production networking configuration introduced
// for network resilience (Plan B): a payment sheet must not inherit
// URLSession.shared's untuned 60s request / 7-day resource defaults.
import MollieComponents

final class MollieEndpointsTests: XCTestCase {
    // MARK: - .production carries a tuned configuration, not URLSession.shared

    //
    // URLSession.shared.configuration.timeoutIntervalForRequest is 60s by
    // default. A hung first response should surface to the buyer well before
    // that; we pin the tuned value so a regression back to .shared (or a
    // looser timeout) fails here.

    func test_production_requestTimeout_isTuned() {
        let config = MollieEndpoints.production.urlSession.configuration
        XCTAssertEqual(
            config.timeoutIntervalForRequest,
            30,
            "production request timeout must be the tuned 30s, not the URLSession.shared 60s default"
        )
    }

    //
    // The default resource timeout is 7 days (604800s). Left unbounded, a
    // stalled connection that keeps the socket alive could keep the payment
    // sheet spinning effectively forever. We require a bounded, sheet-sane cap.

    func test_production_resourceTimeout_isBounded() {
        let config = MollieEndpoints.production.urlSession.configuration
        XCTAssertEqual(
            config.timeoutIntervalForResource,
            120,
            "production resource timeout must be the bounded 120s cap, not the 7-day default"
        )
    }

    //
    // waitsForConnectivity lets a brief connectivity blip wait (up to the
    // resource timeout) instead of failing instantly — paired with the bounded
    // resource cap so it can't hang indefinitely.

    func test_production_waitsForConnectivity_isEnabled() {
        let config = MollieEndpoints.production.urlSession.configuration
        XCTAssertTrue(
            config.waitsForConnectivity,
            "production session must wait for connectivity so a brief blip waits rather than failing instantly"
        )
    }

    //
    // The tuned session must be a hand-constructed one, never URLSession.shared
    // (whose configuration is the untuned default). Identity check guards the
    // wiring: the clients read endpoints.urlSession, so this IS the session the
    // sheet uses.

    func test_production_isNotSharedSession() {
        XCTAssertFalse(
            MollieEndpoints.production.urlSession === URLSession.shared,
            "production must use a tuned session, not URLSession.shared"
        )
    }

    // MARK: - .production enforces SPKI pinning

    //
    // The production session's delegate must be a PinningURLSessionDelegate —
    // that's what actually enforces productionPins against the GTS chain on
    // every TLS handshake. Losing this delegate (e.g. a regression back to a
    // delegate-less session) would silently drop pinning while every other
    // production test above kept passing.

    func test_production_urlSession_hasPinningDelegate() {
        XCTAssertTrue(
            MollieEndpoints.production.urlSession.delegate is PinningURLSessionDelegate,
            "production must enforce SPKI pinning via a PinningURLSessionDelegate"
        )
    }
}
