import XCTest
@testable import MolliePayments

#if canImport(UIKit) && canImport(WebKit)
    import UIKit

    /// Pins the push-instead-of-present contract:
    /// - `ThreeDSCoordinator.present(challengeURL:in:)` pushes its WebView VC
    ///   onto the caller-supplied container's nav stack (no sibling modal).
    /// - A user-initiated pop (back button / back gesture) resolves the
    ///   continuation with `.cancelled` exactly once.
    /// - The continuation never resolves twice when both a WebView result and
    ///   a pop race.
    @MainActor
    final class ThreeDSCoordinatorTests: XCTestCase {
        private func makeChallengeURL() -> URL {
            // swiftlint:disable:next force_unwrapping
            URL(string: "https://3ds.example.com/challenge")!
        }

        // MARK: - Push instead of present

        func test_present_pushesWebViewControllerOntoSuppliedNav_noSiblingModal() async {
            // The container's nav stack must grow by one — the 3DS WebView VC —
            // and no modal must be presented from any VC in the host hierarchy.
            // Regression catch: anyone reintroducing `presenter.present(nav,…)`.
            let host = UIViewController()
            let nav = UINavigationController(rootViewController: host)
            let window = UIWindow(frame: .init(x: 0, y: 0, width: 320, height: 480))
            window.rootViewController = nav
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            let container = UINavigationChallengeContainer(navigationController: nav)
            let coordinator = ThreeDSCoordinator()

            let task = Task { await coordinator.present(challengeURL: makeChallengeURL(), in: container) }

            try? await waitFor { nav.viewControllers.count == 2 }
            XCTAssertEqual(nav.viewControllers.count, 2, "WebView VC should be pushed onto the supplied nav stack")
            XCTAssertTrue(nav.viewControllers.last is ThreeDSWebViewController, "Pushed VC should be the 3DS WebView")
            XCTAssertNil(host.presentedViewController, "Must NOT present as a sibling modal")

            // Resolve to let the task finish so this test doesn't leak it.
            (nav.viewControllers.last as? ThreeDSWebViewController)?.onResult?(.cancelled)
            _ = await task.value
        }

        // MARK: - Back-gesture cancellation

        func test_userInitiatedPop_resolvesAsCancelled_andPopsExactlyOnce() async {
            // Back-button / back-gesture during the challenge MUST surface
            // `.cancelled` (not hang) and MUST resolve the continuation only
            // once even if `viewWillDisappear` and an `onResult` race.
            let host = UIViewController()
            let nav = UINavigationController(rootViewController: host)
            let window = UIWindow(frame: .init(x: 0, y: 0, width: 320, height: 480))
            window.rootViewController = nav
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            let container = UINavigationChallengeContainer(navigationController: nav)
            let coordinator = ThreeDSCoordinator()

            let task = Task { await coordinator.present(challengeURL: makeChallengeURL(), in: container) }
            try? await waitFor { nav.viewControllers.count == 2 }

            // Simulate user popping the 3DS VC off the nav stack.
            nav.popViewController(animated: false)

            let result = await task.value
            XCTAssertEqual(result, .cancelled)
            XCTAssertEqual(nav.viewControllers.count, 1, "Nav stack should be back to the host VC")
        }

        // MARK: - Coordinator-pop on result

        func test_webViewResultAuthenticated_popsItselfAndResolves() async {
            let host = UIViewController()
            let nav = UINavigationController(rootViewController: host)
            let window = UIWindow(frame: .init(x: 0, y: 0, width: 320, height: 480))
            window.rootViewController = nav
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            let container = UINavigationChallengeContainer(navigationController: nav)
            let coordinator = ThreeDSCoordinator()

            let task = Task { await coordinator.present(challengeURL: makeChallengeURL(), in: container) }
            try? await waitFor { nav.viewControllers.count == 2 }

            let webVC = try? XCTUnwrap(nav.viewControllers.last as? ThreeDSWebViewController)
            webVC?.onResult?(.authenticated)

            let result = await task.value
            XCTAssertEqual(result, .authenticated)
            try? await waitFor { nav.viewControllers.count == 1 }
            XCTAssertEqual(nav.viewControllers.count, 1, "Coordinator must pop the WebView VC after a result")
        }

        // MARK: - Double-resolution guard

        func test_concurrentPopAndResult_resolvesContinuationExactlyOnce() async {
            // If a pop happens during the same runloop tick as an `onResult`,
            // the continuation must resume only once — otherwise Swift traps.
            let host = UIViewController()
            let nav = UINavigationController(rootViewController: host)
            let window = UIWindow(frame: .init(x: 0, y: 0, width: 320, height: 480))
            window.rootViewController = nav
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            let container = UINavigationChallengeContainer(navigationController: nav)
            let coordinator = ThreeDSCoordinator()

            let task = Task { await coordinator.present(challengeURL: makeChallengeURL(), in: container) }
            try? await waitFor { nav.viewControllers.count == 2 }

            let webVC = nav.viewControllers.last as? ThreeDSWebViewController
            // Fire both racing resolutions back-to-back; the second must be a no-op.
            webVC?.onResult?(.authenticated)
            nav.popViewController(animated: false)

            let result = await task.value
            XCTAssertEqual(result, .authenticated, "First resolution wins")
        }

        // MARK: - Helpers

        private func waitFor(
            timeout: TimeInterval = 1.0,
            _ condition: @MainActor () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }
#endif
