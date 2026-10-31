import SwiftUI

/// A severity's colour: red, orange, yellow, then the theme's quieter text.
enum DockerScoutStyle {
    @MainActor static func color(_ severity: DockerScoutSeverity, theme: ChromeTheme) -> Color {
        switch severity {
        case .critical: TabStatusStyle.failed
        case .high: TabStatusStyle.waiting
        case .medium: TabStatusStyle.signal
        case .low: theme.text2
        case .unspecified: theme.text3
        }
    }
}

/// An image's Vulnerabilities tab: what Docker Scout does and what it
/// sends, until Scan is pressed; then its progress, and what it found —
/// by severity, worst first, filtered as the window last filtered it. It
/// reads only what the app's scans hold; nothing runs because it shows.
struct DockerScoutPane: View {
    let image: ImageSummary
    @ObservedObject var scans: DockerScoutScans
    @ObservedObject var page: DockerPageModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    /// The rows opened on their advisory's words.
    @State private var expanded: Set<String> = []
    @Environment(\.dockerShown) private var shown

    var body: some View {
        Group {
            if let name = image.tags.first {
                if let scan = scans.scan(for: image.Id) {
                    switch scan.state {
                    case .scanning(let since, let progress): scanning(name, since: since, progress: progress)
                    case .done(let report, let at): done(report, at: at, name: name)
                    case .failed(let failure, _): failed(failure, name: name)
                    }
                } else if page.hasScout {
                    intro(name)
                } else {
                    padded { problem(DockerScoutFailure.notInstalled.message) }
                }
            } else {
                padded {
                    note("Scout scans an image by its name; this one has none — tag it first.")
                    if let tag = page.verbs(for: image).first(where: { $0.title == "Tag…" }) { Button("Tag…") { tag.perform() } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("docker.scout")
    }

    // MARK: Before, during, failed

    private func intro(_ name: String) -> some View {
        padded {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 20)).foregroundStyle(theme.text3)
                Text("Docker Scout").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            }
            note(
                "Scout matches the packages in \(name) against known vulnerabilities: each CVE, the package it is in, the version here and the one that fixes it."
            )
            Text("A scan sends the image's list of packages to Docker's service, signed in as you. That is why it runs only when you press Scan.")
                .font(.system(size: 12)).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
            // Scan is no default button: Return is the page's ↩, pressed out
            // of habit, and a scan sends the packages away — it takes a click.
            HStack(spacing: 8) {
                Button("Scan") { page.scanVulnerabilities(image) }
                    .accessibilityIdentifier("docker.scout.scan")
                Button("In a Tab") { page.scout("cves", name) }
                    .help("docker scout cves \(name), in a terminal tab")
            }
            .padding(.top, 4)
        }
    }

    private func scanning(_ name: String, since: Date, progress: String?) -> some View {
        padded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                // The clock ticks only while someone can see it.
                if shown {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(verbatim: "Scanning \(name) — \(Self.elapsed(context.date.timeIntervalSince(since)))")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.text)
                    }
                } else {
                    Text(verbatim: "Scanning \(name)…").font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.text)
                }
            }
            Text(verbatim: progress ?? "Starting Docker Scout…").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2)
                .lineLimit(3).textSelection(.enabled)
                .accessibilityIdentifier("docker.scout.progress")
            Button("Cancel") { page.cancelScan(image) }
                .accessibilityIdentifier("docker.scout.cancel")
        }
    }

    private func failed(_ failure: DockerScoutFailure, name: String) -> some View {
        padded {
            problem(failure.message)
            HStack(spacing: 8) {
                if failure == .signedOut {
                    Button("Sign In in a Tab") { page.signInToDocker() }
                        .help("docker login, in a terminal tab")
                        .accessibilityIdentifier("docker.scout.signin")
                    Button("Scan Again") { page.scanVulnerabilities(image) }
                } else {
                    Button("Scan Again") { page.scanVulnerabilities(image) }
                    Button("Run in a Tab") { page.scout("cves", name) }
                }
            }
        }
    }

    // MARK: Done

    private func done(_ report: DockerScoutReport, at: Date, name: String) -> some View {
        let groups = page.scoutFilter.groups(report.findings)
        return VStack(alignment: .leading, spacing: 0) {
            toolbar(report, at: at, name: name, shown: groups.flatMap(\.findings))
            Rectangle().fill(theme.border).frame(height: 1)
            if report.findings.isEmpty {
                padded {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield").font(.system(size: 18)).foregroundStyle(TabStatusStyle.done)
                        Text(verbatim: "No known vulnerabilities" + (report.packagesIndexed.map { " in its \($0) packages" } ?? ""))
                            .font(.system(size: 12.5)).foregroundStyle(theme.text)
                    }
                }
            } else if groups.isEmpty {
                padded {
                    note("Nothing matches.")
                    Button("Show All") { page.scoutFilter = DockerScoutFilter() }
                }
            } else {
                list(groups, dropped: report.dropped)
            }
        }
    }

    private func toolbar(_ report: DockerScoutReport, at: Date, name: String, shown: [DockerScoutFinding]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                chips(report, titled: true)
                chips(report, titled: false)
            }
            HStack(spacing: 8) {
                Toggle("Fixable only", isOn: $page.scoutFilter.fixableOnly)
                    .toggleStyle(.checkbox).font(.system(size: 11.5))
                    .accessibilityIdentifier("docker.scout.fixable")
                TextField("CVE or package", text: $page.scoutFilter.text)
                    .textFieldStyle(.roundedBorder).controlSize(.small).font(.system(size: 11.5))
                    .accessibilityIdentifier("docker.scout.filter")
            }
            HStack(spacing: 8) {
                TimelineView(.everyMinute) { _ in
                    Text(verbatim: "scanned " + UsageFormat.age(at) + " · " + report.sentence)
                        .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.tail)
                }
                .help(report.scoutVersion.map { "Docker Scout \($0)" } ?? "Docker Scout")
                Spacer(minLength: 6)
                Button {
                    page.scanVulnerabilities(image)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Scan Again")
                .accessibilityIdentifier("docker.scout.again")
                Menu {
                    Button("Copy the List") { actions.copy(report.lines(shown, limit: .max)) }
                    Button("Vulnerabilities in a Tab") { page.scout("cves", name) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityIdentifier("docker.scout.more")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// One chip a severity, its count of the whole report: a click shows
    /// or hides it.
    private func chips(_ report: DockerScoutReport, titled: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(DockerScoutSeverity.allCases) { severity in
                let count = report.count(severity)
                let on = page.scoutFilter.severities.contains(severity)
                Button {
                    if on { page.scoutFilter.severities.remove(severity) } else { page.scoutFilter.severities.insert(severity) }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(DockerScoutStyle.color(severity, theme: theme)).frame(width: 7, height: 7)
                        if titled { Text(severity.title).foregroundStyle(theme.text2) }
                        Text(verbatim: "\(count)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(theme.text)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on && count > 0 ? theme.rowHover : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border))
                    .opacity(on && count > 0 ? 1 : 0.45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(count == 0)
                .help(on ? "Hide \(severity.title.lowercased())" : "Show \(severity.title.lowercased())")
                .accessibilityIdentifier("docker.scout.severity.\(severity.title)")
            }
        }
    }

    private func list(_ groups: [DockerScoutGroup], dropped: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.findings) { finding in
                            DockerScoutRow(
                                finding: finding, expanded: expanded.contains(finding.id), theme: theme, actions: actions,
                                toggle: {
                                    if expanded.contains(finding.id) { expanded.remove(finding.id) } else { expanded.insert(finding.id) }
                                })
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(DockerScoutStyle.color(group.severity, theme: theme)).frame(width: 7, height: 7)
                            Text(verbatim: "\(group.severity.title.uppercased()) · \(group.findings.count)")
                                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.text3)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.term)
                    }
                }
                if dropped > 0 {
                    Text(verbatim: "… and \(dropped) more Scout listed, left out")
                        .font(.system(size: 11)).foregroundStyle(theme.text3).padding(14)
                }
            }
        }
        .accessibilityIdentifier("docker.scout.list")
    }

    // MARK: Pieces

    private func padded<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
    }

    private func problem(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TabStatusStyle.failed)
            Text(verbatim: message).font(.system(size: 12)).foregroundStyle(theme.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(TabStatusStyle.failed.opacity(0.12)))
        .accessibilityIdentifier("docker.scout.problem")
    }

    /// `0:07`, `12:30`.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// One vulnerability in one package: its id (the advisory a click away),
