import Foundation

/// Settings ▸ Appearance ▸ Themes by folder: lines of `pattern = Theme`, the
/// first whose pattern takes the tab's folder winning. Pure.
///
///     ~/Projects/prod-*   = Red Alert
///     ~/work/payments     = Nord
///
/// A pattern is a folder (it and everything under it) or a glob over the
/// path (`*` crosses folders). `~` is the home folder.
enum FolderThemes {
    struct Rule: Equatable {
        var pattern: String
        var theme: String
    }

    static func rules(_ lines: [String]) -> [Rule] {
        lines.compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#"), let equals = text.lastIndex(of: "=") else { return nil }
            let pattern = text[..<equals].trimmingCharacters(in: .whitespaces)
            let theme = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !theme.isEmpty else { return nil }
            return Rule(pattern: pattern, theme: theme)
        }
    }

    /// The theme for `path`, by the first rule that takes it.
    static func theme(for path: String, rules: [Rule], home: String = NSHomeDirectory()) -> String? {
        let path = (path as NSString).standardizingPath
        for rule in rules {
            var pattern = rule.pattern
            if pattern == "~" || pattern.hasPrefix("~/") { pattern = home + pattern.dropFirst() }
            pattern = (pattern as NSString).standardizingPath
            if pattern.contains(where: { "*?[".contains($0) }) {
                if fnmatch(pattern, path, 0) == 0 || fnmatch(pattern + "/*", path, 0) == 0 { return rule.theme }
            } else if path == pattern || path.hasPrefix(pattern + "/") {
                return rule.theme
            }
        }
        return nil
    }
}
