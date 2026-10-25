import Foundation

/// What completion offers in a console: tables after FROM, a table's columns
/// after `alias.`, and elsewhere the columns of the statement's tables, the
/// keywords and the tables — from the connection's catalog. Pure.
enum SQLCompletion {
    struct Candidate: Equatable {
        enum Kind: Equatable { case table, view, column, schema, keyword }
        var label: String
        var insert: String
        var kind: Kind
        var detail: String
    }

    /// The catalog as far as it is read: tables by schema, columns by schema.
    struct Catalog {
        var schemas: [String]
        var defaultSchema: String?
        var tables: [String: [CatalogTable]]
        var columns: [String: [CatalogColumn]]

        func columns(of table: String, schema: String?) -> [CatalogColumn] {
            let schemas = schema.map { [$0] } ?? ([defaultSchema].compactMap { $0 } + self.schemas)
            for schema in schemas {
                let found = columns[schema]?.filter { $0.table.caseInsensitiveCompare(table) == .orderedSame } ?? []
                if !found.isEmpty { return found }
            }
            return []
        }
    }

    /// The schemas whose columns it needs and hasn't read — read, then asked again.
    static func missing(_ context: SQLText.CompletionContext, statement: String, catalog: Catalog) -> Set<String> {
        var wanted: Set<String> = []
        switch context {
        case .table(let schema, _):
            if let schema = schema ?? catalog.defaultSchema, catalog.tables[schema] == nil { wanted.insert(schema) }
        default:
            for table in SQLText.tables(in: statement) {
                if let schema = table.schema ?? catalog.defaultSchema, catalog.columns[schema] == nil { wanted.insert(schema) }
            }
            if case .qualifiedColumn = context, let schema = catalog.defaultSchema, catalog.columns[schema] == nil { wanted.insert(schema) }
        }
        return wanted
    }

    static func candidates(_ context: SQLText.CompletionContext, statement: String, catalog: Catalog) -> [Candidate] {
        switch context {
        case .table(let schema, let prefix):
            var found = tables(in: schema ?? catalog.defaultSchema, catalog: catalog)
            if schema == nil { found += catalog.schemas.map { Candidate(label: $0, insert: $0, kind: .schema, detail: "schema") } }
            return filter(found, prefix)
        case .qualifiedColumn(let qualifier, let prefix):
            let named = SQLText.tables(in: statement)
            // An alias, else a table's own name, else a schema (its tables).
            if let table = named.first(where: { $0.alias?.caseInsensitiveCompare(qualifier) == .orderedSame })
                ?? named.first(where: { $0.name.caseInsensitiveCompare(qualifier) == .orderedSame })
            {
                return filter(columns(of: table.name, schema: table.schema, catalog: catalog), prefix)
            }
            let direct = columns(of: qualifier, schema: nil, catalog: catalog)
            if !direct.isEmpty { return filter(direct, prefix) }
            if catalog.schemas.contains(where: { $0.caseInsensitiveCompare(qualifier) == .orderedSame }) {
                return filter(tables(in: qualifier, catalog: catalog), prefix)
            }
            return []
        case .any(let prefix):
            guard !prefix.isEmpty else { return [] }
            var found: [Candidate] = []
            for table in SQLText.tables(in: statement) {
                found += columns(of: table.name, schema: table.schema, catalog: catalog)
            }
            // Keywords in the case being typed.
            let lower = prefix.first?.isLowercase == true
            found += SQLText.keywords.map { Candidate(label: lower ? $0.lowercased() : $0, insert: lower ? $0.lowercased() : $0, kind: .keyword, detail: "") }
            found += tables(in: catalog.defaultSchema, catalog: catalog)
            var seen = Set<String>()
            return filter(found, prefix).filter { seen.insert("\($0.kind)|\($0.label.lowercased())").inserted }
        }
    }

    private static func tables(in schema: String?, catalog: Catalog) -> [Candidate] {
        guard let schema else { return [] }
        return (catalog.tables[schema] ?? []).map {
            Candidate(label: $0.name, insert: $0.name, kind: $0.isView ? .view : .table, detail: schema)
        }
    }

    private static func columns(of table: String, schema: String?, catalog: Catalog) -> [Candidate] {
        catalog.columns(of: table, schema: schema).map {
            Candidate(label: $0.name, insert: $0.name, kind: .column, detail: "\(table) · \($0.type)")
        }
    }

    /// Those that start with the prefix first, then those that hold it.
    static func filter(_ candidates: [Candidate], _ prefix: String) -> [Candidate] {
        guard !prefix.isEmpty else { return candidates }
        let starts = candidates.filter { $0.label.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil }
        let holds = candidates.filter {
            $0.label.range(of: prefix, options: [.caseInsensitive, .anchored]) == nil && $0.label.localizedCaseInsensitiveContains(prefix)
        }
        // An exact word already typed isn't offered back.
        return (starts + holds).filter { $0.label != prefix }
    }
}
