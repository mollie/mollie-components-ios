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
}

package extension ChallengePresenting {
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
