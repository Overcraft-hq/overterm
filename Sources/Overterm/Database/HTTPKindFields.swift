import SwiftUI

/// An address pasted into the form of DynamoDB, InfluxDB, Neo4j or RabbitMQ, spread
/// over the connection's fields: its host, port, TLS, a region from AWS's
/// endpoint, Neo4j's `neo4j+s://` and `bolt://` as the HTTP API's place,
/// RabbitMQ's `amqp(s)://…/vhost` as its management API's.
/// A password in it is handed back — the form keeps it, then the keychain.
/// Pure.
enum KindAddress {
    struct Filled: Equatable {
        var connection: DatabaseConnection
        var password: String?
    }

    static func fill(_ connection: DatabaseConnection, from text: String) -> Filled? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let components = URLComponents(string: text.contains("://") ? text : "http://" + text),
            let host = components.host, !host.isEmpty
        else { return nil }
        var connection = connection
        let scheme = components.scheme?.lowercased() ?? "http"
        let tls = scheme == "https" || scheme == "amqps" || scheme.hasSuffix("+s") || scheme.hasSuffix("+ssc")
        connection.host = host
        // A self-signed certificate (`+ssc`) isn't checked.
        connection.sslMode = !tls ? .disable : scheme.hasSuffix("+ssc") ? .require : .verifyFull
        switch connection.kind {
        case .neo4j:
            let bolt = ["neo4j", "bolt"].contains(scheme.split(separator: "+").first.map(String.init) ?? "")
            // Bolt's port says nothing of the HTTP API's; Aura's is 443.
            if bolt {
                connection.port = host.hasSuffix(".databases.neo4j.io") ? 443 : tls ? 7473 : 7474
            } else {
                connection.port = components.port ?? (tls ? 443 : 7474)
            }
            let path = components.path.split(separator: "/").map(String.init)
            if path.count >= 2, path[0] == "db" { connection.database = path[1] }
        case .rabbitmq:
            let amqp = scheme.hasPrefix("amqp")
            let path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if amqp {
                // AMQP's port says nothing of the management API's; a hosted
                // broker (CloudAMQP) serves it on 443.
                connection.port = host.hasSuffix(".cloudamqp.com") ? 443 : tls ? 15671 : 15672
                connection.basePath = ""
                // The path is the vhost, `/` as %2F — none is `/`.
                connection.database = path.isEmpty ? "/" : path.removingPercentEncoding ?? path
            } else {
                connection.port = components.port ?? (tls ? 443 : 15672)
                // The UI's address (`/#/queues`) or the API's (`/api`): the part before is a proxy's.
                var base = path
                if base == "api" { base = "" } else if base.hasSuffix("/api") { base = String(base.dropLast(4)) }
                connection.basePath = base.isEmpty ? "" : "/" + base
            }
        case .dynamodb:
            connection.port = components.port ?? (tls ? nil : 8000)
            if DynamoItems.isAWS(host) {
                let parts = host.split(separator: ".").map(String.init)
                if let at = parts.firstIndex(of: "dynamodb"), at + 1 < parts.count, parts[at + 1] != "amazonaws" { connection.location = parts[at + 1] }
                connection.port = components.port
            }
        default:
            connection.port = components.port ?? (tls ? 443 : connection.kind.defaultPort)
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            connection.basePath = path.isEmpty ? "" : "/" + path
        }
        if let user = components.user, !user.isEmpty { connection.user = user.removingPercentEncoding ?? user }
        // InfluxDB's address may carry what it needs: `?org=…&bucket=…`, `?db=…`.
        if connection.kind == .influxdb {
            for item in components.queryItems ?? [] {
                guard let value = item.value, !value.isEmpty else { continue }
                switch item.name {
                case "org": connection.project = value
                case "bucket", "db", "database": connection.database = value
                default: break
                }
            }
        }
        if connection.name.isEmpty || connection.name == connection.kind.title { connection.name = host }
        return Filled(connection: connection, password: components.password.map { $0.removingPercentEncoding ?? $0 })
    }
}

/// DynamoDB's, InfluxDB's and Neo4j's fields in the connection form.
struct HTTPKindFields: View {
    @Binding var connection: DatabaseConnection
    @Binding var password: String
    let hasSavedPassword: Bool
    /// Something changed: the last test says nothing any more.
    let changed: () -> Void

    var body: some View {
        TextField("URL", text: Binding(get: { "" }, set: { paste($0) }), prompt: Text(verbatim: prompt))
        switch connection.kind {
        case .dynamodb: dynamoFields
        case .influxdb: influxFields
        case .rabbitmq: rabbitFields
        default: neo4jFields
        }
    }

    private var prompt: String {
        switch connection.kind {
        case .dynamodb: "Paste http://localhost:8000 or https://dynamodb.eu-west-1.amazonaws.com"
        case .influxdb: "Paste http://localhost:8086 — ?org=…&bucket=… for 2.x"
        case .rabbitmq: "Paste http://host:15672 or amqps://user:password@host/vhost"
        default: "Paste neo4j+s://…, bolt://host:7687 or http://host:7474"
        }
    }

