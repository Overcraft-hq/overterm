import AppKit
import PDFKit
import SwiftUI

/// A stored file opened in the right-hand pane: what it is, and its
/// contents as far as they can be shown — rows, text, an image, a PDF.
@MainActor
final class StorageObjectModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var bucket = ""
    @Published private(set) var object: StorageObject?
    @Published private(set) var metadata: StorageMetadata?
    @Published private(set) var preview = FilePreview.none
    @Published private(set) var data = Data()
    private(set) var session: StorageSession?
    private var ticket = 0

    /// Read only while the pane shows it.
    var visible = false {
        didSet { if visible, !oldValue, phase == .loading { Task { await load() } } }
    }

    var path: String { object.map { session?.client.path(bucket: bucket, key: $0.key) ?? $0.key } ?? "" }

    func show(_ object: StorageObject, in bucket: String, session: StorageSession) {
        self.session = session
        self.bucket = bucket
        self.object = object
        metadata = nil
        preview = .none
        data = Data()
        phase = .loading
        ticket += 1
        if visible { Task { await load() } }
    }

    /// The object's first bytes (or all of an image or a PDF), as its preview.
    private func load() async {
        guard let session, let object else { return }
        let ticket = self.ticket
        do {
            let metadata = try await session.client.head(bucket: bucket, key: object.key)
            guard ticket == self.ticket else { return }
            self.metadata = metadata
            let kind = FilePreview.kind(of: object.name)
            let limit = kind == .image || kind == .pdf ? FilePreview.fileLimit : FilePreview.textLimit
            guard metadata.size > 0, kind == .image || kind == .pdf ? metadata.size <= limit : true else {
                phase = .loaded
                return
            }
            let range: ClosedRange<Int64>? = metadata.size > limit ? 0...(limit - 1) : nil
            let data = try await session.client.read(bucket: bucket, key: object.key, range: range)
            guard ticket == self.ticket else { return }
            self.data = data
            preview = FilePreview.make(name: object.name, data: data, truncated: range != nil)
            phase = .loaded
        } catch {
            guard ticket == self.ticket else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func reload() {
        guard let session, let object else { return }
        show(object, in: bucket, session: session)
    }

    func close() {
        object = nil
        phase = .idle
    }
}

/// What the object pane asks the window to do.
struct StorageObjectActions {
    var download: () -> Void
    var openInEditor: () -> Void
    var delete: () -> Void
    var copyLink: () -> Void
    var close: () -> Void
}

struct StorageObjectView: View {
    @ObservedObject var model: StorageObjectModel
    @ObservedObject var theme: ChromeTheme
    let actions: StorageObjectActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            if let object = model.object {
                details(object)
                Divider().opacity(0.3)
                content(object)
            } else {
                note("Pick a file in the Database panel (⌥⌘B).")
            }
        }
        .background(theme.strip)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(theme.dimText)
            Text(verbatim: model.object?.name ?? "File").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: actions.close) { Image(systemName: "xmark").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(theme.dimText).help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func details(_ object: StorageObject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: model.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text2)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            HStack(spacing: 10) {
                Text(verbatim: FilePreview.size(model.metadata?.size ?? object.size))
                if let type = model.metadata?.contentType { Text(verbatim: type) }
                if let modified = model.metadata?.modified ?? object.modified {
                    Text(modified, format: .dateTime.year().month().day().hour().minute())
                }
            }
            .font(.system(size: 11)).foregroundStyle(theme.dimText)
            // Icons, each saying what it does: words didn't fit a pane this wide.
            HStack(spacing: 4) {
                iconButton("arrow.down.circle", "Download…", action: actions.download)
                iconButton("doc.text", "Open a copy in the editor", action: actions.openInEditor)
                    .disabled(FilePreview.kind(of: object.name) == .image || FilePreview.kind(of: object.name) == .pdf)
                iconButton("doc.on.doc", "Copy path") { copy(model.path) }
                iconButton("link", model.session?.connection.kind == .gcs ? "Copy the console's link" : "Copy a link that works for an hour", action: actions.copyLink)
                Spacer(minLength: 0)
                iconButton("trash", "Delete…", action: actions.delete)
                    .disabled(model.session?.connection.readOnly == true)
            }
        }
        .padding(12)
    }

    @ViewBuilder private func content(_ object: StorageObject) -> some View {
        switch model.phase {
        case .idle, .loading: note("Reading…")
        case .failed(let message): note(message)
        case .loaded:
            switch model.preview {
            case .table(let result):
                ResultGrid(result: result, theme: theme, table: (object.name as NSString).deletingPathExtension)
                Text(verbatim: "\(result.rows.count) rows\(result.truncated ? " — the file's first part" : "")")
                    .font(.system(size: 11)).foregroundStyle(theme.dimText).padding(.horizontal, 12).padding(.vertical, 4)
            case .text(let text, let truncated):
                ScrollView([.vertical, .horizontal]) {
                    Text(verbatim: text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                if truncated {
                    Text("The file's first \(FilePreview.size(FilePreview.textLimit)) — Download for all of it.")
                        .font(.system(size: 11)).foregroundStyle(theme.dimText).padding(.horizontal, 12).padding(.vertical, 4)
                }
            case .image:
                if let image = NSImage(data: model.data) {
                    ScrollView([.vertical, .horizontal]) {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(maxWidth: max(image.size.width, 1)).padding(12)
                    }
                } else {
                    note("This image can't be shown.")
                }
            case .pdf:
                PDFPreview(data: model.data)
            case .none:
                note(
                    (model.metadata?.size ?? 0) > FilePreview.fileLimit
                        ? "Too large to show here — Download it." : "No preview for this kind of file — Download it.")
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.selected.opacity(0.6)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text2)
        .help(help)
    }

    private func note(_ text: String) -> some View {
        VStack {
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(theme.dimText).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct PDFPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data { view.document = PDFDocument(data: data) }
    }
}
