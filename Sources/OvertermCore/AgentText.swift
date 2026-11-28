import Foundation

/// Text on its way to an agent — a tool's answer, an Ask Agent prompt, a
/// brief — which lands in the agent's transcript and, from there, in its
/// provider's logs. It is made only by scrubbing (SEC-N1): every URL's
/// password and every credential `Secrets.scrubCredentials` finds are
/// masked, whatever a feature did before. A feature's own masking (a
/// container's env values, a Secret's data, Terraform's sensitive values)
/// still comes first: this gate knows no names, only shapes, and a second
/// pass over masked text leaves it as it was.
package struct AgentText: Sendable, Equatable {
    package let text: String

    package init(scrubbing text: String) { self.text = Self.scrub(text) }

    package var isEmpty: Bool { text.isEmpty }

    /// `Secrets`' rules for what an agent reads, in Terraform's order.
    package static func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return Secrets.maskURLs(in: Secrets.scrubCredentials(text))
    }

    /// A JSON-RPC reply on its way back over the MCP bridge with every text
    /// an agent reads in it scrubbed: each text part of a tool's result and
    /// an error's message. Images pass as they are.
    package static func scrubbing(reply: [String: Any]) -> [String: Any] {
        var reply = reply
        if var result = reply["result"] as? [String: Any], let content = result["content"] as? [[String: Any]] {
            result["content"] = content.map { part in
                guard part["type"] as? String == "text", let text = part["text"] as? String else { return part }
                var part = part
                part["text"] = scrub(text)
                return part
            }
            reply["result"] = result
        }
        if var error = reply["error"] as? [String: Any], let message = error["message"] as? String {
            error["message"] = scrub(message)
            reply["error"] = error
        }
        return reply
    }
}
