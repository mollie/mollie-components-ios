#if canImport(UIKit) && canImport(SwiftUI)
    import MollieCore
    import MolliePaymentsUI
    import SwiftUI
    import UIKit

    public extension View {
        /// SwiftUI bridge for `MolliePaymentSheet.present(...)`.
        ///
        /// When `isPresented` flips to `true` the sheet presents from the
        /// active scene's topmost view-controller and awaits a single typed
        /// `MolliePaymentResult`. On any terminal state — `.completed`,
        /// `.failed`, `.cancelled` — the binding flips back to `false` and
        /// `onResult` fires exactly once.
        ///
        /// If the host has no active scene (background launch, app
        /// extension), `onResult` fires with
        /// `.failed(.invalidConfiguration(field: "host", reason: ...))` and
        /// the binding resets without any UI presenting.
        func molliePaymentSheet(
            isPresented: Binding<Bool>,
            clientToken: String,
            theme: MolliePaymentTheme = MolliePaymentTheme(),
            endpoints: MolliePaymentEndpoints = .production,
            onResult: @escaping (MolliePaymentResult) -> Void
        ) -> some View {
            modifier(MolliePaymentSheetModifier(
                isPresented: isPresented,
                clientToken: clientToken,
                theme: theme,
                endpoints: endpoints,
                onResult: onResult
            ))
        }
    }

    private struct MolliePaymentSheetModifier: ViewModifier {
        @Binding var isPresented: Bool
        let clientToken: String
        let theme: MolliePaymentTheme
        let endpoints: MolliePaymentEndpoints
        let onResult: (MolliePaymentResult) -> Void

        func body(content: Content) -> some View {
            // `.task(id: isPresented)` drives the present flow.
            //
            // When `isPresented` flips from false → true, SwiftUI cancels
            // the previous task and re-creates a new one whose closure
            // captures the *current* modifier values — including the
            // `clientToken` that the caller set in the same state update
            // that triggered the flip. Using `.onChange` instead has a
            // race: the onChange closure is registered from the *previous*
            // render (before the state change applies), so `clientToken`
            // is captured with its stale value (often "").
            //
            // Task cancellation (parent pop, SwiftUI lifecycle teardown) is
            // handled by `withTaskCancellationHandler` inside
            // `PaymentSheetCoordinator.present(from:)`: the onCancel
            // closure dismisses the modal and resolves the continuation
            // with `.cancelled`, so the continuation is never orphaned.
            content
                .task(id: isPresented) {
                    guard isPresented else { return }
                    await Self.present(
                        clientToken: clientToken,
                        theme: theme,
                        endpoints: endpoints,
                        onResult: onResult,
                        isPresented: $isPresented
                    )
                }
        }

        @MainActor
        private static func present(
            clientToken: String,
            theme: MolliePaymentTheme,
            endpoints: MolliePaymentEndpoints,
            onResult: @escaping (MolliePaymentResult) -> Void,
            isPresented: Binding<Bool>
        ) async {
            guard let host = SceneRootResolver.activeRootViewController() else {
                // Reset the binding BEFORE delivering the callback — the
                // standard SwiftUI pattern (mirrors `.sheet(isPresented:)`)
                // so a merchant inspecting the binding from inside
                // `onResult` sees the post-dismiss state.
                isPresented.wrappedValue = false
                onResult(.failed(.invalidConfiguration(
                    field: "host",
                    reason: "no active scene"
                )))
                return
            }
            let result = await PaymentSheetCoordinator.run(
                from: host,
                clientToken: clientToken,
                theme: theme,
                endpoints: endpoints
            )
            // Binding flip first, then callback — see comment above.
            isPresented.wrappedValue = false
            onResult(result)
        }
    }
#endif
