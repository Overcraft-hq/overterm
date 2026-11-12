import Foundation

/// What a folder's Terraform files say, read without running Terraform and
/// without credentials (analysis 4.11, 4.12, 5.1): its backend or `cloud`
/// block, `required_version` and `required_providers`, its providers'
/// literal `profile`, `role_arn`, `project` and `subscription_id`, the
/// types it declares, whether anything runs a command (`provisioner`,
/// `local_command`, `external`), the states it reads
/// (`terraform_remote_state`), its modules' sources, and the AWS account
/// IDs any ARN in it names. Pure, over the texts it is given; only literal
/// values are read, never an expression evaluated.
struct TerraformConfigFacts: Equatable, Sendable {
    /// The backend's keys Overterm reads (4.11): the location keys and the
    /// production signals, nothing else. `password`, `access_key`,
    /// `secret_key`, `token`, `*_pem` are never decoded. Never
    /// `Secrets.isSecret` here: its match on `KEY` would hide the S3 `key`.
    static let backendKeys: Set<String> = [
        "bucket", "key", "prefix", "region", "profile", "role_arn", "organization", "address", "path", "workspace_dir", "workspace_key_prefix",
        "use_lockfile", "dynamodb_table", "storage_account_name", "container_name", "secret_suffix", "hostname", "namespace", "schema_name",
        "config_context",
    ]

    /// A backend key's value as it is kept: an `address` (http's, and any
    /// URL) loses its userinfo, query and fragment at decode —
    /// `https://ci:glpat-…@gitlab.example/…/state/prod?token=…` is kept as
    /// `https://gitlab.example/…/state/prod` (4.11: host and path; 5.6
    /// rule 11: a credential is never decoded). Nil drops the key.
    static func kept(_ key: String, _ value: String) -> String? {
        guard key == "address" else { return value }
        return addressWithoutCredentials(value)
    }

    /// `scheme://host[:port]/path`, whatever userinfo, query or fragment it had.
    static func addressWithoutCredentials(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var scheme = ""
        var rest = Substring(text)
        if let separator = text.range(of: "://") {
            scheme = String(text[..<separator.upperBound])
            rest = text[separator.upperBound...]
        }
        if let end = rest.firstIndex(where: { "?#".contains($0) }) { rest = rest[..<end] }
        let authority = rest.prefix { $0 != "/" }
        let path = rest.dropFirst(authority.count)
        // The whole userinfo, up to the authority's last `@`: a token may have no `:`.
        let host = authority.lastIndex(of: "@").map { authority[authority.index(after: $0)...] } ?? authority
        let kept = scheme + host + path
        return kept.isEmpty ? nil : kept
    }

    struct Backend: Equatable, Sendable {
        /// `s3`, `gcs`, `local`, `http`, `cloud` (a `cloud {}` block), `remote`…
        var type: String
        /// The allow-listed keys with a literal value.
        var settings: [String: String] = [:]
        /// `cloud { workspaces { name = … } }`.
        var workspaceName: String?
        /// `workspaces { prefix = … }` (`remote`), or `tags` (`cloud`): the workspace is chosen.
        var workspacePrefix: String?
        var workspaceTags = false
    }

    struct Provider: Equatable, Sendable {
        /// `aws`, `google`…, its block's label.
        var name: String
        /// `profile`, `role_arn`, `project`, `subscription_id`, `config_context`, `host` when literal.
        var settings: [String: String] = [:]
    }

    struct RemoteState: Equatable, Sendable {
        var backend: String?
        /// A local one's `path`, when literal.
        var path: String?
    }

    var backend: Backend?
    var requiredVersion: String?
    /// `required_providers`' names and sources (`aws: hashicorp/aws`).
    var requiredProviders: [String: String] = [:]
    var providers: [Provider] = []
    /// `resource` types, and `data.T`, `ephemeral.T`, `action.T`, `list.T`.
    var types: Set<String> = []
    var hasProvisioner = false
    var remoteStates: [RemoteState] = []
    /// Each `module` block's literal `source`.
    var moduleSources: [String] = []
    /// AWS account IDs from `arn:aws:…::<12 digits>:` anywhere in the text.
    var accountIDs: Set<String> = []
    /// Any top-level block at all.
    var hasBlocks = false

