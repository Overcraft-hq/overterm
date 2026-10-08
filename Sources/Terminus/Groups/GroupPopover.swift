import SwiftUI

/// The sheet that comes up with a new island, under its chip.
///
/// A group is three decisions and they are all easy to get wrong later:
/// its colour (the thing you actually navigate by), whether new tabs
/// opened in its folder join it, and whether it comes back on launch. Made
/// at the moment the island appears, they are three clicks; found
/// afterwards in a context menu, they are three clicks you never make.
///
/// The name is edited in the chip itself, not here — the island is already
/// in the strip and renaming it in place is the thing you can see.
struct GroupPopover: View {
    @ObservedObject var group: TabGroup
    let theme: ChromeTheme
    /// Where the group's tabs are, offered as the folder to bind to.
    let folder: String?
    let done: () -> Void

    private var folderName: String {
        folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text2)
            HStack(spacing: 8) {
                ForEach(TabColor.allCases) { color in
                    Button {
                        group.color = color
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(theme.text, lineWidth: group.color == color ? 2 : 0).padding(-3)
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(color.name)
                }
            }
            Divider()
            if let folder, !folder.isEmpty {
                Toggle(isOn: binding(for: folder)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New tabs opened in this folder join the group")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.text)
                        Text(verbatim: folderName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.text3)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            Toggle(isOn: $group.restoresOnLaunch) {
                Text("Restore the group's tabs and splits on launch")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
            }
            Divider()
            HStack {
                Text("↩ to confirm the name")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text3)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 320)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    /// The checkbox writes the folder itself: `TabGroup.folder` being set
    /// *is* the binding (`TabStore.group(forDirectory:)` reads it).
    private func binding(for folder: String) -> Binding<Bool> {
        Binding(get: { group.folder != nil }, set: { group.folder = $0 ? folder : nil })
    }
}
