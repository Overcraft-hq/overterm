import SwiftUI

/// The empty states that teach (onboarding 7.5): a sentence, one action,
/// and the key bound to it now (`KeyHint`). An empty state decides what to
/// say from what its model already holds — it never runs a tool to find out.
package enum EmptyStates {
    /// Files, rooted at the home folder outside any repository: the strip
    /// over the list.
    package static let filesHome = "This is your home folder. Open a repository to see its changes, branches and agents."
    /// Overgit outside a repository.
    package static let overgit = "Not in a git repository. Open one, or cd into it: the window follows."
    /// Sessions with none yet: the line under it, `%@` New Claude Tab's key.
    package static let sessions = "Start one: New Claude Tab %@"
    package static let sessionsUnbound = "Start one: New Claude Tab"
    /// The Inbox with nothing in it.
    package static let inbox = "When an agent asks, its question and choices appear here."
    package static let inboxNext = "%@ goes to the next tab that needs you."
    /// The command every "not in a repository" state offers.
    package static let openFolderCommand = "file.openFolder"

    /// A scenario's home folder, a scratch one of its own: an isolated run
    /// never opens a tab in the user's.
    @MainActor package static var homeOverride: URL?
    /// The home folder Files' strip is about.
    @MainActor package static var home: URL { homeOverride ?? FileManager.default.homeDirectoryForCurrentUser }

    /// Whether Files shows `filesHome`: its root is the home folder, and the
    /// window's own read of that folder (`DiffModel`, already made for the
    /// badge) said it is no repository — a home folder kept in git is one,
    /// and gets no strip. `checked` is the folder that read was about, so a
    /// tab switch shows nothing until the new folder's read is in. The
    /// three compared with symlinks resolved (`sameFolder`): a shell names
    /// the temporary folder's `/var` as `/private/var`. Pure but for that.
    package nonisolated static func showsHomeStrip(root: URL?, home: URL, checked: URL?, notARepository: Bool) -> Bool {
        guard notARepository, let root, let checked else { return false }
        return sameFolder(root, home) && sameFolder(checked, root)
    }

    /// Whether two URLs name one folder: symlinks resolved on both sides
    /// (`/var` and `/private/var`), then standardized (a trailing slash, `..`).
    package nonisolated static func sameFolder(_ one: URL, _ other: URL) -> Bool {
        one.resolvingSymlinksInPath().standardizedFileURL.path == other.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// An empty state's Open Folder…: Finder's panel, a tab in the folder
/// picked (`TerminalWindowController.openFolder`). Its key, when one is
/// bound, beside it — none is by default (onboarding D-10).
package struct OpenFolderButton: View {
    @ObservedObject private var theme: ChromeTheme
    private let identifier: String
    private let action: () -> Void

    /// `identifier`: the accessibility identifier, `<panel>.openFolder`.
    package init(theme: ChromeTheme, identifier: String, action: @escaping () -> Void) {
        self._theme = ObservedObject(wrappedValue: theme)
        self.identifier = identifier
        self.action = action
    }

    package var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                Label("Open Folder…", systemImage: "folder").font(.system(size: ChromeMetrics.text(11.5)))
            }
            .controlSize(.small)
            .accessibilityIdentifier(identifier)
            KeyHint("%@", command: EmptyStates.openFolderCommand, color: theme.text3)
        }
    }
}

/// Files' strip over the home folder's listing (`EmptyStates.filesHome`).
package struct HomeFolderStrip: View {
    @ObservedObject private var theme: ChromeTheme
    private let openFolder: () -> Void

    package init(theme: ChromeTheme, openFolder: @escaping () -> Void) {
        self._theme = ObservedObject(wrappedValue: theme)
        self.openFolder = openFolder
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(EmptyStates.filesHome)
                .font(.system(size: ChromeMetrics.text(11.5)))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            OpenFolderButton(theme: theme, identifier: "files.openFolder", action: openFolder)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.rowHover))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.homeStrip")
    }
}
