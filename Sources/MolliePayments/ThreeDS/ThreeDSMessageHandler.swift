import Foundation
import MollieCore
#if canImport(WebKit)
    import WebKit
#endif

#if canImport(WebKit)
    /// Receives postMessage events bridged from the ACS page (see the user
    /// script injected in `ThreeDSWebViewController`). Message contract:
    ///   name: "mollieChallenge"
    ///   body: { sender: "mollie-interceptor", type: "complete"|"error"|"canceled", errorCode: Int }
    final class ThreeDSMessageHandler: NSObject, WKScriptMessageHandler {
        private let onResult: @MainActor (ThreeDSResult) -> Void

        init(onResult: @escaping @MainActor (ThreeDSResult) -> Void) {
            self.onResult = onResult
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else {
                // Use the existing summary surface rather than adding a new enum case
                // (which is owned by another agent's MR). Stable token: "dropped: <reason>".
                return
            }
            guard let result = Self.parse(name: message.name, body: message.body) else {
                return
            }
            // Result delivery is single-shot at the resolver layer
            // (`ThreeDSWebViewController.resolve(_:)` guards on `resolved`), so
            // even if two ACS messages race onto the main actor in quick succession
            // only the first lands. No extra serial-arrival guard needed here.
            Task { @MainActor in onResult(result) }
        }

        /// Extracts only the non-PCI fields (`type`, `errorCode`) from the
        /// postMessage body. PAN / CVV / card data never appear in the ACS
        /// → page postMessage contract today, but pulling explicit fields
        /// keeps this safe against contract drift. `package` so unit tests
        /// can verify the redaction contract without a real `WKScriptMessage`.
        package static func makeSummary(_ body: Any) -> String {
            guard let dict = body as? [String: Any],
                  let type = dict["type"] as? String
            else {
                return "type=unknown"
            }
            if let errorCode = dict["errorCode"] as? Int {
                return "type=\(type) errorCode=\(errorCode)"
            }
            return "type=\(type)"
        }

        /// Pure parser exposed package-internal so unit tests can exercise
        /// the contract without instantiating `WKScriptMessage` (which has
        /// no public initialiser).
        package static func parse(name: String, body: Any) -> ThreeDSResult? {
            guard name == "mollieChallenge",
                  let dict = body as? [String: Any],
                  let sender = dict["sender"] as? String, sender == "mollie-interceptor",
                  let type = dict["type"] as? String else { return nil }
            // Fail-closed contract: the ACS must explicitly send `errorCode: 0`
            // to authenticate. A missing or non-Int `errorCode` is treated as a
            // failed challenge — never silently as success. A compromised or
            // misbehaving ACS that omits the field cannot bypass auth.
            switch type {
            case "complete":
                guard let errorCode = dict["errorCode"] as? Int else {
                    return .failed(reason: .challengeFailed)
                }
                return errorCode == 0 ? .authenticated : .failed(reason: .challengeFailed)
            case "error":
                let errorCode = dict["errorCode"] as? Int ?? -1
                return .failed(reason: .sdkError(message: "3DS error \(errorCode)"))
            case "canceled":
                return .cancelled
            default:
                return nil
            }
        }
    }
#endif
