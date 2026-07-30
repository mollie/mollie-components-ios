import Foundation

/// Customer details a merchant can inject into a checkout attempt via
/// `MollieCheckout`'s `beforeSubmit` hook (public API v1).
///
/// Confirmed by backend verification: the Sessions Service accepts
/// `customerDetails.billingAddress`/`customerDetails.shippingAddress` on
/// `POST .../checkout-attempts`.
///
/// `shippingAddress.email` is stripped here even if the caller sets it —
/// belt-and-suspenders alongside the backend's own handling of the field.
public struct MollieCustomerDetails: Encodable, Sendable {
    public let billingAddress: MollieAddress?
    public let shippingAddress: MollieAddress?

    public init(billingAddress: MollieAddress? = nil, shippingAddress: MollieAddress? = nil) {
        self.billingAddress = billingAddress
        self.shippingAddress = shippingAddress.map { address in
            MollieAddress(
                givenName: address.givenName,
                familyName: address.familyName,
                email: nil,
                streetAndNumber: address.streetAndNumber,
                streetAdditional: address.streetAdditional,
                postalCode: address.postalCode,
                city: address.city,
                region: address.region,
                country: address.country,
                organizationName: address.organizationName,
                title: address.title
            )
        }
    }
}

/// An address for `MollieCustomerDetails`, matching the backend
/// `AddressRequest` contract exactly.
///
/// `phone` is deliberately omitted — not part of the confirmed backend
/// contract (G2).
public struct MollieAddress: Encodable, Sendable {
    public let givenName: String?
    public let familyName: String?
    public let email: String?
    public let streetAndNumber: String?
    public let streetAdditional: String?
    public let postalCode: String?
    public let city: String?
    public let region: String?
    public let country: String?
    public let organizationName: String?
    public let title: String?

    public init(
        givenName: String? = nil,
        familyName: String? = nil,
        email: String? = nil,
        streetAndNumber: String? = nil,
        streetAdditional: String? = nil,
        postalCode: String? = nil,
        city: String? = nil,
        region: String? = nil,
        country: String? = nil,
        organizationName: String? = nil,
        title: String? = nil
    ) {
        self.givenName = givenName
        self.familyName = familyName
        self.email = email
        self.streetAndNumber = streetAndNumber
        self.streetAdditional = streetAdditional
        self.postalCode = postalCode
        self.city = city
        self.region = region
        self.country = country
        self.organizationName = organizationName
        self.title = title
    }
}
