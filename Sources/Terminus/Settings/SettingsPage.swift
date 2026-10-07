import AppKit
import Combine
import SwiftUI

/// Settings' sections, as in the list on the page's left.
enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general, appearance, terminal, agents, editor, notifications, shortcuts, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .terminal: "Terminal"
        case .agents: "Agents"
        case .editor: "Editor"
        case .notifications: "Notifications"
        case .shortcuts: "Keyboard Shortcuts"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .terminal: "terminal"
        case .agents: "sparkle"
        case .editor: "doc.text"
        case .notifications: "bell"
        case .shortcuts: "keyboard"
        case .about: "info.circle"
        }
    }

    /// The JSON file its settings live in.
    var file: String { self == .shortcuts ? "keybindings.json" : "settings.json" }

    /// Whether a search finds something here: the title, a setting, a shortcut.
    @MainActor func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if title.lowercased().contains(query.lowercased()) { return true }
        if self == .shortcuts { return KeyCommands.all.contains { $0.matches(query) } }
        if self == .about, ["version", "update", "changelog", "release"].contains(where: { $0.contains(query.lowercased()) }) { return true }
        return SettingsSchema.specs(in: self).contains { $0.matches(query) }
    }
}

/// What the Settings page shows.
@MainActor
final class SettingsPageModel: ObservableObject {
    enum Mode: String { case ui, json }

    @Published var section: SettingsSection = .general
    @Published var search = ""
    @Published var mode: Mode = .ui
    /// The JSON view's text, as typed; nil until the view opens.
    @Published var draft: String?

    var sections: [SettingsSection] { SettingsSection.allCases.filter { $0.matches(search) } }

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

    func options(for source: SettingSource) -> [String] {
        switch source {
        case .monospacedFonts: monospacedFamilies
        case .themes: themes
        }
    }

    func show(_ section: SettingsSection) {
        self.section = section
        mode = .ui
        draft = nil
    }
}

/// The Settings tab: sections on the left, the chosen one on the right —
/// as controls, or as the JSON file they write.
struct SettingsPageView: View {
    @ObservedObject var model: SettingsPageModel
    @ObservedObject var settings: Settings
    @ObservedObject var keybindings: Keybindings
    let theme: ChromeTheme

