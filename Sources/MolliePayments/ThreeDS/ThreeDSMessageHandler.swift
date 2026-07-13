import Foundation
import MollieCore
#if canImport(WebKit)
    import WebKit
#endif

#if canImport(WebKit)
    /// Receives postMessage events bridged from the ACS page (see the user
    /// script injected in `ThreeDSWebViewController`). Message contract:
    ///   name: "mollieChallenge"
    ///   body: { sender: "mollie-interceptor", type: "challenge"|"complete"|"error"|"canceled", errorCode: Int }
    ///
    /// Events are delivered as `ThreeDSBridgeEvent`: a `type:"challenge"`
    /// surfaces as the non-terminal `.challengeEscalation` (the controller
    /// reveals the WebView), while `complete`/`error`/`canceled` surface as a
    /// terminal `.result`. An ACS-level frictionless auth emits `complete` with
    /// no preceding `challenge`, so the WebView never reveals.
    final class ThreeDSMessageHandler: NSObject, WKScriptMessageHandler {
        private let onEvent: @MainActor (ThreeDSBridgeEvent) -> Void

        init(onEvent: @escaping @MainActor (ThreeDSBridgeEvent) -> Void) {
            self.onEvent = onEvent
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else {
                // Use the existing summary surface rather than adding a new enum case
                // (which is owned by another agent's MR). Stable token: "dropped: <reason>".
                return
            }
            guard let event = Self.parseBridgeEvent(name: message.name, body: message.body) else {
                return
            }
            // Capture every accepted interceptor message — including the
            // non-terminal `challenge` — so DevTools / logs can confirm against
            // production which event types actually arrive on each 3DS path.
            // Terminal delivery is single-shot at the resolver layer
            // (`ThreeDSWebViewController.resolve(_:)` guards on `resolved`), so
            // even if two ACS messages race onto the main actor in quick succession
            // only the first terminal one lands. A `.challengeEscalation` is
            // non-terminal and only reveals the WebView — it never resolves.
            Task { @MainActor in onEvent(event) }
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

        /// Bridge-event parser: distinguishes the non-terminal `challenge`
        /// escalation (interactive UI about to show) from a terminal
        /// `ThreeDSResult`. A `type == "challenge"` message with a valid sender
        /// yields `.challengeEscalation`; every other valid message delegates to
        /// `parse` and is wrapped in `.result`. Malformed / non-interceptor
        /// bodies return nil. `package` so unit tests can exercise it directly.
        package static func parseBridgeEvent(name: String, body: Any) -> ThreeDSBridgeEvent? {
            guard name == "mollieChallenge",
                  let dict = body as? [String: Any],
                  let sender = dict["sender"] as? String, sender == "mollie-interceptor",
                  let type = dict["type"] as? String else { return nil }
            if type == "challenge" { return .challengeEscalation }
            guard let result = parse(name: name, body: body) else { return nil }
            return .result(result)
        }
    }
#endif
