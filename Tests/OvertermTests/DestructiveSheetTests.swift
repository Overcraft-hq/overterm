import AppKit
import XCTest

@testable import Overterm
@testable import OvertermKubernetes

/// P04 (Overcraft-hq/issue-tracker#14), D-1 (b): on a sheet that deletes,
/// Return is Cancel's and the action takes a click; a typed name arms
/// Return once it matches; Escape still cancels.
@MainActor
final class DestructiveSheetTests: XCTestCase {
    private final class Pressed: NSObject {
        var titles: [String] = []
        @objc func press(_ sender: NSButton) { titles.append(sender.title) }
    }

    private func key(_ characters: String, _ code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// The buttons' own actions stand in for the sheet's answer: which one
    /// a key presses.
    private func record(_ alert: NSAlert) -> Pressed {
        let pressed = Pressed()
        for button in alert.buttons {
            button.target = pressed
            button.action = #selector(Pressed.press(_:))
        }
        return pressed
    }

    func testReturnIsCancelsAndEscapeStillCancels() {
        let (alert, _) = WriteConfirmation(title: "Remove the volume “data”?", detail: "Its data is deleted.", button: "Remove", destroys: true).alert()
        alert.layout()
        XCTAssertEqual(alert.buttons.map(\.title), ["Remove", "Cancel"], "the order every caller's first-button answer reads")
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "", "the action has no key")
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
        let pressed = record(alert)
        _ = alert.window.performKeyEquivalent(with: key("\r", 36, in: alert.window))
        _ = alert.window.performKeyEquivalent(with: key("\u{1b}", 53, in: alert.window))
        XCTAssertEqual(pressed.titles, ["Cancel", "Cancel"], "Return and Escape both cancel; nothing removes")
    }

    func testANameTypedArmsReturnOnceItMatches() throws {
        let (alert, field) = WriteConfirmation(
            title: "Delete deployment shop/api?", scope: "PRODUCTION · prod · namespace shop", production: true, detail: "Type api to confirm.",
            button: "Delete", typedName: "api", critical: true, destroys: true
        ).alert()
        let typed = try XCTUnwrap(field)
        alert.layout()
        let keys = try XCTUnwrap(typed.delegate as? DestructiveKeys)
        func type(_ text: String) {
            typed.stringValue = text
            keys.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: typed))
        }
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r", "nothing typed: Return cancels")
        type("ap")
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "", "a part of the name arms nothing")
        type(" api ")
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r", "matched, as the callers trim it: Return deletes")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        type("apis")
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "", "no longer the name")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
        XCTAssertTrue(DestructiveKeys.arms("api", name: "api") && !DestructiveKeys.arms("api", name: nil) && !DestructiveKeys.arms("API", name: "api"))
    }

    /// What doesn't delete keeps AppKit's own keys: Return on the action.
    func testAWriteThatDoesntDeleteKeepsReturnOnItsButton() {
        let (alert, _) = WriteConfirmation(title: "Scale shop/api to 3?", detail: "Equals: kubectl scale", button: "Scale").alert()
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "\u{1b}"])
        XCTAssertFalse(alert.buttons[0].hasDestructiveAction)
    }

    // MARK: Which asks delete, and what they say they reach

    func testKubernetesDeletesAreTheDestructiveVerbs() {
        XCTAssertEqual(
            Set(KubeWriteVerb.allCases.filter(\.destroys)), [.delete, .recreate, .forceDelete, .removeFinalizers, .evict],
            "a restart, a scale, a cordon can be set back")
    }
}
