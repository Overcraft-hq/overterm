import SwiftUI

/// A security setting settings.json changed outside the Settings page —
/// by hand, or by an agent, which can write the file as easily as a
/// person. Held (`Settings.held`): the value before stays in effect until
/// a window's banner Keeps the new one, or Revert writes the old one back
/// (docs/design/terraform/analysis.md 5.8, D-7). Which settings are held is
/// `SettingSpec.heldWhenEditedOutside`.
struct HeldSetting: Equatable, Sendable {
    let key: String
    /// In effect now; nil: the default.
    let current: SettingValue?
    /// What the file says now, as it would apply; nil: unset, or a value
    /// the setting can't hold — the default.
    let proposed: SettingValue?
    /// The file's own value before, not fitted: what Revert writes back,
    /// and what `Settings.fileValue` answers meanwhile. Nil: not set.
    let before: SettingValue?
    /// The file's own value now, not fitted; nil: not set, or not a value.
    let written: SettingValue?

    /// One thing the change does, in words.
    struct Line: Equatable, Sendable {
        let text: String
        /// Adds or loosens something (a name added, an entry changed or
        /// removed, a value set): listed before what only narrows.
        let widens: Bool
    }

    /// The change in words, a line for each name or entry, names quoted
    /// and every character visible (an agent wrote them), never cut:
    /// `kubernetes.agentWrites: adds "acme-prod"`.
    @MainActor var lines: [Line] {
        let fallback = SettingsSchema.byKey[key]?.defaultValue
        var found = Self.change(from: current ?? fallback, to: proposed ?? fallback)
        if written != nil && proposed == nil {
            found.insert(Line(text: "the file's value can't be used, so its default", widens: true), at: 0)
        }
        return found.map { Line(text: DockerMCP.displayed("\(key): " + $0.text), widens: $0.widens) }
    }

    /// What changed from `old` to `new`: each name a list adds or removes,
    /// each entry of an object added, removed or changed field by field,
    /// else the two values.
    static func change(from old: SettingValue?, to new: SettingValue?) -> [Line] {
        if let before = old?.list, let after = new?.list {
            let added = after.filter { !before.contains($0) }.map { Line(text: "adds " + quoted($0), widens: true) }
            let removed = before.filter { !after.contains($0) }.map { Line(text: "removes " + quoted($0), widens: false) }
            return added + removed + (added.isEmpty && removed.isEmpty ? [Line(text: "reordered", widens: false)] : [])
        }
        if let before = old?.entries, let after = new?.entries {
            var lines: [Line] = []
            for name in Set(before.keys).union(after.keys).sorted() {
                switch (before[name], after[name]) {
                case (nil, let added?):
                    lines.append(Line(text: quoted(name) + " added" + (added.isEmpty ? "" : " (\(fields(added)))"), widens: true))
                case (let removed?, nil):
                    lines.append(Line(text: quoted(name) + " removed" + (removed.isEmpty ? "" : " (it had \(fields(removed)))"), widens: true))
                case (let was?, let now?) where was != now:
                    let changed = Set(was.keys).union(now.keys).sorted().filter { was[$0] != now[$0] }
                    let said = changed.map { "\($0) \(was[$0]?.json ?? "unset") → \(now[$0]?.json ?? "unset")" }.joined(separator: ", ")
                    lines.append(Line(text: quoted(name) + ": " + said, widens: true))
                default: continue
                }
            }
            return lines.isEmpty ? [Line(text: "unchanged", widens: false)] : lines
        }
        return [Line(text: "now \(new?.json ?? "unset") (was \(old?.json ?? "unset"))", widens: true)]
    }

    private static func quoted(_ name: String) -> String { SettingValue.string(name).json }

    private static func fields(_ fields: [String: SettingValue]) -> String {
        fields.keys.sorted().map { "\($0): \(fields[$0]!.json)" }.joined(separator: ", ")
    }
}

/// What the banner itself has room for: a few lines, each of a bounded
/// length. Anything left out or cut means Keep is not in the banner — the
/// whole change is reviewed first (`HeldReviewProgress`): an agent decides
/// what would fall past a cut, and could put its production name there.
struct HeldBannerSummary: Equatable {
    static let maxLines = 6
    static let maxLength = 160

    /// The lines the banner shows, a long one cut with "…".
    let shown: [String]
    /// Lines not in the banner.
    let hidden: Int
    /// Whether a shown line was cut.
    let cut: Bool

