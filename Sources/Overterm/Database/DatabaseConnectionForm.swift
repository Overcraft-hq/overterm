import AppKit
import SwiftUI

/// New Connection… and Edit Connection…: what a connection is, by its kind,
/// tried before it is saved. A password left empty while editing keeps the
/// one in the keychain.
struct DatabaseConnectionForm: View {
    @State var connection: DatabaseConnection
    let isNew: Bool
    let store: DatabaseStore
    let done: (DatabaseConnection?) -> Void
    /// Filled in from elsewhere (a container's env): shown masked, kept
    /// only if the connection is saved — then in the keychain.
    var suggestedPassword = ""

    @State private var password = ""
    @State private var serviceAccount = ""
    @State private var sshSecret = ""
    @State private var testing = false
    @State private var tested: Result<String, Error>?
    @State private var problem: String?

    private var hasSavedPassword: Bool { !isNew && store.secrets.value(.password, for: connection.id) != nil }
    private var hasSavedKey: Bool { !isNew && store.secrets.value(.serviceAccount, for: connection.id) != nil }
    private var hasSavedSSH: Bool { !isNew && store.secrets.value(.ssh, for: connection.id) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Connection" : "Edit Connection").font(.system(size: 15, weight: .semibold))
                .onAppear { if password.isEmpty { password = suggestedPassword } }
            Form {
                TextField("Name", text: $connection.name)
                Picker("Database", selection: $connection.kind) {
                    ForEach(DatabaseKind.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: connection.kind) { kind in
                    connection.port = kind.defaultPort
                    if kind == .s3 { connection.apply(connection.provider) }
                    if kind == .gcs { connection.bigQueryAuth = .gcloud }
                    tested = nil
                }
                switch connection.kind {
                case .sqlite: sqliteFields
                case .bigquery: bigQueryFields
                case .s3: s3Fields
                case .gcs: gcsFields
                default: serverFields
                }
                Toggle("Read-only — refuse anything that writes", isOn: $connection.readOnly)
            }
            .formStyle(.grouped)
            .frame(minHeight: 300)
            status
            HStack {
                Button(testing ? "Testing…" : "Test Connection", action: test).disabled(testing)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    @ViewBuilder private var serverFields: some View {
        TextField("Host", text: $connection.host)
        TextField(
            "Port",
            text: Binding(
                get: { connection.port.map(String.init) ?? "" },
                set: { connection.port = Int($0.filter(\.isNumber)) }))
        TextField("User", text: $connection.user)
        SecureField(hasSavedPassword ? "Password (saved — empty keeps it)" : "Password", text: $password)
        TextField(connection.kind == .clickhouse ? "Database (default)" : "Database", text: $connection.database)
        Picker("SSL", selection: $connection.sslMode) {
            ForEach(DatabaseSSLMode.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Through an SSH tunnel", isOn: $connection.sshEnabled)
        if connection.sshEnabled { sshFields }
    }

    /// The bastion: Host and Port above are the database as the bastion sees it.
    @ViewBuilder private var sshFields: some View {
        TextField("SSH host (a name from ~/.ssh/config works)", text: $connection.sshHost)
        TextField(
            "SSH port",
            text: Binding(
                get: { connection.sshPort.map(String.init) ?? "" },
                set: { connection.sshPort = Int($0.filter(\.isNumber)) }))
        TextField("SSH user (optional)", text: $connection.sshUser)
        HStack {
            TextField("Private key (optional — else ~/.ssh and your agent)", text: $connection.sshKeyFile)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.showsHiddenFiles = true
                panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
                if panel.runModal() == .OK, let url = panel.url {
                    connection.sshKeyFile = (url.path as NSString).abbreviatingWithTildeInPath
                }
            }
        }
        SecureField(
            hasSavedSSH ? "SSH password or key passphrase (saved — empty keeps it)" : "SSH password or key passphrase (optional)",
            text: $sshSecret)
    }

    @ViewBuilder private var sqliteFields: some View {
        HStack {
            TextField("File", text: $connection.filePath)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.allowsOtherFileTypes = true
                if panel.runModal() == .OK, let url = panel.url { connection.filePath = url.path }
            }
        }
    }

    // MARK: Storage

    @ViewBuilder private var s3Fields: some View {
        Picker("Provider", selection: $connection.provider) {
            ForEach(StorageProvider.allCases) { Text($0.title).tag($0) }
        }
        .onChange(of: connection.provider) { provider in connection.apply(provider) }
        TextField("Region", text: $connection.location)
            .onChange(of: connection.location) { region in
                // A region names the endpoint for these.
                if [.aws, .digitalocean, .backblaze, .wasabi].contains(connection.provider) {
                    connection.host = connection.provider.endpoint(region: region)
                }
            }
        TextField(connection.provider == .r2 ? "Endpoint (your account's id in place of ACCOUNT_ID)" : "Endpoint", text: $connection.host)
        TextField(
            "Port (optional)",
            text: Binding(
                get: { connection.port.map(String.init) ?? "" },
                set: { connection.port = Int($0.filter(\.isNumber)) }))
        Toggle(
            "HTTPS",
            isOn: Binding(get: { connection.sslMode != .disable }, set: { connection.sslMode = $0 ? .require : .disable }))
        Toggle("Bucket name in the path (path-style — MinIO and most self-hosted)", isOn: $connection.pathStyle)
        let profiles = AWSProfile.names()
        if !profiles.isEmpty {
            Picker("Credentials", selection: $connection.awsProfile) {
                Text("Access key").tag("")
                ForEach(profiles, id: \.self) { Text("AWS profile: \($0)").tag($0) }
            }
        }
        if connection.awsProfile.isEmpty {
            TextField("Access key ID", text: $connection.user)
            SecureField(hasSavedPassword ? "Secret access key (saved — empty keeps it)" : "Secret access key", text: $password)
        }
        TextField("Bucket (optional — when the key may list only it)", text: $connection.database)
    }

    @ViewBuilder private var gcsFields: some View {
        TextField("Project", text: $connection.project)
        TextField("Bucket (optional)", text: $connection.database)
        TextField("Location for new buckets (optional — US, EU, europe-west1…)", text: $connection.location)
        googleSignIn
    }

    @ViewBuilder private var bigQueryFields: some View {
        TextField("Project", text: $connection.project)
        TextField("Default dataset (optional)", text: $connection.database)
        TextField("Location (optional — US, EU, europe-west1…)", text: $connection.location)
        googleSignIn
    }

    /// A service account's key, or gcloud on this Mac — BigQuery's and GCS's.
    @ViewBuilder private var googleSignIn: some View {
        Picker("Sign in with", selection: $connection.bigQueryAuth) {
            ForEach(BigQueryAuth.allCases) { Text($0.title).tag($0) }
        }
        if connection.bigQueryAuth == .serviceAccount {
            HStack {
                Text(serviceAccount.isEmpty ? (hasSavedKey ? "Key saved in the keychain" : "No key yet") : "Key read — saved on Save")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose JSON Key…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
                        serviceAccount = text
                        if connection.project.isEmpty,
                            let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                            let project = json["project_id"] as? String
                        {
                            connection.project = project
                        }
                    }
                }
            }
        } else {
            Text("Whoever `gcloud auth login` signed in on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        if let problem {
            Text(verbatim: problem).font(.system(size: 12)).foregroundStyle(.red)
        } else if let tested {
            switch tested {
            case .success(let text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.system(size: 12))
                    .lineLimit(4).textSelection(.enabled)
            }
        }
    }

    /// The secret as it would be saved: what was typed, else the keychain's.
    private var effectivePassword: String? { password.isEmpty ? store.secrets.value(.password, for: connection.id) : password }
    private var effectiveKey: String? { serviceAccount.isEmpty ? store.secrets.value(.serviceAccount, for: connection.id) : serviceAccount }
    private var effectiveSSH: String? { sshSecret.isEmpty ? store.secrets.value(.ssh, for: connection.id) : sshSecret }

    private func test() {
        if let problem = connection.problem {
            self.problem = problem
            return
        }
        problem = nil
        testing = true
        tested = nil
        let connection = self.connection
        let password = effectivePassword
        let key = effectiveKey
        let ssh = effectiveSSH
        Task { @MainActor in
            do {
                let started = Date()
                if connection.kind.isStorage {
                    let client = StorageClients.make(connection, secret: password, serviceAccount: key)
                    try await client.connect()
                    let buckets = (try? await client.buckets())?.count ?? 0
                    tested = .success("Connected in \(Int(Date().timeIntervalSince(started) * 1000)) ms — \(buckets) bucket\(buckets == 1 ? "" : "s")")
                } else {
                    let (driver, tunnel) = try await DatabaseDrivers.open(connection, password: password, serviceAccount: key, sshSecret: ssh)
                    defer { tunnel?.close() }
                    do {
                        try await driver.connect()
                    } catch {
                        await driver.close()
                        throw error
                    }
                    let schemas = (try? await driver.schemas())?.count ?? 0
                    await driver.close()
                    let through = tunnel == nil ? "" : " through \(connection.sshHost)"
                    tested = .success(
                        "Connected\(through) in \(Int(Date().timeIntervalSince(started) * 1000)) ms — \(schemas) schema\(schemas == 1 ? "" : "s")")
                }
            } catch {
                tested = .failure(error)
            }
            testing = false
        }
    }

    private func save() {
        if let problem = connection.problem {
            self.problem = problem
            return
        }
        do {
            try store.save(
                connection, password: password.isEmpty ? nil : password, serviceAccount: serviceAccount.isEmpty ? nil : serviceAccount,
                sshSecret: sshSecret.isEmpty ? nil : sshSecret)
            done(connection)
        } catch {
            problem = error.localizedDescription
        }
    }
}