    private func paste(_ text: String) {
        guard let filled = KindAddress.fill(connection, from: text) else { return }
        connection = filled.connection
        if let secret = filled.password { password = secret }
        changed()
    }

    private var portField: some View {
        TextField(
            "Port",
            text: Binding(
                get: { connection.port.map(String.init) ?? "" },
                set: { connection.port = Int($0.filter(\.isNumber)) }))
    }

    private var tlsPicker: some View {
        Picker("TLS", selection: $connection.sslMode) {
            Text("Off — http").tag(DatabaseSSLMode.disable)
            Text("On — don't check the certificate").tag(DatabaseSSLMode.require)
            Text("On — verify the certificate").tag(DatabaseSSLMode.verifyFull)
        }
        .onAppear { if connection.sslMode == .prefer { connection.sslMode = .disable } }
    }

    private var secretPrompt: String { hasSavedPassword ? " (saved — empty keeps it)" : "" }

    // MARK: DynamoDB

    private var onAWS: Bool { DynamoItems.isAWS(connection.host) }

    @ViewBuilder private var dynamoFields: some View {
        Picker(
            "Endpoint",
            selection: Binding(
                get: { onAWS },
                set: { aws in
                    if aws {
                        connection.host = DynamoItems.endpoint(region: connection.location)
                        connection.port = nil
                        connection.sslMode = .verifyFull
                    } else {
                        connection.host = "localhost"
                        connection.port = 8000
                        connection.sslMode = .disable
                    }
                    changed()
                })
        ) {
            Text("AWS").tag(true)
            Text("DynamoDB Local, or another").tag(false)
        }
        TextField("Region", text: $connection.location, prompt: Text(verbatim: "us-east-1"))
            .onChange(of: connection.location) { region in
                if onAWS { connection.host = DynamoItems.endpoint(region: region) }
            }
        if !onAWS {
            TextField("Host", text: $connection.host)
            portField
            tlsPicker
        }
        let profiles = AWSProfile.names()
        if !profiles.isEmpty {
            Picker("Credentials", selection: $connection.awsProfile) {
                Text("Access key").tag("")
                ForEach(profiles, id: \.self) { Text("AWS profile: \($0)").tag($0) }
            }
        }
        if connection.awsProfile.isEmpty {
            TextField(onAWS ? "Access key ID" : "Access key ID (optional — DynamoDB Local takes any)", text: $connection.user)
            SecureField("Secret access key" + secretPrompt, text: $password)
        }
    }

    // MARK: InfluxDB

    private var version: InfluxVersion? { InfluxVersion(rawValue: connection.location) }

    @ViewBuilder private var influxFields: some View {
        TextField("Host", text: $connection.host)
        portField
        Picker("Version", selection: $connection.location) {
            Text("Ask the server (/ping)").tag("")
            ForEach(InfluxVersion.allCases) { Text($0.title).tag($0.rawValue) }
        }
        switch version {
        case .v1:
            TextField("User (optional)", text: $connection.user)
            SecureField("Password" + secretPrompt, text: $password)
            TextField("Database", text: $connection.database)
        case .v2:
            SecureField("Token" + secretPrompt, text: $password)
            TextField("Organization", text: $connection.project)
            TextField("Bucket (for InfluxQL and WRITE)", text: $connection.database)
        case .v3:
            SecureField("Token (optional)" + secretPrompt, text: $password)
            TextField("Database", text: $connection.database)
        case nil:
            TextField("User (1.x only)", text: $connection.user)
            SecureField("Password, or a token" + secretPrompt, text: $password)
            TextField("Organization (2.x)", text: $connection.project)
            TextField("Database or bucket", text: $connection.database)
        }
        tlsPicker
    }

    // MARK: RabbitMQ

    @ViewBuilder private var rabbitFields: some View {
        TextField("Host", text: $connection.host)
        TextField(
            "Management port",
            text: Binding(
                get: { connection.port.map(String.init) ?? "" },
                set: { connection.port = Int($0.filter(\.isNumber)) }),
            prompt: Text(verbatim: "15672 — 15671 with TLS; not AMQP's 5672"))
        TextField("User", text: $connection.user, prompt: Text(verbatim: "guest"))
        SecureField("Password" + secretPrompt, text: $password)
        TextField("Vhost", text: $connection.database, prompt: Text(verbatim: "/"))
        TextField("Path (behind a proxy)", text: $connection.basePath, prompt: Text(verbatim: "/rabbitmq"))
        tlsPicker
    }

    // MARK: Neo4j

    @ViewBuilder private var neo4jFields: some View {
        TextField("Host", text: $connection.host)
        TextField(
            "HTTP port",
            text: Binding(
                get: { connection.port.map(String.init) ?? "" },
                set: { connection.port = Int($0.filter(\.isNumber)) }),
            prompt: Text(verbatim: "7474 — 7473 with TLS; not Bolt's 7687"))
        TextField("User", text: $connection.user, prompt: Text(verbatim: "neo4j"))
        SecureField("Password" + secretPrompt, text: $password)
        TextField("Database", text: $connection.database, prompt: Text(verbatim: "neo4j"))
        tlsPicker
    }
}
