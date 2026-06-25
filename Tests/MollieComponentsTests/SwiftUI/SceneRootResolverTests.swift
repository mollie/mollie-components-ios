#if canImport(UIKit)
    import UIKit
    import XCTest
    @testable import MollieComponents

    @MainActor
    final class SceneRootResolverTests: XCTestCase {
        func test_topmostPresented_noModalChain_returnsSelf() {
            let root = UIViewController()
            XCTAssertIdentical(SceneRootResolver.topmostPresented(from: root), root)
        }

        func test_topmostPresented_walksToDeepestPresentedChild() {
            // Build a presentation chain root → a → b → c using a real
            // window so UIKit actually wires `presentedViewController`.
            let root = UIViewController()
            let window = UIWindow(frame: .init(x: 0, y: 0, width: 100, height: 100))
            window.rootViewController = root
            window.makeKeyAndVisible()

            let first = UIViewController()
            let second = UIViewController()
            let third = UIViewController()

            let presentExpectation = XCTestExpectation(description: "chain presented")
            root.present(first, animated: false) {
                first.present(second, animated: false) {
                    second.present(third, animated: false) {
                        presentExpectation.fulfill()
                    }
                }
            }
            wait(for: [presentExpectation], timeout: 2.0)

            // Walk from root — should land on `third`, the deepest presented VC.
            XCTAssertIdentical(SceneRootResolver.topmostPresented(from: root), third)
        }
    }
#endif
