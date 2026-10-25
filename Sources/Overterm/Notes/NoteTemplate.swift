import Foundation

/// Obsidian's core Templates: `{{title}}`, `{{date}}` and `{{time}}`, each
/// in the format the vault's templates settings name, or one given after a
/// colon — `{{date:dddd, MMMM Do}}`. Pure.
enum NoteTemplate {
    private static let cache = RegexCache()

    static func apply(_ text: String, title: String, date: Date, settings: ObsidianSettings, locale: Locale = .current) -> String {
        guard let regex = cache.regex(#"\{\{\s*(title|date|time)\s*(?::([^}]*))?\}\}"#, [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let given = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            switch name {
            case "title": out += title
            case "date": out += MomentFormat.string(from: date, format: given ?? settings.templateDateFormat, locale: locale)
            default: out += MomentFormat.string(from: date, format: given ?? settings.templateTimeFormat, locale: locale)
            }
            last = NSMaxRange(match.range)
        }
        return out + ns.substring(from: last)
    }
}

extension NotesVault {
    /// Where the daily note for `date` is: the folder and format of Obsidian's
    /// Daily notes settings (a format may hold folders: `YYYY/MM/DD`).
    func dailyNote(for date: Date) -> URL {
        let name = MomentFormat.string(from: date, format: settings.dailyFormat)
        var folder = root
        let trimmed = settings.dailyFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !trimmed.isEmpty { folder = folder.appendingPathComponent(trimmed, isDirectory: true) }
        return folder.appendingPathComponent(name + ".md")
    }

    /// A template named as Obsidian's settings name them: vault-relative,
    /// `.md` optional.
    func template(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !trimmed.isEmpty else { return nil }
        let url = root.appendingPathComponent(trimmed.hasSuffix(".md") ? trimmed : trimmed + ".md")
        return contains(url) ? url : nil
    }

    /// The templates in the templates folder, for Insert Template.
    var templates: [URL] {
        let trimmed = settings.templatesFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !trimmed.isEmpty else { return [] }
        let folder = root.appendingPathComponent(trimmed, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// `Untitled.md`, else `Untitled 1.md`… — a name nothing in `folder` has.
    static func freeName(_ base: String, extension ext: String, in folder: URL) -> URL {
        let suffix = ext.isEmpty ? "" : "." + ext
        var candidate = folder.appendingPathComponent(base + suffix)
        var number = 1
        while FileManager.default.fileExists(atPath: candidate.path) || NoteFiles.isEvicted(candidate) {
            candidate = folder.appendingPathComponent("\(base) \(number)\(suffix)")
            number += 1
        }
        return candidate
    }
}

/// Files put into the vault from a note — a pasted image, a file dropped
/// in — where Obsidian puts them, named as it names them. Pure but for
/// the names already taken.
enum NoteAttachments {
    /// Obsidian's name for a pasted image: `Pasted image 20261025101500.png`.
    static func pastedName(at date: Date, extension ext: String = "png") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "Pasted image \(formatter.string(from: date)).\(ext)"
    }

    /// The embed for a file put at `path` (vault-relative), from the note at
    /// `source`: `![[name]]`, or `![](path)` when the vault uses Markdown links.
    static func embed(_ path: String, from source: String, resolver: LinkResolver, settings: ObsidianSettings) -> String {
        if settings.useMarkdownLinks {
            let target =
                settings.newLinkFormat == "relative" ? LinkResolver.relative(path, from: LinkResolver.folder(of: source)) : path
            return "![](\(target.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: " ", with: "%20")))"
        }
        return "![[\(resolver.linkText(for: path, from: source, format: settings.newLinkFormat))]]"
    }
}

/// Terminal text put into a note: under the time and the command it came
/// from, fenced so it reads as it printed. Pure.
enum NoteAppend {
    static func entry(_ text: String, command: String?, folder: String?, date: Date, settings: ObsidianSettings) -> String {
        var heading = "#### " + MomentFormat.string(from: date, format: settings.templateTimeFormat)
        if let command, !command.isEmpty { heading += " — `\(command.replacingOccurrences(of: "`", with: "'"))`" }
        if let folder, !folder.isEmpty { heading += " in \((folder as NSString).abbreviatingWithTildeInPath)" }
        // A fence longer than any run of backticks in the text.
        var fence = "```"
        while text.contains(fence) { fence += "`" }
        return "\(heading)\n\(fence)\n\(text.trimmingCharacters(in: .newlines))\n\(fence)\n"
    }

    /// `entry` after `existing`, a blank line between.
    static func append(_ entry: String, to existing: String) -> String {
        if existing.isEmpty { return entry }
        let trimmed = existing.hasSuffix("\n") ? existing : existing + "\n"
        return trimmed + (trimmed.hasSuffix("\n\n") ? "" : "\n") + entry
    }
}
