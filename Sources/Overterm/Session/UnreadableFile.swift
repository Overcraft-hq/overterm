import Foundation
import os

/// A state file that exists but can't be read — a hand edit gone wrong, a
/// newer version's format. It is moved aside rather than left in place: the
/// next save would write over it, and what was in it would be gone.
enum UnreadableFile {
    private static let logger = Logger(subsystem: AppEnvironment.bundleIdentifier, category: "state")

    /// `snippets.json` → `snippets.unreadable-2026-09-27-143005.json`, next to
    /// it. Returns where it went (nil if it couldn't be moved).
    @discardableResult
    static func setAside(_ url: URL, now: Date = Date()) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = url.deletingPathExtension().lastPathComponent + ".unreadable-" + formatter.string(from: now)
        let aside = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            logger.error("\(url.lastPathComponent, privacy: .public) unreadable, kept as \(aside.lastPathComponent, privacy: .public)")
            return aside
        } catch {
            logger.error("\(url.lastPathComponent, privacy: .public) unreadable and not moved: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
