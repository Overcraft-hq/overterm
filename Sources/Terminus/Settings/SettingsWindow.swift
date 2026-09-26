import AppKit
import Combine
import SwiftUI

/// Terminus ▸ Settings… (⌘,): one window, reused.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    let model = SettingsViewModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.minSize = NSSize(width: 640, height: 420)
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model, settings: .shared))
        window.setFrameAutosaveName("TerminusSettings")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ section: SettingsSection? = nil) {
        if let section { model.section = section }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The window's sections, as in the list on its left.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, agents, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .agents: "Agents"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .agents: "sparkle"
        case .shortcuts: "keyboard"
        }
    }

    /// What the search matches besides the title: the settings in it.
    var keywords: [String] {
        switch self {
        case .general: ["restore", "session", "tabs", "scrollback", "new tab", "folder", "home", "close", "confirm", "notifications", "dock", "badge"]
        case .appearance: ["font", "size", "theme", "colour", "color", "padding", "cursor", "dim", "split", "pane", "ghostty"]
        case .agents: ["claude", "codex", "model", "arguments", "flags", "task", "worktree", "branch", "base"]
        case .shortcuts: ["keys", "keybind", "hotkey", "split", "search", "copy", "paste", "tab", "pane", "click"]
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return title.lowercased().contains(query) || keywords.contains { $0.contains(query) }
    }
}

/// What the window shows, and the lists its pickers offer.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var section: SettingsSection = .general
    @Published var search = ""

    /// Fixed-pitch font families, for the font picker.
    lazy var monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { family in
        guard let member = NSFontManager.shared.availableMembers(ofFontFamily: family)?.first, let name = member.first as? String else { return false }
        return NSFont(name: name, size: 12)?.isFixedPitch == true
    }

    /// Ghostty's bundled themes (Contents/Resources/ghostty/themes).
    lazy var themes: [String] = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes") else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    var sections: [SettingsSection] { SettingsSection.allCases.filter { $0.matches(search) } }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.bottom, 4)
                ForEach(model.sections) { section in
                    Button {
                        model.section = section
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(model.section == section ? Color.accentColor.opacity(0.22) : .clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 200)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(model.section.title).font(.title2.weight(.semibold))
                    switch model.section {
                    case .general: GeneralSettings(settings: settings)
                    case .appearance: AppearanceSettings(settings: settings, model: model)
                    case .agents: AgentSettings(settings: settings)
                    case .shortcuts: ShortcutSettings()
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: model.search) { _ in
            if let first = model.sections.first, !model.sections.contains(model.section) { model.section = first }
        }
    }
}

/// A titled group of rows.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}

/// A row's explanation, under it.
struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var settings: Settings

    var body: some View {
        SettingsGroup(title: "Startup") {
            Toggle("Reopen the last session's tabs", isOn: $settings.restoreTabs)
            Toggle("…with each shell pane's text", isOn: $settings.restoreScrollback)
                .disabled(!settings.restoreTabs)
                .padding(.leading, 20)
            SettingsNote("Agent tabs resume their conversation either way. A pane's text is its last 2000 lines, saved at quit.")
        }
        SettingsGroup(title: "Tabs") {
            Picker("New tabs open in", selection: $settings.newTabDirectory) {
                Text("The current tab's folder").tag(Settings.NewTabDirectory.current)
                Text("Home").tag(Settings.NewTabDirectory.home)
            }
            .fixedSize()
            Picker("Ask before closing", selection: $settings.confirmClose) {
                Text("Always").tag(Settings.CloseConfirmation.always)
                Text("Only when something is running").tag(Settings.CloseConfirmation.whenRunning)
            }
            .fixedSize()
            SettingsNote("Tabs, the window and quitting. A pane of a split asks only when something runs in it.")
        }
        SettingsGroup(title: "When a tab needs you") {
            Toggle("Notifications while Terminus is in the background", isOn: $settings.notifications)
            Toggle("Count them on the Dock icon", isOn: $settings.dockBadge)
        }
    }
}

private struct ShortcutSettings: View {
    @State private var filter = ""
    @State private var shortcuts: [Shortcut] = []

