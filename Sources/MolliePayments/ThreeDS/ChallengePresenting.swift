import Foundation

/// Boundary for 3-D Secure challenge presentation. Lets the coordinator be
/// tested without requiring UIKit/WebKit; the real implementation lives on
/// `ThreeDSCoordinator` and is platform-guarded.
///
/// The caller supplies the `ChallengeContainer` (typically the payment
/// sheet's navigation stack). The presenter pushes its UI onto the container
/// and resolves the returned `ThreeDSResult` when the challenge completes,
/// fails, or is dismissed by the user.
package protocol ChallengePresenting: Sendable {
    func present(challengeURL: URL, in container: any ChallengeContainer) async -> ThreeDSResult

    /// Present a standard 3DS challenge with the merchant's `redirectUrl`
    /// threaded through. When the ACS bounces the WebView to that URL after
    /// auth completes the presenter cancels the navigation, dismisses the
    /// WebView, and resolves `.authenticated` — meaning "presentation done";
    /// the coordinator resumes polling and only `status=completed` from a
    /// subsequent poll signals true payment success.
    ///
    /// Pass `returnURL: nil` for a challenge with no known merchant return
    /// (legacy code paths; equivalent to the old `present(challengeURL:in:)`).
    func present(
        challengeURL: URL,
        returnURL: URL?,
        in container: any ChallengeContainer
    ) async -> ThreeDSResult

    /// Present a hosted-page redirect (Mollie's prepare-authentication /
    /// final-screen URL emitted with `actionType=redirect`). Dismisses when
    /// the WebView lands on `returnURL`'s host. Returns `.authenticated`
    /// purely to mean "presentation done"; the coordinator resumes polling
    /// and only `status=completed` from a subsequent poll signals true
    /// payment success.
    func presentRedirect(url: URL, returnURL: URL?, in container: any ChallengeContainer) async -> ThreeDSResult

    /// Force-dismiss an in-flight presentation and resolve it as `.cancelled`.
    ///
    /// PXP-5009: a frictionless-hosted 3DS page completes the payment
    /// server-side without ever navigating to the return URL or firing the
    /// `mollie-interceptor` postMessage, so `present`/`presentRedirect` never
    /// resolves on its own even after the coordinator's poller has already
    /// observed the terminal `.sessionCompleted`/`.sessionFailed`. The
    /// coordinator races the presentation against continued poll-stream
    /// draining; when a terminal poll event wins, it calls `dismiss()` here
    /// to tear down the still-open WebView instead of leaving it stranded.
    ///
    /// Default is a no-op so existing test doubles that only implement
    /// `present`/`presentRedirect` keep compiling; the real
    /// `ThreeDSCoordinator` overrides it to actually dismiss its UI and
    /// resolve the pending continuation.
    func dismiss() async
}

package extension ChallengePresenting {
    func dismiss() async {}

    /// Default `present(challengeURL:returnURL:in:)` falls back to the
    /// returnURL-free overload. Existing test mocks that only implement the
    /// older signature keep working — they just won't see the merchant
    /// return URL. The real `ThreeDSCoordinator` overrides this with the
    /// real WebView wiring.
    func present(
        challengeURL: URL,
        returnURL _: URL?,
        in container: any ChallengeContainer
    ) async -> ThreeDSResult {
        await present(challengeURL: challengeURL, in: container)
    }

    /// Default falls back to the standard challenge presenter. Test mocks
    /// can override; the real `ThreeDSCoordinator` provides its own impl.
    func presentRedirect(url: URL, returnURL _: URL?, in container: any ChallengeContainer) async -> ThreeDSResult {
        await present(challengeURL: url, in: container)
    }
}
