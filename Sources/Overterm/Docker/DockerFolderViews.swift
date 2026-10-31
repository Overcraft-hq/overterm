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

extension DockerFolderBrowsing {
    /// Files and folders from the Mac copied into `folder` of `source`:
    /// what a drop and Copy Here… do. What is there already is asked about
    /// first — read from the list when it is the folder shown and listed,
    /// else looked at: while a folder is being listed, the list may be
    /// another folder's, or this one's before the last copy — and the
    /// folder is listed again once they are in.
    func copyIn(_ urls: [URL], into folder: String, of source: DockerFileSource, actions: DockerActions, transfers: DockerFileTransfers = .shared) {
        let listed = folder == self.folder && filesError == nil && !listing ? entries : nil
        transfers.copyIn(urls, into: folder, of: source, listed: listed, confirm: actions.confirm) { [weak self] in
            guard let self, self.folder == folder else { return }
            self.open(folder)
        }
    }
}

/// A Files tab's folders, a container's or a volume's: the path's crumbs,
/// a path to open, the folder's entries — folders first, a file a click
/// from the editor (saved back where it came from), or to the Mac. Files
/// and folders dropped from Finder go into the folder shown, or into a
/// folder row they are dropped on; a row dragged out to Finder is copied
/// there (`DockerFileDrag`). Each copy shows at the foot until it is done.
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
    /// A drag from Finder is over the list, or over a folder row in it.
    @State private var dropTargeted = false
    @State private var targetedFolder: String?

    private var shown: String { browser.folder ?? "/" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                if let leading { leading.padding(.trailing, 8) }
                ForEach(DockerFiles.crumbs(shown), id: \.path) { crumb in
                    Button(crumb.name == "/" ? "/" : crumb.name + " ›") { browser.open(crumb.path) }
                        .buttonStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text2)
                }
                Spacer(minLength: 6)
                if browser.listing { ProgressView().controlSize(.mini) }
                Button {
                    let folder = shown
                    actions.pickFiles("Copy into \(folder) of \(source.title)") { urls in
                        browser.copyIn(urls, into: folder, of: source, actions: actions)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy files or folders from the Mac into \(shown) — or drop them on the list")
                .accessibilityIdentifier("docker.files.copyHere")
                Button {
                    browser.open(shown)
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
            content
                .dockerFileDrop(targeted: $dropTargeted) { urls in browser.copyIn(urls, into: shown, of: source, actions: actions) }
                .overlay { dropMark }
            DockerTransfersStrip(transfers: .shared, source: source, theme: theme)
        }
    }

    /// The folder's entries, or why they can't be listed — a stopped
    /// container's, a distroless one's: a drop goes in all the same, as the
    /// archive endpoint needs no shell and nothing running.
    @ViewBuilder private var content: some View {
        if let error = browser.filesError {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: error).font(.system(size: 12)).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
                if let remedy { remedy }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        } else {
            // A scroll view, as a bucket's folders are, not a List: a
            // list's table has row drags of its own, and a row here is a
            // drag source and a drop target itself.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let folder = browser.folder, folder != "/" {
                        row(symbol: "arrow.turn.left.up", name: "..", detail: "") { browser.open(DockerFiles.parent(folder)) }
                    }
                    ForEach(browser.entries) { entry in entryRow(entry) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .id(browser.folder)
            .accessibilityIdentifier("docker.files")
        }
    }

    /// While a drag from Finder is over it: the list ringed, and where the
    /// drop would go.
    @ViewBuilder private var dropMark: some View {
        if dropTargeted || targetedFolder != nil {
            ZStack(alignment: .bottom) {
                if targetedFolder == nil { RoundedRectangle(cornerRadius: 6).strokeBorder(theme.accentText, lineWidth: 2).padding(2) }
                Text(verbatim: "Drop to copy into \(targetedFolder ?? shown)")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(theme.card))
                    .overlay(Capsule().strokeBorder(theme.accentText, lineWidth: 1))
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("docker.files.drop")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func entryRow(_ entry: DockerFiles.Entry) -> some View {
        let full = DockerFiles.join(shown, entry.name)
        let open = {
            if entry.kind == .folder { browser.open(full) } else if entry.kind == .file { actions.openFile(source, full) }
        }
        let shownRow = row(
            symbol: Self.symbol(entry.kind), name: entry.name, detail: entry.size.map { DockerBytes.string($0) } ?? "",
            highlighted: targetedFolder == full, open: open
        )
        .overlay {
            // Files and folders go to Finder; a link or a device doesn't.
            if entry.kind == .folder || entry.kind == .file {
                DockerFileDrag(item: DockerFileItem(source: source, path: full, isFolder: entry.kind == .folder), open: open)
            }
        }
        .contextMenu {
            if entry.kind == .folder { Button("Open") { browser.open(full) } }
            if entry.kind == .file { Button("Open in the Editor") { actions.openFile(source, full) } }
            if entry.kind == .file || entry.kind == .folder { Button("Save to the Mac…") { actions.downloadFile(source, full) } }
            Button("Copy Path") { actions.copy(full) }
        }
        if entry.kind == .folder {
            shownRow.dockerFileDrop(targeted: folderTargeted(full)) { urls in browser.copyIn(urls, into: full, of: source, actions: actions) }
        } else {
            shownRow
        }
    }

    private func folderTargeted(_ folder: String) -> Binding<Bool> {
        Binding(
            get: { targetedFolder == folder },
            set: { over in
                if over {
                    targetedFolder = folder
                } else if targetedFolder == folder {
                    targetedFolder = nil
                }
            })
    }

    /// A folder's path lists it; anything else opens as a file.
    private func go(_ typed: String) {
        let path = typed.trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/") else { return }
        if path.hasSuffix("/") || browser.entries.contains(where: { DockerFiles.join(shown, $0.name) == path && $0.kind == .folder }) {
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

    private func row(symbol: String, name: String, detail: String, highlighted: Bool = false, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(theme.text3).frame(width: 16)
                Text(verbatim: name).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(verbatim: detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5).fill(highlighted ? theme.accentText.opacity(0.22) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(highlighted ? theme.accentText : .clear, lineWidth: 1))
            )
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
