import Foundation

/// A drop in the Notes panel: what moves where. Pure — the panel and its
/// checks read the same answer.
enum NoteMove {
    /// Where `item` goes when dropped on `folder` — nil when it can't: from
    /// outside the vault, onto itself or into its own folders, or already
    /// there.
    static func target(of item: URL, into folder: URL, vault root: URL) -> URL? {
        let item = item.standardizedFileURL
        let folder = folder.standardizedFileURL
        let root = root.standardizedFileURL.path
        func inVault(_ url: URL) -> Bool { url.path == root || url.path.hasPrefix(root + "/") }
        guard inVault(item), inVault(folder), item.path != root else { return nil }
        // A folder into itself, or into a folder of its own.
        if folder.path == item.path || folder.path.hasPrefix(item.path + "/") { return nil }
        // Where it already is.
        if item.deletingLastPathComponent().path == folder.path { return nil }
        return folder.appendingPathComponent(item.lastPathComponent)
    }
}

/// Files dropped from a drag, handed back on the main thread. Built
/// nonisolated: the providers answer on a queue of their own, and a closure
/// written in a view is main-actor-isolated — Swift 6 traps when the system
/// calls it there (CLAUDE.md).
enum DroppedURLs {
    nonisolated static func load(_ providers: [NSItemProvider], then: @escaping @MainActor @Sendable ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        nonisolated(unsafe) var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let found = urls
            MainActor.assumeIsolated { then(found) }
        }
    }
}
