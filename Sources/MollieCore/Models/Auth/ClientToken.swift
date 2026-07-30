import Foundation

/// Decoded representation of the base64-JSON clientAccessToken provided by the merchant app.
/// The merchant backend creates a session via POST /v2/sessions and forwards
/// the returned client_access_token directly to the SDK.
public struct ClientToken: Decodable {
    public let sessionToken: String
    public let secret: String
    public let availablePaymentMethods: [String]
    public let testmode: Bool
    public let profileToken: String
    public let merchantProfileName: String?
    public let organizationCountryCode: String?
    /// Client-safe Pusher connection block forwarded by the backend:
    /// app `key`, `cluster`, resolved `channel` name, and
    /// `event` name. Absent when Pusher isn't enabled for the session.
    public let pusherConfiguration: PusherConfiguration?
    private let enabledFeatures: [String]

    public var isPusherEnabled: Bool {
        enabledFeatures.contains("session_pusher_enabled")
    }

    enum CodingKeys: String, CodingKey {
        case sessionToken
        case secret
        case availablePaymentMethods
        case testmode
        case profileToken
        case merchantProfileName
        case organizationCountryCode
        case pusherConfiguration
        case enabledFeatures = "_enabledFeatures"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionToken = try container.decode(String.self, forKey: .sessionToken)
        secret = try container.decode(String.self, forKey: .secret)
        availablePaymentMethods = try container.decode([String].self, forKey: .availablePaymentMethods)
        testmode = try container.decode(Bool.self, forKey: .testmode)
        profileToken = try container.decode(String.self, forKey: .profileToken)
        merchantProfileName = try container.decodeIfPresent(String.self, forKey: .merchantProfileName)
        organizationCountryCode = try container.decodeIfPresent(String.self, forKey: .organizationCountryCode)
        // A malformed or partial `pusherConfiguration` must NOT fail the whole
        // token: the real-time doorbell is best-effort and HTTP polling covers
        // its absence. On a backend field drift we degrade to nil (poll-only)
        // rather than throwing and blocking the payment. `makeChannelsClient`
        // applies the same fail-safe for empty fields.
        pusherConfiguration = try? container.decodeIfPresent(PusherConfiguration.self, forKey: .pusherConfiguration)
        enabledFeatures = try (container.decodeIfPresent([String].self, forKey: .enabledFeatures)) ?? []
    }
}

public extension ClientToken {
    static func decode(from base64String: String) throws -> ClientToken {
        guard let data = Data(base64Encoded: base64String) else {
            throw MollieError.invalidClientToken(reason: "not valid base64")
        }
        do {
            return try JSONDecoder().decode(ClientToken.self, from: data)
        } catch let mollieError as MollieError {
            throw mollieError
        } catch {
            throw MollieError.invalidClientToken(reason: error.localizedDescription)
        }
    }
}
