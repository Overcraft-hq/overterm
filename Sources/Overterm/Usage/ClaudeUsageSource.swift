import Foundation

/// What Claude says is left, and what the transcripts say was spent.
///
/// Two halves from two places. The **meters** come out of `~/.claude.json`,
/// where Claude Code caches what the API told it — we never ask the network
/// ourselves. They are as old as the last time Claude Code asked (eight
/// hours is normal), so the pane shows when they were taken, and a window
/// whose reset has gone by reads as rolled over rather than as a stale
/// percentage. They are also **account-wide**: the same file's breakdown
/// counts chat and the desktop app beside Claude Code, which is why the
/// pane calls the provider "Claude" and not "Claude Code".
///
/// The **spend** is ours: `~/.claude/projects/**.jsonl` carries every
/// reply's tokens and model, read from the end backwards
/// (`UsageTailScanner`) and priced by `ModelPricing`.
enum ClaudeUsageSource {
    /// Whether there is anything of Claude's on this Mac to read.
    static func isPresent() -> Bool {
        FileManager.default.fileExists(atPath: AppEnvironment.claudeConfigFile.path)
            || FileManager.default.fileExists(atPath: ClaudeUsageReader.projectsDirectory.path)
    }

    // MARK: The windows

    /// The last parse that worked. Claude Code rewrites the 190 KB file
    /// while it runs, so a read can land mid-write; the pane keeps what it
    /// had rather than blinking empty.
    nonisolated(unsafe) private static var lastGood: (meters: [UsageMeter], asOf: Date?)?
    private static let lastGoodLock = NSLock()

