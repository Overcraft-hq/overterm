import Foundation

/// A GraphQL server's schema, as its introspection answers — pure, so it is
/// tested without a server: the types, their fields and arguments, and what
/// can be written at a place in a query (the fields of the type there, an
/// argument's name, a type after `on`).
struct GraphQLSchema: Equatable, Sendable {
    struct TypeRef: Equatable, Sendable {
        var kind: String
        var name: String?
        var ofType: [TypeRef]

        /// The named type under any lists and non-nulls: `[User!]!` → User.
        var named: String? { name ?? ofType.first?.named }

        /// As a query writes it: `[User!]!`.
        var display: String {
            switch kind {
            case "NON_NULL": (ofType.first?.display ?? "?") + "!"
            case "LIST": "[" + (ofType.first?.display ?? "?") + "]"
            default: name ?? "?"
            }
        }
    }

    struct Argument: Equatable, Sendable {
        var name: String
        var type: TypeRef
        var description: String?
        var defaultValue: String?
    }

    struct Field: Equatable, Sendable {
        var name: String
        var type: TypeRef
        var arguments: [Argument]
        var description: String?
        var deprecation: String?
    }

    struct NamedType: Equatable, Sendable {
        var kind: String
        var name: String
        var description: String?
        var fields: [Field]
        var inputFields: [Argument]
        var enumValues: [String]
        var interfaces: [String]
        var possibleTypes: [String]

        /// A type a query names a field of: an object, an interface, a union.
        var isComposite: Bool { ["OBJECT", "INTERFACE", "UNION"].contains(kind) }
    }

    var queryType: String?
    var mutationType: String?
    var subscriptionType: String?
    var types: [String: NamedType]

    /// The types a person reads, not the schema's own (`__Type`…), roots first.
    var browsable: [NamedType] {
        let roots = [queryType, mutationType, subscriptionType].compactMap { $0 }
        let rest = types.values.filter { !$0.name.hasPrefix("__") && !roots.contains($0.name) }.sorted { $0.name < $1.name }
        return roots.compactMap { types[$0] } + rest
    }

