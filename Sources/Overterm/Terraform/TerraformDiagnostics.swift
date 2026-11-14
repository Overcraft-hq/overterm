import Foundation

/// One of Terraform's diagnostics, as `validate -json` (and later a plan's
/// stream) gives it, decoded through an allow-list (analysis 5.6 rule 10):
/// severity, summary, detail, the range and the snippet's code. The
/// snippet's `values` — which can hold a variable's value — never are.
struct TerraformDiagnostic: Equatable, Sendable {
    enum Severity: String, Sendable { case error, warning }

    /// 1-based line; 1-based column in characters (HCL counts grapheme
    /// clusters, as Swift's `Character` does); 0-based byte offset.
    struct Position: Equatable, Sendable {
        var line: Int
        var column: Int
        var byte: Int
    }

    var severity: Severity
    var summary: String
    var detail: String
    /// The file, relative to the folder terraform ran in.
    var file: String?
    var start: Position?
    var end: Position?
    var code: String?
    /// The resource an apply's error is about (`diagnostic.address`, 2a).
    var address: String? = nil

    /// What the editor says over the squiggle.
    var message: String { detail.isEmpty ? summary : "\(summary): \(detail)" }
}

/// What `terraform validate -json` said about a folder. Pure.
struct TerraformValidation: Equatable, Sendable {
    var valid: Bool
    var diagnostics: [TerraformDiagnostic]

    var errors: Int { diagnostics.filter { $0.severity == .error }.count }
    var warnings: Int { diagnostics.filter { $0.severity == .warning }.count }

    /// The folder isn't initialised, so validate can't say anything of its
    /// code: a provider or module not installed, no backend set up, a lock
    /// file out of step (analysis 4.12: "needs init" is a diagnostic, never
    /// a missing `.terraform` folder).
    var needsInit: Bool { diagnostics.contains { $0.severity == .error && Self.isInitDiagnostic($0) } }

    static let initSummaries: Set<String> = [
        "Missing required provider", "Missing required providers", "Module not installed", "Backend initialization required",
        "Required plugins are not installed", "Inconsistent dependency lock file", "Module source has changed", "Module version requirements have changed",
        "Failed to load plugin schemas",
    ]

    static func isInitDiagnostic(_ diagnostic: TerraformDiagnostic) -> Bool {
        initSummaries.contains(diagnostic.summary) || diagnostic.detail.contains("terraform init")
    }

    enum DecodeError: Error, Equatable { case notJSON, unknownFormat(String) }

    /// What runs over every kept string: credentials in text, URLs' passwords.
    static func scrub(_ text: String) -> String {
        Secrets.maskURLs(in: Secrets.scrubCredentials(text))
    }

    /// `validate -json`'s output. Its `format_version` is "1.0": a later
    /// major is refused, a minor read (analysis 4.15). Every other key is
    /// dropped. `scrub` runs over every kept string (`Secrets`' rules, for
    /// a detail that quotes a value).
    static func decode(_ data: Data, scrub: (String) -> String = { $0 }) throws -> TerraformValidation {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DecodeError.notJSON }
        if let version = object["format_version"] as? String, let major = version.split(separator: ".").first, major != "1" {
            throw DecodeError.unknownFormat(version)
        }
        let diagnostics = (object["diagnostics"] as? [[String: Any]] ?? []).map { decodeDiagnostic($0, scrub: scrub) }
        return TerraformValidation(valid: object["valid"] as? Bool ?? false, diagnostics: diagnostics)
    }

    static func decodeDiagnostic(_ object: [String: Any], scrub: (String) -> String) -> TerraformDiagnostic {
        func position(_ value: Any?) -> TerraformDiagnostic.Position? {
            guard let value = value as? [String: Any], let line = value["line"] as? Int else { return nil }
            return .init(line: line, column: value["column"] as? Int ?? 1, byte: value["byte"] as? Int ?? 0)
        }
        let range = object["range"] as? [String: Any]
        let snippet = object["snippet"] as? [String: Any]
        return TerraformDiagnostic(
            severity: (object["severity"] as? String).flatMap(TerraformDiagnostic.Severity.init(rawValue:)) ?? .error,
            summary: scrub(object["summary"] as? String ?? ""), detail: scrub(object["detail"] as? String ?? ""),
            file: range?["filename"] as? String, start: position(range?["start"]), end: position(range?["end"]),
            code: (snippet?["code"] as? String).map(scrub), address: (object["address"] as? String).map { scrub(String($0.prefix(1_024))) })
    }

    /// The UTF-16 range of `start`..`end` in `text`, by line and column
    /// (characters, as HCL counts them), clamped to the text: a diagnostic
    /// of the file on disk laid over the buffer's text. A diagnostic with
    /// no end marks its start's character; one past the last line, the end.
    static func range(from start: TerraformDiagnostic.Position, to end: TerraformDiagnostic.Position?, in text: NSString) -> NSRange {
        let starts = lineStarts(text)
        func offset(_ position: TerraformDiagnostic.Position) -> Int {
            let line = position.line - 1
            guard line >= 0 else { return 0 }
            guard line < starts.count else { return text.length }
            let lineStart = starts[line]
            var lineEnd = line + 1 < starts.count ? starts[line + 1] : text.length
            while lineEnd > lineStart, [0x0A, 0x0D].contains(text.character(at: lineEnd - 1)) { lineEnd -= 1 }
            let content = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            var index = content.startIndex
            for _ in 0..<max(0, position.column - 1) {
                guard index < content.endIndex else { break }
                index = content.index(after: index)
            }
            return lineStart + content.utf16.distance(from: content.utf16.startIndex, to: index.samePosition(in: content.utf16) ?? content.utf16.endIndex)
        }
        let from = offset(start)
        var to = end.map(offset) ?? from
        if to <= from { to = min(text.length, from + 1) }
        return NSRange(location: from, length: max(0, to - from))
    }

    private static func lineStarts(_ text: NSString) -> [Int] {
        var starts = [0]
        for index in 0..<text.length where text.character(at: index) == 0x0A { starts.append(index + 1) }
        return starts
    }
}
