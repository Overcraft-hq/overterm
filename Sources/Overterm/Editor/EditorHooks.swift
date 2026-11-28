import AppKit
import SwiftUI

/// What the editor asks of the features it sits under (the SQL console,
/// a Kubernetes manifest, Terraform): each sets its own at install
/// (`OvertermFeatures`), and the editor calls them where it once called
/// the feature by name. A hook that doesn't apply to a buffer says so —
/// nil, false, or nothing done.
package struct EditorHooks {
    /// The view loaded: what a feature observes for the editor's life.
    package var didLoad: [@MainActor (EditorViewController) -> Void] = []
    /// A URL that is no file on disk — a cluster object's YAML — its buffer.
    package var resourceAt: [@MainActor (URL) -> (any EditorResource)?] = []
    /// A file just opened: the feature's part attached to its buffer.
    package var attach: [@MainActor (EditorViewController, EditorBuffer) -> Void] = []
    /// The buffer shown again: its part bound to this editor; `requireResource`,
    /// only where the buffer is a cluster object's YAML.
    package var rebind: [@MainActor (EditorViewController, EditorBuffer, _ requireResource: Bool) -> Void] = []
    /// A buffer's preview of its own in the editor's place (a request's
    /// form); nil when it has none.
    package var requestView: [@MainActor (EditorViewController, EditorBuffer) -> AnyView?] = []
    /// A save of a buffer that is no file yet (a new request): true when the
    /// feature took it, then calling `done` (nil: none waits).
    package var draft: [@MainActor (EditorViewController, EditorBuffer, _ done: ((Bool) -> Void)?) -> Bool] = []
    /// The buffer's tab closed (its document already closed).
    package var closed: [@MainActor (EditorViewController, EditorBuffer) -> Void] = []
    /// The buffer showing changed (nil: none): a panel under it shown or hidden.
    package var show: [@MainActor (EditorViewController, EditorBuffer?) -> Void] = []
    /// The buffer has no console: true when the feature's bar takes its place
    /// under the editor (a manifest's, a Terraform folder's).
    package var panel: [@MainActor (EditorViewController, EditorBuffer) -> Bool] = []
    /// A command the feature answers for this buffer; nil when it doesn't.
    package var command: [@MainActor (EditorViewController, String, EditorBuffer) -> Bool?] = []
    /// ⌘⇧I: the feature's own formatter took it.
    package var format: [@MainActor (EditorViewController, EditorBuffer) -> Bool] = []
    /// Text typed: true when the feature's completion answered for it.
    package var typed: [@MainActor (EditorViewController, EditorBuffer, String) -> Bool] = []
    /// Completion asked: true when the feature's own list shows instead.
    package var trigger: [@MainActor (EditorViewController, EditorBuffer, _ manual: Bool, _ character: String?, _ skip: Bool) -> Bool] = []
    /// The list re-ranked: true when it was the feature's, and it answered.
    package var refilter: [@MainActor (EditorViewController, CompletionState) -> Bool] = []
    package var didChange: [@MainActor (EditorViewController, EditorBuffer) -> Void] = []
    package var didSave: [@MainActor (EditorViewController, EditorBuffer) -> Void] = []
    /// Before a save: nil, not the feature's file; `.formatting`, it formats
    /// and then calls `save` (formatted); `.asIs`, saved without formatting.
    package var saveFormat: [@MainActor (EditorViewController, EditorBuffer, _ save: @escaping () -> Void) -> SaveFormat?] = []
    /// ⇧⌘O's symbols, from the feature's own index; nil when it has none.
    package var symbols: [@MainActor (EditorViewController, EditorBuffer) -> [EditorSymbol]?] = []
    /// F12 at `index` without a language server: true when the feature went.
    package var definition: [@MainActor (EditorViewController, EditorBuffer, Int) -> Bool] = []
    /// A hover at `index`: true when the feature answers (a manifest's
    /// field, from its cluster's docs). It calls `fallback` for the
    /// language server's instead, asks `still` before presenting.
    package var hover:
        [@MainActor (
            EditorViewController, EditorBuffer, _ index: Int, _ unasked: Bool, _ fallback: @escaping @MainActor () -> Void,
            _ still: @escaping @MainActor () -> Bool, _ present: @escaping (String) -> Void
        ) -> Bool] = []

    package enum SaveFormat {
        case formatting, asIs
    }

    package init() {}
}

