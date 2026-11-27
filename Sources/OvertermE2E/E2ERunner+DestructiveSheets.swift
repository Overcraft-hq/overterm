#if E2E
import AppKit
import Foundation

/// D-1 (P04, Overcraft-hq/issue-tracker#14): a sheet that deletes leaves
/// Return on Cancel — the button that deletes has no key and takes a
/// click — says what it reaches, and with a name to type arms Return only
/// once it matches. Every sheet here is cancelled: nothing is removed.
extension E2ERunner {
    /// The attached sheet's key for `title`'s button, nil when it has none.
    private func key(of title: String) -> String? {
        sheetButtons.first { $0.title == title }.map(\.key)
    }

    /// Cancel holds Return — or no key at all: AppKit drops a sheet's keys
    /// when the app isn't frontmost, as in a full run beside other windows
    /// (`onlyAClickPresses` says the same). Either way Return deletes nothing.
    private var cancelHoldsReturn: Bool { ["\r", ""].contains(key(of: "Cancel") ?? "?") }

    /// Cancels the sheet by its button and waits for it to go.
    private func cancelSheet(_ cancel: String = "Cancel") async -> Bool {
        guard clickSheetButton(cancel) else { return false }
        return await eventually(3) { self.window.attachedSheet == nil }
    }

    /// The Move to Trash question, before it is answered.
    func trashSheetKeys() {
        check("Move to Trash… has no key: it takes a click", key(of: "Move to Trash") == "", "\(sheetButtons)")
        check("Return is Cancel's", cancelHoldsReturn, "\(sheetButtons)")
        check("it says where the file is", sheetTexts().contains { $0.hasPrefix("In ") })
    }

    func destructiveSheetChecks() async {
        // A Docker delete: which engine, Return on Cancel, Escape kept.
        var removed = false
        app.confirmDocker("Remove the volume “e2e-data”?", "Their data is deleted, and can't be brought back.", "Remove", destroys: true) {
            removed = true
        }
        let asked = await eventually(3) { self.window.attachedSheet != nil }
        check("a Docker delete asks on the shared sheet", asked)
        check("its Remove has no key", key(of: "Remove") == "", "\(sheetButtons)")
        check("Return is Cancel's there too", cancelHoldsReturn, "\(sheetButtons)")
        check("Escape still cancels", sheetButtons.contains { $0.title.isEmpty && $0.key == "\u{1b}" })
        check("and Cancel removes nothing", await cancelSheet() && !removed)

        // A Kubernetes delete with its name to type: Return arms only once
        // the name matches.
        var deleted = false
        WriteConfirmation(
            title: "Delete deployment shop/e2e-api?", scope: "fake-dev · namespace shop", detail: "Type e2e-api to confirm.", button: "Delete",
            typedName: "e2e-api", critical: true, destroys: true
        ).present(on: window) { _ in deleted = true }
        _ = await eventually(3) { self.window.attachedSheet != nil }
        check("a name not typed: Return is Cancel's", cancelHoldsReturn && key(of: "Delete") == "", "\(sheetButtons)")
        let field = Self.find(NSTextField.self, in: window.attachedSheet?.contentView) {
            $0.accessibilityIdentifier() == WriteConfirmation.typedNameField
        }
        field?.stringValue = "e2e-api"
        if let field { (field.delegate as? DestructiveKeys)?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field)) }
        check("the name typed: Return deletes", key(of: "Delete") == "\r" && key(of: "Cancel") == "\u{1b}", "\(sheetButtons)")
        check("cancelled, nothing deleted", await cancelSheet() && !deleted)
    }
}
#endif
