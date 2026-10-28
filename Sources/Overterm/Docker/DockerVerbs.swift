import SwiftUI

/// One thing a container, an image, a volume… can have done to it. A
/// resource's verbs are one list (`DockerPageModel.verbs(for:)`) drawn
/// twice: as the buttons on its detail and as its right-click menu — so
/// nothing is only in the menu, and the two never disagree.
struct DockerVerb: Identifiable {
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
    var children: [DockerVerb] = []
    var perform: @MainActor () -> Void = {}

    var id: String { title }

    var help: String {
        [title + (key.map { " (\($0))" } ?? ""), unavailable].compactMap { $0 }.joined(separator: " — ")
    }
}

/// A detail's verbs under its title: the used ones as labelled buttons,
/// the rest behind ⋯, removal last as a red bin — those two as icons
/// always, so the words fit a detail's 420 pt. Narrower, the first two
/// keep their words; narrower still (the right-hand pane), all icons.
struct DockerActionBar: View {
    let verbs: [DockerVerb]
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(words: .max)
            row(words: 2)
            row(words: 0)
        }
        .accessibilityIdentifier("docker.actions")
    }

    /// `words`: how many of the buttons say theirs.
    private func row(words: Int) -> some View {
        HStack(spacing: 5) {
            let buttons = verbs.filter { $0.place == .button }
            ForEach(Array(buttons.enumerated()), id: \.element.id) { index, verb in item(verb, labelled: index < words) }
            let more = verbs.filter { $0.place == .more }
            if !more.isEmpty {
                Menu {
                    DockerVerbItems(verbs: more)
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
                .accessibilityIdentifier("docker.actions.more")
            }
            Spacer(minLength: 8)
            ForEach(verbs.filter { $0.place == .remove }) { verb in item(verb, labelled: false, destructive: true) }
        }
    }

    @ViewBuilder private func item(_ verb: DockerVerb, labelled: Bool, destructive: Bool = false) -> some View {
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
                DockerVerbItems(verbs: verb.children)
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
            Image(systemName: symbol).font(.system(size: 10.5))
            if labelled { Text(text).font(.system(size: 11.5)).lineLimit(1).fixedSize() }
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
struct DockerVerbMenu: View {
    let verbs: [DockerVerb]

    var body: some View {
        DockerVerbItems(verbs: verbs.filter { $0.place == .button })
        let more = verbs.filter { $0.place == .more }
        if !more.isEmpty {
            Divider()
            DockerVerbItems(verbs: more)
        }
        let remove = verbs.filter { $0.place == .remove }
        if !remove.isEmpty {
            Divider()
            DockerVerbItems(verbs: remove)
        }
    }
}

/// Verbs as menu items, a divider where the group changes.
struct DockerVerbItems: View {
    let verbs: [DockerVerb]

    var body: some View {
        ForEach(Array(verbs.enumerated()), id: \.element.id) { index, verb in
            if index > 0, verb.group != verbs[index - 1].group { Divider() }
            if verb.children.isEmpty {
                Button(verb.title) { verb.perform() }.disabled(verb.unavailable != nil)
            } else {
                Menu(verb.title) { DockerVerbItems(verbs: verb.children) }.disabled(verb.unavailable != nil)
            }
        }
    }
}