    var body: some View {
        TextField("Filter shortcuts", text: $filter)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 380)
        ForEach(Shortcut.Group.allCases, id: \.self) { group in
            let rows = shortcuts.filter { $0.group == group && $0.matches(filter) }
            if !rows.isEmpty {
                SettingsGroup(title: group.rawValue) {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack {
                                Text(verbatim: row.title).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 12)
                                Text(verbatim: row.keys)
                                    .font(.system(.body, design: .rounded).weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                            }
                            .padding(.vertical, 4)
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
        SettingsNote(
            "A menu's shortcut changes in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts. The terminal's come from your Ghostty config: a line like keybind = cmd+d=new_split:right."
        )
        .onAppear { shortcuts = Shortcuts.all() }
    }
}

private struct AgentSettings: View {
    @ObservedObject var settings: Settings

    var body: some View {
        SettingsGroup(title: "Arguments") {
            argumentField("Claude", text: $settings.claudeArguments, example: "--model opus")
            argumentField("Codex", text: $settings.codexArguments, example: "-m gpt-5")
            SettingsNote(
                "Added wherever the agent starts or picks up again: ⌥⌘C / ⌥⌘X, New Task, tabs reopened at launch, and Sessions' resume."
            )
        }
        SettingsGroup(title: "New Task") {
            Picker("Starts", selection: $settings.taskAgent) {
                ForEach(Agent.allCases) { Text($0.name).tag($0.rawValue) }
                Text("A shell only").tag("shell")
            }
            .fixedSize()
            Picker("Worktrees go", selection: $settings.worktreeLocation) {
                Text("Next to the repository — repo-wt-branch").tag(Settings.WorktreeLocation.sibling)
                Text("Inside it — repo/.worktrees/branch").tag(Settings.WorktreeLocation.inside)
            }
            .fixedSize()
            SettingsNote("Inside the repository, .worktrees/ is added to its local exclude file (.git/info/exclude) — no tracked file changes.")
            TextField("New branches start from", text: $settings.taskBase, prompt: Text("the main worktree's branch"))
                .frame(maxWidth: 380)
        }
    }

    private func argumentField(_ name: String, text: Binding<String>, example: String) -> some View {
        TextField(name, text: text, prompt: Text(example))
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: 380)
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var settings: Settings
    let model: SettingsViewModel

    private var configFontSize: Double { GhosttyRuntime.shared.configNumber("font-size") ?? 13 }

    var body: some View {
        SettingsNote(
            "These override your Ghostty config (~/.config/ghostty/config) and apply to every terminal at once; left at \"From your Ghostty config\", it decides."
        )
        SettingsGroup(title: "Text") {
            Picker("Font", selection: $settings.fontFamily) {
                Text("From your Ghostty config").tag(String?.none)
                Divider()
                ForEach(model.monospacedFamilies, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: 380)
            HStack {
                Stepper(
                    value: Binding(get: { settings.fontSize ?? configFontSize }, set: { settings.fontSize = $0 }), in: 8...32, step: 1
                ) {
                    Text(verbatim: "Size \(Int(settings.fontSize ?? configFontSize)) pt")
                }
                if settings.fontSize != nil { Button("Reset") { settings.fontSize = nil }.controlSize(.small) }
            }
        }
        SettingsGroup(title: "Colours") {
            Picker("Theme", selection: $settings.theme) {
                Text("From your Ghostty config").tag(String?.none)
                Divider()
                ForEach(model.themes, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: 380)
            SettingsNote("The terminal changes at once; the tab strip and sidebar take the new colours on the next launch.")
        }
        SettingsGroup(title: "Window") {
            HStack {
                Stepper(
                    value: Binding(get: { settings.windowPadding ?? 2 }, set: { settings.windowPadding = $0 }), in: 0...40, step: 2
                ) {
                    Text(verbatim: settings.windowPadding.map { "Padding \($0) pt" } ?? "Padding: from your Ghostty config")
                }
                if settings.windowPadding != nil { Button("Reset") { settings.windowPadding = nil }.controlSize(.small) }
            }
            Picker("Cursor", selection: $settings.cursorStyle) {
                Text("From config").tag(Settings.CursorStyle?.none)
                ForEach(Settings.CursorStyle.allCases) { Text($0.rawValue.capitalized).tag(Settings.CursorStyle?.some($0)) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)
            HStack {
                Text("Dim the panes without the keyboard")
                Slider(value: $settings.unfocusedPaneDim, in: 0...0.7)
                    .frame(maxWidth: 180)
            }
        }
        Button("Open Your Ghostty Config") {
            let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/config")
            if !FileManager.default.fileExists(atPath: config.path) {
                try? FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: config.path, contents: Data("# Ghostty config: https://ghostty.org/docs/config\n".utf8))
            }
            NSWorkspace.shared.open(config)
        }
    }
}
