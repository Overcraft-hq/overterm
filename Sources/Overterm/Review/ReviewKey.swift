import Foundation

/// The review page's keys, while the page has the keyboard and nothing in
/// it took them (`ReviewHostingView.keyDown`), and what `?` lists
/// (DISC-U5). Pure.
package enum ReviewKey: String, CaseIterable, Sendable {
    case nextFile, previousFile, nextChange, previousChange, viewed, help

    package var key: String {
        switch self {
        case .nextFile: "j"
        case .previousFile: "k"
        case .nextChange: "n"
        case .previousChange: "p"
        case .viewed: "v"
        case .help: "?"
        }
    }

    package var title: String {
        switch self {
        case .nextFile: "Next file"
        case .previousFile: "Previous file"
        case .nextChange: "Next change in the file"
        case .previousChange: "Previous change in the file"
        case .viewed: "Mark the file as viewed, or not"
        case .help: "These keys"
        }
    }

    /// The key a typed character is: letters either case, as the page took them.
    package static func of(_ characters: String) -> ReviewKey? {
        characters == "?" ? .help : allCases.first { $0.key == characters.lowercased() }
    }

    /// What `?` shows: these, and the window's Review commands with their keys now.
    @MainActor package static func groups(binding: (KeyCommand) -> String?) -> [KeySheetGroup] {
        let own = KeySheetGroup(title: KeySheet.listGroup, rows: allCases.map { KeySheetRow(key: $0.key, title: $0.title) })
        // Copy is Edit ▸ Copy's key, as bound now; shown only while it has one.
        let copy = KeyCommands.byID["edit.copy"].flatMap(binding).map { key in KeySheetRow(key: key, title: "Copy the picked lines") }
        let mouse = KeySheetGroup(title: "Lines", rows: [copy].compactMap { $0 } + [KeySheetRow(key: "Esc", title: "Let go of the picked lines")])
        let window = KeySheet.commands(KeySheet.commands(prefixed: ["review."]), title: KeySheet.windowGroup, binding: binding)
        return [own, mouse] + [window].compactMap { $0 }
    }
}
