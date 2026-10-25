import Foundation

/// What a note says, as Obsidian reads it: its properties (frontmatter),
/// links and embeds, tags, headings, tasks and block ids — with where each
/// is in the text (UTF-16, as the editor counts), so a link can be followed
/// and a task ticked in place. Pure: text in, structure out.
struct NoteDocument: Equatable, Sendable {
    struct Link: Equatable, Hashable, Sendable {
        /// What it points at, as written: `Folder/Note`, `Note.md`, `image.png`.
        var target: String
        /// `#Heading` or `#^block`, without the `#`.
        var heading: String?
        var block: String?
        var alias: String?
        /// `![[…]]` (or `![](…)`): shown in place, not linked to.
        var isEmbed = false
        /// `[text](path.md)` rather than `[[…]]`.
        var isMarkdown = false
        var range: NSRange
    }

    struct Tag: Equatable, Hashable, Sendable {
        /// Without `#`: `project/overterm`.
        var name: String
        var range: NSRange?
    }

    struct Heading: Equatable, Hashable, Sendable {
        var level: Int
        var text: String
        var line: Int
        var range: NSRange
    }

    struct Task: Equatable, Hashable, Sendable {
        var text: String
        /// The character between the brackets: " ", "x", "/", "-"…
        var status: Character
        var line: Int
        /// The status character itself, to tick it in place.
        var statusRange: NSRange
        var isDone: Bool { status == "x" || status == "X" }
    }

    /// The frontmatter as text, and parsed (JSON's shapes, through YAMLReader).
    var frontmatter: String?
    var frontmatterRange: NSRange?
    var properties: [String: PropertyValue] = [:]
    var links: [Link] = []
    var tags: [Tag] = []
    var headings: [Heading] = []
    var tasks: [Task] = []
    var blockIDs: [String] = []
    var aliases: [String] = []

    /// Every tag, frontmatter's and inline, once each.
    var allTags: [String] {
        var seen = Set<String>()
        return tags.map(\.name).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The first heading, or nil: what a note may be titled by.
    var title: String? { headings.first { $0.level == 1 }?.text }
}

/// A property's value, kept in the shapes YAML gives.
enum PropertyValue: Equatable, Hashable, Sendable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case list([String])
    case null

    init(_ any: Any) {
        switch any {
        case let string as String: self = .text(string)
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let list as [Any]: self = .list(list.map { "\($0)" })
        case is NSNull: self = .null
        default: self = .text("\(any)")
        }
    }

    var display: String {
        switch self {
        case .text(let text): text
        case .number(let number): number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let value): value ? "true" : "false"
        case .list(let items): items.joined(separator: ", ")
        case .null: ""
        }
    }

    var strings: [String] {
        switch self {
        case .list(let items): items
        case .text(let text): text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: []
        }
    }
}

