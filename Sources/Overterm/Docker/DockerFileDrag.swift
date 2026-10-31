import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A Files row's drag out, AppKit's: SwiftUI's drags can't promise a file,
/// and Finder writes nothing a drag doesn't promise. It lies over the row.
struct DockerFileDrag: NSViewRepresentable {
    let item: DockerFileItem
    /// The row's own click: a click on it opens the row as its button would.
    let open: () -> Void

    func makeNSView(context: Context) -> DockerFileDragSourceView { DockerFileDragSourceView(item: item, open: open) }

    func updateNSView(_ view: DockerFileDragSourceView, context: Context) {
        view.item = item
        view.open = open
    }
}

/// Takes only a left press: a click opens the row, a drag past 4 pt
/// promises it to wherever it is dropped (`DockerFilePromise`). Anything
/// else — a right-click, a ⌃-click, the pointer moving, the scroll wheel —
/// goes through it to the row and its menu.
final class DockerFileDragSourceView: NSView, NSDraggingSource {
    var item: DockerFileItem
    var open: () -> Void
    private var down: NSEvent?
    private var promise: DockerFilePromise?

    init(item: DockerFileItem, open: @escaping () -> Void) {
        self.item = item
        self.open = open
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Whether an event is this view's: a left press without ⌃. Pure.
    nonisolated static func takes(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) -> Bool {
        type == .leftMouseDown && !flags.contains(.control)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, Self.takes(event.type, event.modifierFlags) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { down = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down, promise == nil else { return }
        let from = convert(down.locationInWindow, from: nil)
        let to = convert(event.locationInWindow, from: nil)
        guard hypot(to.x - from.x, to.y - from.y) > 4 else { return }
        let (provider, promise) = Self.provider(for: item)
        self.promise = promise
        let dragged = NSDraggingItem(pasteboardWriter: provider)
        let icon = NSWorkspace.shared.icon(for: UTType(item.fileType) ?? .data)
        icon.size = NSSize(width: 32, height: 32)
        dragged.setDraggingFrame(NSRect(x: from.x - 16, y: from.y - 16, width: 32, height: 32), contents: icon)
        beginDraggingSession(with: [dragged], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { down = nil }
        guard down != nil, promise == nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Taken: kept until it has written. Not: nobody will ask.
        if operation == [], let promise { DockerFilePromise.release(promise) }
        promise = nil
        down = nil
    }

    /// A row's promise, kept until it is written (the provider holds its
    /// delegate weakly). The scenario writes one through this too.
    static func provider(for item: DockerFileItem, transfers: DockerFileTransfers = .shared) -> (NSFilePromiseProvider, DockerFilePromise) {
        let promise = DockerFilePromise(item: item, transfers: transfers)
        DockerFilePromise.keep(promise)
        return (NSFilePromiseProvider(fileType: item.fileType, delegate: promise), promise)
    }
}

extension View {
    /// Files and folders from Finder dropped here: their URLs, and
    /// `targeted` while a drag is over it.
    func dockerFileDrop(targeted: Binding<Bool>, perform: @escaping @MainActor ([URL]) -> Void) -> some View {
        onDrop(of: [.fileURL], isTargeted: targeted) { providers in
            FileTreeDrag.urls(providers, done: perform)
            return true
        }
    }
}

/// The copies into and out of what a Files tab shows, at its foot: what
/// goes where, its bar (the bytes so far when a folder's size isn't
/// known), a ✕ to stop it. A finished one goes by itself; a failed one
/// stays, in the engine's own words, until OK.
struct DockerTransfersStrip: View {
    @ObservedObject var transfers: DockerFileTransfers
    let source: DockerFileSource
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        let rows = transfers.transfers(for: source)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { transfer in row(transfer) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("docker.files.transfers")
        }
    }

    private func row(_ transfer: DockerFileTransfers.Transfer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(transfer)).font(.system(size: 11)).foregroundStyle(color(transfer))
                Text(verbatim: "\(transfer.name) → \(transfer.place)").font(.system(size: 11.5)).foregroundStyle(theme.text2)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if transfer.running {
                    if transfer.total == nil {
                        Text(verbatim: DockerBytes.string(transfer.done)).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
                    }
                    Button {
                        transfers.cancel(transfer.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Stop this copy: what went already stays")
                } else if transfer.error != nil || !transfer.skipped.isEmpty {
                    Button("OK") { transfers.dismiss(transfer.id) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(theme.accentText)
                }
            }
            if let error = transfer.error {
                Text(verbatim: error).font(.system(size: 11)).foregroundStyle(DiffColors.removed).lineLimit(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if transfer.running {
                if let total = transfer.total, total > 0 {
                    ProgressView(value: Double(min(transfer.done, total)), total: Double(total)).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
            } else if !transfer.skipped.isEmpty {
                Text(verbatim: Self.leftOut(transfer)).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func symbol(_ transfer: DockerFileTransfers.Transfer) -> String {
        if transfer.error != nil { return "exclamationmark.triangle.fill" }
        if transfer.finished { return "checkmark.circle.fill" }
        return transfer.direction == .into ? "arrow.up.circle" : "arrow.down.circle"
    }

    private func color(_ transfer: DockerFileTransfers.Transfer) -> Color {
        if transfer.error != nil { return DiffColors.removed }
        return transfer.finished ? TabStatusStyle.done : theme.text3
    }

    /// What didn't go, and why. Pure.
    nonisolated static func leftOut(_ transfer: DockerFileTransfers.Transfer) -> String {
        let names = transfer.skipped.joined(separator: ", ")
        return transfer.direction == .into
            ? "Left on the Mac: \(names) — a link that points above the drop, a socket or a device."
            : "Left out: \(names) — outside the folder, or not a file, a folder or a link."
    }
}