    var body: some View {
        HStack(spacing: 0) {
            sidebar.background(theme.strip)
            Rectangle().fill(theme.dimText.opacity(0.15)).frame(width: 1)
            content
        }
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onChange(of: model.search) { _ in
            if let first = model.sections.first, !model.sections.contains(model.section) { model.show(first) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.dimText)
                TextField("Search settings", text: $model.search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("settings.search")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.selected.opacity(0.6)))
            .padding(.bottom, 8)
            ForEach(model.sections) { section in
                Button {
                    model.show(section)
                } label: {
                    Label(section.title, systemImage: section.symbol)
                        .foregroundStyle(model.section == section ? theme.text : theme.dimText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(model.section == section ? theme.selected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(14)
        .frame(width: 240)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.section.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                if model.section != .about {
                    Picker("", selection: $model.mode) {
                        Text("UI").tag(SettingsPageModel.Mode.ui)
                        Text("JSON").tag(SettingsPageModel.Mode.json)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("Edit \(model.section.file) itself")
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 12)
            if model.mode == .json && model.section != .about {
                SettingsJSONView(model: model, settings: settings, keybindings: keybindings, theme: theme)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        problems
                        sectionBody
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private var problems: some View {
        let list = model.section == .shortcuts ? keybindings.problems : settings.problems
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(list, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout) }
                Button("Fix in \(model.section.file)") { model.mode = .json }
            }
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }

    @ViewBuilder private var sectionBody: some View {
        switch model.section {
        case .shortcuts:
            ShortcutsSettings(keybindings: keybindings, theme: theme, filter: $model.search)
        case .about:
            SpecRows(section: .about, model: model, settings: settings, theme: theme)
            AboutSettings(updates: .shared, theme: theme)
        default:
            SpecRows(section: model.section, model: model, settings: settings, theme: theme)
            if model.section == .appearance || model.section == .terminal { GhosttyNote(theme: theme) }
        }
    }
}

/// A section's settings, grouped, as rows.
private struct SpecRows: View {
    let section: SettingsSection
    @ObservedObject var model: SettingsPageModel
    @ObservedObject var settings: Settings
    let theme: ChromeTheme

    var body: some View {
        let specs = SettingsSchema.specs(in: section).filter { $0.matches(model.search) || section.title.lowercased().contains(model.search.lowercased()) }
        let groups = specs.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        ForEach(groups, id: \.self) { group in
            VStack(alignment: .leading, spacing: 0) {
                Text(group).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.dimText).padding(.bottom, 6)
                ForEach(specs.filter { $0.group == group }) { spec in
                    SettingRow(spec: spec, model: model, settings: settings, theme: theme)
                    Rectangle().fill(theme.dimText.opacity(0.12)).frame(height: 1)
                }
            }
        }
    }
}

/// One setting: what it is on the left, its control on the right, and a
/// way back to the default when it is set.
private struct SettingRow: View {
    let spec: SettingSpec
    @ObservedObject var model: SettingsPageModel
    @ObservedObject var settings: Settings
    let theme: ChromeTheme

    private var enabled: Bool { spec.requires.map { settings.bool($0) } ?? true }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(spec.title).foregroundStyle(theme.text)
                if let help = spec.help {
                    Text(help).font(.caption).foregroundStyle(theme.dimText).fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: spec.key).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.dimText.opacity(0.7))
            }
            Spacer(minLength: 12)
            control.disabled(!enabled)
            Button {
                settings.set(spec.key, nil)
            } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help(spec.defaultValue == nil ? "Back to your Ghostty config" : "Back to the default")
            .opacity(settings.isSet(spec.key) ? 1 : 0)
            .disabled(!settings.isSet(spec.key))
        }
        .padding(.vertical, 10)
        .opacity(enabled ? 1 : 0.5)
    }

    /// Unset Ghostty settings show what Ghostty uses now.
    private var unsetLabel: String { "From your Ghostty config" }

