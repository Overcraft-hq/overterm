import Foundation

/// What a window's tabs looked like, enough to rebuild them on the next
/// launch. Terminal contents are not saved — each tab gets a fresh shell in
/// its old directory, and an agent tab resumes its agent's last
/// conversation there.
struct SessionState: Codable, Equatable {
    struct TabState: Codable, Equatable {
        var workingDirectory: String?
        var customTitle: String?
        var color: String?
        var isPinned: Bool
        var agent: Agent?
    }

    var tabs: [TabState]
    var selectedIndex: Int?

    static let empty = SessionState(tabs: [], selectedIndex: nil)

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Terminus", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    /// Nil when there is no file or it can't be read — a bad session file
    /// means a fresh start, never a failed launch.
    static func load(from url: URL = defaultURL) -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
