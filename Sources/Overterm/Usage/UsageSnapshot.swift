import Foundation
import SwiftUI

/// Tokens, as every provider counts them.
struct UsageTokens: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    /// Written into a cache that lives five minutes, and one that lives an
    /// hour: they cost different money (`ModelPricing`).
    var cacheWrite5m = 0
    var cacheWrite1h = 0

    var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    static func + (a: UsageTokens, b: UsageTokens) -> UsageTokens {
        UsageTokens(
            input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
    }
}

/// One of a provider's quota windows: how much of it is gone, and when it
/// starts again.
struct UsageMeter: Equatable, Sendable, Identifiable {
    /// "5-hour", "Weekly", "Extra usage".
    let name: String
    /// 0…100, as the provider reports it.
    let usedPercent: Double
    let resetsAt: Date?
    /// The window you are inside right now — Claude's session, Codex's
    /// five hours. It is the one worth a glance in the strip: the weekly
    /// one moves slowly and you can do nothing about it today.
    var isSession = false
    /// Set only where the provider gives money rather than a percentage.
    var usedDollars: Double?
    var limitDollars: Double?

    var id: String { name }

    /// A window whose reset has passed: the percentage we have is from
    /// before it, so it says nothing about the one running now. Claude
    /// Code caches these figures and only refreshes them while it runs —
    /// eight hours old is normal.
    func isSpent(_ now: Date = Date()) -> Bool { resetsAt.map { $0 <= now } ?? false }

    /// What the bar shows: nothing once the window has rolled over.
    func fraction(_ now: Date = Date()) -> Double {
        isSpent(now) ? 0 : min(max(usedPercent / 100, 0), 1)
    }

    /// "90%", or "—" for a window that has started again.
    func reading(_ now: Date = Date()) -> String {
        isSpent(now) ? "—" : "\(Int(usedPercent.rounded()))%"
    }

    /// "resets in 2 h 14 m", "rolled over", "resets in a moment".
    func resets(_ now: Date = Date()) -> String {
        guard let resetsAt else { return "" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "rolled over" }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "resets in a moment" }
        if minutes < 60 { return "resets in \(minutes) m" }
        let hours = minutes / 60
        if hours < 24 { return "resets in \(hours) h\(minutes % 60 > 0 ? " \(minutes % 60) m" : "")" }
        return "resets in \(hours / 24) d\(hours % 24 > 0 ? " \(hours % 24) h" : "")"
    }

    /// How a meter reads as a warning: the chip and the bar take their
    /// colour from it.
    enum Level { case easy, close, spent }

    func level(_ now: Date = Date()) -> Level {
        if isSpent(now) { return .easy }
        if usedPercent >= 95 { return .spent }
        return usedPercent >= 80 ? .close : .easy
    }
}

/// What a provider's logs say was spent over a stretch of time.
struct UsageSpend: Equatable, Sendable {
    var tokens = UsageTokens()
    /// Nil where no model in the stretch has a price (then: tokens only,
    /// never a made-up number).
    var dollars: Double?
    /// The models it came from, for the detail line.
    var models: [String] = []
    /// Tokens from a model this build has no price for: shown, never
    /// guessed at.
    var unpriced = 0

    /// Adds up what each model spent and prices what can be priced. A
    /// model with no rate in the table is counted in the tokens and left
    /// out of the money, and `unpriced` says how much was left out.
    static func of(_ byModel: [String: UsageTokens]) -> UsageSpend {
        var spend = UsageSpend()
        for (model, tokens) in byModel {
            spend.tokens = spend.tokens + tokens
            if let cost = ModelPricing.cost(tokens, model: model) {
                spend.dollars = (spend.dollars ?? 0) + cost
            } else if tokens.total > 0 {
                spend.unpriced += tokens.total
            }
        }
        spend.models = byModel.filter { !$0.key.isEmpty && $0.value.total > 0 }.keys.sorted()
        return spend
    }

    static func + (a: UsageSpend, b: UsageSpend) -> UsageSpend {
        UsageSpend(
            tokens: a.tokens + b.tokens,
            dollars: a.dollars == nil && b.dollars == nil ? nil : (a.dollars ?? 0) + (b.dollars ?? 0),
            models: a.models + b.models.filter { !a.models.contains($0) }, unpriced: a.unpriced + b.unpriced)
    }
}

