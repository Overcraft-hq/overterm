import AppKit
import SwiftUI

/// One thing a resource — a container, an image, a volume… — can have
/// done to it. A resource's verbs are one list (Docker's is
/// `DockerPageModel.verbs(for:)`) drawn twice: as the buttons on its
/// detail and as its right-click menu — so nothing is only in the menu,
/// and the two never disagree. Shared by the pages that list resources.
struct ResourceVerb: Identifiable {
    enum Place { case button, more, remove }

    /// As the menu says it: `Browse in a Tab`.
    var title: String
    /// As its button says it, when shorter: `Browse`.
    var label: String?
    var symbol: String
    var place: Place = .more
    /// The list's key for it, said in its help.
    var key: String?
    /// Why it can't be done now; nil when it can.
    var unavailable: String?
    /// Verbs of another group are set apart in a menu.
    var group = 0
    /// A submenu instead (Docker Scout's, the containers to connect).
    var children: [ResourceVerb] = []
    /// What a detail's box says of it, the box whose button it is: an
    /// emulated container's why and what this does (`DockerEmulationNote`).
    var note: String?
    var perform: @MainActor () -> Void = {}

    var id: String { title }

    var help: String {
        [title + (key.map { " (\($0))" } ?? ""), unavailable].compactMap { $0 }.joined(separator: " — ")
    }
}

/// A detail's verbs under its title: the used ones as labelled buttons,
/// the rest behind ⋯, removal last as a red bin — those two as icons
/// always, so the words fit a detail's 420 pt. Narrower, the last
/// buttons give up their words first, one at a time down to the first
/// two: a database's fifth button, its client, doesn't cost Shell its
/// word. Narrower still (the right-hand pane), all icons.
struct ResourceActionBar: View {
    let verbs: [ResourceVerb]
    @ObservedObject var theme: ChromeTheme
    /// How many buttons say their words, always: a row's own small bar (a
    /// project's service) is icons, whatever fits.
    var words: Int? = nil

    /// What the accessibility tree calls the bar; its ⋯ is `<this>.more`.
    var identifier = "docker.actions"

    var body: some View {
        Group {
            if let words {
                row(words: words)
            } else {
                ViewThatFits(in: .horizontal) {
                    row(words: .max)
                    row(words: 4)
                    row(words: 3)
                    row(words: 2)
                    row(words: 0)
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }

    /// `words`: how many of the buttons say theirs.
    private func row(words: Int) -> some View {
        HStack(spacing: 5) {
            let buttons = verbs.filter { $0.place == .button }
            ForEach(Array(buttons.enumerated()), id: \.element.id) { index, verb in item(verb, labelled: index < words) }
            let more = verbs.filter { $0.place == .more }
            if !more.isEmpty {
                Menu {
                    ResourceVerbItems(verbs: more)
                } label: {
                    face("More", "ellipsis", labelled: false)
                }
                // `.button`, not borderless: a borderless menu draws its
                // label its own way, without the face's background.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityIdentifier(identifier + ".more")
            }
            let remove = verbs.filter { $0.place == .remove }
            // A bar across a detail puts removal at its far end; a row's
            // own bar is only as wide as its buttons.
            if self.words == nil || !remove.isEmpty { Spacer(minLength: 8) }
            ForEach(remove) { verb in item(verb, labelled: false, destructive: true) }
        }
    }

    @ViewBuilder private func item(_ verb: ResourceVerb, labelled: Bool, destructive: Bool = false) -> some View {
        if verb.children.isEmpty {
            Button {
                verb.perform()
            } label: {
                face(verb.label ?? verb.title, verb.symbol, labelled: labelled, destructive: destructive)
            }
            .buttonStyle(.plain)
            .disabled(verb.unavailable != nil)
            .opacity(verb.unavailable == nil ? 1 : 0.45)
            .help(verb.help)
        } else {
            Menu {
                ResourceVerbItems(verbs: verb.children)
            } label: {
                face(verb.label ?? verb.title, verb.symbol, labelled: labelled)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(verb.unavailable != nil)
            .help(verb.help)
        }
    }

    private func face(_ text: String, _ symbol: String, labelled: Bool, destructive: Bool = false) -> some View {
        let color = destructive ? TabStatusStyle.failed : theme.text
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: ChromeMetrics.text(10.5)))
            if labelled { Text(text).font(.system(size: ChromeMetrics.text(11.5))).lineLimit(1).fixedSize() }
        }
        .foregroundStyle(color)
        .padding(.horizontal, labelled ? 8 : 0)
        .frame(minWidth: labelled ? nil : 26, minHeight: 24, maxHeight: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(destructive ? TabStatusStyle.failed.opacity(0.12) : theme.rowHover))
        .contentShape(Rectangle())
    }
}

/// The same verbs as a right-click menu: the buttons' first, then More's,
/// then removal.
struct ResourceVerbMenu: View {
    let verbs: [ResourceVerb]