    /// The provider settings read; anything else in a provider block is not.
    static let providerKeys: Set<String> = ["profile", "role_arn", "project", "subscription_id", "config_context", "host", "region"]

    static func read(_ texts: [String]) -> TerraformConfigFacts {
        var facts = TerraformConfigFacts()
        for text in texts { facts.add(text) }
        return facts
    }

    private static let accountPattern = try! NSRegularExpression(pattern: #"arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:(\d{12}):"#)
    private static let requiredProviderPattern = try! NSRegularExpression(
        pattern: #"([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*\{[^{}]*?source\s*=\s*"([^"]+)""#)
    private static let pathPattern = try! NSRegularExpression(pattern: #"\bpath\s*=\s*"([^"$%]*)""#)

    mutating func add(_ text: String) {
        let scanned = TerraformBlocks.scan(text)
        if !scanned.blocks.isEmpty { hasBlocks = true }
        for block in scanned.blocks {
            switch block.type {
            case "terraform":
                readTerraformBlock(block, in: text)
            case "provider":
                guard let name = block.labels.first else { continue }
                var provider = Provider(name: name)
                for attribute in block.attributes where Self.providerKeys.contains(attribute.name) {
                    if let value = attribute.value { provider.settings[attribute.name] = value }
                }
                // `assume_role { role_arn = … }`.
                for nested in TerraformBlocks.nested(in: block, of: text).blocks where nested.type == "assume_role" {
                    if let arn = nested.attributes.first(where: { $0.name == "role_arn" })?.value { provider.settings["role_arn"] = arn }
                }
                providers.append(provider)
            case "resource":
                guard let type = block.labels.first else { continue }
                types.insert(type)
                if TerraformBlocks.nested(in: block, of: text).blocks.contains(where: { $0.type == "provisioner" }) { hasProvisioner = true }
            case "data", "ephemeral", "action", "list":
                guard let type = block.labels.first else { continue }
                types.insert("\(block.type).\(type)")
                if block.type == "data", type == "terraform_remote_state" {
                    var state = RemoteState(backend: block.attributes.first { $0.name == "backend" }?.value)
                    if let body = TerraformBlocks.body(of: block, in: text)?.text,
                        let match = Self.pathPattern.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                        let range = Range(match.range(at: 1), in: body)
                    {
                        state.path = String(body[range])
                    }
                    remoteStates.append(state)
                }
            case "module":
                if let source = block.attributes.first(where: { $0.name == "source" })?.value { moduleSources.append(source) }
            default:
                break
            }
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in Self.accountPattern.matches(in: text, range: range) {
            if let id = Range(match.range(at: 1), in: text) { accountIDs.insert(String(text[id])) }
        }
    }

    private mutating func readTerraformBlock(_ block: TerraformBlocks.Block, in text: String) {
        if let version = block.attributes.first(where: { $0.name == "required_version" })?.value { requiredVersion = version }
        guard let body = TerraformBlocks.body(of: block, in: text) else { return }
        let inner = TerraformBlocks.scan(body.text)
        for nested in inner.blocks {
            switch nested.type {
            case "backend":
                guard let type = nested.labels.first else { continue }
                var backend = Backend(type: type)
                for attribute in nested.attributes where Self.backendKeys.contains(attribute.name) {
                    if let value = attribute.value.flatMap({ Self.kept(attribute.name, $0) }) { backend.settings[attribute.name] = value }
                }
                self.backend = backend
            case "cloud":
                var backend = Backend(type: "cloud")
                for attribute in nested.attributes where Self.backendKeys.contains(attribute.name) {
                    if let value = attribute.value.flatMap({ Self.kept(attribute.name, $0) }) { backend.settings[attribute.name] = value }
                }
                for workspaces in TerraformBlocks.nested(in: nested, of: body.text).blocks where workspaces.type == "workspaces" {
                    backend.workspaceName = workspaces.attributes.first { $0.name == "name" }?.value
                    backend.workspacePrefix = workspaces.attributes.first { $0.name == "prefix" }?.value
                    backend.workspaceTags = workspaces.attributes.contains { $0.name == "tags" }
                }
                self.backend = backend
            case "required_providers":
                guard let providers = TerraformBlocks.body(of: nested, in: body.text)?.text else { continue }
                let range = NSRange(providers.startIndex..., in: providers)
                for match in Self.requiredProviderPattern.matches(in: providers, range: range) {
                    guard let name = Range(match.range(at: 1), in: providers), let source = Range(match.range(at: 2), in: providers) else { continue }
                    requiredProviders[String(providers[name])] = String(providers[source])
                }
            default:
                break
            }
        }
        // `remote` backends keep their workspaces in a nested block too.
        if let backend, backend.type == "remote" {
            for nested in inner.blocks where nested.type == "backend" {
                for workspaces in TerraformBlocks.nested(in: nested, of: body.text).blocks where workspaces.type == "workspaces" {
                    self.backend?.workspaceName = workspaces.attributes.first { $0.name == "name" }?.value
                    self.backend?.workspacePrefix = workspaces.attributes.first { $0.name == "prefix" }?.value
                }
            }
        }
    }

    /// The providers the configuration names: `required_providers`' local
    /// names and the prefix of every type it declares (`aws_s3_bucket` →
    /// `aws`; `terraform_data` is the builtin `terraform`).
    var providerNames: Set<String> {
        var names = Set(requiredProviders.keys).union(providers.map(\.name))
        for type in types {
            let bare = type.split(separator: ".").last.map(String.init) ?? type
            if let prefix = bare.split(separator: "_").first { names.insert(String(prefix)) }
        }
        return names
    }
}

/// `.terraform.lock.hcl`'s providers: `registry.terraform.io/hashicorp/random`. Pure.
enum TerraformLockFile {
    struct Provider: Equatable, Hashable, Sendable {
        var host: String
        var namespace: String
        var type: String

        init?(_ address: String) {
            let parts = address.split(separator: "/").map(String.init)
            guard parts.count == 3 else { return nil }
            host = parts[0].lowercased()
            namespace = parts[1].lowercased()
            type = parts[2].lowercased()
        }
    }

    static func providers(in text: String) -> [Provider] {
        TerraformBlocks.scan(text).blocks.filter { $0.type == "provider" }.compactMap { $0.labels.first.flatMap(Provider.init) }
    }
}

/// `.terraform/terraform.tfstate`: the record `init` keeps of the backend.
/// It holds the backend's whole configuration — `-backend-config=password=…`
/// included, in clear (spike 4) — so only the type and the allow-listed
/// keys are decoded (`TerraformConfigFacts.backendKeys`); everything else
/// is dropped unread. Pure.
enum TerraformInitRecord {
    static func backend(from data: Data) -> TerraformConfigFacts.Backend? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let backend = object["backend"] as? [String: Any], let type = backend["type"] as? String, !type.isEmpty
        else { return nil }
        var result = TerraformConfigFacts.Backend(type: type)
        let config = backend["config"] as? [String: Any] ?? [:]
        for key in TerraformConfigFacts.backendKeys {
            switch config[key] {
            case let value as String where !value.isEmpty: result.settings[key] = TerraformConfigFacts.kept(key, value)
            case let value as Bool: result.settings[key] = value ? "true" : "false"
            default: break
            }
        }
        if let workspaces = config["workspaces"] as? [String: Any] {
            result.workspaceName = (workspaces["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            result.workspacePrefix = (workspaces["prefix"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            result.workspaceTags = workspaces["tags"] != nil && !(workspaces["tags"] is NSNull)
        }
        return result
    }
}

/// The folders `init` installed modules into, from
/// `.terraform/modules/modules.json`: each module's `Dir`, relative to the
/// root. Pure.
enum TerraformModulesManifest {
    static func directories(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let modules = object["Modules"] as? [[String: Any]]
        else { return [] }
        return modules.compactMap { $0["Dir"] as? String }.filter { !$0.isEmpty && $0 != "." }
    }
}