extension Array {
    /// The first hook's answer that isn't nil, each asked once and in
    /// order (never `lazy.compactMap(…).first`, which asks the one it
    /// returns twice — a statement run twice).
    package func firstAnswer<Answer>(_ ask: (Element) -> Answer?) -> Answer? {
        for element in self {
            if let answer = ask(element) { return answer }
        }
        return nil
    }
}

extension EditorViewController {
    package static var hooks: EditorHooks {
        FeatureHooks.ensure()
        return hooksStorage
    }
    package nonisolated(unsafe) static var hooksStorage = EditorHooks()
}

/// A buffer that belongs to something else — a cluster object's YAML
/// (`KubeResourceBuffer`): held and followed by the editors that show it.
@MainActor
package protocol EditorResource: AnyObject {
    var buffer: EditorBuffer { get }
    var isEdited: Bool { get }
    /// Its edits thrown away: the YAML back to what the cluster has.
    func revert()
    /// "deployment shop/web".
    var spoken: String { get }
    /// The context it is read from.
    var contextName: String { get }
    func watch(by who: AnyObject)
    func unwatch(by who: AnyObject)
    func hold(by holder: AnyObject)
    func release(by holder: AnyObject)
}

/// A console under a buffer (the SQL console): what the editor asks of it.
@MainActor
package protocol EditorConsole: AnyObject {
    /// Rows edited and not saved.
    func unsavedEdits() -> Int
    func discardAllEdits()
    /// Asked before they are thrown away; false: keep them.
    static func askDiscardRowEdits(_ edits: Int, on window: NSWindow) async -> Bool
}

/// A cluster manifest's bar under a buffer (`KubeManifestSession`).
@MainActor
package protocol EditorManifest: AnyObject {
    func say(_ text: String)
    func close()
}

/// A request open in the editor (`APIRequestModel`): what the editor tells it.
@MainActor
package protocol EditorRequestPart: AnyObject {
    func textChanged(_ text: String)
}

/// The notes' part in the editor (`OvertermNotes`): a note's Live Preview,
/// its reading view, a drawing, a note's completion, paste and templates.
/// One object, set at install; nil, the editor is the notes' nowhere.
@MainActor
package protocol EditorNotes: AnyObject {
    /// Only iCloud's placeholder is there: true when it is fetched first and
    /// the open asked again (`then` once it arrives, or false).
    func opensLater(_ url: URL, in editor: EditorViewController, then done: @escaping (Bool) -> Void) -> Bool
    func attach(_ buffer: EditorBuffer, in editor: EditorViewController)
    func activated(_ buffer: EditorBuffer, in editor: EditorViewController)
    func closing(_ buffer: EditorBuffer, in editor: EditorViewController)
    func textChanged(_ buffer: EditorBuffer, in editor: EditorViewController)
    func selectionChanged(in editor: EditorViewController)
    func themeChanged(dark: Bool, in editor: EditorViewController)
    /// The reading view is showing: redrawn in the new theme.
    func invalidateReader(in editor: EditorViewController) -> Bool
    func hideReader(in editor: EditorViewController)
    /// A drawing in the preview's place (nil: none shown).
    func showDrawing(of buffer: EditorBuffer?, in editor: EditorViewController)
    func showNote(_ buffer: EditorBuffer, in editor: EditorViewController)
    func styleLive(_ target: NSMutableAttributedString, at location: Int, in buffer: EditorBuffer, editor: EditorViewController)
    func liveTypingAttributes(in editor: EditorViewController) -> [NSAttributedString.Key: Any]
    func liveClick(at index: Int, in editor: EditorViewController) -> Bool
    func paste(_ pasteboard: NSPasteboard, in editor: EditorViewController) -> Bool
    func addTemplateItems(to menu: NSMenu, in editor: EditorViewController)
    func updateCompletion(in editor: EditorViewController) -> Bool
    func acceptCompletion(_ candidate: CompletionState.Candidate, anchor: Int, in editor: EditorViewController)
    /// Where a caret moving from `old` to `new` lands: past a folded heading's lines.
    func caretPastFolds(from old: NSRange, to new: NSRange, in editor: EditorViewController) -> NSRange
}

extension EditorViewController {
    package static var notes: (any EditorNotes)? {
        FeatureHooks.ensure()
        return notesStorage
    }
    package nonisolated(unsafe) static var notesStorage: (any EditorNotes)?
}
