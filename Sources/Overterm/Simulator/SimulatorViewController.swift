import AppKit
import Combine

/// The simulator, in the browser's column: the device Simulator.app is
/// running, mirrored beside the terminal so you watch the app an agent is
/// building without a window in front of everything.
///
/// Looking, not touching — taps still go to Simulator.app itself (the
/// toolbar's ↗, or a double-click on the picture, brings it forward).
@MainActor
final class SimulatorViewController: NSViewController {
    var onClose: (() -> Void)?
    var onToggleZoom: (() -> Void)?
    /// The column's other half.
    var onShowBrowser: (() -> Void)?

    let chrome: ChromeTheme
    let theme: EditorTheme
    private let mirror = SimulatorMirror()
    private let display = SimulatorDisplayView()
    private let deviceButton = NSButton()
    private let noteBar = NSView()
    private let noteLabel = NSTextField(labelWithString: "")
    private let noteAction = NSButton()
    private var noteHeight: NSLayoutConstraint!
    private let empty = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptyAction = NSButton()
    private(set) var zoomButton = NSButton()

    private(set) var devices: [SimulatorDevice] = []
    private(set) var selected: SimulatorDevice?
    private(set) var isActive = false
    /// What the picture is coming from — the E2E scenario reads it.
    var mirrorStatus: SimulatorMirror.Status { mirror.status }
    private var observers: Set<AnyCancellable> = []
    private var poll: Timer?

