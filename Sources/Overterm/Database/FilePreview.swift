import Foundation

/// What a stored file is shown as, from its name and its first bytes:
/// rows (CSV, TSV, JSON Lines), JSON pretty-printed, text, an image, a PDF
/// — or nothing to show. Pure.
enum FilePreview: Equatable {
    case table(QueryResult)
    case text(String, truncated: Bool)
    case image
    case pdf
    case none

    /// The first this many bytes are read for a text-like preview.
    static let textLimit: Int64 = 2 << 20
    /// Images and PDFs are read whole up to this.
    static let fileLimit: Int64 = 30 << 20

    enum Kind: Equatable { case table(Character?), json, text, image, pdf, other }

    static func kind(of name: String) -> Kind {
        switch (name as NSString).pathExtension.lowercased() {
        case "csv": .table(",")
        case "tsv", "tab": .table("\t")
        case "jsonl", "ndjson": .table(nil)
        case "json", "geojson": .json
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "tif", "svg", "ico": .image
        case "pdf": .pdf
        case "txt", "log", "md", "yaml", "yml", "xml", "html", "htm", "css", "js", "ts", "tsx", "jsx", "sql", "sh", "py", "rb", "go", "rs",
            "swift", "java", "kt", "c", "h", "cpp", "toml", "ini", "conf", "env", "properties", "csv.gz.txt", "gitignore", "dockerfile":
            .text
        case "": .text
        default: .other
        }
    }

    /// The preview of `data` — the file's first bytes when `truncated`.
    static func make(name: String, data: Data, truncated: Bool, rowLimit: Int = 5000) -> FilePreview {
        switch kind(of: name) {
        case .image: return .image
        case .pdf: return .pdf
        case .other:
            // Text after all, when it reads as UTF-8 with no NULs.
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return .none }
            return .text(text, truncated: truncated)
        case .text:
            return .text(String(decoding: data, as: UTF8.self), truncated: truncated)
        case .json:
            let text = String(decoding: data, as: UTF8.self)
            if !truncated, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
            {
                return .text(String(decoding: pretty, as: UTF8.self), truncated: false)
            }
            return .text(text, truncated: truncated)
        case .table(let separator):
            var text = String(decoding: data, as: UTF8.self)
            // A cut file's last line is half a row.
            if truncated, let end = text.lastIndex(of: "\n") { text = String(text[..<end]) }
            var result = separator.map { delimited(text, separator: $0, limit: rowLimit) } ?? jsonLines(text, limit: rowLimit)
            result.truncated = result.truncated || truncated
            return .table(result)
        }
    }

    /// CSV (RFC 4180: quotes, doubled quotes, newlines inside quotes) or TSV;
    /// the first row is the header.
    static func delimited(_ text: String, separator: Character, limit: Int) -> QueryResult {
        var rows: [[String?]] = []
        var row: [String?] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?
        var more = false
        func endRow() {
            row.append(field)
            field = ""
            if !(row.count == 1 && row[0] == "") { rows.append(row) }
            row = []
        }
        while let c = pending ?? iterator.next() {
            pending = nil
            if rows.count > limit {
                more = true
                break
            }
            if quoted {
                if c == "\"" {
                    let next = iterator.next()
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        quoted = false
                        pending = next
                    }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty: quoted = true
            case separator:
                row.append(field)
                field = ""
            case "\n", "\r\n": endRow()
            case "\r": continue
            default: field.append(c)
            }
        }
        if !more, !field.isEmpty || !row.isEmpty { endRow() }
        guard let header = rows.first else { return QueryResult() }
        let width = header.count
        let body = rows.dropFirst().prefix(limit).map { row in (0..<width).map { $0 < row.count ? row[$0] : nil } }
        return QueryResult(
            columns: header.map { $0 ?? "" }, types: [], rows: Array(body), truncated: more || rows.count - 1 > limit)
    }

    /// JSON Lines: an object a line; the columns are every key seen, in order.
    static func jsonLines(_ text: String, limit: Int) -> QueryResult {
        var columns: [String] = []
        var objects: [[String: Any]] = []
        var more = false
        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if objects.count >= limit {
                more = true
                break
            }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            for key in object.keys.sorted() where !columns.contains(key) { columns.append(key) }
            objects.append(object)
        }
        let rows = objects.map { object in columns.map { object[$0].flatMap(ClickHouseDriver.text) } }
        return QueryResult(columns: columns, types: [], rows: rows, truncated: more)
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// A file's type for an upload, from its name.
    static func contentType(of name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "json": "application/json"
        case "csv": "text/csv"
        case "txt", "log": "text/plain"
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "js": "text/javascript"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "pdf": "application/pdf"
        case "zip": "application/zip"
        case "gz": "application/gzip"
        case "parquet": "application/vnd.apache.parquet"
        case "xml": "application/xml"
        case "md": "text/markdown"
        default: "application/octet-stream"
        }
    }
}
