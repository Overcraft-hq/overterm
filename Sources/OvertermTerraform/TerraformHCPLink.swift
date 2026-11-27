import Foundation

/// A `cloud {}` or `remote` root's workspace in HCP Terraform (TF-G6):
/// Overterm plans none of its runs, so the card and the refusal open the
/// workspace where they happen — `https://<hostname>/app/<org>/workspaces/<name>`,
/// built only from the block's literal values. None when the workspace is
/// chosen by tags, or by a prefix with no workspace selected. Pure.
package enum TerraformHCPLink {
    package static let defaultHost = "app.terraform.io"

    package static func url(backend: TerraformConfigFacts.Backend, workspace: String) -> URL? {
        guard backend.type == "cloud" || backend.type == "remote" else { return nil }
        guard let organization = backend.settings["organization"], isName(organization) else { return nil }
        let host = backend.settings["hostname"] ?? defaultHost
        guard isHost(host) else { return nil }
        let name: String
        if let named = backend.workspaceName {
            name = named
        } else if let prefix = backend.workspacePrefix, workspace != "default" {
            // `remote`'s prefix: the workspace is the prefix and the one selected.
            name = prefix + workspace
        } else {
            return nil
        }
        guard isName(name) else { return nil }
        return URL(string: "https://\(host)/app/\(organization)/workspaces/\(name)")
    }

    package static func url(for card: TerraformRootCard) -> URL? { url(backend: card.facts.backend, workspace: card.workspace) }

    /// HCP's names: letters, digits, `-` and `_` (a workspace's, an organization's).
    private static func isName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 90 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// A host name, nothing more: no scheme, userinfo, port path or query.
    private static func isHost(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 253 && !text.hasPrefix(".") && !text.hasPrefix("-")
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }

    package static let title = "Open in HCP Terraform"
}
