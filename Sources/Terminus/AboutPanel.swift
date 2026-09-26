import AppKit

/// Terminus ▸ About Terminus: the standard panel — its "Version 1.10.0 (103)"
/// is CFBundleShortVersionString (VERSION) and CFBundleVersion (the commit
/// count) — with the commit the app was built from and the day as credits.
/// Scripts/make-app.sh writes all four keys (docs/architecture.md, Build
/// metadata).
enum AboutPanel {
    static let commitKey = "TerminusCommit"
    static let buildDateKey = "TerminusBuildDate"

    @MainActor
    static func show() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let text = credits(for: .main) {
            let centred = NSMutableParagraphStyle()
            centred.alignment = .center
            options[.credits] = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    // Drawn as given: without a colour it stays black in dark mode.
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: centred,
                ])
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    static func credits(for bundle: Bundle) -> String? {
        credits(commit: bundle.object(forInfoDictionaryKey: commitKey) as? String, date: bundle.object(forInfoDictionaryKey: buildDateKey) as? String)
    }

    /// "commit 7e68283 · 26 Sep 2026", from TerminusCommit (a short SHA, with
    /// "-dirty" when built with uncommitted changes, or "unknown" without
    /// git) and TerminusBuildDate (an ISO date). What is missing is left out;
    /// nil when both are — no credits.
    static func credits(commit: String?, date: String?) -> String? {
        let commit = commit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let date = date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts: [String] = []
        if !commit.isEmpty { parts.append("commit \(commit)") }
        if !date.isEmpty { parts.append(day(date) ?? date) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2026-09-26" → "26 Sep 2026": English like the rest of the app, in any
    /// locale. Nil for anything but an ISO date.
    static func day(_ iso: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: iso) else { return nil }
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}