enum NoteParser {
    static func parse(_ text: String) -> NoteDocument {
        var doc = NoteDocument()
        // A native NSString: a bridged Swift string pays for every UTF-16
        // offset, and a 2 MB note (agents' transcripts) took seconds.
        let ns = NSString(string: text)
        var bodyStart = 0

        // Frontmatter: `---` on the first line, to the next `---` or `...`.
        if text.hasPrefix("---\n") || text.hasPrefix("---\r\n") {
            let search = NSRange(location: 3, length: ns.length - 3)
            let close = ns.range(of: #"\r?\n(---|\.\.\.)[ \t]*(\r?\n|$)"#, options: .regularExpression, range: search)
            if close.location != NSNotFound {
                let start = text.hasPrefix("---\r\n") ? 5 : 4
                let yaml = ns.substring(with: NSRange(location: start, length: max(0, close.location - start)))
                doc.frontmatter = yaml
                doc.frontmatterRange = NSRange(location: 0, length: NSMaxRange(close))
                bodyStart = NSMaxRange(close)
                if let map = YAMLReader.parse(yaml) as? [String: Any] {
                    for (key, value) in map { doc.properties[key] = PropertyValue(value) }
                }
                for key in ["tags", "tag"] {
                    for tag in doc.properties[key]?.strings ?? [] {
                        doc.tags.append(NoteDocument.Tag(name: tag.hasPrefix("#") ? String(tag.dropFirst()) : tag, range: nil))
                    }
                }
                for key in ["aliases", "alias"] { doc.aliases += doc.properties[key]?.strings ?? [] }
            }
        }

        let code = codeRanges(in: ns, from: bodyStart)
        func inCode(_ location: Int) -> Bool { NoteParser.contains(code, location) }

        // Lines: headings, tasks, block ids.
        var lineNumber = ns.substring(to: bodyStart).components(separatedBy: "\n").count - 1
        var location = bodyStart
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            defer {
                location = NSMaxRange(lineRange)
                lineNumber += 1
            }
            guard !inCode(lineRange.location) else { continue }
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if let heading = match(#"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$"#, line) {
                doc.headings.append(
                    NoteDocument.Heading(level: heading[1].count, text: heading[2], line: lineNumber, range: lineRange))
            }
            if let task = match(#"^([ \t]*(?:[-*+]|\d+[.)])[ \t]+\[)(.)\][ \t]+(.*)$"#, line) {
                let status = NSRange(location: lineRange.location + (task[1] as NSString).length, length: 1)
                doc.tasks.append(NoteDocument.Task(text: task[3], status: Character(task[2]), line: lineNumber, statusRange: status))
            }
            if let block = match(#"\s\^([A-Za-z0-9-]+)$"#, line) { doc.blockIDs.append(block[1]) }
        }

        // Wikilinks and embeds.
        each(#"(!?)\[\[([^\[\]\n]+?)\]\]"#, in: ns, from: bodyStart) { groups, range in
            guard !inCode(range.location) else { return }
            // In a table the bar is escaped: `[[Note\|alias]]`.
            var inner = groups[2].replacingOccurrences(of: "\\|", with: "|")
            var alias: String?
            if let bar = inner.firstIndex(of: "|") {
                alias = String(inner[inner.index(after: bar)...])
                inner = String(inner[..<bar])
            }
            var target = inner
            var heading: String?
            var block: String?
            if let hash = inner.firstIndex(of: "#") {
                target = String(inner[..<hash])
                let anchor = String(inner[inner.index(after: hash)...])
                if anchor.hasPrefix("^") { block = String(anchor.dropFirst()) } else { heading = anchor }
            }
            doc.links.append(
                NoteDocument.Link(
                    target: target.trimmingCharacters(in: .whitespaces), heading: heading, block: block, alias: alias,
                    isEmbed: groups[1] == "!", range: range))
        }
        // Markdown links to files in the vault — not to the web.
        each(#"(!?)\[([^\]\n]*)\]\(([^)\s]+(?:\s[^)]*)?)\)"#, in: ns, from: bodyStart) { groups, range in
            guard !inCode(range.location) else { return }
            var destination = groups[3]
            if destination.hasPrefix("<"), destination.hasSuffix(">") { destination = String(destination.dropFirst().dropLast()) }
            guard !destination.contains("://"), !destination.hasPrefix("mailto:"), !destination.hasPrefix("#") else { return }
            let decoded = destination.removingPercentEncoding ?? destination
            var target = decoded
            var heading: String?
            if let hash = decoded.firstIndex(of: "#") {
                target = String(decoded[..<hash])
                heading = String(decoded[decoded.index(after: hash)...])
            }
            doc.links.append(
                NoteDocument.Link(
                    target: target, heading: heading, alias: groups[2].isEmpty ? nil : groups[2], isEmbed: groups[1] == "!", isMarkdown: true,
                    range: range))
        }
        doc.links.sort { $0.range.location < $1.range.location }

        // Inline tags: `#` after a space or the line's start, letters,
        // digits, _ - / and at least one that isn't a digit (Obsidian's rule).
        each(#"(?:^|(?<=[\s(]))#([\p{L}\p{N}_/\-]+)"#, in: ns, from: bodyStart, options: [.anchorsMatchLines]) { groups, range in
            guard !inCode(range.location) else { return }
            let name = groups[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty, name.contains(where: { !$0.isNumber }) else { return }
            doc.tags.append(NoteDocument.Tag(name: name, range: range))
        }
        return doc
    }

    // MARK: Code, which holds no links or tags

    /// Fenced blocks (``` or ~~~, to their closing fence or the end) and
    /// inline code spans.
    static func codeRanges(in ns: NSString, from start: Int = 0) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = start
        var fenceStart: Int?
        var fence = ""
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = fenceStart {
                if line.hasPrefix(fence), line.allSatisfy({ String($0) == String(fence.first!) }) {
                    ranges.append(NSRange(location: open, length: NSMaxRange(lineRange) - open))
                    fenceStart = nil
                }
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fenceStart = lineRange.location
                fence = String(line.prefix { $0 == line.first })
            }
            location = NSMaxRange(lineRange)
        }
        if let open = fenceStart { ranges.append(NSRange(location: open, length: ns.length - open)) }
        let blocks = ranges
        each("(`+)[^`\\n]+?\\1", in: ns, from: start) { _, range in
            if !contains(blocks, range.location) { ranges.append(range) }
        }
        return ranges.sorted { $0.location < $1.location }
    }

    /// Whether `location` is in one of `ranges` — sorted, not overlapping.
    static func contains(_ ranges: [NSRange], _ location: Int) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) <= location { low = mid + 1 } else { high = mid }
        }
        return low < ranges.count && NSLocationInRange(location, ranges[low])
    }

    // MARK: Regex

    private static func match(_ pattern: String, _ line: String) -> [String]? {
        guard let regex = cachedRegex(pattern, []),
            let found = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }
        return (0..<found.numberOfRanges).map { index in
            let range = found.range(at: index)
            return range.location == NSNotFound ? "" : (line as NSString).substring(with: range)
        }
    }

    private static func each(
        _ pattern: String, in ns: NSString, from start: Int, options: NSRegularExpression.Options = [],
        _ body: ([String], NSRange) -> Void
    ) {
        guard let regex = cachedRegex(pattern, options), start < ns.length else { return }
        regex.enumerateMatches(in: ns as String, range: NSRange(location: start, length: ns.length - start)) { found, _, _ in
            guard let found else { return }
            let groups = (0..<found.numberOfRanges).map { index -> String in
                let range = found.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            body(groups, found.range)
        }
    }

    private static let cache = RegexCache()

    private static func cachedRegex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression? {
        cache.regex(pattern, options)
    }
}

/// Compiled patterns, shared across threads (the index parses off the main one).
final class RegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var compiled: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        return lock.withLock {
            if let regex = compiled[key] { return regex }
            let regex = try? NSRegularExpression(pattern: pattern, options: options)
            compiled[key] = regex
            return regex
        }
    }
}
