import AppKit
import SwiftUI

// MARK: Builds

/// The builds `buildx history` keeps — a running one first, its time
/// counting — and beside them the one selected, step by step as BuildKit
/// reports it. The list is read by the page's poll, not on appearing; the
/// detail's session is the page's (`updateBuildStream`), only looked up
/// here: made or closed while a view draws, it would publish from there.
struct DockerBuildsView: View {
    @ObservedObject var page: DockerPageModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    var body: some View {
        HStack(spacing: 0) {
            if let error = page.buildsError {
                VStack(spacing: 10) {
                    Text(verbatim: error).font(.system(size: 12)).foregroundStyle(theme.text2).multilineTextAlignment(.center).textSelection(.enabled)
                    Button("Read Again") { page.loadBuilds() }.controlSize(.small).accessibilityIdentifier("docker.builds.again")
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $page.buildSelection) {
                    ForEach(page.builds) { build in
                        DockerBuildRow(build: build, theme: theme)
                            .tag(build.id)
                            .listRowSeparator(.hidden)
                            .contextMenu { DockerVerbMenu(verbs: page.verbs(for: build)) }
                    }
                    if page.builds.isEmpty { Text("No builds yet.").font(.system(size: 12)).foregroundStyle(theme.text3) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("docker.builds")
                if page.showDetail, let build = page.detailedBuild {
                    Rectangle().fill(theme.border).frame(width: 1)
                    Group {
                        if let session = page.buildSession, session.ref == build.shortRef {
                            DockerBuildDetailView(build: build, session: session, page: page, theme: theme, actions: actions)
                        } else {
                            // A turn of the run loop, until the page has made it.
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .id(build.id)
                    .frame(width: 520)
                }
            }
        }
    }
}

/// A build in the list: a running one's time ticks, once a second, only
/// while it runs.
private struct DockerBuildRow: View {
    let build: DockerBuildRecord
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if build.running {
            TimelineView(.periodic(from: .now, by: 1)) { context in row(now: context.date) }
        } else {
            row(now: Date())
        }
    }

    private func row(now: Date) -> some View {
        DockerResourceRow(
            symbol: build.failed ? "xmark.octagon" : build.running ? "hourglass" : "checkmark.circle",
            title: build.name, subtitle: "\(build.status) · \(build.shortRef.prefix(12))",
            figures: build.running
                ? ["running", DockerBuildRecord.duration(build.elapsed(now: now)) + "…"]
                : [
                    "\(build.cachedSteps)/\(build.totalSteps) cached", build.duration.map(DockerBuildRecord.duration) ?? "…",
                    DockerBuildRecord.date(build.createdAt).map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now) } ?? "",
                ],
            dim: false, theme: theme)
    }
}

/// A build beside the list: how it went, where it was built from, its
/// Dockerfile's warnings and where it failed, then its steps.
struct DockerBuildDetailView: View {
    let build: DockerBuildRecord
    @ObservedObject var session: DockerBuildSession
    @ObservedObject var page: DockerPageModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    glyph
                    Text(verbatim: build.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                DockerActionBar(verbs: page.verbs(for: build), theme: theme)
                summary
                if let detail = session.detail { builtFrom(detail) }
                failure
                warnings
            }
            .padding(16)
            Rectangle().fill(theme.border).frame(height: 1)
            DockerBuildStepsView(session: session, theme: theme)
        }
        .accessibilityIdentifier("docker.build.detail")
    }

    @ViewBuilder private var glyph: some View {
        let status = session.detail?.status
        if session.isRunning || (build.running && session.state != .ended) {
            Image(systemName: "hourglass").foregroundStyle(TabStatusStyle.working)
        } else if build.failed || status == "failed" || session.progress.failedStep != nil {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(TabStatusStyle.failed)
        } else if status == "canceled" || build.status.lowercased() == "canceled" {
            Image(systemName: "minus.circle.fill").foregroundStyle(theme.text3)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(TabStatusStyle.done)
        }
    }

    /// Its time ticks while it runs.
    @ViewBuilder private var summary: some View {
        Group {
            if session.isRunning {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in summaryText(context.date) }
            } else {
                summaryText(Date())
            }
        }
        .accessibilityIdentifier("docker.build.summary")
    }

    private func summaryText(_ now: Date) -> some View {
        Text(verbatim: session.summaryLine(now: now)).font(.system(size: 11.5)).foregroundStyle(theme.text2).lineLimit(1)
    }

    private func builtFrom(_ detail: DockerBuildDetail) -> some View {
        DockerDetailBlock(title: "Built from", theme: theme) {
            if let context = detail.context { DockerDetailRow(key: "Context", value: (context as NSString).abbreviatingWithTildeInPath, theme: theme) }
            if let file = detail.dockerfile { DockerDetailRow(key: "Dockerfile", value: file, theme: theme) }
            if let revision = detail.revision { DockerDetailRow(key: "Commit", value: String(revision.prefix(12)), theme: theme) }
            // A detail's top stays short: the steps are what it is for.
            ForEach(Array(detail.buildArgs.prefix(5).enumerated()), id: \.offset) { _, arg in DockerDetailRow(key: arg.key, value: arg.value, theme: theme) }
            if detail.buildArgs.count > 5 {
                Text(verbatim: "and \(detail.buildArgs.count - 5) more build args").font(.system(size: 11)).foregroundStyle(theme.text3)
            }
        }
    }

    /// BuildKit's error, and where in the Dockerfile (its `>>>` excerpt).
    @ViewBuilder private var failure: some View {
        if let detail = session.detail, let error = detail.error {
            Text(verbatim: error).font(.system(size: 12)).foregroundStyle(TabStatusStyle.failed).textSelection(.enabled).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if let source = detail.errorSource?.trimmingCharacters(in: .newlines), !source.isEmpty {
                Text(verbatim: source.split(separator: "\n", omittingEmptySubsequences: false).suffix(8).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover))
                    .accessibilityIdentifier("docker.build.source")
            }
        }
    }

    /// The Dockerfile's checks (BuildKit's lint): folded, each with its line.
    /// Only once the build args are known: a line of the Dockerfile can be
    /// a secret one's value expanded.
    @ViewBuilder private var warnings: some View {
        let warnings = session.progress.warnings
        if !warnings.isEmpty, session.secretsKnown {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in row(warning) }
                }
                .padding(.top, 4)
            } label: {
                Label {
                    Text(verbatim: warnings.count == 1 ? "1 warning" : "\(warnings.count) warnings").font(.system(size: 11.5, weight: .medium))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TabStatusStyle.waiting)
                }
                .foregroundStyle(theme.text2)
            }
            .accessibilityIdentifier("docker.build.warnings")
        }
    }

    private func row(_ warning: DockerBuildProgress.Warning) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: session.shown(warning.short)).font(.system(size: 11.5)).foregroundStyle(theme.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let link = warning.url, let url = URL(string: link) {
                    Button("Rule") { actions.open(url) }.buttonStyle(.link).font(.system(size: 11)).help(link)
                }
            }
            if let file = warning.file {
                Text(verbatim: warning.line.map { "\(file):\($0)" } ?? file).font(.system(size: 10.5)).foregroundStyle(theme.text3)
            }
            if let source = warning.source {
                Text(verbatim: session.shown(source)).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text2).lineLimit(1)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The steps, as a list, and the shown one's output under it. By default
