import Foundation

/// Which state a root and workspace read and write (analysis 4.11): the
/// backend's type and its location keys, the workspace folded in as each
/// backend does. Two roots with one identity share their state — in two
/// worktrees, or under two folder names — and production follows the
/// identity (5.1). Pure.
struct TerraformStateIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    /// `terraform`; `tofu` later (stage 3).
    var product: String
    var backend: String
    /// The location, as one string per backend: `acme-tfstate/env:/acme-stage/net.tfstate`.
    var location: String

    var description: String { "\(product) \(backend) \(location)" }

    /// The identity of `backend` for `workspace`, `root` being the
    /// root's absolute folder (a local backend's state is a file in it).
    /// Nil when the backend's keys don't say where its state is: a
    /// partial configuration (`-backend-config` files, never read), `pg`
    /// (its location is in a connection string, a secret).
    static func of(backend: TerraformConfigFacts.Backend?, workspace: String, root: URL, product: String = "terraform") -> TerraformStateIdentity? {
        let backend = backend ?? TerraformConfigFacts.Backend(type: "local")
        let settings = backend.settings
        let isDefault = workspace == "default"
        func make(_ location: String) -> TerraformStateIdentity { TerraformStateIdentity(product: product, backend: backend.type, location: location) }
        switch backend.type {
        case "local":
            return make(localStatePath(backend: backend, workspace: workspace, root: root).path)
        case "s3":
            guard let bucket = settings["bucket"], let key = settings["key"] else { return nil }
            let prefix = settings["workspace_key_prefix"] ?? "env:"
            return make(bucket + "/" + (isDefault ? key : "\(prefix)/\(workspace)/\(key)"))
        case "gcs":
            guard let bucket = settings["bucket"] else { return nil }
            let prefix = settings["prefix"].map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? ""
            return make(bucket + "/" + (prefix.isEmpty ? "" : prefix + "/") + "\(workspace).tfstate")
        case "azurerm":
            guard let account = settings["storage_account_name"], let container = settings["container_name"], let key = settings["key"] else { return nil }
            return make("\(account)/\(container)/" + (isDefault ? key : "\(key)env:\(workspace)"))
        case "kubernetes":
            guard let suffix = settings["secret_suffix"] else { return nil }
            return make((settings["namespace"].map { $0 + "/" } ?? "") + "tfstate-\(workspace)-\(suffix)")
        case "http":
            guard let address = settings["address"], let url = URL(string: address), let host = url.host else { return nil }
            // Host and path only: a URL's credentials and query never key anything.
            return make(host + (url.port.map { ":\($0)" } ?? "") + url.path)
        case "cloud", "remote":
            guard let organization = settings["organization"] else { return nil }
            if let name = backend.workspaceName { return make("\(organization)/\(name)") }
            if let prefix = backend.workspacePrefix { return make("\(organization)/\(prefix)\(workspace)") }
            return backend.workspaceTags ? make("\(organization)/\(workspace)") : nil
        default:
            return nil
        }
    }

    /// Where a local backend keeps `workspace`'s state: `path` (default
    /// `terraform.tfstate`) for `default` only; any other under
    /// `<workspace_dir, default terraform.tfstate.d>/<ws>/terraform.tfstate`
    /// (spike 28). Relative to the root.
    static func localStatePath(backend: TerraformConfigFacts.Backend?, workspace: String, root: URL) -> URL {
        let settings = backend?.settings ?? [:]
        func resolved(_ path: String) -> URL {
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        }
        if workspace == "default" { return resolved(settings["path"] ?? "terraform.tfstate").standardizedFileURL }
        let folder = settings["workspace_dir"] ?? "terraform.tfstate.d"
        return resolved(folder).appendingPathComponent(workspace).appendingPathComponent("terraform.tfstate").standardizedFileURL
    }

    /// The backend as the root chip says it (6.2): `s3 · acme-tfstate/prod/network.tfstate · eu-west-1`,
    /// `cloud · globex/net-prod`, `local · terraform.tfstate`.
    static func summary(of backend: TerraformConfigFacts.Backend?, workspace: String) -> String {
        let backend = backend ?? TerraformConfigFacts.Backend(type: "local")
        let settings = backend.settings
        var parts = [backend.type]
        switch backend.type {
        case "local":
            if workspace == "default" {
                parts.append(settings["path"] ?? "terraform.tfstate")
            } else {
                parts.append("\(settings["workspace_dir"] ?? "terraform.tfstate.d")/\(workspace)/terraform.tfstate")
            }
        case "s3":
            if let bucket = settings["bucket"] { parts.append(bucket + (settings["key"].map { "/" + $0 } ?? "")) }
            if let region = settings["region"] { parts.append(region) }
        case "gcs":
            if let bucket = settings["bucket"] { parts.append(bucket + (settings["prefix"].map { "/" + $0 } ?? "")) }
        case "azurerm":
            if let account = settings["storage_account_name"] {
                parts.append(account + (settings["container_name"].map { "/" + $0 } ?? "") + (settings["key"].map { "/" + $0 } ?? ""))
            }
        case "cloud", "remote":
            if let organization = settings["organization"] {
                parts.append(organization + (backend.workspaceName.map { "/" + $0 } ?? backend.workspacePrefix.map { "/\($0)*" } ?? ""))
            }
        case "http":
            if let address = settings["address"], let url = URL(string: address), let host = url.host { parts.append(host + url.path) }
        case "kubernetes":
            if let suffix = settings["secret_suffix"] { parts.append("tfstate-\(workspace)-\(suffix)") }
        default:
            break
        }
        return parts.joined(separator: " · ")
    }

    /// The backend in effect: the init record's when `init` has run (it is
    /// what terraform reads), else the HCL's; none at all is `local`.
    static func effective(config: TerraformConfigFacts.Backend?, record: TerraformConfigFacts.Backend?) -> TerraformConfigFacts.Backend {
        record ?? config ?? TerraformConfigFacts.Backend(type: "local")
    }

    /// Whether the HCL's backend and the init record's disagree on what
    /// both say: plans refuse then (4.11, stage 1d); the chip says so now.
    static func changedSinceInit(config: TerraformConfigFacts.Backend?, record: TerraformConfigFacts.Backend?) -> Bool {
        guard let config, let record else { return false }
        if config.type != record.type { return true }
        for (key, value) in config.settings where key != "use_lockfile" {
            if let recorded = record.settings[key], recorded != value { return true }
        }
        return false
    }
}
