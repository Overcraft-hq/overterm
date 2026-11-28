import AppKit
import SwiftUI

/// The Setup page (docs/design/onboarding/analysis.md, 7.7): one column
/// that scrolls, no text field. Each row says what was found and where
/// Overterm looked — its dot beside the words, never alone. A row's action
/// copies a command, types it into a new tab with no Return, opens a tool's
/// own page or a Settings page: nothing is fixed for the person (3.2).
///
/// Its sizes are `ChromeMetrics`', its colours the window's theme's. It is
/// opened only by the person — Help ▸ Check Setup…, ⌘K, the Start card,
/// the "isn't on your PATH" warning — and Esc gives the keyboard back to
/// the terminal (`SetupHostingView`).
package struct SetupView: View {
    @ObservedObject private var model: SetupPageModel
    @ObservedObject private var start: Start
    @ObservedObject private var theme: ChromeTheme
    private let perform: (SetupPageAction) -> Void

    package init(model: SetupPageModel, start: Start = .shared, theme: ChromeTheme, perform: @escaping (SetupPageAction) -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self._start = ObservedObject(wrappedValue: start)
        self._theme = ObservedObject(wrappedValue: theme)
        self.perform = perform
    }

    package var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                header
                core
                panels
                runsByItself
                gettingStarted
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SetupCheck.title)
        .accessibilityIdentifier("setup.page")
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: SetupCheck.title)
                    .font(.system(size: ChromeMetrics.text(20), weight: .semibold))
                    .foregroundStyle(theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(SetupCheck.checkAgain) { perform(.checkAgain) }
                    .controlSize(.small)
                    .accessibilityIdentifier("setup.checkAgain")
            }
            Text(verbatim: SetupCheck.note)
                .font(.system(size: ChromeMetrics.text(11.5)))
                .foregroundStyle(theme.text3)
                .accessibilityIdentifier("setup.note")
        }
    }

    @ViewBuilder private var core: some View {
        if let rows = model.rows {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows, id: \.id) { row in SetupRowView(row: row, theme: theme, perform: perform) }
            }
        } else {
            Text(verbatim: SetupCheck.asking)
                .font(.system(size: ChromeMetrics.text(12)))
                .foregroundStyle(theme.text2)
                .accessibilityIdentifier("setup.asking")
        }
    }

    /// "Tools the panels use": folded until opened — only then read, and
    /// only for the panels that are on.
    private var panels: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                perform(.panels(!model.panels.isOpen))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.panels.isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: ChromeMetrics.text(10), weight: .semibold))
                        .foregroundStyle(theme.text3)
                        .accessibilityHidden(true)
                    Text(verbatim: SetupCheck.panelsTitle + (model.panelRows.map { rows in " (\(rows.count))" } ?? ""))
                        .font(.system(size: ChromeMetrics.text(13), weight: .semibold))
                        .foregroundStyle(theme.text)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.panels.isOpen ? "open" : "folded")
            .accessibilityIdentifier("setup.panels")
            switch model.panels {
            case .closed:
                EmptyView()
            case .reading:
                Text(verbatim: SetupCheck.asking).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2)
            case .notLooked:
                Text(verbatim: SetupCheck.isolatedPanels).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2)
            case .read:
                Text(verbatim: SetupCheck.panelsNote)
                    .font(.system(size: ChromeMetrics.text(11)))
                    .foregroundStyle(theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.panelRows ?? [], id: \.id) { row in SetupRowView(row: row, theme: theme, perform: perform) }
            }
        }
    }

    private var runsByItself: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(SetupCheck.runsByItselfTitle)
            Toggle(isOn: Binding(get: { model.usageAsk }, set: { on in perform(.usageAsk(on)) })) {
                Text(verbatim: SetupCheck.usageTitle).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("setup.usageAsk")
            Text(verbatim: SetupCheck.usageDetail)
                .font(.system(size: ChromeMetrics.text(11)))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(SetupCheck.gettingStartedTitle)
            Text(verbatim: SetupCheck.stepTimes(start.state.steps, firstLaunch: start.firstLaunch) ?? SetupCheck.noStepsYet)
                .font(.system(size: ChromeMetrics.text(12)))
                .foregroundStyle(theme.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup.steps")
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: SetupCheck.keptHere).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                Spacer()
                if start.active {
                    Button(SetupCheck.resetTips) { perform(.resetTips) }
                        .controlSize(.small)
                        .accessibilityIdentifier("setup.resetTips")
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.system(size: ChromeMetrics.text(13), weight: .semibold))
            .foregroundStyle(theme.text)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One row: its dot, its name, what was found and where Overterm looked,
/// then what can be done.
package struct SetupRowView: View {
    let row: SetupRow
    @ObservedObject var theme: ChromeTheme
    let perform: (SetupPageAction) -> Void
    @State private var expanded = false

    package init(row: SetupRow, theme: ChromeTheme, perform: @escaping (SetupPageAction) -> Void) {
        self.row = row
        self._theme = ObservedObject(wrappedValue: theme)
        self.perform = perform
    }

    package var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: row.found ? "circle.fill" : "circle")
                .font(.system(size: ChromeMetrics.text(8)))
                .foregroundStyle(row.isProblem ? theme.orangeText : (row.found ? theme.greenText : theme.text3))
                .accessibilityHidden(true)
            Text(verbatim: row.title)
                .font(.system(size: ChromeMetrics.text(12), weight: .medium))
                .foregroundStyle(theme.text)
                .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.detail)
                    .font(.system(size: ChromeMetrics.text(12)))
                    .foregroundStyle(row.isProblem ? theme.orangeText : theme.text2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup.detail.\(row.id.key)")
                if let looked = row.looked {
                    Text(verbatim: looked)
                        .font(.system(size: ChromeMetrics.text(10.5)))
                        .foregroundStyle(theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.more.isEmpty {
                    Button(expanded ? "Hide Each" : "Show Each") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: ChromeMetrics.text(10.5)))
                        .foregroundStyle(theme.accentText)
                        .accessibilityIdentifier("setup.more.\(row.id.key)")
                    if expanded {
                        ForEach(row.more, id: \.self) { line in
                            Text(verbatim: line).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text2).textSelection(.enabled)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.title), \(row.detail)")
        .accessibilityIdentifier("setup.row.\(row.id.key)")
    }

    @ViewBuilder private var actions: some View {
        switch row.action {
        case .command(let command)?:
            HStack(spacing: 6) {
                Button(SetupCheck.copy + " " + command) { perform(.copy(command)) }
                    .accessibilityIdentifier("setup.copy.\(row.id.key)")
                Button(SetupCheck.putInNewTab) { perform(.newTab(command)) }
                    .accessibilityIdentifier("setup.newTab.\(row.id.key)")
            }
            .controlSize(.small)
        case .page(let url)?:
            Button(SetupCheck.installPage) { perform(.open(url)) }
                .controlSize(.small)
                .accessibilityIdentifier("setup.page.\(row.id.key)")
        case .settings(let section, let key)?:
            Button(StartText.settingsName(section)) { perform(.settings(section, key: key)) }
                .controlSize(.small)
                .accessibilityIdentifier("setup.settings.\(row.id.key)")
        case .allowNotifications?:
            Button(SetupCheck.allowNotifications) { perform(.allowNotifications) }
                .controlSize(.small)
                .accessibilityIdentifier("setup.allow.\(row.id.key)")
        case nil:
            EmptyView()
        }
    }
}

/// The page's host: it takes the keyboard when the person opens the page
/// (`showOverlay`), and Esc — on it or on a control inside — closes the
/// page and gives the keyboard back to the selected terminal.
package final class SetupHostingView: NSHostingView<SetupView> {
    package var escape: (@MainActor () -> Void)?

    package override var acceptsFirstResponder: Bool { true }

    package override func cancelOperation(_ sender: Any?) { escape?() }

    package override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let escape { return escape() }
        super.keyDown(with: event)
    }
}
