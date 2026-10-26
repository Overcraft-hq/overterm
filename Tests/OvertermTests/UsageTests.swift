import XCTest

@testable import Overterm

final class UsageMeterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    func testReadingAndBar() {
        let meter = UsageMeter(name: "5-hour", usedPercent: 90, resetsAt: now.addingTimeInterval(3600))
        XCTAssertEqual(meter.reading(now), "90%")
        XCTAssertEqual(meter.fraction(now), 0.9, accuracy: 0.0001)
        XCTAssertEqual(meter.resets(now), "resets in 1 h")
        XCTAssertEqual(meter.level(now), .close)
    }

    /// Claude Code caches these figures and refreshes them only while it
    /// runs: eight hours later the window it measured is long gone, and
    /// 90% would be a lie about the one running now.
    func testAWindowThatHasRolledOverReadsAsNothing() {
        let meter = UsageMeter(name: "5-hour", usedPercent: 90, resetsAt: now.addingTimeInterval(-60))
        XCTAssertTrue(meter.isSpent(now))
        XCTAssertEqual(meter.reading(now), "—")
        XCTAssertEqual(meter.fraction(now), 0)
        XCTAssertEqual(meter.resets(now), "rolled over")
        XCTAssertEqual(meter.level(now), .easy)
    }

    func testCountdownsNeverRunBackwards() {
        for seconds in [-100_000.0, -1, 0] {
            let meter = UsageMeter(name: "x", usedPercent: 10, resetsAt: now.addingTimeInterval(seconds))
            XCTAssertEqual(meter.resets(now), "rolled over", "\(seconds)")
        }
        XCTAssertEqual(UsageMeter(name: "x", usedPercent: 1, resetsAt: now.addingTimeInterval(30)).resets(now), "resets in a moment")
        XCTAssertEqual(UsageMeter(name: "x", usedPercent: 1, resetsAt: now.addingTimeInterval(8100)).resets(now), "resets in 2 h 15 m")
        XCTAssertEqual(UsageMeter(name: "x", usedPercent: 1, resetsAt: now.addingTimeInterval(200_000)).resets(now), "resets in 2 d 7 h")
    }

    /// The strip shows the window you are working in, even when a weekly
    /// one is further along: that is the number you can do something
    /// about this afternoon.
    func testTheChipShowsTheSessionYouAreIn() {
        var snapshot = UsageSnapshot(provider: .claude)
        snapshot.meters = [
            UsageMeter(name: "Session", usedPercent: 9, resetsAt: now.addingTimeInterval(3600), isSession: true),
            UsageMeter(name: "Week (all models)", usedPercent: 34, resetsAt: now.addingTimeInterval(86_400)),
        ]
        XCTAssertEqual(snapshot.chipMeter(now)?.name, "Session")

        // No session window reported: the fullest of what there is.
        snapshot.meters = [
            UsageMeter(name: "Session", usedPercent: 99, resetsAt: now.addingTimeInterval(-1), isSession: true),  // rolled over
            UsageMeter(name: "Week (all models)", usedPercent: 28, resetsAt: now.addingTimeInterval(86_400)),
            UsageMeter(name: "Week (Opus)", usedPercent: 64, resetsAt: now.addingTimeInterval(86_400)),
        ]
        XCTAssertEqual(snapshot.chipMeter(now)?.name, "Week (Opus)")
    }

    func testMoneyAndAge() {
        XCTAssertEqual(UsageFormat.money(0), "$0.00")
        XCTAssertEqual(UsageFormat.money(0.004), "<$0.01")
        XCTAssertEqual(UsageFormat.money(4.127), "$4.13")
        XCTAssertEqual(UsageFormat.money(1204.9), "$1205")
        XCTAssertEqual(UsageFormat.age(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(UsageFormat.age(now.addingTimeInterval(-1200), now: now), "20 min ago")
        XCTAssertEqual(UsageFormat.age(now.addingTimeInterval(-31_500), now: now), "8 h ago")
    }
}

final class ModelPricingTests: XCTestCase {
    func testTheCacheWritesArePricedApart() {
        // Claude Code writes into the hour-long cache, which is twice the
        // base rate; pricing it as the five-minute one underpays by a third.
        let tokens = UsageTokens(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 1_000_000)
        XCTAssertEqual(ModelPricing.cost(tokens, model: "claude-opus-5") ?? 0, 5 + 25 + 0.5 + 10, accuracy: 0.001)
    }

    func testADatedOrShortenedNameStillFindsItsFamily() {
        XCTAssertEqual(ModelPricing.rate(for: "claude-opus-5")?.input, 5)
        XCTAssertEqual(ModelPricing.rate(for: "claude-opus-5-20261001")?.input, 5)
        XCTAssertEqual(ModelPricing.rate(for: "claude-opus-5-5")?.input, 4, "the longer prefix wins")
        XCTAssertEqual(ModelPricing.rate(for: "claude-sonnet-5")?.output, 10)
        XCTAssertEqual(ModelPricing.rate(for: "gpt-5.6-sol")?.input, 1.25)
    }

    /// A model nobody here has heard of has no price at all: the pane shows
    /// its tokens and says they are unpriced, rather than a confident $0.
    func testAnUnknownModelHasNoPrice() {
        XCTAssertNil(ModelPricing.rate(for: "llama-9"))
        XCTAssertNil(ModelPricing.cost(UsageTokens(input: 1_000_000), model: "llama-9"))
        XCTAssertNil(ModelPricing.rate(for: ""))
    }

    func testSpendLeavesUnpricedTokensOutOfTheMoney() {
        let spend = UsageSpend.of([
            "claude-opus-5": UsageTokens(input: 1_000_000),
            "llama-9": UsageTokens(input: 2_000_000),
        ])
        XCTAssertEqual(spend.dollars ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(spend.unpriced, 2_000_000)
        XCTAssertEqual(spend.tokens.total, 3_000_000)
    }

    func testShortName() {
        XCTAssertEqual(ModelPricing.shortName("claude-opus-5"), "opus 5")
        XCTAssertEqual(ModelPricing.shortName("claude-haiku-4-5-20251001"), "haiku 4 5")
        XCTAssertEqual(ModelPricing.shortName("gpt-5.6-sol"), "gpt 5.6 sol")
    }
}

final class UsageBytesTests: XCTestCase {
    /// Both shapes occur in the files, and an ISO8601DateFormatter set up
    /// for one returns nil for the other.
    func testEveryTimestampShapeTheLogsUse() {
        let withFraction = UsageBytes.instant("2026-10-15T11:10:00.812478+00:00")
        let withZ = UsageBytes.instant("2026-10-15T11:10:00Z")
        let plain = UsageBytes.instant("2026-11-05T07:59:00+00:00")
        XCTAssertEqual(withFraction, withZ)
        XCTAssertEqual(withFraction?.timeIntervalSince1970, 1_792_062_600)
        XCTAssertEqual(plain?.timeIntervalSince1970, 1_793_865_540)
        XCTAssertNil(UsageBytes.instant("yesterday"))
        XCTAssertNil(UsageBytes.instant(""))
    }

    func testEpochAgreesWithTheCalendar() {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 2, 29 - 1)
        components.timeZone = TimeZone(identifier: "UTC")
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(UsageBytes.epoch(year: 2026, month: 2, day: 28), calendar.date(from: components)!.timeIntervalSince1970)
    }
}

final class ClaudeUsageSourceTests: XCTestCase {
    /// The shape in ~/.claude.json, including the long tail of code-named
    /// windows — one of which is a live $250 allowance, and most of which
    /// are null.
    private let utilization: [String: Any] = [
        "five_hour": ["utilization": 90.0, "resets_at": "2026-10-15T11:10:00.812478+00:00"],
        "seven_day": ["utilization": 28.0, "resets_at": "2026-10-22T02:00:00.812532+00:00"],
        "seven_day_opus": NSNull(),
        "iguana_necktie": [
            "utilization": 12.0, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": 250.0, "used_dollars": 30.0,
        ],
        "extra_usage": ["is_enabled": false, "utilization": 4.0],
    ]

    func testTheWindowsItKnowsComeFirstAndTheOddOnesAreNotDropped() {
        let meters = ClaudeUsageSource.windows(in: utilization)
        XCTAssertEqual(meters.map(\.name), ["Session", "Week (all models)", "Iguana Necktie"])
        XCTAssertEqual(meters[0].usedPercent, 90)
        XCTAssertEqual(meters[0].resetsAt?.timeIntervalSince1970, 1_792_062_600)
        XCTAssertEqual(meters[2].limitDollars, 250)
        XCTAssertNil(meters.first { $0.name == "Extra usage" }, "switched off")
    }

    /// The file has grown a `limits` array; when it is there it is the
    /// truth, and the named keys beside it are the old shape. `is_active`
    /// there marks the window that is *biting*, not the ones that exist —
    /// reading it as "show this" left the session at 90% on screen and
    /// dropped the weekly one at 28%.
    func testTheLimitsArrayWinsAndEveryWindowInItIsShown() {
        var newer = utilization
        newer["limits"] = [
            ["kind": "session", "group": "session", "percent": 90.0, "resets_at": "2026-10-15T11:10:00.812478+00:00", "is_active": true],
            ["kind": "weekly_all", "group": "weekly", "percent": 28.0, "resets_at": "2026-10-22T02:00:00Z", "is_active": false],
            [
                "kind": "weekly_scoped", "group": "weekly", "percent": 0.0, "resets_at": "2026-10-22T02:00:00+00:00",
                "is_active": false, "scope": ["model": ["id": NSNull(), "display_name": "Fable"]],
            ],
        ]
        let meters = ClaudeUsageSource.windows(in: newer)
        XCTAssertEqual(meters.map(\.name), ["Session", "Week (all models)", "Week (Fable)"])
        XCTAssertEqual(meters[0].usedPercent, 90)
        XCTAssertEqual(meters[1].usedPercent, 28)
    }

    func testAReplyLineIsReadWithItsCacheSplit() throws {
        let line = #"""
            {"type":"assistant","timestamp":"2026-10-15T14:23:45.123Z","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":20455,"cache_read_input_tokens":30344,"output_tokens":514,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":20455}}}}
            """#
        let found = try XCTUnwrap(Array(line.utf8).withUnsafeBytes { ClaudeUsageSource.line($0) })
        XCTAssertEqual(found.id, "msg_1")
        XCTAssertEqual(found.model, "claude-opus-5")
        XCTAssertEqual(found.tokens, UsageTokens(input: 2, output: 514, cacheRead: 30344, cacheWrite5m: 0, cacheWrite1h: 20455))
        XCTAssertEqual(found.at.timeIntervalSince1970, 1_792_074_225)
    }

    func testSyntheticRepliesAndOtherLinesAreNotSpend() {
        let synthetic = #"{"type":"assistant","timestamp":"2026-10-15T14:23:45.123Z","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":1}}}"#
        let found = Array(synthetic.utf8).withUnsafeBytes { ClaudeUsageSource.line($0) }
        XCTAssertNil(found?.model, "nothing to charge it to")
        let user = #"{"type":"user","timestamp":"2026-10-15T14:23:45.123Z","message":{"role":"user","content":"hi"}}"#
        XCTAssertNil(Array(user.utf8).withUnsafeBytes { ClaudeUsageSource.line($0) })
    }
}

final class CodexUsageSourceTests: XCTestCase {
    private let event = #"""
        {"timestamp":"2026-08-21T17:05:35.453Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":19239,"cached_input_tokens":11008,"cache_write_input_tokens":0,"output_tokens":338,"reasoning_output_tokens":118,"total_tokens":19577},"last_token_usage":{"input_tokens":1200,"cached_input_tokens":1000,"cache_write_input_tokens":0,"output_tokens":90,"reasoning_output_tokens":40,"total_tokens":1290},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":4.0,"window_minutes":300,"resets_at":1787857752},"secondary":{"used_percent":37.0,"window_minutes":10080,"resets_at":1788277627},"credits":{"has_credits":false},"plan_type":"plus"}}}
        """#

    /// Codex counts the cached part *inside* the input, where Claude keeps
    /// them apart: added up as they stand, every turn is counted twice.
    func testATurnsOwnTokensWithTheCachedPartTakenOut() throws {
        let found = try XCTUnwrap(Array(event.utf8).withUnsafeBytes { CodexUsageSource.line($0, model: "gpt-5.6-sol") })
        XCTAssertEqual(found.tokens, UsageTokens(input: 200, output: 90, cacheRead: 1000, cacheWrite5m: 0, cacheWrite1h: 0))
        XCTAssertEqual(found.tokens.total, 1290, "what the event itself calls the total")
        XCTAssertEqual(found.model, "gpt-5.6-sol")
    }

    /// "primary" is not a window: early in a session it is the weekly one
    /// and there is no secondary at all. The minutes say which is which.
    func testTheWindowsAreReadOffTheirLength() throws {
        let found = try XCTUnwrap(Array(event.utf8).withUnsafeBytes { CodexUsageSource.limits(in: $0) })
        XCTAssertEqual(found.plan, "plus")
        XCTAssertEqual(found.meters.map(\.name).sorted(), ["5-hour", "Weekly"])
        let weekly = try XCTUnwrap(found.meters.first { $0.name == "Weekly" })
        XCTAssertEqual(weekly.usedPercent, 37)
        XCTAssertEqual(weekly.resetsAt?.timeIntervalSince1970, 1_788_277_627)
        XCTAssertEqual(CodexUsageSource.name(forWindow: 10080), "Weekly")
        XCTAssertEqual(CodexUsageSource.name(forWindow: 300), "5-hour")
        XCTAssertEqual(CodexUsageSource.name(forWindow: 1440), "Daily")
    }
}

final class UsageTailScannerTests: XCTestCase {
    private func write(_ lines: [String]) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-usage-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func reply(_ id: String, at: String, input: Int, output: Int, model: String = "claude-opus-5") -> String {
        #"{"type":"assistant","timestamp":"\#(at)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    func testOnlyTheWindowIsCounted() throws {
        let file = try write([
            reply("old", at: "2026-10-13T09:00:00.000Z", input: 999, output: 999),
            reply("in", at: "2026-10-15T09:00:00.000Z", input: 10, output: 2),
            reply("in", at: "2026-10-15T09:00:00.000Z", input: 10, output: 2),  // the same reply again
            reply("later", at: "2026-10-15T10:30:00.000Z", input: 1, output: 1),
        ])
        defer { try? FileManager.default.removeItem(at: file) }
        let since = try XCTUnwrap(UsageBytes.instant("2026-10-15T00:00:00Z"))
        let slices = UsageTailScanner().slices(of: file, since: since, parse: ClaudeUsageSource.line)
        XCTAssertEqual(slices.values.reduce(0) { $0 + $1.total }, 14, "the repeat counts once, the old line not at all")
        XCTAssertEqual(slices.count, 2, "an hour each")
        XCTAssertEqual(Set(slices.keys.map(\.model)), ["claude-opus-5"])
    }

    /// Lines that carry no usage are written out of order by hours; only a
    /// reply older than the window may stop the walk back.
    func testAnUnorderedLineDoesNotStopTheWalk() throws {
        let file = try write([
            reply("in", at: "2026-10-15T09:00:00.000Z", input: 5, output: 5),
            #"{"type":"attachment","timestamp":"2026-10-10T04:00:00.000Z","content":"written late, dated early"}"#,
            reply("also-in", at: "2026-10-15T11:00:00.000Z", input: 7, output: 0),
        ])
        defer { try? FileManager.default.removeItem(at: file) }
        let since = try XCTUnwrap(UsageBytes.instant("2026-10-15T00:00:00Z"))
        let slices = UsageTailScanner().slices(of: file, since: since, parse: ClaudeUsageSource.line)
        XCTAssertEqual(slices.values.reduce(0) { $0 + $1.total }, 17)
    }

    func testAFileNobodyHasWrittenToIsNotReadTwice() throws {
        let file = try write([reply("a", at: "2026-10-15T09:00:00.000Z", input: 3, output: 4)])
        defer { try? FileManager.default.removeItem(at: file) }
        let since = try XCTUnwrap(UsageBytes.instant("2026-10-15T00:00:00Z"))
        let scanner = UsageTailScanner()
        let first = scanner.slices(of: file, since: since, parse: ClaudeUsageSource.line)
        var reads = 0
        let second = scanner.slices(
            of: file, since: since,
            parse: { line in
                reads += 1
                return ClaudeUsageSource.line(line)
            })
        XCTAssertEqual(first, second)
        XCTAssertEqual(reads, 0, "answered from what it already read")
    }
}

/// Canaries: the real files on this Mac, when they are there. They are what
/// catches a format that has moved — the fixtures above only prove we read
/// the format we wrote down.
final class UsageOnThisMacTests: XCTestCase {
    func testClaudesOwnFileStillParses() throws {
        let file = AppEnvironment.claudeConfigFile
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "no ~/.claude.json")
        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        // Written only once Claude Code has asked: a config folder that
        // never ran /usage has none, which says nothing about the format.
        try XCTSkipUnless(root["cachedUsageUtilization"] != nil, "no usage cached in \(file.path) yet — `claude -p /usage` once")
        let cached = try XCTUnwrap(root["cachedUsageUtilization"] as? [String: Any], "the key Claude Code caches limits in")
        let meters = ClaudeUsageSource.windows(in: cached["utilization"] as? [String: Any] ?? [:])
        XCTAssertFalse(meters.isEmpty, "a window with a percentage in it")
        XCTAssertTrue(meters.allSatisfy { (0...100).contains($0.usedPercent) }, "\(meters.map(\.usedPercent))")
    }

    func testCodexsNewestRolloutStillParses() throws {
        try XCTSkipUnless(CodexUsageSource.isPresent(), "no ~/.codex/sessions")
        // The newest that has one, as the pane reads them: Codex writes two
        // rollouts at once, and only one of them carries the quota.
        let rollouts = CodexUsageSource.rollouts(limit: 8)
        try XCTSkipUnless(!rollouts.isEmpty, "no rollouts")
        // Read once each — never lazy.compactMap(…).first over files (CLAUDE.md).
        var found: Data?
        for file in rollouts where found == nil { found = CodexUsageSource.lastTokenCount(in: file) }
        let line = try XCTUnwrap(found, "a token_count event in the newest rollouts")
        let limits = try XCTUnwrap(line.withUnsafeBytes { CodexUsageSource.limits(in: $0) })
        XCTAssertFalse(limits.meters.isEmpty)
    }
}
