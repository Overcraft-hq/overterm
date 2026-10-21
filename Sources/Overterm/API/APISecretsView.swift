import SwiftUI

/// An environment's secrets: the names its file lists under `vars:secret`,
/// their values typed here and kept in the keychain — never in the file,
/// which is committed. A new name is added to the file's list.
struct APISecretsView: View {
    let environment: String
    @State var names: [String]
    @State private var values: [String: String]
    @State private var newName = ""
    let save: (_ names: [String], _ values: [String: String]) -> Void
    let cancel: () -> Void

    init(
        environment: String, names: [String], values: [String: String], save: @escaping ([String], [String: String]) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.environment = environment
        _names = State(initialValue: names)
        _values = State(initialValue: values)
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Secrets of “\(environment)”").font(.headline)
            Text("Kept in your keychain on this Mac, never in the environment's file — the file only names them, so it can be committed.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(names, id: \.self) { name in
                HStack {
                    Text(verbatim: name).font(.system(size: 12, design: .monospaced)).frame(width: 130, alignment: .leading)
                    SecureField("Value", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        names.removeAll { $0 == name }
                        values[name] = nil
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Stop treating it as a secret")
                }
            }
            HStack {
                TextField("New secret's name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(add)
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(names, values) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !names.contains(name), name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else { return }
        names.append(name)
        newName = ""
    }
}
