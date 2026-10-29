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

    /// Seconds since it started, for one still running: never below 0, a
    /// remote engine's clock may be ahead of this Mac's.
    func elapsed(now: Date) -> TimeInterval {
        Self.date(createdAt).map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    static func date(_ stamp: String) -> Date? {
        let trimmed = stamp.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: stamp)
    }

    /// The listing, running ones first, then newest first, as buildx's
    /// own `ls` orders it; lines that aren't a record are skipped.
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
        .sorted { $0.running != $1.running ? $0.running : $0.createdAt > $1.createdAt }
    }

    /// `6.9 s`, `2 min 14 s`.
    static func duration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.1f s", seconds) : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }
}

/// What `buildx history inspect --format json` adds: where it was built
/// from, with what, how it ended. Build args are masked as env is, and a
/// secret one's value is taken out of the rest — BuildKit expands an ARG
/// into a RUN step's name, which the error names. Pure.
struct DockerBuildDetail: Equatable, Sendable {
    var context: String?
    var dockerfile: String?
    var buildArgs: [(key: String, value: String)]
    var repository: String?
    var revision: String?
    var error: String?
    /// `running`, `completed`, `failed`, `canceled`.
    var status: String?
    /// The step that failed, as BuildKit names it.
    var errorStep: String?
    /// Where in the Dockerfile: BuildKit's excerpt, the line marked `>>>`.
    var errorSource: String?
    /// The secret build args' values, to take out of step names and output:
    /// in memory only, and no part of `==`.
    var secrets: [String] = []

    static func == (a: DockerBuildDetail, b: DockerBuildDetail) -> Bool {
        a.context == b.context && a.dockerfile == b.dockerfile && a.repository == b.repository && a.revision == b.revision && a.error == b.error
            && a.status == b.status && a.errorStep == b.errorStep && a.errorSource == b.errorSource
            && a.buildArgs.map { "\($0.key)=\($0.value)" } == b.buildArgs.map { "\($0.key)=\($0.value)" }
    }

    static func parse(_ output: String) -> DockerBuildDetail? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return nil }
        let raw = (json["BuildArgs"] as? [[String: Any]] ?? []).compactMap { arg -> (key: String, value: String)? in
            guard let name = arg["Name"] as? String else { return nil }
            return (name, arg["Value"] as? String ?? "")
        }
        let secrets = DockerSecrets.values(in: raw)
        let failure = json["Error"] as? [String: Any]
        func shown(_ text: String?) -> String? { text.map { DockerSecrets.redact($0, values: secrets) } }
        let sources = (failure?["Sources"] as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
        return DockerBuildDetail(
            context: json["Context"] as? String, dockerfile: json["Dockerfile"] as? String,
            buildArgs: raw.map { ($0.key, DockerSecrets.masked($0.key, $0.value)) }, repository: json["VCSRepository"] as? String,
            revision: json["VCSRevision"] as? String, error: shown(failure?["Message"] as? String ?? json["Error"] as? String),
            status: json["Status"] as? String, errorStep: shown(failure?["Name"] as? String), errorSource: shown(sources), secrets: secrets)
    }

    /// What buildx 0.20's `history inspect` prints, which has no
    /// `--format`: `Key:` and its value a line, tab-padded, then a table a
    /// `BUILD ARG  VALUE` header heads, an arg a row, a blank line after.
    /// No table means no build args: buildx prints none then. Nil for
    /// output that isn't one, so its secrets are never taken as none. Its
    /// status is said only by `Duration: … (running)`, `Error:` and
    /// `Status: Canceled`. Pure.
    static func parsePlain(_ output: String) -> DockerBuildDetail? {
        func cells(_ line: Substring) -> (String, String) {
            let isPad: (Character) -> Bool = { $0 == "\t" || $0 == " " }
            guard let cut = line.firstIndex(where: isPad) else { return (String(line), "") }
            return (String(line[..<cut]), String(line[cut...].drop(while: isPad)))
        }
        var fields: [String: String] = [:]
        var raw: [(key: String, value: String)] = []
        var inArgs = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.hasSuffix("\r") ? line.dropLast() : line
            if inArgs {
                if line.allSatisfy(\.isWhitespace) { inArgs = false } else { raw.append(cells(line)) }
            } else if line.range(of: #"^BUILD ARG[\t ]+VALUE[\t ]*$"#, options: .regularExpression) != nil {
                inArgs = true
            } else if let colon = line.range(of: ":\t"), !line[..<colon.lowerBound].contains("\t") {
                fields[String(line[..<colon.lowerBound])] = String(line[colon.upperBound...].drop { $0 == "\t" || $0 == " " })
            }
        }
        guard fields["Started"] != nil || fields["Duration"] != nil || fields["Build Steps"] != nil else { return nil }
        let secrets = DockerSecrets.values(in: raw)
        // `Error:	Unknown process "…" did not complete…`: its gRPC code first.
        let error = fields["Error"].map { said in said.split(separator: " ", maxSplits: 1).last.map(String.init) ?? said }
        let status =
            fields["Duration"]?.hasSuffix("(running)") == true
            ? "running" : fields["Status"]?.lowercased() == "canceled" ? "canceled" : error != nil ? "failed" : "completed"
        return DockerBuildDetail(
            context: fields["Context"], dockerfile: fields["Dockerfile"], buildArgs: raw.map { ($0.key, DockerSecrets.masked($0.key, $0.value)) },
            repository: fields["VCS Repository"], revision: fields["VCS Revision"], error: error.map { DockerSecrets.redact($0, values: secrets) },
            status: status, secrets: secrets)
    }

    /// `buildx history inspect <ref> --format json`, read; buildx 0.20
    /// refuses the flag, and its plain table is read then (`parsePlain`).
    /// Nil when neither answers.
    static func read(_ ref: String, cli: DockerCLI) async -> DockerBuildDetail? {
        do {
            return parse(try await cli.run(["buildx", "history", "inspect", ref, "--format", "json"], timeout: 30))
        } catch let error as GitError where error.stderr.contains("unknown flag") {
            guard let output = try? await cli.run(["buildx", "history", "inspect", ref], timeout: 30) else { return nil }
            return parsePlain(output)
        } catch {
            return nil
        }
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
