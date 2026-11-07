import SwiftUI

/// `?` over the Kubernetes page: every key it answers, grouped
/// (`KubeKeySheet`), the window's commands with the keys they are bound to
/// now. Esc, `?` or a click outside closes it; `:` and `/` close it and go
/// on to the command bar and the filter (`KubernetesPageModel.press`).
struct KubeKeySheetView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var theme: ChromeTheme
    @ObservedObject var keybindings = Keybindings.shared

    static let identifier = "kubernetes.keys"

    var body: some View {
        let groups = KubeKeySheet.groups { keybindings.key(for: $0)?.display }
        ZStack {
            Color.black.opacity(0.001).onTapGesture { page.cheatSheet = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Keys on the Kubernetes page").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                    Spacer()
                    Text("Esc").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                Divider().opacity(0.4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text3)
                                    .accessibilityIdentifier("kubernetes.keys.\(group.id)")
                                ForEach(group.rows) { row in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(verbatim: row.key).font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(row.key == KubeKeySheet.unbound ? theme.text3 : theme.text)
                                            .frame(width: 64, alignment: .leading)
                                        Text(verbatim: row.title).font(.system(size: 12)).foregroundStyle(theme.text2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        Text("↑↓ to move, ⇧ and ⌘ to pick several, ⌘C copies their names.").font(.system(size: 11)).foregroundStyle(theme.text3)
                    }
                    .padding(18)
                }
                .frame(maxHeight: 520)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.menuEdge))
            .accessibilityIdentifier(Self.identifier)
        }
    }
}
