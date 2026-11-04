import AppKit

/// Another terminal's or editor's colours, as a Ghostty theme file — what
/// Settings ▸ Themes ▸ Import… and a drop on the gallery write into the
/// user's themes folder (a theme is a file, not code: CLAUDE.md).
///
/// - iTerm2's `.itermcolors`: a property list of colour dictionaries, each
///   in its own colour space (sRGB, P3, or the "calibrated" generic RGB of
///   older files), converted to sRGB.
/// - A VS Code colour theme: JSON with comments (`colors` →
///   `terminal.ansiRed`…), falling back to the editor's background and
///   foreground for a theme that names no terminal colours.
enum ThemeImport {
    enum Failure: Error, Equatable {
        case unreadable(String)
        /// Neither a background nor a foreground: nothing to draw.
        case noColours
    }

    /// A theme's colours, by Ghostty's names.
    struct Colours: Equatable {
        var background: ThemeColor?
        var foreground: ThemeColor?
        var cursor: ThemeColor?
        var cursorText: ThemeColor?
        var selectionBackground: ThemeColor?
        var selectionForeground: ThemeColor?
        var palette: [Int: ThemeColor] = [:]

        /// The theme file: Ghostty's keys, the sixteen as `palette = N=#…`.
        func file(source: String) throws(Failure) -> String {
            guard let background, let foreground else { throw .noColours }
            var lines = ["# Imported by Overterm from \(source)"]
            for index in palette.keys.sorted() { lines.append("palette = \(index)=\(ThemeImport.hex(palette[index]!))") }
            lines.append("background = \(ThemeImport.hex(background))")
            lines.append("foreground = \(ThemeImport.hex(foreground))")
            if let cursor { lines.append("cursor-color = \(ThemeImport.hex(cursor))") }
            if let cursorText { lines.append("cursor-text = \(ThemeImport.hex(cursorText))") }
            if let selectionBackground { lines.append("selection-background = \(ThemeImport.hex(selectionBackground))") }
            if let selectionForeground { lines.append("selection-foreground = \(ThemeImport.hex(selectionForeground))") }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static func hex(_ colour: ThemeColor) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(colour.red), byte(colour.green), byte(colour.blue))
    }

    // MARK: iTerm2

    static func iterm(_ data: Data) throws(Failure) -> Colours {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw .unreadable("not an .itermcolors property list")
        }
        func colour(_ key: String) -> ThemeColor? {
            guard let entry = plist[key] as? [String: Any],
                let red = (entry["Red Component"] as? NSNumber)?.doubleValue,
                let green = (entry["Green Component"] as? NSNumber)?.doubleValue,
                let blue = (entry["Blue Component"] as? NSNumber)?.doubleValue
            else { return nil }
            let space = (entry["Color Space"] as? String)?.lowercased() ?? "calibrated"
            let source: NSColor
            switch space {
            case "srgb": source = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            case "p3": source = NSColor(displayP3Red: red, green: green, blue: blue, alpha: 1)
            // "Calibrated" (and "Device", older still): generic RGB.
            default: source = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
            }
            guard let srgb = source.usingColorSpace(.sRGB) else { return nil }
            // Extended-range sRGB can fall outside 0…1: clamped.
            func unit(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
            return ThemeColor(red: unit(srgb.redComponent), green: unit(srgb.greenComponent), blue: unit(srgb.blueComponent))
        }
        var colours = Colours(
            background: colour("Background Color"), foreground: colour("Foreground Color"), cursor: colour("Cursor Color"),
            cursorText: colour("Cursor Text Color"), selectionBackground: colour("Selection Color"),
            selectionForeground: colour("Selected Text Color"))
        for index in 0...15 { colours.palette[index] = colour("Ansi \(index) Color") }
        guard colours.background != nil || colours.foreground != nil else { throw .noColours }
        return colours
    }

    // MARK: VS Code

    /// VS Code's terminal colours, in ANSI order.
    static let vscodeANSI = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
        "BrightBlack", "BrightRed", "BrightGreen", "BrightYellow", "BrightBlue", "BrightMagenta", "BrightCyan", "BrightWhite",
    ]

    static func vscode(_ text: String) throws(Failure) -> (name: String?, colours: Colours) {
        let object: [String: Any]
        do {
            object = try SettingsJSON.object(from: text)
        } catch {
            throw .unreadable("not a VS Code colour theme (JSON)")
        }
        guard let map = object["colors"] as? [String: Any] else { throw .unreadable("no \"colors\" in it") }
        func colour(_ keys: String...) -> ThemeColor? {
            for key in keys {
                // #rrggbbaa: VS Code's alpha is over the editor; the colour is what is kept.
                if let value = map[key] as? String, let colour = ThemeColor(String(value.prefix(7))) { return colour }
            }
            return nil
        }
        var colours = Colours(
            background: colour("terminal.background", "editor.background"), foreground: colour("terminal.foreground", "editor.foreground"),
            cursor: colour("terminalCursor.foreground", "editorCursor.foreground"),
            cursorText: colour("terminalCursor.background"),
            selectionBackground: colour("terminal.selectionBackground", "editor.selectionBackground"),
            selectionForeground: colour("terminal.selectionForeground"))
        for (index, name) in vscodeANSI.enumerated() {
            if let found = colour("terminal.ansi\(name)") { colours.palette[index] = found }
        }
        guard colours.background != nil || colours.foreground != nil else { throw .noColours }
        return (object["name"] as? String, colours)
    }

    // MARK: Files

    /// A file of either kind: its theme's name and text.
    static func theme(from url: URL) throws(Failure) -> (name: String, text: String) {
        guard let data = try? Data(contentsOf: url) else { throw .unreadable("can't be read") }
        let fileName = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "itermcolors" {
            return (fileName, try iterm(data).file(source: url.lastPathComponent))
        }
        guard let text = String(data: data, encoding: .utf8) else { throw .unreadable("isn't text") }
        let (name, colours) = try vscode(text)
        return (name ?? fileName, try colours.file(source: url.lastPathComponent))
    }

    /// Writes it into `directory` under `name` — or "name 2", "name 3"…
    /// beside a theme of that name already there. Returns the name used.
    static func save(_ text: String, named name: String, in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A name is a file name: no folders in it.
        let base = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        var chosen = base.isEmpty ? "Imported" : base
        var number = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(chosen).path) {
            chosen = "\(base) \(number)"
            number += 1
        }
        try text.write(to: directory.appendingPathComponent(chosen), atomically: true, encoding: .utf8)
        return chosen
    }
}
