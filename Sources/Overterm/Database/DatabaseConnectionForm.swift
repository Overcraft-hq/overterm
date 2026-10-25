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

    @State private var password = ""
    @State private var serviceAccount = ""
    @State private var testing = false
    @State private var tested: Result<String, Error>?
    @State private var problem: String?

    private var hasSavedPassword: Bool { !isNew && store.secrets.value(.password, for: connection.id) != nil }
    private var hasSavedKey: Bool { !isNew && store.secrets.value(.serviceAccount, for: connection.id) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Connection" : "Edit Connection").font(.system(size: 15, weight: .semibold))
            Form {
                TextField("Name", text: $connection.name)
                Picker("Database", selection: $connection.kind) {
                    ForEach(DatabaseKind.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: connection.kind) { kind in
                    connection.port = kind.defaultPort
                    tested = nil
                }
                switch connection.kind {
                case .sqlite: sqliteFields
                case .bigquery: bigQueryFields
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

    @ViewBuilder private var bigQueryFields: some View {
        TextField("Project", text: $connection.project)
        TextField("Default dataset (optional)", text: $connection.database)
        TextField("Location (optional — US, EU, europe-west1…)", text: $connection.location)
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
        Task { @MainActor in
            let driver = DatabaseDrivers.make(connection, password: password, serviceAccount: key)
            do {
                let started = Date()
                try await driver.connect()
                let schemas = (try? await driver.schemas())?.count ?? 0
                await driver.close()
                tested = .success("Connected in \(Int(Date().timeIntervalSince(started) * 1000)) ms — \(schemas) schema\(schemas == 1 ? "" : "s")")
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
                connection, password: password.isEmpty ? nil : password, serviceAccount: serviceAccount.isEmpty ? nil : serviceAccount)
            done(connection)
        } catch {
            problem = error.localizedDescription
        }
    }
}
