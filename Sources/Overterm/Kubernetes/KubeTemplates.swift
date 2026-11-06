import Foundation

/// A new-resource template (2.8, "Create from a template"): a file, as a
/// theme is — Overterm's in `Resources/kubernetes/templates`, the user's
/// own in the support folder's `Kubernetes/Templates` (one of the same file
/// name replaces Overterm's). Opened as Overterm's copy in the editor, its
/// `${namespace}` the one shown, where the manifest's bar diffs and applies
/// it as any manifest (stage 2b): the access review, the confirmation, the
/// rules of a writable context. The copy is never saved — a Secret's value
/// typed into it stays in the editor's memory — and goes with its tab.
struct KubeTemplate: Identifiable, Equatable, Sendable {
    var file: URL
    /// The object's kind, from its `kind:` line (`Deployment`).
    var kind: String
    var isUsers: Bool

    var id: String { file.lastPathComponent }
    /// `deployment.yaml` → `deployment`.
    var name: String { file.deletingPathExtension().lastPathComponent }
}

enum KubeTemplates {
    /// The app's own.
    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("kubernetes/templates", isDirectory: true) }

    /// The user's, in the support folder — a unit test's own in the
    /// temporary directory.
    static var userFolder: URL {
        let base =
            AppEnvironment.isUnitTest && !AppEnvironment.isIsolated
            ? FileManager.default.temporaryDirectory.appendingPathComponent("overterm-unit-test-\(getpid())", isDirectory: true)
            : AppEnvironment.supportDirectory
        return base.appendingPathComponent("Kubernetes/Templates", isDirectory: true)
    }

    /// Larger than any template: a file past it is passed over.
    static let maxSize = 256 * 1024

    /// Every template, by kind: the user's file of a name in place of
    /// Overterm's. A file that isn't a manifest is passed over.
    static func list(bundled: URL? = bundled, user: URL? = userFolder) -> [KubeTemplate] {
        var byName: [String: KubeTemplate] = [:]
        for (folder, isUsers) in [(bundled, false), (user, true)] {
            guard let folder else { continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where !name.hasPrefix(".") && ["yaml", "yml"].contains((name as NSString).pathExtension.lowercased()) {
                let file = folder.appendingPathComponent(name)
                guard let text = read(file), let kind = kind(of: text) else { continue }
                byName[file.deletingPathExtension().lastPathComponent] = KubeTemplate(file: file, kind: kind, isUsers: isUsers)
            }
        }
        return byName.values.sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }

    static func read(_ file: URL) -> String? {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxSize, let data = try? Data(contentsOf: file) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// The first top-level `kind:` — a template is one object.
    static func kind(of text: String) -> String? {
        guard KubeManifest.looksLikeManifest(text) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("kind:") {
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The copy's text: what it is and where it would go, then the
    /// template with `${namespace}` the namespace — a YAML word, quoted
    /// when it would read as something else.
    static func text(_ template: String, kind: String, context: String?, production: Bool, namespace: String) -> String {
        let place = context.map { "\(production ? "PRODUCTION · " : "")\($0) · namespace \(namespace)" } ?? "namespace \(namespace)"
        let header =
            "# A new \(kind) from a template — \(place)\n"
            + "# Overterm's copy, never saved: Diff with Cluster shows what an apply would make; Apply is a step of its own.\n"
        return header + template.replacingOccurrences(of: "${namespace}", with: KubeTerminalConfig.quoted(namespace))
    }
}