/// Everything the pane shows about one provider.
struct UsageSnapshot: Equatable, Sendable, Identifiable {
    let provider: Provider
    /// "plus", "max", "pro" — what the provider calls the plan, when it says.
    var plan: String?
    var meters: [UsageMeter] = []
    var spend = UsageSpend()
    /// When the provider's own figures were taken. Nil when the numbers are
    /// ours, read from the logs just now.
    var metersAsOf: Date?
    /// Why there is nothing to show, when there is nothing to show.
    var note: String?

    var id: String { provider.rawValue }

    /// Who is being counted. The two the app starts are read properly;
    /// the rest are here because they are on a lot of Macs and a pane
    /// that pretended they weren't would be lying by omission — they
    /// keep their usage on their own servers, and the row says so.
    enum Provider: String, Sendable, CaseIterable {
        case claude, codex, cursor, copilot, gemini, antigravity

        var name: String {
            switch self {
            // Claude's own figures count chat and the desktop app too,
            // not just Claude Code: the name has to be the account's.
            case .claude: "Claude"
            case .codex: "Codex"
            case .cursor: "Cursor"
            case .copilot: "GitHub Copilot"
            case .gemini: "Gemini"
            case .antigravity: "Antigravity"
            }
        }

        /// Its glyph in the pane. The two agents keep the ones their tabs
        /// already wear, so the same thing looks the same everywhere.
        var symbol: String {
            switch self {
            case .claude: Agent.claude.symbol
            case .codex: Agent.codex.symbol
            case .cursor: "cursorarrow"
            case .copilot: "cpu"
            case .gemini: "diamond"
            case .antigravity: "arrow.up.forward"
            }
        }

        /// Its colour, near enough its own brand's to tell the rows apart
        /// at a glance without borrowing anybody's logo.
        var tint: Color {
            switch self {
            case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
            case .codex: Color(red: 0.06, green: 0.64, blue: 0.50)
            case .cursor: Color(red: 0.35, green: 0.56, blue: 0.98)
            case .copilot: Color(red: 0.61, green: 0.45, blue: 0.93)
            case .gemini: Color(red: 0.27, green: 0.60, blue: 0.95)
            case .antigravity: Color(red: 0.93, green: 0.64, blue: 0.24)
            }
        }

        /// Where to look to know it is on this Mac. Nil for the two that
        /// are found by their own logs (`isPresent`), and for all of them
        /// in an isolated run — a scenario must not depend on what the
        /// person running it happens to have installed.
        var home: URL? {
            guard !AppEnvironment.isIsolated else { return nil }
            let directory: String?
            switch self {
            case .claude, .codex: directory = nil
            case .cursor: directory = ".cursor"
            case .copilot: directory = ".copilot"
            case .gemini: directory = ".gemini"
            case .antigravity: directory = ".antigravity"
            }
            return directory.map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0) }
        }

        /// Why there are no numbers for it, for the ones there are none for.
        var elsewhere: String {
            "Keeps its usage on its own servers — nothing to read on this Mac."
        }
    }

    /// Every window ended after these figures were written down: they say
    /// nothing about the ones running now, and only the agent itself can
    /// refresh them.
    func isStale(_ now: Date = Date()) -> Bool {
        !meters.isEmpty && meters.allSatisfy { $0.isSpent(now) }
    }

    /// What the chip in the strip shows: the window you are in. Only
    /// when a provider reports no session window does the tightest of the
    /// others stand in for it.
    func chipMeter(_ now: Date = Date()) -> UsageMeter? {
        let live = meters.filter { !$0.isSpent(now) }
        return live.first(where: \.isSession) ?? live.max { $0.usedPercent < $1.usedPercent }
    }
}

/// Which stretch of time the pane counts spend over.
enum UsageScope: String, CaseIterable, Identifiable, Sendable {
    case today, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    /// The instant the stretch starts: midnight here for today, otherwise
    /// a round number of days back.
    func start(_ now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .today: calendar.startOfDay(for: now)
        case .week: now.addingTimeInterval(-7 * 86_400)
        case .month: now.addingTimeInterval(-30 * 86_400)
        }
    }
}

enum UsageFormat {
    /// "$4.12", "$0.03", "$1,204" — money, as money is written.
    static func money(_ dollars: Double) -> String {
        if dollars >= 1000 { return "$" + String(format: "%.0f", dollars) }
        if dollars >= 1 { return "$" + String(format: "%.2f", dollars) }
        if dollars >= 0.01 { return "$" + String(format: "%.2f", dollars) }
        return dollars > 0 ? "<$0.01" : "$0.00"
    }

    /// How old a provider's own figures are: "just now", "20 min ago".
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 90 { return "just now" }
        if seconds < 5400 { return "\(seconds / 60) min ago" }
        if seconds < 172_800 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86_400) d ago"
    }
}
