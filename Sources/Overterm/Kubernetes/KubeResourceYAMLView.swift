import AppKit
import SwiftUI

/// The detail's YAML tab (2.8): the object's YAML in the editor — the
/// app's own, embedded (tree-sitter YAML, the cluster's API docs on hover
/// and completion) — showing the resource's one buffer, the one `y` opens
/// in the window's editor. Over it the bar: where it goes, Diff with
/// Cluster, Apply… (greyed with why on a read-only context), Revert while
/// it has edits, and the banner when the object changed on the cluster
/// under them. The diff shows here, in place of the text: the right-hand
/// pane is under the page.
struct KubeResourceYAMLView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var detail: KubeDetailSession
    @ObservedObject var resource: KubeResourceBuffer
    @ObservedObject var theme: ChromeTheme
    let editor: EditorViewController

    var body: some View {
        VStack(spacing: 0) {
            KubeResourceBarHost(session: resource.session, resource: resource, theme: theme) { page.editYAML(resource.ref) }
            Rectangle().fill(theme.border).frame(height: 1)
            note
            Rectangle().fill(theme.border).frame(height: 1)
            switch resource.state {
            case .empty:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let reason):
                Text(verbatim: reason).font(.system(size: 12)).foregroundStyle(TabStatusStyle.failed).padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .loaded:
                if resource.showsDiff {
                    KubeManifestDiffContent(
                        session: resource.session, theme: theme, onClose: { resource.showsDiff = false }, onOpen: { _ in resource.showsDiff = false })
                } else {
                    KubeEmbeddedEditor(editor: editor, buffer: resource.buffer)
                        .accessibilityIdentifier("kubernetes.detail.editor")
                }
            }
        }
        .accessibilityIdentifier("kubernetes.detail.yaml")
    }

    /// What the text is, and the read-only view of the object as served.
    private var note: some View {
        HStack(spacing: 10) {
            Text(
                verbatim: "In memory, never saved · without managedFields and status"
                    + (detail.secret != nil ? " · every value masked" : " · secret-looking env values hidden")
            )
            .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
            Spacer(minLength: 4)
            if resource.showsDiff {
                Button("Back to the YAML") { resource.showsDiff = false }.font(.system(size: 11.5))
            }
            if detail.hasHidden {
                Toggle("As served", isOn: $detail.showsHidden).toggleStyle(.checkbox).font(.system(size: 11.5))
                    .help("The object as the server sent it, managedFields and all — read only")
                    .accessibilityIdentifier("kubernetes.detail.showHidden")
            }
            Button("Copy") { page.actions?.copy(resource.buffer.storage.string) }.font(.system(size: 11.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

/// The bar, as tall as what it says: a status line, the banner.
struct KubeResourceBarHost: View {
    @ObservedObject var session: KubeManifestSession
    @ObservedObject var resource: KubeResourceBuffer
    @ObservedObject var theme: ChromeTheme
    let openInEditor: () -> Void

    var body: some View {
        KubeManifestBar(session: session, theme: theme, openInEditor: openInEditor)
            .frame(height: KubeManifestBar.height(status: session.state.text != nil || session.applyRefusal != nil, banner: resource.clusterChange != nil))
    }
}

/// The page's editor (`KubernetesPageModel.yamlEditor`) in the tab: its
/// view moved into this one, showing `buffer` and only it.
struct KubeEmbeddedEditor: NSViewRepresentable {
    let editor: EditorViewController
    let buffer: EditorBuffer

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.clipsToBounds = true
        place(in: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        place(in: host)
        editor.showOnly(buffer)
    }

    static func dismantleNSView(_ host: NSView, coordinator: ()) {
        for view in host.subviews { view.removeFromSuperview() }
    }

    private func place(in host: NSView) {
        let view = editor.view
        guard view.superview !== host else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor), view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor), view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }
}
