import AppKit
import SwiftUI

/// Settings ▸ Themes ▸ a theme ▸ Duplicate and Edit… (or Edit… for one of
/// yours): its colours in wells, the preview following, saved as a file in
/// your themes folder — the file edited in place (`ThemeFile`), so whatever
/// else the theme said stays.
struct ThemeEditorView: View {
    /// What is edited, and whether saving makes a new theme or rewrites it.
    struct Target: Identifiable {
        let entry: ThemeCatalog.Entry
        let duplicate: Bool
        var id: String { entry.id + (duplicate ? "+" : "") }
    }

    let target: Target
    @ObservedObject var theme: ChromeTheme
    /// Saved under this name; nil when cancelled.
    let done: (String?) -> Void

    @State private var name = ""
    @State private var colours: [String: Color] = [:]
    @State private var error: String?

    /// Each well: its key in the file and its label.
    static let keys: [(key: String, label: String)] =
        [("background", "Background"), ("foreground", "Text"), ("cursor-color", "Cursor"), ("selection-background", "Selection")]
        + ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"].enumerated().map { ("palette \($0.offset)", $0.element) }
        + ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"].enumerated().map { ("palette \($0.offset + 8)", "Bright \($0.element.lowercased())") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.duplicate ? "New Theme from \(target.entry.theme.name)" : "Edit \(target.entry.theme.name)").font(.headline)
            if target.duplicate {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 280)
            }
            HStack(alignment: .top, spacing: 20) {
                ThemePreview(theme: edited).frame(width: 260, height: 150)
                VStack(alignment: .leading, spacing: 10) {
                    wells(Array(Self.keys.prefix(4)), columns: 2)
                    Divider()
                    palette
                }
            }
            if let error { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(target.duplicate && name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 780)
        .onAppear(perform: start)
    }

    static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    /// The sixteen as a grid: a column a colour, a row normal and bright.
    private var palette: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("").frame(width: 44)
                ForEach(Self.ansiNames, id: \.self) { Text($0).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(.secondary) }
            }
            ForEach([("Normal", 0), ("Bright", 8)], id: \.1) { row in
                GridRow {
                    Text(row.0).font(.system(size: ChromeMetrics.text(11)))
                    ForEach(0..<8, id: \.self) { column in
                        ColorPicker("", selection: binding("palette \(row.1 + column)"), supportsOpacity: false)
                            .labelsHidden()
                            .help("\(row.0) \(Self.ansiNames[column].lowercased()) — palette \(row.1 + column)")
                    }
                }
            }
        }
    }

    private func wells(_ keys: [(key: String, label: String)], columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), alignment: .leading), count: columns), alignment: .leading, spacing: 6) {
            ForEach(keys, id: \.key) { item in
                HStack(spacing: 6) {
                    ColorPicker("", selection: binding(item.key), supportsOpacity: false).labelsHidden()
                    Text(item.label).font(.system(size: ChromeMetrics.text(11))).lineLimit(1)
                }
                .help(item.key)
            }
        }
    }

    private func binding(_ key: String) -> Binding<Color> {
        Binding(get: { colours[key] ?? .gray }, set: { colours[key] = $0 })
    }

    /// The theme as it now is, for the preview.
    private var edited: TerminalTheme {
        let base = target.entry.theme
        func colour(_ key: String) -> ThemeColor? { colours[key].flatMap(Self.themeColor) }
        return TerminalTheme(
            name: base.name, background: colour("background") ?? base.background, foreground: colour("foreground") ?? base.foreground,
            cursor: colour("cursor-color") ?? base.cursor, selection: colour("selection-background") ?? base.selection,
            palette: (0...15).map { colour("palette \($0)") ?? base.ansi($0) })
    }

    private func start() {
        let base = target.entry.theme
        name = target.duplicate ? "\(base.name) (mine)" : base.name
        var start: [String: Color] = [
            "background": base.background.color, "foreground": base.foreground.color,
            "cursor-color": (base.cursor ?? base.foreground).color, "selection-background": (base.selection ?? base.ansi(8)).color,
        ]
        for index in 0...15 { start["palette \(index)"] = base.ansi(index).color }
        colours = start
    }

    static func themeColor(_ colour: Color) -> ThemeColor? {
        guard let rgb = NSColor(colour).usingColorSpace(.sRGB) else { return nil }
        func unit(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
        return ThemeColor(red: unit(rgb.redComponent), green: unit(rgb.greenComponent), blue: unit(rgb.blueComponent))
    }

    private func save() {
        guard let directory = ThemeCatalog.writableDirectory else { return error = "No themes folder to write to." }
        let original = target.entry.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let changes = colours.compactMapValues(Self.themeColor)
        let text = ThemeFile.set(changes, in: original)
        do {
            if target.duplicate {
                done(try ThemeImport.save(text, named: name, in: directory))
            } else if let url = target.entry.url {
                try text.write(to: url, atomically: true, encoding: .utf8)
                done(target.entry.theme.name)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