    @ViewBuilder private var control: some View {
        switch spec.kind {
        case .toggle:
            if spec.defaultValue == nil {
                Picker("", selection: optionalString) {
                    Text(unsetLabel).tag(String?.none)
                    Text("On").tag(String?.some("true"))
                    Text("Off").tag(String?.some("false"))
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Toggle("", isOn: Binding(get: { settings.bool(spec.key) }, set: { settings.set(spec.key, .bool($0)) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        case .choice(let options):
            Picker("", selection: optionalString) {
                if spec.defaultValue == nil { Text(unsetLabel).tag(String?.none) }
                ForEach(options, id: \.value) { Text($0.label).tag(String?.some($0.value)) }
            }
            .labelsHidden()
            .fixedSize()
        case .dynamicChoice(let source):
            Picker("", selection: optionalString) {
                Text(unsetLabel).tag(String?.none)
                Divider()
                ForEach(model.options(for: source), id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
        case .integer(let range, let step, let unit):
            // Unset: what Ghostty uses, when it can be read (padding can't).
            let known = settings.number(spec.key) ?? spec.ghostty.flatMap(ghosttyNumber) ?? spec.defaultValue?.number
            let current = known ?? Double(range.lowerBound)
            Stepper(value: Binding(get: { Int(current) }, set: { settings.set(spec.key, .int($0)) }), in: range, step: step) {
                Group {
                    if let known {
                        Text(verbatim: settings.isSet(spec.key) || spec.defaultValue != nil ? "\(Int(known)) \(unit)" : "\(Int(known)) \(unit) (Ghostty)")
                    } else {
                        Text(unsetLabel)
                    }
                }
                .monospacedDigit()
                .foregroundStyle(theme.text)
            }
            .fixedSize()
        case .number(let range, let step):
            HStack {
                Slider(value: Binding(get: { settings.number(spec.key) ?? range.lowerBound }, set: { settings.set(spec.key, .double(($0 / step).rounded() * step)) }), in: range)
                    .frame(width: 180)
                Text(verbatim: String(format: "%.2f", settings.number(spec.key) ?? range.lowerBound)).monospacedDigit().foregroundStyle(theme.dimText)
            }
        case .text(let placeholder, let monospaced):
            SettingTextField(text: settings.string(spec.key), placeholder: placeholder, monospaced: monospaced) { settings.set(spec.key, .string($0)) }
                .frame(width: 260)
        }
    }

    /// A string setting's value, nil when unset (Ghostty decides).
    private var optionalString: Binding<String?> {
        Binding(
            get: {
                guard let value = settings.isSet(spec.key) ? settings.value(spec.key) : spec.defaultValue else { return nil }
                if case .bool(let flag) = value { return flag ? "true" : "false" }
                return value.string
            },
            set: { new in
                guard let new else { return settings.set(spec.key, nil) }
                if case .toggle = spec.kind { settings.set(spec.key, .bool(new == "true")) } else { settings.set(spec.key, .string(new)) }
            })
    }

    private func ghosttyNumber(_ option: String) -> Double? {
        switch option {
        case "font-size": GhosttyRuntime.shared.configNumber("font-size")
        case "scrollback-limit": GhosttyRuntime.shared.configNumber("scrollback-limit").map { ($0 / 1_000_000).rounded() }
        default: nil
        }
    }
}

/// A text setting, saved when editing ends (Return, or leaving the field)
/// — not at each keystroke, which would rewrite the file each time.
private struct SettingTextField: View {
    let text: String
    let placeholder: String
    let monospaced: Bool
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, prompt: Text(placeholder))
            .textFieldStyle(.roundedBorder)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { draft = $0 }
            .onSubmit { onCommit(draft) }
            .onChange(of: focused) { if !$0, draft != text { onCommit(draft) } }
    }
}

/// Where Appearance and Terminal's values go, and what Ghostty says about them.
private struct GhosttyNote: View {
    let theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "These are Ghostty settings. Left \"From your Ghostty config\", ~/.config/ghostty/config decides; set here, they override it for every terminal at once."
            )
            .font(.caption).foregroundStyle(theme.dimText).fixedSize(horizontal: false, vertical: true)
            ForEach(GhosttyRuntime.shared.configDiagnostics, id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
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
}

// MARK: JSON

/// A section's file as text: typed into, checked as it is typed, saved
/// with ⌘S or Save. Saved with problems, the good parts apply and the rest
/// is listed — as VS Code does.
private struct SettingsJSONView: View {
    @ObservedObject var model: SettingsPageModel
    @ObservedObject var settings: Settings
    @ObservedObject var keybindings: Keybindings
    let theme: ChromeTheme

    private var isKeybindings: Bool { model.section == .shortcuts }
    private var saved: String { isKeybindings ? keybindings.fileText : settings.fileText }
    private var url: URL { isKeybindings ? keybindings.url : settings.url }

    /// A parse error in the text as typed, before it is saved.
    private var typingError: String? {
        guard let draft = model.draft else { return nil }
        do {
            if isKeybindings { _ = try SettingsJSON.array(from: draft) } else { _ = try SettingsJSON.object(from: draft) }
            return nil
        } catch {
            return error.message
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(verbatim: url.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.dimText).lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Revert") { model.draft = saved }.disabled(model.draft == saved)
                Button("Save") { save() }.keyboardShortcut("s").disabled(model.draft == saved)
            }
            JSONTextView(text: Binding(get: { model.draft ?? saved }, set: { model.draft = $0 }), theme: theme)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.dimText.opacity(0.2)))
            Group {
                if let typingError {
                    Label(typingError, systemImage: "xmark.octagon").foregroundStyle(.red)
                } else {
                    ForEach(isKeybindings ? keybindings.problems : settings.problems, id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                Text(
                    isKeybindings
                        ? "Command ids are in Keyboard Shortcuts' UI view, under each name. Comments (//) are fine."
                        : "Only what differs from the defaults is here; every key is under its setting in the UI view. Comments (//) are fine."
                )
                .foregroundStyle(theme.dimText)
            }
            .font(.caption)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .onAppear { if model.draft == nil { model.draft = saved } }
        // Another section's file, while this view stays: load that one.
        .onChange(of: model.section) { section in
            model.draft = section == .shortcuts ? keybindings.fileText : settings.fileText
        }
    }

    private func save() {
        guard let draft = model.draft else { return }
        if isKeybindings { keybindings.save(text: draft) } else { settings.save(text: draft) }
    }
}

/// A plain monospaced text view (SwiftUI's TextEditor substitutes quotes
/// and dashes as you type — wrong for JSON).
private struct JSONTextView: NSViewRepresentable {
    @Binding var text: String
    let theme: ChromeTheme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = theme.textNS
        textView.insertionPointColor = theme.textNS
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 10)
        for off in [
            \NSTextView.isAutomaticQuoteSubstitutionEnabled, \.isAutomaticDashSubstitutionEnabled, \.isAutomaticTextReplacementEnabled,
            \.isAutomaticSpellingCorrectionEnabled, \.isContinuousSpellCheckingEnabled,
        ] as [ReferenceWritableKeyPath<NSTextView, Bool>] { textView[keyPath: off] = false }
        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

// MARK: Keyboard shortcuts

private struct ShortcutsSettings: View {
    @ObservedObject var keybindings: Keybindings
    let theme: ChromeTheme
    @Binding var filter: String
    @State private var recording: String?

    var body: some View {
        HStack {
            Text("Click a shortcut, then press the keys. Esc cancels; ⌫ removes it.")
                .font(.caption).foregroundStyle(theme.dimText)
            Spacer()
            Button("Reset All") { keybindings.resetAll() }.disabled(keybindings.entries.isEmpty)
        }
        ForEach(KeyCommands.groups, id: \.self) { group in
            let commands = KeyCommands.all.filter { $0.group == group && ($0.matches(filter) || "keyboard shortcuts".contains(filter.lowercased())) }
            if !commands.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(group).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.dimText).padding(.bottom, 6)
                    ForEach(commands) { command in
                        ShortcutRow(command: command, keybindings: keybindings, theme: theme, recording: $recording)
                        Rectangle().fill(theme.dimText.opacity(0.12)).frame(height: 1)
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 0) {
            Text("Mouse and dropping").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.dimText).padding(.bottom, 6)
            ForEach(Shortcuts.mouse.filter { $0.matches(filter) || filter.isEmpty }) { shortcut in
                HStack {
                    Text(verbatim: shortcut.title).foregroundStyle(theme.text)
                    Spacer()
                    Text(verbatim: shortcut.keys).foregroundStyle(theme.dimText)
                }
                .padding(.vertical, 8)
                Rectangle().fill(theme.dimText.opacity(0.12)).frame(height: 1)
            }
        }
    }
}

private struct ShortcutRow: View {
    let command: KeyCommand
    @ObservedObject var keybindings: Keybindings
    let theme: ChromeTheme
    @Binding var recording: String?

    var body: some View {
        let key = keybindings.key(for: command)
        let clashes = keybindings.conflicts(for: command)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title).foregroundStyle(theme.text)
                Text(verbatim: command.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.dimText.opacity(0.7))
            }
            Spacer()
            if !clashes.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Also " + clashes.map(\.title).joined(separator: ", ") + " — the first one in the menus wins")
            }
            if recording == command.id {
                KeyRecorder(
                    onKey: { combo in
                        recording = nil
                        keybindings.set(command, to: combo)
                    },
                    onClear: {
                        recording = nil
                        keybindings.set(command, to: nil)
                    }, onCancel: { recording = nil }
                )
                .frame(width: 150, height: 24)
            } else {
                Button {
                    recording = command.id
                } label: {
                    Text(verbatim: key?.display ?? "—")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(key == nil ? theme.dimText : theme.text)
                        .padding(.horizontal, 9)
                        .frame(minWidth: 70, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.selected))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(keybindings.isChanged(command) ? Color.accentColor.opacity(0.7) : theme.dimText.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .help("Click, then press the new keys")
            }
            Button {
                keybindings.reset(command)
            } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help(keybindings.defaultKey(command).map { "Back to \($0.display)" } ?? "Back to none")
            .opacity(keybindings.isChanged(command) ? 1 : 0)
            .disabled(!keybindings.isChanged(command))
        }
        .padding(.vertical, 7)
    }
}

/// Takes the next key pressed — before any menu or terminal sees it.
private struct KeyRecorder: NSViewRepresentable {
    let onKey: (KeyCombo) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyRecorderView {
        let view = KeyRecorderView()
        view.onKey = onKey
        view.onClear = onClear
        view.onCancel = onCancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: KeyRecorderView, context: Context) {
        view.onKey = onKey
        view.onClear = onClear
        view.onCancel = onCancel
    }
}

final class KeyRecorderView: NSView {
    var onKey: (KeyCombo) -> Void = { _ in }
    var onClear: () -> Void = {}
    var onCancel: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
        let text = "Press the keys…" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    /// ⌘ keys come here first; the menus never see them while recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        take(event)
        return true
    }

