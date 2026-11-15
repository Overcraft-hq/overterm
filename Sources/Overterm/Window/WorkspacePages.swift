import AppKit

/// A page over the window's body (`WorkspaceOverlay`), as the window wires
/// it: what it makes, what it does when it shows or goes, what of the window
/// it answers for while it shows. Declared once (`declarePage`) — Settings
/// and Docker are; a new page is a declaration, not a copy of Docker's
/// wiring. Every hook is optional: a page that leaves one out has nothing
/// to say there, and the window does what it does without a page.
@MainActor
struct WorkspacePage {
    let overlay: WorkspaceOverlay
    /// Its view, made the first time it opens; nil for a page whose view is
    /// made with the window (Settings), or one that can't be yet.
    var makeView: (@MainActor () -> NSView?)?
    /// It began or stopped showing over the body. The emitted value of
    /// `TabStore.$showingOverlay`: reading the store back gives the old one.
    var visibilityChanged: (@MainActor (Bool) -> Void)?
    /// Its ✕ (or ⌘W while it shows): what it forgets.
    var closed: (@MainActor () -> Void)?
    /// Whether it has a list — its first table — that takes the keyboard
    /// when it opens from the menu and when a sheet over it closes.
    var hasList = false
    /// A key down while its list has the keyboard, with no ⌘, ⌃ or ⌥ (those
    /// are menus'): true when the key meant something there. A page reads
    /// it by its own table (`ResourceKey.press`); false lets it go on to
    /// the list, never to the terminal under the page.
    var press: (@MainActor (String) -> Bool)?
    /// A key with ⌘ alone (⌘[, ⌘]) while it shows and no text is being
    /// typed: true when the page took it, before the menus do — false
    /// leaves it to them.
    var commandPress: (@MainActor (String) -> Bool)?
    /// ⌘L while it shows: its own answer (false beeps), never the terminal
    /// hidden under it.
    var askAboutSelection: (@MainActor () -> Bool)?
    /// What it offers the palette, after the snippets and before history.
    var paletteItems: (@MainActor () -> [PaletteItem])?
    /// The window was covered, uncovered, minimized or brought back.
    var occlusionChanged: (@MainActor () -> Void)?
    /// The window is closing: what it holds goes with it.
    var windowClosing: (@MainActor () -> Void)?

    init(_ overlay: WorkspaceOverlay) { self.overlay = overlay }

    /// Whether a key with these modifiers is the list's at all.
    static func isListKey(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .control, .option]).isEmpty
    }
}

/// A window's pages: their declarations and their views, each covering
/// everything under the tab strip, hidden until shown.
@MainActor
final class WorkspacePages {
    private var declared: [WorkspaceOverlay: WorkspacePage] = [:]
    private var views: [WorkspaceOverlay: NSView] = [:]
    /// Where a page made later goes: the window's content, under the strip.
    private weak var content: NSView?
    private var top: NSLayoutYAxisAnchor?

    func declare(_ page: WorkspacePage) { declared[page.overlay] = page }

    subscript(_ overlay: WorkspaceOverlay) -> WorkspacePage? { declared[overlay] }

    /// The declared pages, in `WorkspaceOverlay`'s order.
    var all: [WorkspacePage] { WorkspaceOverlay.allCases.compactMap { declared[$0] } }

    func view(_ overlay: WorkspaceOverlay) -> NSView? { views[overlay] }

    /// A page's view, hidden, covering everything under the tab strip.
    func add(_ overlay: WorkspaceOverlay, _ view: NSView, in content: NSView, below top: NSLayoutYAxisAnchor) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        // Beside the pages already there, under what floats over them (the
        // palette, the switcher) — a page made later must not cover those.
        if let sibling = views.values.first {
            content.addSubview(view, positioned: .above, relativeTo: sibling)
        } else {
            content.addSubview(view)
        }
        self.content = content
        self.top = top
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: top),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        views[overlay] = view
    }

    /// A page's view, made (and added where the others are) the first time
    /// it is asked for — once a page has been added, so there is a where.
    func made(_ overlay: WorkspaceOverlay) -> NSView? {
        if views[overlay] == nil, let content, let top, let view = declared[overlay]?.makeView?() {
            add(overlay, view, in: content, below: top)
        }
        return views[overlay]
    }

    /// A page's list: its first table, depth first — the one that takes the
    /// keyboard, not a table in a detail (a build's steps).
    func list(_ overlay: WorkspaceOverlay) -> NSTableView? {
        guard declared[overlay]?.hasList == true, let view = views[overlay] else { return nil }
        return Self.firstTable(in: view)
    }

    static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }
}
