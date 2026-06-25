import Foundation
@preconcurrency import MollieCore

package final class CardTokenizer: Sendable {
    private let httpClient: any HTTPClient
    private let profileToken: String
    private let testmode: Bool

    package init(httpClient: any HTTPClient, profileToken: String, testmode: Bool) {
        self.httpClient = httpClient
        self.profileToken = profileToken
        self.testmode = testmode
    }

    package func tokenize(_ data: CardSubmissionData) async throws -> CardToken {
        do {
            return try await httpClient.perform(
                TokenizerEndpoint.tokenize(data, profileToken: profileToken, testmode: testmode)
            )
        } catch let MollieError.api(.validationFailed(violations)) {
            let reason = violations.first.map { "\($0.name): \($0.reason)" } ?? "Validation failed"
            throw MollieError.tokenizationFailed(
                reason: reason,
                underlying: MollieError.api(.validationFailed(violations))
            )
        }
        // Other errors propagate unchanged.
    }
}