    override func keyDown(with event: NSEvent) { take(event) }

    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [onCancel] in onCancel() }
        return true
    }

    private func take(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plain && Int(event.keyCode) == 53 { return onCancel() }  // Esc
        if plain && (Int(event.keyCode) == 51 || Int(event.keyCode) == 117) { return onClear() }  // ⌫ ⌦
        if let combo = KeyCombo(event: event) { onKey(combo) } else { NSSound.beep() }
    }
}

// MARK: About

private struct AboutSettings: View {
    @ObservedObject var updates: UpdateChecker
    let theme: ChromeTheme

    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    private var whatsNew: [String] { Changelog.bundled.map { Changelog.entry(for: updates.currentVersion, in: $0) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Terminus \(updates.currentVersion)").font(.title3.weight(.semibold)).foregroundStyle(theme.text)
                    Text(verbatim: "Build \(build)").foregroundStyle(theme.dimText)
                    if let credits = AboutPanel.credits(for: .main) { Text(verbatim: credits).font(.caption).foregroundStyle(theme.dimText) }
                }
            }
            HStack(spacing: 8) {
                Button("Check for Updates") { Task { await updates.check() } }.disabled(updates.state == .checking)
                Button("View the Full Changelog") { ChangelogWindowController.shared.show() }
            }
            status
            if !whatsNew.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's new in \(updates.currentVersion)").font(.headline).foregroundStyle(theme.text)
                    ForEach(whatsNew, id: \.self) { Text(verbatim: "• \($0)").foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch updates.state {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Label("Up to date", systemImage: "checkmark.circle").foregroundStyle(theme.dimText)
        case .available(let release):
            Text(verbatim: "Terminus \(release.version) is available — you have \(updates.currentVersion).").foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button("Download & Open") { Task { await updates.download(release) } }.fixedSize()
                if let url = release.url { Button("Release Page") { NSWorkspace.shared.open(url) }.fixedSize() }
            }
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(theme.dimText)
            }
        case .downloaded(let dmg):
            Text(verbatim: "Opened \(dmg.lastPathComponent) — drag Terminus to Applications, then relaunch.")
                .foregroundStyle(theme.dimText).fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(verbatim: message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// View ▸ Latest Changelog (⌥⌘O): the bundled CHANGELOG.md.
@MainActor
final class ChangelogWindowController: NSWindowController {
    static let shared = ChangelogWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered,
            defer: false)
        window.title = "Terminus Changelog"
        window.contentViewController = NSHostingController(rootView: ChangelogView(text: Changelog.bundled ?? "No changelog in this build."))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct ChangelogView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                // The file's own preamble is for committers; versions start at the first "## ".
                let lines = text.components(separatedBy: "\n").drop { !$0.hasPrefix("## ") }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("## ") {
                        Text(verbatim: String(line.dropFirst(3))).font(.headline).padding(.top, 10)
                    } else if line.hasPrefix("- ") {
                        Text(verbatim: "• " + line.dropFirst(2)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
