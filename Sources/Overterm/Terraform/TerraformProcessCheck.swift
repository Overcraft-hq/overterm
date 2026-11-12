import Foundation

/// What a terraform Overterm starts does (analysis 5.3): the one place the
/// verbs-by-class table lives. Pure.
enum TerraformVerb: String, CaseIterable, Sendable {
    // Reads: started on any class.
    case version, format, validate, show, workspaceList, stateList
    /// Downloads code, changes no infrastructure: the person's click.
    case initialize
    /// Runs providers and data sources with the user's credentials and
    /// takes the lock: started; the first one per root and session on
    /// production asks (the caller).
    case plan
    /// Writes the checkout's `.terraform/environment`.
    case workspaceSelect
    /// `apply <the shown plan>`, and a destroy plan's apply (stage 2a).
    case apply
    /// `apply` of a refresh-only plan: it writes state (2d).
    case refreshOnlyApply
    /// `terraform test` of files whose every provider is mocked (2.9, 2d):
    /// nothing reaches a cloud — run without credentials, on any class.
    case test
    /// `terraform test` with a real provider: it creates real
    /// infrastructure with the root's credentials — a write (asked).
    case testRealProviders
    /// A stale lock blocks the person's own CI: allowed on every class,
    /// from a parsed, probed ID, the root's name typed (2e).
    case forceUnlock
    // Never built, on any class (5.3's last row).
    case stateSurgery, cliImport, taint, statePush, applyWithoutPlan, autoApprove, lockFalse, workspaceNew, workspaceDelete, initUpgrade
}

/// Whether Overterm may start `verb` in a root (5.3, 5.13 rule 5): the
/// analogue of `KubeProcessCheck`. A read-only root is production without
/// its session switch, or remote not set writable. Pure.
enum TerraformProcessCheck {
    static let neverBuilt: Set<TerraformVerb> = [
        .stateSurgery, .cliImport, .taint, .statePush, .applyWithoutPlan, .autoApprove, .lockFalse, .workspaceNew, .workspaceDelete, .initUpgrade,
    ]

    /// Whether a root of `rootClass` is writable now: local always;
    /// remote when its `writable` is set; production only by its session
    /// switch (`TerraformRunRegistry.sessionWrites`), never a setting.
    static func isWritable(_ rootClass: TerraformClass, writable: Bool, sessionWrites: Bool) -> Bool {
        switch rootClass {
        case .local: true
        case .remote: writable
        case .production: sessionWrites
        }
    }

    /// The backends whose runs happen in HCP Terraform (2.8, D-20): a
    /// `plan -out` there starts a remote, or saved cloud, run in the team's
    /// workspace. Stages 1–2 give them the guards, the editor and a link.
    static let remoteExecution: Set<String> = ["cloud", "remote"]
    static let remoteExecutionRefusal = "HCP runs remotely: plan it in HCP (stage 3)"

    /// Why `verb` may not start in a root whose backend is `backendType`
    /// — plan and init, never on an HCP root; force unlock, never on the
    /// local backend nor HCP's (2e) — or nil.
    static func refused(_ verb: TerraformVerb, backendType: String) -> String? {
        if verb == .forceUnlock {
            if backendType == "local" { return localUnlockRefusal }
            if remoteExecution.contains(backendType) { return "An HCP workspace's lock is HCP's: unlock it in HCP Terraform." }
            return nil
        }
        guard verb == .plan || verb == .initialize, remoteExecution.contains(backendType) else { return nil }
        return remoteExecutionRefusal
    }

    /// The local backend's lock is an OS lock that went with its process
    /// (4.10): one held is a terraform still running, and Terraform itself
    /// refuses to force it ("Local state cannot be unlocked by another process").
    static let localUnlockRefusal =
        "A local state's lock is the operating system's: it goes with its process. Held, it is a terraform still running on this Mac — stop that one; there is nothing to force."


    /// Why `verb` may not start in a root of `rootClass`, or nil.
    static func refused(_ verb: TerraformVerb, rootClass: TerraformClass, writable: Bool = false, sessionWrites: Bool = false) -> String? {
        if neverBuilt.contains(verb) {
            return "Overterm never runs this: state changes go through moved, removed and import blocks, planned and applied; the rest is typed in a terminal"
        }
        switch verb {
        case .version, .format, .validate, .show, .workspaceList, .stateList, .initialize, .plan, .workspaceSelect, .forceUnlock, .test:
            return nil
        case .apply, .refreshOnlyApply, .testRealProviders:
            guard isWritable(rootClass, writable: writable, sessionWrites: sessionWrites) else {
                return rootClass == .production
                    ? "\(rootClass.title) is plan only: writes are turned on for this session from the root, never by a setting"
                    : "\(rootClass.title) roots are plan only until the root is set writable"
            }
            return nil
        default:
            return "not a verb Overterm runs"
        }
    }
}

/// Whether the workspace a run would use exists, before it starts (4.9):
/// a workspace that doesn't is silently created by `plan`, `init` and
/// `state pull` — named by `TF_WORKSPACE` or by `.terraform/environment`
/// (spikes 13, 14) — and its plan creates everything again. Pure.
enum TerraformWorkspaceCheck {
    /// Why a run in `workspace` is refused, or nil. `local`: the local
    /// backend's `terraform.tfstate.d` folders (`default` always exists);
    /// `listed`: a remote backend's last `workspace list`, nil when none
    /// was read (the caller lists, then asks again).
    static func refusal(workspace: String, backend: TerraformConfigFacts.Backend, localWorkspaces: [String], listed: [String]?) -> String? {
        guard TerraformCommands.isWorkspaceName(workspace) else { return "“\(workspace)” isn't a workspace's name" }
        let summary = TerraformStateIdentity.summary(of: backend, workspace: "default")
        if backend.type == "local" {
            if workspace == "default" || localWorkspaces.contains(workspace) { return nil }
            return "Workspace \(workspace) no longer exists in \(summary): a plan would create it, and everything in it. Select another, or create it in a terminal."
        }
        if let name = backend.workspaceName, backend.type == "cloud" || backend.type == "remote" {
            // A `cloud { workspaces { name } }` root has its one workspace.
            return workspace == "default" || workspace == name ? nil : "This root's workspace is \(name), set in its cloud block."
        }
        guard let listed else { return nil }
        if listed.contains(workspace) { return nil }
        return "Workspace \(workspace) no longer exists in \(summary): a plan would create it, and everything in it. Select another, or create it in a terminal."
    }

    /// `workspace list`'s names: `  default`, `* acme-stage`.
    static func parseList(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            var name = line.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return TerraformCommands.isWorkspaceName(name) ? name : nil
        }
    }
}