/// it follows the build (`automaticStep`); a step clicked is kept until
/// Follow the Build. Nothing of them shows until the build args are known
/// (`secretsKnown`): BuildKit expands an ARG into a RUN step's name.
struct DockerBuildStepsView: View {
    @ObservedObject var session: DockerBuildSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        let steps = session.progress.steps
        if steps.isEmpty || !session.secretsKnown {
            empty(hasSteps: !steps.isEmpty).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if case .failed(let why) = session.state { lost(why) }
                    list(steps).frame(height: max(80, geometry.size.height * 0.42))
                    Rectangle().fill(theme.border).frame(height: 1)
                    if let step = session.shownStep {
                        DockerBuildStepPane(step: step, state: session.progress.state(of: step), session: session, theme: theme)
                    }
                }
            }
        }
    }

    private func empty(hasSteps: Bool) -> some View {
        VStack(spacing: 8) {
            if case .failed(let why) = session.state {
                Text(verbatim: session.shown(why)).foregroundStyle(theme.text2).multilineTextAlignment(.center).textSelection(.enabled)
                Text("Log in a Tab (t) shows what buildx says.").foregroundStyle(theme.text3)
                readAgain
            } else if hasSteps, session.detailFailed {
                Text("Its steps stay hidden: buildx didn't say this build's args, and a step's name can hold a secret one's value.")
                    .foregroundStyle(theme.text2).multilineTextAlignment(.center)
                Text("Log in a Tab (t) shows buildx's own log.").foregroundStyle(theme.text3)
                readAgain
            } else if session.state == .ended, !hasSteps {
                Text("This build's record kept no log.").foregroundStyle(theme.text3)
            } else {
                ProgressView().controlSize(.small)
                Text("Reading the build…").foregroundStyle(theme.text3)
            }
        }
        .font(.system(size: 12))
        .padding(20)
        .accessibilityIdentifier("docker.build.empty")
    }

    /// Asks buildx again: the follow, the inspect, whichever didn't answer.
    private var readAgain: some View {
        Button("Read Again") { session.follow(shown: true) }.controlSize(.small).accessibilityIdentifier("docker.build.again")
    }

    /// The follow broke off with steps read: why, over them — which stay,
    /// those still open then no longer drawn as running.
    private func lost(_ why: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(TabStatusStyle.waiting)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Stopped following: " + session.shown(why)).font(.system(size: 11.5)).foregroundStyle(theme.text2).lineLimit(3)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Log in a Tab (t) shows what buildx says.").font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            Spacer(minLength: 6)
            readAgain
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityIdentifier("docker.build.lost")
    }

    private func list(_ steps: [DockerBuildProgress.Step]) -> some View {
        let shown = session.shownStep?.id
        return VStack(spacing: 0) {
            if session.state == .reading, session.picked != nil {
                HStack {
                    Spacer()
                    Button("Follow the Build") { session.picked = nil }.controlSize(.small)
                        .help("Show the step that is writing, or the one that failed")
                        .accessibilityIdentifier("docker.build.follow")
                }
                .padding(.horizontal, 10).padding(.top, 6)
            }
            ScrollViewReader { proxy in
                List(selection: Binding(get: { session.shownStep?.id }, set: { session.picked = $0 })) {
                    ForEach(steps) { step in
                        DockerBuildStepRow(step: step, state: session.progress.state(of: step), shown: session.shown, theme: theme)
                            .tag(Optional(step.id))
                            .id(step.id)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("docker.build.steps")
                .onChange(of: shown) { id in
                    // Kept in sight while it follows the build.
                    if session.picked == nil, let id { proxy.scrollTo(id) }
                }
            }
        }
    }
}

/// A step's row: how it is, its number and name, how long it took.
private struct DockerBuildStepRow: View {
    let step: DockerBuildProgress.Step
    let state: DockerBuildProgress.Step.State
    let shown: (String) -> String
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                glyph.frame(width: 14, height: 14)
                Text(verbatim: "#\(step.number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
                    .frame(minWidth: 26, alignment: .leading)
                Text(verbatim: shown(step.name)).font(.system(size: 12)).foregroundStyle(step.isInternal ? theme.text3 : theme.text)
                    .lineLimit(1).truncationMode(.middle)
                if !step.warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(TabStatusStyle.waiting)
                        .help(step.warnings.map { shown($0.short) }.joined(separator: "\n"))
                }
                Spacer(minLength: 6)
                trailing
            }
            if state == .failed, let error = step.error {
                Text(verbatim: shown(error)).font(.system(size: 10.5)).foregroundStyle(TabStatusStyle.failed).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 46)
            }
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder private var glyph: some View {
        switch state {
        case .running: ProgressView().controlSize(.mini)
        case .done, .cached: Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.text3)
        case .failed: Image(systemName: "xmark.octagon.fill").font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed)
        case .canceled: Image(systemName: "minus.circle").font(.system(size: 11)).foregroundStyle(theme.text3)
        case .unknown: Image(systemName: "questionmark.circle").font(.system(size: 11)).foregroundStyle(theme.text3)
        }
    }

    @ViewBuilder private var trailing: some View {
        let font = Font.system(size: 10.5, design: .monospaced)
        switch state {
        case .cached: Text(verbatim: "CACHED").font(font).foregroundStyle(theme.text3)
        case .failed: Text(verbatim: "ERROR").font(font).foregroundStyle(TabStatusStyle.failed)
        case .canceled: Text(verbatim: "CANCELED").font(font).foregroundStyle(theme.text3)
        case .unknown: Text(verbatim: "?").font(font).foregroundStyle(theme.text3).help("Still running when the follow stopped")
        case .running:
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(verbatim: DockerBuildRecord.duration(step.duration(until: context.date))).font(font).foregroundStyle(TabStatusStyle.working)
            }
        case .done: Text(verbatim: DockerBuildRecord.duration(step.duration(until: Date()))).font(font).foregroundStyle(theme.text3)
        }
    }
}

