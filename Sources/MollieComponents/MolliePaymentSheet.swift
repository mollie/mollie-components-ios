import MolliePaymentsUI
#if canImport(UIKit)
    import UIKit
#endif

/// Single merchant-facing entry point for the Mollie payment sheet.
///
/// Declared as an `enum` (no cases) so it can never be instantiated and the
/// public surface stays strictly static — per Decision 1 / Approach B in the
/// Phase 3 plan ("no public initialiser on the sheet").
///
/// MR1 stub: `present(...)` returns `.cancelled` so callers can compile
/// against the final signature today. MR3 swaps the body for a real call
/// into `PaymentSheetCoordinator`.
public enum MolliePaymentSheet {
    #if canImport(UIKit)
        /// Present the Mollie card-payment sheet from the given UIKit host.
        ///
        /// - Parameters:
        ///   - host: The view controller to present from.
        ///   - clientToken: The server-issued client access token that
        ///     identifies the session to drive.
        ///   - theme: Visual configuration; defaults to Mollie branding.
        /// - Returns: A typed `MolliePaymentResult` describing the terminal
        ///   outcome of the flow.
        @MainActor
        public static func present(
            from host: UIViewController,
            clientToken: String,
            theme: MolliePaymentTheme = MolliePaymentTheme()
        ) async -> MolliePaymentResult {
            await present(from: host, clientToken: clientToken, theme: theme, endpoints: .production)
        }

        /// Advanced overload that lets callers point the sheet at non-production
        /// Mollie hosts (e.g. a test/sandbox environment or a local development
        /// server); production merchants should use the standard overload above.
        @MainActor
        public static func present(
            from host: UIViewController,
            clientToken: String,
            theme: MolliePaymentTheme = MolliePaymentTheme(),
            endpoints: MolliePaymentEndpoints
        ) async -> MolliePaymentResult {
            await PaymentSheetCoordinator.run(
                from: host,
                clientToken: clientToken,
                theme: theme,
                endpoints: endpoints
            )
        }

    #endif
}
