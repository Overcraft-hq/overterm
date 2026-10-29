import SwiftUI

/// What a Files tab lists from: a container's session, or a volume's.
@MainActor
protocol DockerFolderBrowsing: ObservableObject {
    var folder: String? { get }
    var entries: [DockerFiles.Entry] { get }
    var filesError: String? { get }
    var listing: Bool { get }
    func open(_ folder: String)
}

extension ContainerSession: DockerFolderBrowsing {}

/// A Files tab's folders, a container's or a volume's: the path's crumbs,
/// a path to open, the folder's entries — folders first, a file a click
/// from the editor (saved back where it came from), or to the Mac.
struct DockerFolderList<Browser: DockerFolderBrowsing>: View {
    @ObservedObject var browser: Browser
    let source: DockerFileSource
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    var placeholder = "Open a path — /etc/nginx/nginx.conf"
    /// Left of the crumbs: a container's Folders | Changes.
    var leading: AnyView? = nil
    /// Under the error, when there is one: what to do about it.
    var remedy: AnyView? = nil
    @State private var path = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                if let leading { leading.padding(.trailing, 8) }
                ForEach(DockerFiles.crumbs(browser.folder ?? "/"), id: \.path) { crumb in
                    Button(crumb.name == "/" ? "/" : crumb.name + " ›") { browser.open(crumb.path) }
                        .buttonStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text2)
                }
                Spacer(minLength: 6)
                if browser.listing { ProgressView().controlSize(.mini) }
                Button {
                    browser.open(browser.folder ?? "/")
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("List it again")
                .accessibilityIdentifier("docker.files.reload")
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.text3)
                TextField(placeholder, text: $path).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .onSubmit { go(path) }
                    .accessibilityIdentifier("docker.files.path")
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.7)))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            Rectangle().fill(theme.border).frame(height: 1)
            if let error = browser.filesError {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: error).font(.system(size: 12)).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
                    if let remedy { remedy }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else {
                List {
                    if let folder = browser.folder, folder != "/" {
                        row(symbol: "arrow.turn.left.up", name: "..", detail: "") { browser.open(DockerFiles.parent(folder)) }
                    }
                    ForEach(browser.entries) { entry in
                        let full = DockerFiles.join(browser.folder ?? "/", entry.name)
                        row(symbol: Self.symbol(entry.kind), name: entry.name, detail: entry.size.map { DockerBytes.string($0) } ?? "") {
                            if entry.kind == .folder { browser.open(full) } else if entry.kind == .file { actions.openFile(source, full) }
                        }
                        .contextMenu {
                            if entry.kind == .file {
                                Button("Open in the Editor") { actions.openFile(source, full) }
                                Button("Save to the Mac…") { actions.downloadFile(source, full) }
                            }
                            Button("Copy Path") { actions.copy(full) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("docker.files")
            }
        }
    }

    /// A folder's path lists it; anything else opens as a file.
    private func go(_ typed: String) {
        let path = typed.trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/") else { return }
        if path.hasSuffix("/") || browser.entries.contains(where: { DockerFiles.join(browser.folder ?? "/", $0.name) == path && $0.kind == .folder }) {
            browser.open(path)
        } else {
            actions.openFile(source, path)
        }
        self.path = ""
    }

    static func symbol(_ kind: DockerFiles.Entry.Kind) -> String {
        switch kind {
        case .folder: "folder"
        case .file: "doc"
        case .link: "arrow.uturn.right"
        case .other: "questionmark.square.dashed"
        }
    }

    private func row(symbol: String, name: String, detail: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(theme.text3).frame(width: 16)
                Text(verbatim: name).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(verbatim: detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A volume's Files tab: its folders as a container's are, the paths the
/// volume's own (`/` its top). A running container that mounts it sees a
/// saved file at once, and the tab says so first.
struct VolumeFilesPane: View {
    let volume: VolumeSummary
    @ObservedObject var session: VolumeFilesSession
    @ObservedObject var docker: DockerModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    var body: some View {
        VStack(spacing: 0) {
            let running = docker.containers(mounting: volume).filter { $0.state == .running }.map(\.name)
            if !running.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(theme.text3)
                    Text(verbatim: Self.mountedNote(running)).font(.system(size: 11.5)).foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityIdentifier("docker.volume.files.mounted")
            }
            DockerFolderList(
                browser: session, source: .volume(volume.Name), theme: theme, actions: actions, placeholder: "Open a path in the volume — /pg_hba.conf",
                remedy: session.needsImage ? AnyView(pull) : nil)
        }
        .accessibilityIdentifier("docker.volume.files")
    }

    /// `Mounted by db, running: it sees a saved file at once.` Pure.
    nonisolated static func mountedNote(_ names: [String]) -> String {
        "Mounted by \(names.joined(separator: ", ")), running: \(names.count == 1 ? "it sees" : "they see") a saved file at once."
    }

    private var pull: some View {
        HStack(spacing: 8) {
            Button("Pull busybox") { session.pullShellImage() }
                .disabled(session.pulling)
                .help("docker pull \(DockerVolumeFiles.fallbackImage): a few MB, and only now")
                .accessibilityIdentifier("docker.volume.files.pull")
            if session.pulling { ProgressView().controlSize(.small) }
            Text("A file can still be opened by its path.").font(.system(size: 11.5)).foregroundStyle(theme.text3)
        }
    }
}
