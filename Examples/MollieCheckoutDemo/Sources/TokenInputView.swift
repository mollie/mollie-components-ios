import SwiftUI

// MARK: - Integration shape

//
// Every Mollie checkout starts with a `clientAccessToken`. In a real
// integration your app NEVER mints this token itself — your backend calls
// Mollie to create a payment session and returns the token to the app over
// your own authenticated API. The SDK then drives that session.
//
// This sample ships no backend, so the examples let you PASTE a token you
// generated elsewhere (e.g. from a curl against your server). The paste
// field below exists ONLY so you can try the flows end-to-end without
// standing up a server.
//
//   ⚠️  DO NOT ship a paste field in your production app. Fetch the token
//       from your server — see the commented `fetchClientAccessToken`
//       reference below for the shape that belongs in real code.

/// A reusable paste field that binds to the `clientAccessToken` an example
/// will hand to the SDK.
///
/// Duplicated verbatim across the examples on purpose: each example file is
/// meant to be read (and copy-pasted) on its own, so the token plumbing
/// lives inline rather than behind a shared abstraction.
struct TokenInputView: View {
    /// The server-issued client access token. In this sample it is pasted by
    /// hand; in your app it comes from your backend (see below).
    @Binding var clientAccessToken: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Client access token")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Paste a client access token", text: $clientAccessToken, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(2 ... 4)

            Text("Demo only — paste a token you minted on your server. "
                + "Production apps fetch this from their own backend.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Production reference: fetch the token from YOUR server

//
// In your real app, replace the paste field above with a call to your own
// backend, which creates the Mollie session and returns the token. The SDK
// only ever needs the resulting `clientAccessToken` string. Shape:
//
//     func fetchClientAccessToken() async throws -> String {
//         // `/checkout/session` is YOUR endpoint, not a Mollie endpoint.
//         // Your server authenticates the shopper, creates a Mollie
//         // payment session server-side, and returns its client token.
//         var request = URLRequest(url: URL(string: "https://api.your-shop.example/checkout/session")!)
//         request.httpMethod = "POST"
//         request.setValue("application/json", forHTTPHeaderField: "Content-Type")
//         // request.setValue("Bearer \(yourUserSessionToken)", forHTTPHeaderField: "Authorization")
//
//         let (data, response) = try await URLSession.shared.data(for: request)
//         guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
//             throw URLError(.badServerResponse)
//         }
//
//         struct CheckoutSession: Decodable { let clientAccessToken: String }
//         return try JSONDecoder().decode(CheckoutSession.self, from: data).clientAccessToken
//     }