    init(chrome: ChromeTheme, background: NSColor) {
        self.chrome = chrome
        theme = EditorTheme(background: background)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = BrowserRootView(color: theme.background)
        let toolbar = BrowserBackground(color: chrome.stripNS)
        let text = theme.text

        func button(_ button: NSButton, _ symbol: String, _ tip: String, _ action: Selector, id: String) {
            EditorHeaderView.style(button, symbol, tip: tip, color: text, target: self, action: action, size: 12)
            button.identifier = NSUserInterfaceItemIdentifier(id)
        }
        let web = NSButton()
        button(web, "globe", "Browser", #selector(showBrowser), id: "simulatorBrowser")
        let reconnect = NSButton()
        button(reconnect, "arrow.clockwise", "Look Again", #selector(reconnect(_:)), id: "simulatorReconnect")
        let forward = NSButton()
        button(forward, "arrow.up.forward.app", "Open Simulator", #selector(openSimulator), id: "simulatorOpen")
        button(zoomButton, "arrow.up.left.and.arrow.down.right", "Zoom Simulator", #selector(toggleZoom), id: "simulatorZoom")
        let close = NSButton()
        button(close, "xmark", "Close", #selector(closeColumn), id: "simulatorClose")

        deviceButton.isBordered = false
        deviceButton.target = self
        deviceButton.action = #selector(pickDevice)
        deviceButton.identifier = NSUserInterfaceItemIdentifier("simulatorDevice")
        deviceButton.alignment = .left
        setDeviceTitle("No simulator")

        noteBar.wantsLayer = true
        noteBar.layer?.backgroundColor = chrome.stripNS.cgColor
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = theme.lineNumber
        noteLabel.lineBreakMode = .byTruncatingTail
        noteAction.isBordered = false
        noteAction.target = self
        noteAction.action = #selector(takeNoteAction)
        noteAction.identifier = NSUserInterfaceItemIdentifier("simulatorNoteAction")

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = theme.lineNumber
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyAction.isBordered = false
        emptyAction.target = self
        emptyAction.action = #selector(takeEmptyAction)
        emptyAction.identifier = NSUserInterfaceItemIdentifier("simulatorEmptyAction")
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 10
        empty.setViews([emptyLabel, emptyAction], in: .center)

        display.onOpenSimulator = { [weak self] in self?.openSimulator() }

        for view in [deviceButton, web, reconnect, forward, zoomButton, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            toolbar.addSubview(view)
        }
        for view in [noteLabel, noteAction] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            noteBar.addSubview(view)
        }
        for view in [toolbar, display, empty, noteBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        noteHeight = noteBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 38),
            deviceButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            deviceButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            deviceButton.trailingAnchor.constraint(lessThanOrEqualTo: web.leadingAnchor, constant: -6),
            web.trailingAnchor.constraint(equalTo: reconnect.leadingAnchor, constant: -2),
            reconnect.trailingAnchor.constraint(equalTo: forward.leadingAnchor, constant: -2),
            forward.trailingAnchor.constraint(equalTo: zoomButton.leadingAnchor, constant: -2),
            zoomButton.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),
            close.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            display.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            display.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            display.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            display.bottomAnchor.constraint(equalTo: noteBar.topAnchor),
            empty.centerXAnchor.constraint(equalTo: display.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: display.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: display.widthAnchor, constant: -40),
            noteBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            noteBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            noteBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            noteHeight,
            noteLabel.leadingAnchor.constraint(equalTo: noteBar.leadingAnchor, constant: 10),
            noteLabel.centerYAnchor.constraint(equalTo: noteBar.centerYAnchor),
            noteLabel.trailingAnchor.constraint(lessThanOrEqualTo: noteAction.leadingAnchor, constant: -8),
            noteAction.trailingAnchor.constraint(equalTo: noteBar.trailingAnchor, constant: -10),
            noteAction.centerYAnchor.constraint(equalTo: noteBar.centerYAnchor),
        ])
        for view in [web, reconnect, forward, zoomButton, close] {
            view.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
            view.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        view = root

        mirror.onFrame = { [weak self] contents, size in self?.display.show(contents, size: size) }
        mirror.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.showStatus(status) }
            .store(in: &observers)
        showStatus(.stopped)
    }

    // MARK: Showing and hiding

    /// The column is showing the simulator: find the devices and mirror.
    /// Nothing is read while it isn't — the picture costs a stream.
    func activate() {
        guard !isActive else { return }
        isActive = true
        reloadDevices()
        // Devices are booted and shut down outside Overterm; the picker
        // notices, and a simulator that comes up is mirrored.
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadDevices() }
        }
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        poll?.invalidate()
        poll = nil
        mirror.stop()
        display.clear()
    }

    func setZoomed(_ zoomed: Bool) {
        EditorHeaderView.style(
            zoomButton, zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            tip: zoomed ? "Unzoom Simulator" : "Zoom Simulator", color: theme.text, target: self, action: #selector(toggleZoom), size: 12)
    }

    // MARK: The devices

    private func reloadDevices() {
        Task { [weak self] in
            let found = await SimulatorControl.devices()
            guard let self, self.isActive else { return }
            self.devices = found
            let keep = self.selected.flatMap { current in found.first { $0.udid == current.udid } }
            // Whatever is booted, else what the picker was left on.
            self.choose(found.first { $0.isBooted } ?? keep ?? found.first, start: true)
        }
    }

    private func choose(_ device: SimulatorDevice?, start: Bool) {
        selected = device
        setDeviceTitle(device?.label ?? "No simulator")
        guard let device else {
            mirror.stop()
            display.clear()
            return showEmpty(devices.isEmpty ? .noXcode : .nothingBooted)
        }
        guard device.isBooted else {
            mirror.stop()
            display.clear()
            return showEmpty(.nothingBooted)
        }
        showEmpty(nil)
        if start { mirror.start(device) }
    }

    private func setDeviceTitle(_ title: String) {
        deviceButton.attributedTitle = NSAttributedString(
            string: "\(title)  ⌄",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.text])
    }

    @objc private func pickDevice() {
        let menu = NSMenu()
        if devices.isEmpty {
            menu.addItem(withTitle: "No simulators — Xcode isn't installed", action: nil, keyEquivalent: "")
        }
        for device in devices {
            let item = NSMenuItem(title: device.label, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.udid
            item.state = device.udid == selected?.udid ? .on : .off
            if device.isBooted { item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Booted") }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: deviceButton.bounds.height + 4), in: deviceButton)
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String, let device = devices.first(where: { $0.udid == udid }) else { return }
        guard device.isBooted else {
            // A device that isn't up is booted first — Simulator.app shows
            // it, and the mirror picks it up on the next sweep.
            choose(device, start: false)
            Task { await SimulatorControl.openSimulator(device: device) }
            return
        }
        choose(device, start: true)
    }

    // MARK: What the pane says

    /// The middle of the pane, when there is no picture.
    private enum Empty {
        case noXcode, nothingBooted
    }

    private var emptyState: Empty?

    private func showEmpty(_ state: Empty?) {
        emptyState = state
        empty.isHidden = state == nil
        switch state {
        case .noXcode:
            emptyLabel.stringValue = "No simulators on this Mac.\nThey come with Xcode."
            emptyAction.isHidden = true
        case .nothingBooted:
            emptyLabel.stringValue = "No simulator is running."
            emptyAction.isHidden = false
            style(emptyAction, "Open Simulator")
        case nil:
            break
        }
    }

    private func showStatus(_ status: SimulatorMirror.Status) {
        switch status {
        case .live, .stopped:
            noteLabel.stringValue = ""
            noteAction.isHidden = true
            noteHeight.constant = 0
        case .connecting:
            note("Looking for the simulator…", action: nil)
        case .polling(.denied):
            note(
                SimulatorMirror.isAllowedToRecord
                    ? "Screen Recording was allowed — restart Overterm for the live picture. A frame every half second until then."
                    : "Without Screen Recording it is a frame every half second, not the live screen.",
                action: "Allow…")
        case .polling(.noWindow):
            note("Simulator.app isn't showing this device: a frame every half second.", action: "Open Simulator")
        }
    }

    private func note(_ text: String, action: String?) {
        noteLabel.stringValue = text
        noteHeight.constant = 24
        noteAction.isHidden = action == nil
        if let action { style(noteAction, action) }
    }

    private func style(_ button: NSButton, _ title: String) {
        button.attributedTitle = NSAttributedString(
            string: title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.info])
    }

    // MARK: Actions

    @objc private func takeNoteAction() {
        if case .polling(.denied) = mirror.status {
            SimulatorMirror.requestRecording()
            return
        }
        openSimulator()
    }

    @objc private func takeEmptyAction() {
        switch emptyState {
        case .nothingBooted:
            let device = selected ?? devices.first
            Task { [weak self] in
                await SimulatorControl.openSimulator(device: device)
                self?.reloadDevices()
            }
        default: break
        }
    }

    @objc private func openSimulator() {
        Task { [weak self] in
            await SimulatorControl.openSimulator(device: self?.selected, activate: true)
            self?.mirror.reconnect()
        }
    }

    @objc private func reconnect(_ sender: Any?) {
        mirror.reconnect()
        reloadDevices()
    }

    @objc private func showBrowser() { onShowBrowser?() }
    @objc private func toggleZoom() { onToggleZoom?() }
    @objc private func closeColumn() { onClose?() }
}

/// The picture: a layer holding the stream's frames, kept to the device's
/// own proportions in the middle of the pane.
final class SimulatorDisplayView: NSView {
    var onOpenSimulator: (() -> Void)?
    private let content = CALayer()
    private var natural: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Since macOS 14 a subview draws past its bounds unless it is told
        // not to; a phone's screen is taller than this pane.
        clipsToBounds = true
        content.contentsGravity = .resizeAspect
        content.masksToBounds = true
        layer?.addSublayer(content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A frame — an IOSurface from the stream, a CGImage from a screenshot.
    func show(_ contents: Any, size: CGSize) {
        let resized = size != natural
        natural = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = contents
        CATransaction.commit()
        if resized { place() }
    }

    func clear() {
        content.contents = nil
        natural = .zero
    }

    override func layout() {
        super.layout()
        place()
    }

    override func mouseDown(with event: NSEvent) {
        // Taps belong to Simulator.app: a double-click goes there.
        if event.clickCount == 2 { onOpenSimulator?() }
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        content.contentsScale = window?.backingScaleFactor ?? 2
        guard natural.width > 0, natural.height > 0, bounds.width > 0, bounds.height > 0 else {
            content.frame = bounds
            return
        }
        let scale = min(bounds.width / natural.width, bounds.height / natural.height)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        content.frame = CGRect(
            x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width.rounded(), height: size.height.rounded())
    }
}
