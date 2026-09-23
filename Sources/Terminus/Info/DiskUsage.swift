import Foundation

/// How much disk a checkout takes, and where.
struct DiskReport: Equatable {
    let root: URL
    let total: UInt64
    let files: Int
    /// The largest top-level entries, biggest first.
    let largest: [(name: String, bytes: UInt64)]
    /// Stopped at the file limit: the numbers are a lower bound.
    let partial: Bool

    static func == (a: DiskReport, b: DiskReport) -> Bool {
        a.root == b.root && a.total == b.total && a.files == b.files && a.partial == b.partial
            && a.largest.map(\.name) == b.largest.map(\.name) && a.largest.map(\.bytes) == b.largest.map(\.bytes)
    }
}

/// A cancellation flag a background measurement checks.
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

enum DiskUsage {
    /// A generous cap: a big monorepo with node_modules is a few hundred
    /// thousand files. Beyond it the report says "at least".
    static let fileLimit = 2_000_000

    /// Walks `root` (not following symlinks), summing allocated sizes per
    /// top-level entry. Blocking and possibly long; call off main.
    static func measure(_ root: URL, top: Int = 6, cancellation: Cancellation? = nil) -> DiskReport? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return nil }
        let rootComponents = root.standardizedFileURL.pathComponents.count
        var perEntry: [String: UInt64] = [:]
        var total: UInt64 = 0
        var files = 0
        var partial = false
        for case let url as URL in walker {
            if files % 4096 == 0, cancellation?.isCancelled == true { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = UInt64(values.totalFileAllocatedSize ?? 0)
            total += size
            files += 1
            let components = url.standardizedFileURL.pathComponents
            if components.count > rootComponents {
                perEntry[components[rootComponents], default: 0] += size
            }
            if files >= fileLimit {
                partial = true
                break
            }
        }
        let largest = perEntry.sorted { $0.value > $1.value }.prefix(top).map { (name: $0.key, bytes: $0.value) }
        return DiskReport(root: root, total: total, files: files, largest: largest, partial: partial)
    }
}
