import Foundation

/// A theme file edited in place: the lines for the keys that change are
/// rewritten (or added), every other line — comments, keys Overterm doesn't
/// read — kept as it was. Pure. The theme editor writes through this, so a
/// theme duplicated from Ghostty's keeps all of what made it.
enum ThemeFile {
    /// A key's identity: `palette` is one per index.
    private static func slot(of line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        guard key == "palette" else { return key }
        let value = trimmed[trimmed.index(after: equals)...]
        guard let inner = value.firstIndex(of: "=") else { return nil }
        return "palette " + value[value.startIndex..<inner].trimmingCharacters(in: .whitespaces)
    }

    /// `changes` by key ("background", "palette 3"); each value a colour.
    static func set(_ changes: [String: ThemeColor], in text: String) -> String {
        var remaining = changes
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        for (index, line) in lines.enumerated() {
            guard let slot = slot(of: Substring(line)), let colour = remaining.removeValue(forKey: slot) else { continue }
            lines[index] = render(slot, colour)
        }
        // New keys after the rest, the palette in its order.
        for slot in remaining.keys.sorted(by: order) { lines.append(render(slot, remaining[slot]!)) }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func render(_ slot: String, _ colour: ThemeColor) -> String {
        if slot.hasPrefix("palette ") { return "palette = \(slot.dropFirst(8))=\(ThemeImport.hex(colour))" }
        return "\(slot) = \(ThemeImport.hex(colour))"
    }

    private static func order(_ a: String, _ b: String) -> Bool {
        func number(_ slot: String) -> Int { slot.hasPrefix("palette ") ? Int(slot.dropFirst(8)) ?? 99 : -1 }
        let (x, y) = (number(a), number(b))
        return x == y ? a < b : x < y
    }
}