/// Scout's score, the package, the version here and the fix. A click
/// opens the advisory's words.
private struct DockerScoutRow: View {
    let finding: DockerScoutFinding
    let expanded: Bool
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(DockerScoutStyle.color(finding.severity, theme: theme)).frame(width: 7, height: 7)
                Button {
                    if let advisory = finding.advisory { actions.open(advisory) }
                } label: {
                    Text(verbatim: finding.vulnerability).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(finding.advisory == nil ? theme.text : theme.accentText)
                }
                .buttonStyle(.plain)
                .disabled(finding.advisory == nil)
                .help(finding.advisory?.absoluteString ?? "")
                Spacer(minLength: 6)
                if let score = finding.score, finding.severity != .unspecified {
                    Text(verbatim: DockerScoutReport.score(score)).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text2)
                        .help("Scout's score (security-severity): the advisory's CVSS where it has one")
                }
            }
            HStack(spacing: 5) {
                Text(verbatim: finding.package.displayName).font(.system(size: 11.5)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                if let version = finding.package.version {
                    Text(verbatim: version).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.middle)
                }
                if let fixed = finding.fixedIn {
                    Text(verbatim: "→ fixed in \(fixed)").font(.system(size: 11)).foregroundStyle(theme.greenText).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("no fix yet").font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let type = finding.package.type { Text(verbatim: type).font(.system(size: 10.5)).foregroundStyle(theme.text3) }
            }
            .padding(.leading, 13)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let summary = finding.summary {
                        Text(verbatim: summary).font(.system(size: 11.5)).foregroundStyle(theme.text2)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    let facts = [finding.affected.map { "affected \($0)" }, finding.epss.map { "EPSS " + String(format: "%.2f%%", $0 * 100) }]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !facts.isEmpty {
                        Text(verbatim: facts).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3).textSelection(.enabled)
                    }
                }
                .padding(.leading, 13)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(expanded ? theme.rowHover.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .contextMenu {
            if let advisory = finding.advisory { Button("Open Advisory") { actions.open(advisory) } }
            Button("Copy ID") { actions.copy(finding.vulnerability) }
            Button("Copy Package") { actions.copy(finding.package.reference) }
            if let fixed = finding.fixedIn { Button("Copy Fixed Version") { actions.copy(fixed) } }
        }
        .accessibilityIdentifier("docker.scout.row.\(finding.vulnerability)")
    }
}
