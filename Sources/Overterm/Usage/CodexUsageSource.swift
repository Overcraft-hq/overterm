import Foundation

/// What Codex says is left, and what its rollouts say was spent.
///
/// Codex writes both into the same place: `~/.codex/sessions/YYYY/MM/DD/
/// rollout-*.jsonl`, where every turn ends with a `token_count` event
/// carrying the turn's tokens **and** the server's own `rate_limits` —
/// percentages and reset times straight from the service, no API call of
/// ours. The newest rollout holds the newest limits.
///
/// Two traps in those numbers, both of which make a careless reader wrong
/// by a factor: `total_token_usage` is cumulative for the whole session
/// (one rollout here reaches 73 M over four days), so spend comes from
/// `last_token_usage` per turn; and `cached_input_tokens` is *part of*
/// `input_tokens` (input + output == total), where Claude counts them
/// separately.
enum CodexUsageSource {
    static func isPresent() -> Bool {
        FileManager.default.fileExists(atPath: AppEnvironment.codexSessionsDirectory.path)
    }

    // MARK: The rollouts

    /// The rollout files, newest first. The tree is a day per directory,
    /// so this is an enumerator rather than a sort of everything.
    static func rollouts(since: Date? = nil, limit: Int = 400) -> [URL] {
        let manager = FileManager.default
        guard
            let walk = manager.enumerator(
                at: AppEnvironment.codexSessionsDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var found = [(file: URL, at: Date)]()
        for case let file as URL in walk where file.pathExtension == "jsonl" {
            let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let since, at < since { continue }
            found.append((file, at))
        }
        return found.sorted { $0.at > $1.at }.prefix(limit).map(\.file)
    }

    // MARK: The windows

    private static let tokenCountKey = UsageBytes.key(#""type":"token_count""#)
    private static let rateLimitsKey = UsageBytes.key(#""rate_limits":"#)
    private static let windowKey = UsageBytes.key(#""window_minutes":"#)
    private static let usedPercentKey = UsageBytes.key(#""used_percent":"#)
    private static let resetsKey = UsageBytes.key(#""resets_at":"#)
    private static let planKey = UsageBytes.key(#""plan_type":""#)
    private static let lastUsageKey = UsageBytes.key(#""last_token_usage":{"#)
    private static let inputKey = UsageBytes.key(#""input_tokens":"#)
    private static let cachedKey = UsageBytes.key(#""cached_input_tokens":"#)
    private static let cacheWriteKey = UsageBytes.key(#""cache_write_input_tokens":"#)
    private static let outputKey = UsageBytes.key(#""output_tokens":"#)
    private static let timestampKey = UsageBytes.key(#""timestamp":""#)
    private static let modelKey = UsageBytes.key(#""model":""#)

    /// The limits the newest `token_count` carries. Which window is which
    /// is read off `window_minutes` — the fields are named "primary" and
    /// "secondary" and they swap: early in a session the primary is the
    /// weekly one.
    static func limits(in line: UnsafeRawBufferPointer) -> (meters: [UsageMeter], plan: String?)? {
        guard let at = UsageBytes.find(rateLimitsKey, in: line) else { return nil }
        let limits = UnsafeRawBufferPointer(rebasing: line[at...])
        var meters = [UsageMeter]()
        var from = 0
        // A window is written as its percentage, then its length, then its
        // reset — so each percentage is read with what follows it. Looking
        // around a `window_minutes` instead picks up the *previous*
        // window's percentage.
        while from < limits.count, let found = UsageBytes.find(usedPercentKey, in: UnsafeRawBufferPointer(rebasing: limits[from...])) {
            let start = from + found
            let rest = UnsafeRawBufferPointer(rebasing: limits[start...])
            let percent = Double(UsageBytes.int(after: usedPercentKey, in: rest))
            let minutes = UsageBytes.int(after: windowKey, in: rest)
            let resets = UsageBytes.int(after: resetsKey, in: rest)
            if minutes > 0 {
                meters.append(
                    UsageMeter(
                        name: name(forWindow: minutes), usedPercent: percent,
                        resetsAt: resets > 0 ? Date(timeIntervalSince1970: Double(resets)) : nil))
            }
            from = start + usedPercentKey.count
        }
        return (meters.sorted { $0.name < $1.name }, UsageBytes.string(after: planKey, in: limits))
    }

    static func name(forWindow minutes: Int) -> String {
        switch minutes {
        case ..<90: "Hourly"
        case ..<1440: "\(minutes / 60)-hour"
        case 1440: "Daily"
        case ..<20160: "Weekly"
        default: "Monthly"
        }
    }

    /// The newest rollout's last `token_count` — the freshest thing Codex
    /// has written down about your quota.
    static func newestLimits() -> (meters: [UsageMeter], plan: String?, at: Date?)? {
        for file in rollouts(limit: 8) {
            guard let line = lastTokenCount(in: file) else { continue }
            let found = line.withUnsafeBytes { limits(in: $0) }
            guard let found, !found.meters.isEmpty else { continue }
            let at = line.withUnsafeBytes { UsageBytes.timestamp(timestampKey, in: $0) }
            return (found.meters, found.plan, at)
        }
        return nil
    }

    /// Walks back through a rollout until it finds a `token_count` line.
    /// They are not near the end of a long session's file — a rollout here
    /// reaches 65 MB — so the walk grows rather than taking a fixed tail.
    static func lastTokenCount(in file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var end = (try? handle.seekToEnd()) ?? 0
        var carry = Data()
        while end > 0 {
            let length = UInt64(min(UsageTailScanner.step, Int(end)))
            let start = end - length
            try? handle.seek(toOffset: start)
            var data = autoreleasepool { handle.readData(ofLength: Int(length)) }
            data.append(carry)
            var from = data.startIndex
            if start > 0, let newline = data.firstIndex(of: 0x0A) {
                carry = data[data.startIndex...newline]
                from = data.index(after: newline)
            } else {
                carry = Data()
            }
            let lines = data[from...].split(separator: 0x0A, omittingEmptySubsequences: true)
            for line in lines.reversed() where line.withUnsafeBytes({ UsageBytes.has(tokenCountKey, in: $0) }) {
                return Data(line)
            }
            if UInt64(UsageTailScanner.limit) < (try? handle.seekToEnd()).map({ $0 - start }) ?? 0 { break }
            end = start
        }
        return nil
    }

    // MARK: What it cost

    /// A turn's own tokens. `cached_input_tokens` is part of
    /// `input_tokens`, so the cached part is taken out and charged at the
    /// cache rate; `reasoning_output_tokens` is already inside the output.
    static func line(_ line: UnsafeRawBufferPointer, model: String?) -> UsageLine? {
        guard UsageBytes.has(tokenCountKey, in: line), let at = UsageBytes.timestamp(timestampKey, in: line),
            let usageAt = UsageBytes.find(lastUsageKey, in: line)
        else { return nil }
        let usage = UnsafeRawBufferPointer(rebasing: line[usageAt...])
        let input = UsageBytes.int(after: inputKey, in: usage)
        let cached = UsageBytes.int(after: cachedKey, in: usage)
        let tokens = UsageTokens(
            input: max(0, input - cached), output: UsageBytes.int(after: outputKey, in: usage), cacheRead: cached,
            cacheWrite5m: UsageBytes.int(after: cacheWriteKey, in: usage), cacheWrite1h: 0)
        guard tokens.total > 0 else { return nil }
        return UsageLine(at: at, model: model, id: nil, tokens: tokens)
    }

    /// The model a rollout ran: it is named in the session's own header,
    /// not in the turns.
    static func model(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = autoreleasepool { handle.readData(ofLength: 256 << 10) }
        return head.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            return UsageBytes.string(after: modelKey, in: UnsafeRawBufferPointer(start: base, count: raw.count))
        }
    }

    static func spend(since: Date, scanner: UsageTailScanner) -> UsageSpend {
        var byModel = [String: UsageTokens]()
        for file in rollouts(since: since) {
            let model = model(of: file)
            for (key, tokens) in scanner.slices(of: file, since: since, parse: { line(_: $0, model: model) }) {
                byModel[key.model] = (byModel[key.model] ?? UsageTokens()) + tokens
            }
        }
        return UsageSpend.of(byModel)
    }

    static func snapshot(scope: UsageScope, scanner: UsageTailScanner, cost: Bool, now: Date = Date()) -> UsageSnapshot? {
        guard isPresent() else { return nil }
        var snapshot = UsageSnapshot(provider: .codex)
        if let found = newestLimits() {
            snapshot.meters = found.meters
            snapshot.plan = found.plan
            snapshot.metersAsOf = found.at
        }
        if cost { snapshot.spend = spend(since: scope.start(now), scanner: scanner) }
        if snapshot.meters.isEmpty {
            snapshot.note = "No limits in the rollouts yet — Codex writes them as it works."
        }
        return snapshot
    }
}
