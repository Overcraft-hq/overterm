import SwiftUI

/// Asked once per island, under its chip: this group holds every tab in the
/// strip, so a new tab is as plausibly a member as not (`NewTabGroup.ask`).
///
/// The tab is already open and outside the group — the question is only
/// whether to move it in, so Escape is a real answer and nothing waits on
/// one. Whichever way it goes, it goes for the island: the strip stops
/// asking, and Group Settings can change its mind.
struct NewTabPrompt: View {
    @ObservedObject var group: TabGroup
    let theme: ChromeTheme
    let keepOut: () -> Void
    let join: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where does this tab belong?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
            HStack(spacing: 6) {
                Circle().fill(group.color.color).frame(width: 9, height: 9)
                Text(verbatim: group.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("holds every tab you have open.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
            }
            HStack(spacing: 8) {
                Button("Keep It Out", action: keepOut)
                    .keyboardShortcut(.cancelAction)
                Button("Add to \(group.name)", action: join)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Asked once per group — Group Settings can change it later.")
                .font(.system(size: 11))
                .foregroundStyle(theme.text3)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}
