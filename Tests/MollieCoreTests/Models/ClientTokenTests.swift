import XCTest
@testable import MollieCore

final class ClientTokenTests: XCTestCase {
    private func makeBase64(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
    }

    private let validJSON = """
    {
        "sessionToken": "sess_abc123",
        "secret": "s3cr3t",
        "availablePaymentMethods": ["creditcard", "ideal"],
        "testmode": true,
        "profileToken": "pfl_xyz",
        "merchantProfileName": "Acme Shop",
        "organizationCountryCode": "NL",
        "_enabledFeatures": ["session_pusher_enabled"]
    }
    """

    func test_decode_happyPath() throws {
        let token = try ClientToken.decode(from: makeBase64(validJSON))
        XCTAssertEqual(token.sessionToken, "sess_abc123")
        XCTAssertEqual(token.secret, "s3cr3t")
        XCTAssertEqual(token.availablePaymentMethods, ["creditcard", "ideal"])
        XCTAssertTrue(token.testmode)
        XCTAssertEqual(token.profileToken, "pfl_xyz")
        XCTAssertEqual(token.merchantProfileName, "Acme Shop")
        XCTAssertEqual(token.organizationCountryCode, "NL")
    }

    func test_isPusherEnabled_whenFeaturePresent() throws {
        let token = try ClientToken.decode(from: makeBase64(validJSON))
        XCTAssertTrue(token.isPusherEnabled)
    }

    func test_isPusherEnabled_whenFeatureAbsent() throws {
        let json = """
        {
            "sessionToken": "sess_abc123",
            "secret": "s3cr3t",
            "availablePaymentMethods": [],
            "testmode": false,
            "profileToken": "pfl_xyz",
            "_enabledFeatures": []
        }
        """
        let token = try ClientToken.decode(from: makeBase64(json))
        XCTAssertFalse(token.isPusherEnabled)
    }

    func test_isPusherEnabled_whenEnabledFeaturesKeyMissing() throws {
        let json = """
        {
            "sessionToken": "sess_abc123",
            "secret": "s3cr3t",
            "availablePaymentMethods": [],
            "testmode": false,
            "profileToken": "pfl_xyz"
        }
        """
        let token = try ClientToken.decode(from: makeBase64(json))
        XCTAssertFalse(token.isPusherEnabled)
    }

    func test_optionalFields_missingFromJSON_decodeAsNil() throws {
        let json = """
        {
            "sessionToken": "sess_abc123",
            "secret": "s3cr3t",
            "availablePaymentMethods": [],
            "testmode": false,
            "profileToken": "pfl_xyz"
        }
        """
        let token = try ClientToken.decode(from: makeBase64(json))
        XCTAssertNil(token.merchantProfileName)
        XCTAssertNil(token.organizationCountryCode)
    }

    func test_pusherConfiguration_whenPresent_decodesAllFields() throws {
        let json = """
        {
            "sessionToken": "sess_abc123",
            "secret": "s3cr3t",
            "availablePaymentMethods": [],
            "testmode": false,
            "profileToken": "pfl_xyz",
            "pusherConfiguration": {
                "key": "k",
                "cluster": "eu",
                "channel": "px_sessions_app_session_sess_abc",
                "event": "session_changed"
            }
        }
        """
        let token = try ClientToken.decode(from: makeBase64(json))
        let config = try XCTUnwrap(token.pusherConfiguration)
        XCTAssertEqual(config.key, "k")
        XCTAssertEqual(config.cluster, "eu")
        XCTAssertEqual(config.channel, "px_sessions_app_session_sess_abc")
        XCTAssertEqual(config.event, "session_changed")
    }

    func test_pusherConfiguration_whenAbsent_decodesAsNil() throws {
        let json = """
        {
            "sessionToken": "sess_abc123",
            "secret": "s3cr3t",
            "availablePaymentMethods": [],
            "testmode": false,
            "profileToken": "pfl_xyz"
        }
        """
        let token = try ClientToken.decode(from: makeBase64(json))
        XCTAssertNil(token.pusherConfiguration)
    }

    /// A malformed/partial `pusherConfiguration` (here: missing `channel`) must
    /// NOT fail the whole token — the real-time doorbell is best-effort and HTTP
    /// polling covers its absence. The token still decodes; the block is dropped.
    func test_pusherConfiguration_whenMalformed_decodesAsNilAndTokenSurvives() throws {
        let json = """
        {
            "sessionToken": "sess_abc123",
            "secret": "s3cr3t",
            "availablePaymentMethods": [],
            "testmode": false,
            "profileToken": "pfl_xyz",
            "pusherConfiguration": {
                "key": "k",
                "cluster": "eu",
                "event": "session_changed"
            }
        }
        """
        let token = try ClientToken.decode(from: makeBase64(json))
        XCTAssertEqual(token.sessionToken, "sess_abc123")
        XCTAssertNil(token.pusherConfiguration)
    }

    func test_invalidBase64_throwsInvalidClientToken() {
        XCTAssertThrowsError(try ClientToken.decode(from: "not-base64!!!")) { error in
            guard case MollieError.invalidClientToken = error else {
                XCTFail("Expected MollieError.invalidClientToken, got \(error)")
                return
            }
        }
    }

    func test_missingRequiredField_throwsInvalidClientToken() {
        let json = """
        {
            "sessionToken": "sess_abc123"
        }
        """
        XCTAssertThrowsError(try ClientToken.decode(from: makeBase64(json))) { error in
            guard case MollieError.invalidClientToken = error else {
                XCTFail("Expected MollieError.invalidClientToken, got \(error)")
                return
            }
        }
    }
}
