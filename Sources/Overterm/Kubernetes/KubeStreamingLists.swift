import Foundation
import os

/// Which contexts' servers take a streaming list (`sendInitialEvents`, the
/// WatchList gate) in place of a follow's first list: known from the
/// server's version (`KubeClient.servesStreamingLists` — 1.32, 1.34+),
/// and turned off for the run once a server refuses one (the gate off on a
/// version that has it on by default) or never says where its list ends
/// (its Tables' bookmarks without `k8s.io/initial-events-end`). Unknown —
/// no version read yet, or the read failed — is list plus watch, the
/// baseline. A version read again that says another minor clears a
/// refusal: the cluster was upgraded, or the context now names another.
/// It keeps each kind's Table columns too, from the last list on the
/// context: an empty streaming list whose end carries none (kind's 1.37
/// puts them on it; a server needn't) would otherwise be listed again for
/// its headers. Forgotten with the context when
/// its name stops naming the same cluster (`KubernetesModel.loaded`).
/// One for the app's model; every client it makes for a context asks it
/// when a follow starts.
final class KubeStreamingLists: Sendable {
    enum State: Equatable, Sendable {
        /// No version read: list and watch.
        case unknown
        /// Its version serves them.
        case served
        /// Its version doesn't (1.31 and before, 1.33).
        case notServed
        /// It refused one, or cut one short: list and watch for the run.
        case refused
    }

    private struct Entry: Sendable {
        var minor: Int?
        var refused = false
        /// By kind (`group/version/resource`).
        var columns: [String: [KubeColumn]] = [:]
    }

    private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    init() {}

    func state(of context: String) -> State {
        entries.withLock { entries in
            guard let entry = entries[context], let minor = entry.minor else { return .unknown }
            if entry.refused { return .refused }
            return KubeClient.servesStreamingLists(minor: minor) ? .served : .notServed
        }
    }

    /// Whether a follow on `context` starts with a streaming list.
    func uses(_ context: String) -> Bool { state(of: context) == .served }

    /// What `/version` said. Nil (no minor in it) changes nothing.
    func learn(_ context: String, minor: Int?) {
        guard let minor else { return }
        entries.withLock { entries in
            var entry = entries[context] ?? Entry()
            if entry.minor != minor { entry.refused = false }
            // Another version's Tables may have other columns.
            if let old = entry.minor, old != minor { entry.columns = [:] }
            entry.minor = minor
            entries[context] = entry
        }
    }

    /// The server refused a streaming list, or never ended one.
    func refuse(_ context: String) {
        entries.withLock { entries in
            var entry = entries[context] ?? Entry()
            entry.refused = true
            entries[context] = entry
        }
    }

    /// The kind's Table columns from the last list on the context.
    func columns(of kind: KubeResourceKind, on context: String) -> [KubeColumn]? {
        entries.withLock { $0[context]?.columns[Self.key(kind)] }
    }

    func remember(_ columns: [KubeColumn], of kind: KubeResourceKind, on context: String) {
        guard !columns.isEmpty else { return }
        entries.withLock { entries in
            var entry = entries[context] ?? Entry()
            entry.columns[Self.key(kind)] = columns
            entries[context] = entry
        }
    }

    private static func key(_ kind: KubeResourceKind) -> String { "\(kind.groupVersion)/\(kind.resource)" }

    /// Forgotten, the columns with it: the next follow lists and watches
    /// until a version is read.
    func forget(_ context: String) {
        _ = entries.withLock { $0.removeValue(forKey: context) }
    }
}