    var body: some View {
        ResourceVerbItems(verbs: verbs.filter { $0.place == .button })
        let more = verbs.filter { $0.place == .more }
        if !more.isEmpty {
            Divider()
            ResourceVerbItems(verbs: more)
        }
        let remove = verbs.filter { $0.place == .remove }
        if !remove.isEmpty {
            Divider()
            ResourceVerbItems(verbs: remove)
        }
    }
}

/// Verbs as menu items, a divider where the group changes.
struct ResourceVerbItems: View {
    let verbs: [ResourceVerb]

    var body: some View {
        ForEach(Array(verbs.enumerated()), id: \.element.id) { index, verb in
            if index > 0, verb.group != verbs[index - 1].group { Divider() }
            if verb.children.isEmpty {
                Button(verb.title) { verb.perform() }.disabled(verb.unavailable != nil)
            } else {
                Menu(verb.title) { ResourceVerbItems(verbs: verb.children) }.disabled(verb.unavailable != nil)
            }
        }
    }
}

/// A verb as an AppKit menu item (a table's right-click menu): its title,
/// disabled when it can't be done now, the reason as its tooltip.
@MainActor
final class ResourceVerbMenuItem: NSMenuItem {
    private let verb: ResourceVerb

    init(_ verb: ResourceVerb) {
        self.verb = verb
        super.init(title: verb.title, action: verb.children.isEmpty ? #selector(runVerb) : nil, keyEquivalent: "")
        target = self
        isEnabled = verb.unavailable == nil
        toolTip = verb.unavailable
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func runVerb() { verb.perform() }

    /// Verbs as their SwiftUI menu has them (`ResourceVerbMenu`): the
    /// buttons', the rest's, then removal, apart; a divider where the
    /// group changes; a verb with children a submenu.
    static func items(_ verbs: [ResourceVerb]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for place in [ResourceVerb.Place.button, .more, .remove] {
            let these = verbs.filter { $0.place == place }
            guard !these.isEmpty else { continue }
            if !items.isEmpty { items.append(.separator()) }
            items += group(these)
        }
        return items
    }

    private static func group(_ verbs: [ResourceVerb]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (index, verb) in verbs.enumerated() {
            if index > 0, verb.group != verbs[index - 1].group { items.append(.separator()) }
            let item = ResourceVerbMenuItem(verb)
            if !verb.children.isEmpty {
                let submenu = NSMenu(title: verb.title)
                for child in group(verb.children) { submenu.addItem(child) }
                item.submenu = submenu
            }
            items.append(item)
        }
        return items
    }
}

/// A right-click menu of verbs over a SwiftUI view, made only as it opens
/// (SwiftUI's `.contextMenu` builds its content with every render of the
/// view under it, and a verb's guard may ask kubectl or a server). Only a
/// right-click (or a control-click) lands on it: every other press, the
/// pointer's hover and tooltips go through to the view under it.
struct ResourceVerbMenuArea: NSViewRepresentable {
    let verbs: @MainActor () -> [ResourceVerb]

    func makeNSView(context: Context) -> ResourceVerbMenuView { ResourceVerbMenuView(verbs: verbs) }

    func updateNSView(_ view: ResourceVerbMenuView, context: Context) { view.verbs = verbs }
}

@MainActor
final class ResourceVerbMenuView: NSView {
    var verbs: @MainActor () -> [ResourceVerb]

    init(verbs: @escaping @MainActor () -> [ResourceVerb]) {
        self.verbs = verbs
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Whether `type` (with `flags`) opens a context menu.
    nonisolated static func opensMenu(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) -> Bool {
        type == .rightMouseDown || (type == .leftMouseDown && flags.contains(.control))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, Self.opensMenu(event.type, event.modifierFlags) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard Self.opensMenu(event.type, event.modifierFlags), let menu = menu(for: event) else { return super.mouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// The verbs as they stand now, asked for here and nowhere else.
    override func menu(for event: NSEvent) -> NSMenu? {
        let items = ResourceVerbMenuItem.items(verbs())
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        return menu
    }
}
