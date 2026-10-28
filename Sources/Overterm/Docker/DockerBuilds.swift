import Foundation

/// A build, as `docker buildx history ls --format json` lists it: one JSON
/// object a line. Docker Desktop's Builds view reads the same records.
/// Pure.
struct DockerBuildRecord: Identifiable, Equatable, Sendable {
    /// `builder/node/id`.
    var ref: String
    var name: String
    /// `Completed`, `Error`, `Running`, `Canceled`.
    var status: String
    var createdAt: String
    var completedAt: String?
    var totalSteps: Int
    var cachedSteps: Int
    var completedSteps: Int

    var id: String { ref }
    /// The record's own id, as `buildx history` commands take it.
    var shortRef: String { String(ref.split(separator: "/").last ?? Substring(ref)) }
    var failed: Bool { status.lowercased() == "error" }
    var running: Bool { status.lowercased() == "running" }

    /// Seconds from start to end, when it ended.
    var duration: Double? {
        guard let completedAt, let start = Self.date(createdAt), let end = Self.date(completedAt) else { return nil }
        return end.timeIntervalSince(start)
    }

    static func date(_ stamp: String) -> Date? {
        let trimmed = stamp.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: stamp)
    }

    /// The listing, newest first; lines that aren't a record are skipped.
    static func parse(_ output: String) -> [DockerBuildRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> DockerBuildRecord? in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let ref = json["ref"] as? String else {
                return nil
            }
            return DockerBuildRecord(
                ref: ref, name: json["name"] as? String ?? ref, status: json["status"] as? String ?? "", createdAt: json["created_at"] as? String ?? "",
                completedAt: json["completed_at"] as? String, totalSteps: json["total_steps"] as? Int ?? 0, cachedSteps: json["cached_steps"] as? Int ?? 0,
                completedSteps: json["completed_steps"] as? Int ?? 0)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// `6.9 s`, `2 min 14 s`.
    static func duration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.1f s", seconds) : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }
}

/// What `buildx history inspect --format json` adds: where it was built
/// from, with what. Build args are masked as env is. Pure.
struct DockerBuildDetail: Equatable, Sendable {
    var context: String?
    var dockerfile: String?
    var buildArgs: [(key: String, value: String)]
    var repository: String?
    var revision: String?
    var error: String?

    static func == (a: DockerBuildDetail, b: DockerBuildDetail) -> Bool {
        a.context == b.context && a.dockerfile == b.dockerfile && a.repository == b.repository && a.revision == b.revision && a.error == b.error
            && a.buildArgs.map { "\($0.key)=\($0.value)" } == b.buildArgs.map { "\($0.key)=\($0.value)" }
    }

    static func parse(_ output: String) -> DockerBuildDetail? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return nil }
        let args = (json["BuildArgs"] as? [[String: Any]] ?? []).compactMap { arg -> (key: String, value: String)? in
            guard let name = arg["Name"] as? String else { return nil }
            return (name, DockerSecrets.masked(name, arg["Value"] as? String ?? ""))
        }
        let error = (json["Error"] as? [String: Any])?["Message"] as? String ?? json["Error"] as? String
        return DockerBuildDetail(
            context: json["Context"] as? String, dockerfile: json["Dockerfile"] as? String, buildArgs: args, repository: json["VCSRepository"] as? String,
            revision: json["VCSRevision"] as? String, error: error)
    }

    /// The Dockerfile on this Mac, when the context is a folder here.
    var dockerfileURL: URL? {
        guard let context, context.hasPrefix("/") else { return nil }
        let file =
            dockerfile.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : URL(fileURLWithPath: context).appendingPathComponent($0) }
            ?? URL(fileURLWithPath: context).appendingPathComponent("Dockerfile")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