    init(_ lines: [String]) {
        let first = lines.prefix(Self.maxLines)
        shown = first.map { $0.count > Self.maxLength ? String($0.prefix(Self.maxLength)) + "…" : $0 }
        hidden = lines.count - first.count
        cut = first.contains { $0.count > Self.maxLength }
    }

    /// Whether the banner shows the whole change, so Keep can be in it.
    var keepInBanner: Bool { hidden == 0 && !cut }
}

/// The review of a change too long for the banner: Keep only once every
/// line has been on screen.
struct HeldReviewProgress: Equatable {
    let count: Int
    private(set) var seen: Set<Int> = []

    init(count: Int) { self.count = count }

    mutating func saw(_ index: Int) {
        if (0..<count).contains(index) { seen.insert(index) }
    }

    var canKeep: Bool { count > 0 && seen.count == count }
}

/// The banner over every window while `Settings.held` has something: the
/// changes in words, Keep and Revert — the same in each window, either
/// answering for all.
struct SettingsHeldBanner: View {
    @ObservedObject var settings: Settings
    @ObservedObject var theme: ChromeTheme
    @State private var reviewing = false

    /// Every line of the change, untruncated: what widens first, then by
    /// key, each setting's lines in their own order.
    @MainActor static func lines(_ held: [String: HeldSetting]) -> [String] {
        let all = held.keys.sorted().flatMap { held[$0]!.lines }
        return all.filter(\.widens).map(\.text) + all.filter { !$0.widens }.map(\.text)
    }

    var body: some View {
        let shown = settings.held
        if !shown.isEmpty {
            let lines = Self.lines(shown)
            let summary = HeldBannerSummary(lines)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .font(.system(size: ChromeMetrics.text(14))).foregroundStyle(KubeResourceBanner.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("settings.json changed outside Overterm. Until you keep it, the value before stays in effect:")
                        .font(.system(size: ChromeMetrics.text(11.5), weight: .semibold)).foregroundStyle(theme.text)
                    ForEach(Array(summary.shown.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !summary.keepInBanner {
                        Text(verbatim: summary.hidden > 0 ? "…and \(summary.hidden) more. Review all of it before keeping it." : "Review all of it before keeping it.")
                            .font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(KubeResourceBanner.warning)
                    }
                }
                Spacer(minLength: 8)
                Button("Revert") { settings.revert(shown) }
                    .help("Write the values before back into settings.json")
                    .accessibilityIdentifier("settings.held.revert")
                if summary.keepInBanner {
                    Button("Keep") { settings.keep(shown) }
                        .help("Let the file's new values take effect")
                        .accessibilityIdentifier("settings.held.keep")
                } else {
                    Button("Review…") { reviewing = true }
                        .help("Every line of the change; Keep is there, once you have seen them all")
                        .accessibilityIdentifier("settings.held.review")
                        .popover(isPresented: $reviewing, arrowEdge: .bottom) {
                            SettingsHeldReview(settings: settings, shown: shown, lines: lines) { reviewing = false }
                                .id(lines)
                        }
                }
            }
            .controlSize(.small)
            .padding(10)
            .frame(maxWidth: 760)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 8).fill(KubeResourceBanner.warning.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(KubeResourceBanner.warning.opacity(0.6)))
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.held.banner")
        }
    }
}

/// Every line of a held change, each in full, scrolled through: Keep
/// turns on once the last has been on screen.
private struct SettingsHeldReview: View {
    @ObservedObject var settings: Settings
    let shown: [String: HeldSetting]
    let lines: [String]
    let done: () -> Void
    @State private var progress: HeldReviewProgress

    init(settings: Settings, shown: [String: HeldSetting], lines: [String], done: @escaping () -> Void) {
        self.settings = settings
        self.shown = shown
        self.lines = lines
        self.done = done
        _progress = State(initialValue: HeldReviewProgress(count: lines.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "settings.json changes \(lines.count) things outside Overterm:").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(verbatim: line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .onAppear { progress.saw(index) }
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 360)
            HStack {
                if !progress.canKeep {
                    Text("Scroll to the end to keep it.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") {
                    settings.revert(shown)
                    done()
                }
                Button("Keep") {
                    settings.keep(shown)
                    done()
                }
                .disabled(!progress.canKeep)
                .accessibilityIdentifier("settings.held.reviewKeep")
            }
        }
        .padding(14)
        .frame(width: 560)
    }
}