    /// The windows Claude last heard about, and when it heard.
    static func meters() -> (meters: [UsageMeter], asOf: Date?) {
        guard let data = try? Data(contentsOf: AppEnvironment.claudeConfigFile),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let cached = root["cachedUsageUtilization"] as? [String: Any]
        else { return lastGoodLock.withLock { lastGood } ?? ([], nil) }
        let asOf = (cached["fetchedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        let read = (meters: windows(in: cached["utilization"] as? [String: Any] ?? [:]), asOf: asOf)
        lastGoodLock.withLock { lastGood = read }
        return read
    }

    /// The shape moves: there is a `limits` array now, and beside it a long
    /// tail of windows with code names, most of them null and one of them a
    /// live $250 allowance. So: the array when it is there, else every
    /// object that has a percentage in it — rather than a list of names
    /// that goes quietly out of date.
    static func windows(in utilization: [String: Any]) -> [UsageMeter] {
        if let limits = utilization["limits"] as? [[String: Any]], !limits.isEmpty {
            // `is_active` marks the one that is biting, not the ones that
            // exist: taking it as "show this" left a window at 90% and
            // dropped the weekly one at 28%.
            return limits.compactMap { limit in
                guard let percent = (limit["percent"] ?? limit["utilization"]) as? Double else { return nil }
                let kind = (limit["kind"] as? String) ?? (limit["group"] as? String) ?? "Limit"
                // A window for one model says so: "weekly_scoped" with a
                // scope of Fable is "Weekly · Fable".
                let scope = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
                let model = scope?["display_name"] as? String
                return UsageMeter(
                    name: model.map { "\(label(for: kind)) (\($0))" } ?? label(for: kind), usedPercent: percent,
                    resetsAt: resets(limit["resets_at"]), isSession: isSession(kind),
                    usedDollars: limit["used_dollars"] as? Double, limitDollars: limit["limit_dollars"] as? Double)
            }
        }
        var meters = [(order: Int, meter: UsageMeter)]()
        for (key, value) in utilization {
            guard let window = value as? [String: Any], let percent = window["utilization"] as? Double else { continue }
            // "extra_usage" and friends say whether they are switched on.
            if let enabled = window["is_enabled"] as? Bool, !enabled { continue }
            meters.append(
                (
                    order(of: key),
                    UsageMeter(
                        name: label(for: key), usedPercent: percent, resetsAt: resets(window["resets_at"]),
                        isSession: isSession(key),
                        usedDollars: (window["used_dollars"] ?? window["used_credits"]) as? Double,
                        limitDollars: (window["limit_dollars"] ?? window["monthly_limit"]) as? Double)
                ))
        }
        return meters.sorted { ($0.order, $0.meter.name) < ($1.order, $1.meter.name) }.map(\.meter)
    }

    /// The windows everyone has come first and in the order they bite.
    private static func order(of key: String) -> Int {
        switch key {
        case "five_hour": 0
        case "seven_day": 1
        case "seven_day_opus", "seven_day_sonnet": 2
        case "extra_usage": 4
        default: 3
        }
    }

    /// The window you are working in now, whatever it has been called.
    private static func isSession(_ kind: String) -> Bool {
        ["session", "five_hour", "five_hour_limit"].contains(kind)
    }

    /// The words Claude Code's own `/usage` uses, so the two can be read
    /// side by side without translating.
    private static func label(for key: String) -> String {
        switch key {
        case "five_hour", "five_hour_limit", "session": "Session"
        case "seven_day", "weekly_limit", "weekly_all", "weekly": "Week (all models)"
        case "weekly_scoped": "Week"
        case "seven_day_opus": "Week (Opus)"
        case "seven_day_sonnet": "Week (Sonnet)"
        case "extra_usage": "Extra usage"
        default:
            // A code name nobody outside Anthropic can read ("iguana_necktie")
            // still carries a real allowance: show it as words.
            key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// `resets_at` is an ISO string with or without fractional seconds, and
    /// `UsageBytes.instant` reads both; a number means epoch seconds.
    private static func resets(_ value: Any?) -> Date? {
        if let text = value as? String { return UsageBytes.instant(text) }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    // MARK: What it cost

    private static let assistantKey = UsageBytes.key(#""type":"assistant""#)
    private static let timestampKey = UsageBytes.key(#""timestamp":""#)
    private static let idKey = UsageBytes.key(#""id":""#)
    private static let modelKey = UsageBytes.key(#""model":""#)
    private static let usageKey = UsageBytes.key(#""usage":{"#)
    private static let inputKey = UsageBytes.key(#""input_tokens":"#)
    private static let outputKey = UsageBytes.key(#""output_tokens":"#)
    private static let cacheReadKey = UsageBytes.key(#""cache_read_input_tokens":"#)
    private static let cacheWriteKey = UsageBytes.key(#""cache_creation_input_tokens":"#)
    private static let cache5mKey = UsageBytes.key(#""ephemeral_5m_input_tokens":"#)
    private static let cache1hKey = UsageBytes.key(#""ephemeral_1h_input_tokens":"#)

    /// One transcript line, if it is a reply that cost something. Claude's
    /// `input_tokens` excludes what it read from the cache, so the counts
    /// add up as they stand.
    static func line(_ line: UnsafeRawBufferPointer) -> UsageLine? {
        guard UsageBytes.has(assistantKey, in: line), UsageBytes.find(usageKey, in: line) != nil,
            let at = UsageBytes.timestamp(timestampKey, in: line)
        else { return nil }
        let usage = UnsafeRawBufferPointer(rebasing: line[UsageBytes.find(usageKey, in: line)!...])
        let write5m = UsageBytes.int(after: cache5mKey, in: usage)
        let write1h = UsageBytes.int(after: cache1hKey, in: usage)
        let written = UsageBytes.int(after: cacheWriteKey, in: usage)
        let model = UsageBytes.string(after: modelKey, in: line)
        return UsageLine(
            at: at,
            // "<synthetic>" is Claude Code talking to itself, and costs
            // nothing: it has no model and no price.
            model: model.flatMap { $0.hasPrefix("<") ? nil : $0 },
            id: UsageBytes.string(after: idKey, in: line),
            tokens: UsageTokens(
                input: UsageBytes.int(after: inputKey, in: usage),
                output: UsageBytes.int(after: outputKey, in: usage),
                cacheRead: UsageBytes.int(after: cacheReadKey, in: usage),
                // Older transcripts have only the total; it is then priced
                // as the cheaper of the two caches.
                cacheWrite5m: write5m + write1h == 0 ? written : write5m, cacheWrite1h: write1h))
    }

    /// Every transcript written since `since`: each project folder's
    /// sessions, and each session's subagents a level further down — a Task
    /// agent's tokens are nowhere in the session that started it.
    static func transcripts(since: Date) -> [URL] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: ClaudeUsageReader.projectsDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        var found = [URL]()
        for folder in folders {
            guard let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for entry in entries {
                if entry.pathExtension == "jsonl" {
                    if modified(entry) >= since { found.append(entry) }
                    continue
                }
                let subagents = entry.appendingPathComponent("subagents")
                let agents = (try? manager.contentsOfDirectory(at: subagents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                found += agents.filter { $0.pathExtension == "jsonl" && modified($0) >= since }
            }
        }
        return found
    }

    private static func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// What was spent since `since`, over every project.
    static func spend(since: Date, scanner: UsageTailScanner) -> UsageSpend {
        var byModel = [String: UsageTokens]()
        for file in transcripts(since: since) {
            for (key, tokens) in scanner.slices(of: file, since: since, parse: line) {
                byModel[key.model] = (byModel[key.model] ?? UsageTokens()) + tokens
            }
        }
        return UsageSpend.of(byModel)
    }

    /// How old the figures may be before the agent is asked again. Its
    /// own `/usage` is a request to the service; every ten minutes is what
    /// openusage settles on too, and nobody needs a percentage to the
    /// second.
    static let staleAfter: TimeInterval = 600

    /// Asks Claude for fresh figures when what it last wrote down has
    /// aged, by running the command a person would run. Blocking; call
    /// off the main thread.
    static func refresh(asking: Bool, force: Bool = false, now: Date = Date()) {
        guard asking || force else { return }
        let age = meters().asOf.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard force || age > staleAfter else { return }
        AgentUsageCommand.askClaude()
    }

    /// Everything the pane shows for Claude.
    static func snapshot(scope: UsageScope, scanner: UsageTailScanner, cost: Bool, now: Date = Date()) -> UsageSnapshot? {
        guard isPresent() else { return nil }
        var snapshot = UsageSnapshot(provider: .claude)
        (snapshot.meters, snapshot.metersAsOf) = meters()
        if cost { snapshot.spend = spend(since: scope.start(now), scanner: scanner) }
        if snapshot.meters.isEmpty {
            snapshot.note = "No limits written down yet — Claude Code saves them once it has asked."
        }
        return snapshot
    }
}