/// The shown step: its name, how it went, its sub-progress, its error,
/// then its output as plain progress prints it.
private struct DockerBuildStepPane: View {
    let step: DockerBuildProgress.Step
    let state: DockerBuildProgress.Step.State
    @ObservedObject var session: DockerBuildSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "#\(step.number) " + session.shown(step.name)).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text)
                    .lineLimit(2).textSelection(.enabled)
                if state == .running {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in stateLine(context.date) }
                } else {
                    stateLine(Date())
                }
                ForEach(step.statuses.prefix(6), id: \.id) { status in
                    Text(verbatim: session.shown(status.plain)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3).lineLimit(1)
                        .truncationMode(.middle)
                }
                if step.statuses.count > 6 {
                    Text(verbatim: "and \(step.statuses.count - 6) more").font(.system(size: 10.5)).foregroundStyle(theme.text3)
                }
                if state == .failed, let error = step.error {
                    Text(verbatim: session.shown(error)).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.failed).textSelection(.enabled)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(theme.border).frame(height: 1)
            if step.log.isEmpty {
                Text("No output.").font(.system(size: 12)).foregroundStyle(theme.text3).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                output
            }
            if step.clipped {
                Text("Output clipped at 2 MB: Log in a Tab (t) has all of it.").font(.system(size: 11)).foregroundStyle(theme.text3)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
    }

    private func stateLine(_ now: Date) -> some View {
        let time = DockerBuildRecord.duration(step.duration(until: now))
        let text: String =
            switch state {
            case .running: "Running · " + time
            case .done: "Done in " + time
            case .cached: "From the cache"
            case .failed: "Failed after " + time
            case .canceled: "Canceled: another step failed, or the build was stopped"
            case .unknown: "Still running when the follow stopped: Read Again to see how it went"
            }
        return Text(verbatim: text).font(.system(size: 11)).foregroundStyle(state == .running ? TabStatusStyle.working : theme.text3)
    }

    /// Its offsets dim, as plain progress has them; a line's level in its
    /// colour. Drawn again, not added to, when another read starts or the
    /// step changes. The secrets are known before it is drawn at all.
    private var output: some View {
        let lines = step.log
        let text = theme.textNS
        let dim = text.withAlphaComponent(0.45)
        let secrets = session.detail?.secrets ?? []
        let revision = session.generation &* 100_000 &+ step.number
        return DockerTextView(
            count: lines.count, revision: revision,
            render: { range in
                lines[range].map { line in
                    let body = DockerSecrets.redact(line.text, values: secrets)
                    let color = DockerLogStyle.color(DockerLogLine.inlineLevel(body)) ?? (line.stderr ? text.withAlphaComponent(0.85) : text)
                    let out = NSMutableAttributedString(string: line.offsetText + "  ", attributes: [.font: DockerLogStyle.font, .foregroundColor: dim])
                    out.append(NSAttributedString(string: body, attributes: [.font: DockerLogStyle.font, .foregroundColor: color]))
                    return out
                }
            }, wrap: true, follow: true)
    }
}