    // MARK: Reading introspection

    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// From the answer to `introspectionQuery`: `{"data": {"__schema": …}}`,
    /// or what the server said instead.
    static func parse(_ data: Data) throws -> GraphQLSchema {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
            throw Failure(message: "The server didn't answer with JSON: \(text)")
        }
        guard let schema = (object["data"] as? [String: Any])?["__schema"] as? [String: Any] else {
            let errors = (object["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String } ?? []
            throw Failure(
                message: errors.isEmpty ? "No schema in the answer — introspection may be off on this server." : errors.joined(separator: "\n"))
        }
        func name(_ key: String) -> String? { (schema[key] as? [String: Any])?["name"] as? String }
        var types: [String: NamedType] = [:]
        for type in schema["types"] as? [[String: Any]] ?? [] {
            guard let named = type["name"] as? String else { continue }
            types[named] = NamedType(
                kind: type["kind"] as? String ?? "",
                name: named,
                description: type["description"] as? String,
                fields: (type["fields"] as? [[String: Any]] ?? []).map(field),
                inputFields: (type["inputFields"] as? [[String: Any]] ?? []).map(argument),
                enumValues: (type["enumValues"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                interfaces: (type["interfaces"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                possibleTypes: (type["possibleTypes"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        }
        return GraphQLSchema(queryType: name("queryType"), mutationType: name("mutationType"), subscriptionType: name("subscriptionType"), types: types)
    }

    private static func typeRef(_ any: Any?) -> TypeRef {
        let object = any as? [String: Any] ?? [:]
        return TypeRef(kind: object["kind"] as? String ?? "", name: object["name"] as? String, ofType: object["ofType"].map { [typeRef($0)] } ?? [])
    }

    private static func field(_ object: [String: Any]) -> Field {
        Field(
            name: object["name"] as? String ?? "", type: typeRef(object["type"]),
            arguments: (object["args"] as? [[String: Any]] ?? []).map(argument), description: object["description"] as? String,
            deprecation: (object["isDeprecated"] as? Bool == true) ? (object["deprecationReason"] as? String ?? "deprecated") : nil)
    }

    private static func argument(_ object: [String: Any]) -> Argument {
        Argument(
            name: object["name"] as? String ?? "", type: typeRef(object["type"]), description: object["description"] as? String,
            defaultValue: object["defaultValue"] as? String)
    }

    /// The query every GraphQL IDE sends for a schema — seven levels of
    /// `ofType`, as GraphiQL's.
    static let introspectionQuery = """
        query IntrospectionQuery {
          __schema {
            queryType { name }
            mutationType { name }
            subscriptionType { name }
            types { ...FullType }
          }
        }
        fragment FullType on __Type {
          kind name description
          fields(includeDeprecated: true) { name description args { ...InputValue } type { ...TypeRef } isDeprecated deprecationReason }
          inputFields { ...InputValue }
          interfaces { ...TypeRef }
          enumValues(includeDeprecated: true) { name description isDeprecated deprecationReason }
          possibleTypes { ...TypeRef }
        }
        fragment InputValue on __InputValue { name description type { ...TypeRef } defaultValue }
        fragment TypeRef on __Type {
          kind name
          ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } } }
        }
        """

    // MARK: Completion

    /// What can be written where the caret is, given the query up to it.
    enum Place: Equatable {
        /// A field of this type (inside its selection set).
        case field(String)
        /// An argument of this field of this type (inside its parentheses).
        case argument(type: String, field: String)
        /// A type's name (after `on`, or a variable's type).
        case type
        /// The start of a document: `query`, `mutation`, a `{`.
        case document
    }

    /// The type at each `{` the caret is inside, the field the parentheses
    /// it is inside belong to — read from the text alone, strings and
    /// comments skipped, so a query that doesn't parse yet still completes.
    func place(before text: String) -> Place {
        var stack: [String?] = []
        var lastField: String?
        var pendingType: String?
        var argumentOf: (type: String, field: String)?
        var parenDepth = 0
        var afterOn = false
        var operation: String?
        var inVariables = false
        var expectingType = false
        var word = ""
        let chars = Array(text)
        var index = 0

        func flushWord() {
            guard !word.isEmpty else { return }
            defer { word = "" }
            if expectingType {
                expectingType = false
                return
            }
            if afterOn {
                pendingType = word
                afterOn = false
                return
            }
            if parenDepth == 0 && stack.isEmpty {
                if ["query", "mutation", "subscription"].contains(word) { operation = word }
                return
            }
            if word == "on" {
                afterOn = true
                return
            }
            guard parenDepth == 0, let current = stack.last ?? nil else { return }
            // An alias's name comes before a colon; the field is the word after.
            lastField = word
            pendingType = types[current]?.fields.first { $0.name == word }?.type.named
        }

        while index < chars.count {
            let c = chars[index]
            if c == "#" {
                flushWord()
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if c == "\"" {
                flushWord()
                // A block string, or a plain one.
                if index + 2 < chars.count, chars[index + 1] == "\"", chars[index + 2] == "\"" {
                    index += 3
                    while index + 2 < chars.count, !(chars[index] == "\"" && chars[index + 1] == "\"" && chars[index + 2] == "\"") { index += 1 }
                    index += 3
                } else {
                    index += 1
                    while index < chars.count, chars[index] != "\"" {
                        if chars[index] == "\\" { index += 1 }
                        index += 1
                    }
                    index += 1
                }
                continue
            }
            if c.isLetter || c.isNumber || c == "_" {
                word.append(c)
                index += 1
                continue
            }
            flushWord()
            switch c {
            case "{":
                if stack.isEmpty {
                    let root = operation == "mutation" ? mutationType : operation == "subscription" ? subscriptionType : queryType
                    stack.append(pendingType ?? root)
                } else {
                    stack.append(pendingType)
                }
                pendingType = nil
                lastField = nil
            case "}":
                if !stack.isEmpty { stack.removeLast() }
                pendingType = nil
            case "(":
                parenDepth += 1
                if stack.isEmpty {
                    inVariables = true
                } else if parenDepth == 1, let current = stack.last ?? nil, let field = lastField {
                    argumentOf = (current, field)
                }
            case ")":
                parenDepth = max(0, parenDepth - 1)
                if parenDepth == 0 {
                    argumentOf = nil
                    inVariables = false
                }
            case ":":
                if inVariables { expectingType = true }
                // `alias: field` — the field comes next; the alias was no field.
                if parenDepth == 0 { pendingType = nil }
            default:
                break
            }
            index += 1
        }
        if afterOn || expectingType { return .type }
        if parenDepth > 0 {
            if inVariables { return .type }
            if let argumentOf { return .argument(type: argumentOf.type, field: argumentOf.field) }
        }
        if let current = stack.last ?? nil { return .field(current) }
        return .document
    }

    struct Candidate: Equatable {
        var label: String
        var detail: String
    }

    /// The word being typed, and what may finish it.
    func complete(before text: String) -> (typed: String, candidates: [Candidate]) {
        let typed = String(text.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed())
        let place = place(before: String(text.dropLast(typed.count)))
        var out: [Candidate]
        switch place {
        case .field(let type):
            guard let named = types[type] else { return (typed, []) }
            out = named.fields.map { Candidate(label: $0.name, detail: $0.type.display) }
            if named.kind != "OBJECT" || !named.possibleTypes.isEmpty { out.append(Candidate(label: "__typename", detail: "String!")) }
        case .argument(let type, let field):
            out = (types[type]?.fields.first { $0.name == field }?.arguments ?? []).map { Candidate(label: $0.name, detail: $0.type.display) }
        case .type:
            out = browsable.map { Candidate(label: $0.name, detail: $0.kind.lowercased()) }
        case .document:
            out = ["query", "mutation", "subscription", "fragment"].map { Candidate(label: $0, detail: "") }
        }
        let lower = typed.lowercased()
        let matching = typed.isEmpty ? out : out.filter { $0.label.lowercased().hasPrefix(lower) && $0.label != typed }
        return (typed, matching)
    }
}
