public enum SessionEndpoint {
    public static func get(sessionToken: String) -> Endpoint<SessionResponse> {
        Endpoint(path: "client/v2/sessions/\(sessionToken)", method: .get, body: nil, requiresAuth: true)
    }

    public static func updateDetails(
        sessionToken: String,
        body: UpdateDetailsRequest
    ) -> Endpoint<SessionResponse> {
        Endpoint(
            path: "client/v2/sessions/\(sessionToken)/details",
            method: .patch,
            body: body,
            requiresAuth: true
        )
    }

    public static func cancelPayment(sessionToken: String) -> Endpoint<SessionResponse> {
        Endpoint(
            path: "client/v2/sessions/\(sessionToken)/cancel-payment",
            method: .post,
            body: nil,
            requiresAuth: true
        )
    }

    /// PATCH the session out of `pending_authentication` after the user
    /// abandons the 3-D Secure flow (ANNULEREN on the hosted page, swipe-
    /// to-dismiss on the modal, nav-pop on the push container). Must be
    /// awaited before declaring the attempt cancelled — otherwise the
    /// session stays stuck and the next `POST /checkout-attempts` is
    /// rejected. Method/path verified against the published Sessions API
    /// contract.
    public static func cancelAuthentication(sessionToken: String) -> Endpoint<SessionResponse> {
        Endpoint(
            path: "client/v2/sessions/\(sessionToken)/cancel-authentication",
            method: .patch,
            body: nil,
            requiresAuth: true
        )
    }

    /// Charging POST that authorizes the payment — **not auto-retried**.
    ///
    /// Per spike #316 (Model B, token-as-anchor), the Sessions Service honours
    /// no inbound idempotency header on this endpoint, so the SDK emits none
    /// and never transparently retries it (POST is excluded from `isIdempotent`
    /// in `SessionClient`). Auto-retrying with no server-side dedup would risk a
    /// duplicate authorization. The `checkoutAttemptToken` in the response is
    /// the natural dedup anchor: on an indeterminate failure the SDK surfaces
    /// `.timeout` and the merchant reconciles server-side via checkout-attempt
    /// state. In-process re-taps are guarded by `SingleFlight` in
    /// `CardPaymentCoordinator.runSubmit`. See decisions-log "2026-06-23 —
    /// Network idempotency model decided (spike #316 resolved)".
    public static func createCheckoutAttempt(
        sessionToken: String,
        body: CreateCheckoutAttemptRequest
    ) -> Endpoint<CreateCheckoutAttemptResponse> {
        Endpoint(
            path: "client/v2/sessions/\(sessionToken)/checkout-attempts",
            method: .post,
            body: body,
            requiresAuth: true
        )
    }

    /// Trailing slash is required — the backend routes on the literal path.
    public static func getCheckoutAttempts(sessionToken: String) -> Endpoint<CheckoutAttemptsStateMap> {
        Endpoint(
            path: "client/v2/sessions/\(sessionToken)/checkout-attempts/",
            method: .get,
            body: nil,
            requiresAuth: true
        )
    }
}

// MARK: - Request / response bodies

public struct UpdateDetailsRequest: Encodable {
    public let paymentMethodDetails: PaymentMethodDetailsRequest
    public let fingerprint: DeviceFingerprint

    public init(paymentMethodDetails: PaymentMethodDetailsRequest, fingerprint: DeviceFingerprint) {
        self.paymentMethodDetails = paymentMethodDetails
        self.fingerprint = fingerprint
    }
}

public struct PaymentMethodDetailsRequest: Encodable {
    public let method: String
    public let params: CreditCardParams

    public init(method: String, cardToken: String) {
        self.method = method
        params = CreditCardParams(pspToken: cardToken)
    }
}

/// Encodes as `{"creditcard": {"pspToken": "..."}}` — the Sessions API
/// requires the method name as the outer key inside `params`.
public struct CreditCardParams: Encodable {
    public let pspToken: String

    public func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: CreditCardParamsMethodKey.self)
        var inner = outer.nestedContainer(keyedBy: CreditCardParamsParamKey.self, forKey: .creditcard)
        try inner.encode(pspToken, forKey: .pspToken)
    }
}

private enum CreditCardParamsMethodKey: String, CodingKey { case creditcard }
private enum CreditCardParamsParamKey: String, CodingKey { case pspToken }

/// Device fingerprint sent with every PATCH /details call.
/// Maps to the browser fingerprint the web SDK collects; native apps
/// supply fixed or device-derived values for each field.
public struct DeviceFingerprint: Encodable, Sendable {
    public let language: String
    public let javascriptEnabled: Bool
    public let screenWidth: String
    public let screenHeight: String
    public let timeZoneOffset: String
    public let javaEnabled: Bool
    public let colorDepth: String

    public init(
        language: String,
        javascriptEnabled: Bool,
        screenWidth: String,
        screenHeight: String,
        timeZoneOffset: String,
        javaEnabled: Bool,
        colorDepth: String
    ) {
        self.language = language
        self.javascriptEnabled = javascriptEnabled
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.timeZoneOffset = timeZoneOffset
        self.javaEnabled = javaEnabled
        self.colorDepth = colorDepth
    }
}
