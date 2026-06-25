#if canImport(UIKit) && canImport(SwiftUI)
    import MollieCore
    import MolliePaymentsUI
    import SwiftUI
    import UIKit

    /// Embeddable SwiftUI surface for the Mollie card form.
    ///
    /// Drop this view directly into any host layout (a checkout screen, a
    /// settings page, anywhere) and the SDK card form renders inline. The
    /// form's own "Pay with card" button is the CTA — no modal sheet, no
    /// nav controller required. On any terminal state — `.completed`,
    /// `.failed`, `.cancelled` — `onResult` fires exactly once.
    ///
    /// For the modal-presentation alternative, see
    /// `View.molliePaymentSheet(...)` and `MolliePaymentSheet.present(...)`.
    /// Both APIs share the same theme and the same `MolliePaymentResult`
    /// type — pick the one that fits
    /// the host's layout.
    public struct MolliePaymentCardFormView: View {
        private let clientToken: String
        private let theme: MolliePaymentTheme
        private let endpoints: MolliePaymentEndpoints
        private let onResult: (MolliePaymentResult) -> Void

        public init(
            clientToken: String,
            theme: MolliePaymentTheme = MolliePaymentTheme(),
            endpoints: MolliePaymentEndpoints = .production,
            onResult: @escaping (MolliePaymentResult) -> Void
        ) {
            self.clientToken = clientToken
            self.theme = theme
            self.endpoints = endpoints
            self.onResult = onResult
        }

        public var body: some View {
            switch PaymentSheetCoordinator.decode(clientToken: clientToken) {
            case let .success(decoded):
                EmbeddedFormRepresentable(
                    decodedToken: decoded,
                    rawClientToken: clientToken,
                    theme: theme,
                    endpoints: endpoints,
                    onResult: onResult
                )
            case let .failure(error):
                // Bail visibly: render nothing, deliver the typed failure
                // once on first appear, then leave the slot empty. The host
                // can react in `onResult` (e.g. dismiss the screen, surface
                // an error banner) without the SDK rendering any chrome.
                Color.clear
                    .frame(height: 0)
                    .task { onResult(.failed(error)) }
            }
        }
    }

    /// UIViewControllerRepresentable that mounts `MollieCardFormViewController`
    /// inside SwiftUI. Owns the coordinator instance so the form's submit/
    /// cancel callbacks drive the embed-side payment loop without a modal.
    private struct EmbeddedFormRepresentable: UIViewControllerRepresentable {
        let decodedToken: ClientToken
        let rawClientToken: String
        let theme: MolliePaymentTheme
        let endpoints: MolliePaymentEndpoints
        let onResult: (MolliePaymentResult) -> Void

        @MainActor
        func makeCoordinator() -> EmbeddedCardFormCoordinator {
            EmbeddedCardFormCoordinator(
                clientToken: decodedToken,
                rawClientToken: rawClientToken,
                theme: theme,
                endpoints: endpoints,
                onResult: onResult
            )
        }

        func makeUIViewController(context: Context) -> MollieCardFormViewController {
            let form = MollieCardFormViewController(theme: theme)
            let coordinator = context.coordinator
            coordinator.formViewController = form
            form.onSubmit = { snapshot in
                MainActor.assumeIsolated {
                    coordinator.handleSubmit(snapshot: snapshot)
                }
            }
            form.onCancel = {
                MainActor.assumeIsolated {
                    coordinator.handleCancel()
                }
            }
            return form
        }

        func updateUIViewController(_: MollieCardFormViewController, context _: Context) {
            // No-op. Form state lives inside the VC + the coordinator; we
            // never need to push fresh props down on a parent re-render
            // because `clientToken`/`theme`/etc. are captured into the
            // coordinator at `makeUIViewController` time and the embed
            // view's identity is keyed on `clientToken` upstream.
        }

        @MainActor
        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiViewController: MollieCardFormViewController,
            context _: Context
        ) -> CGSize? {
            // Ask the form's view what height it wants given the proposed
            // width. The form's outer stack uses a `lessThanOrEqual` bottom
            // anchor so this returns a true content-fit height — without
            // it the embed would stretch to fill whatever vertical slot
            // SwiftUI gave us.
            let targetWidth = proposal.width ?? UIView.layoutFittingExpandedSize.width
            let fitting = uiViewController.view.systemLayoutSizeFitting(
                CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            return CGSize(width: targetWidth, height: fitting.height)
        }
    }
#endif
