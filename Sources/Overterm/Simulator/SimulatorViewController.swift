import AppKit
import Combine

/// The simulator in the browser's column: the booted device's own screen,
/// read out of CoreSimulator (`SimulatorMirror`) so it is here whether
/// Simulator.app is showing it or not.
///
/// Looking, not touching: a frame is a picture, and nothing types into it.
/// The toolbar's ↗ — or a double-click on the picture — brings Simulator.app
/// forward, which is where taps go.
@MainActor
final class SimulatorViewController: NSViewController {
    var onClose: (() -> Void)?
    var onToggleZoom: (() -> Void)?

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
    /// Where the picture is coming from — the E2E scenario reads it.
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
        let again = NSButton()
        button(again, "arrow.clockwise", "Look Again", #selector(lookAgain), id: "simulatorReconnect")
        let forward = NSButton()
        button(forward, "arrow.up.forward.app", "Open Simulator — taps go there", #selector(openSimulator), id: "simulatorOpen")
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
        noteAction.action = #selector(openSimulator)
        noteAction.identifier = NSUserInterfaceItemIdentifier("simulatorNoteAction")

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = theme.lineNumber
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyAction.isBordered = false
        emptyAction.target = self
        emptyAction.action = #selector(bootSelected)
        emptyAction.identifier = NSUserInterfaceItemIdentifier("simulatorEmptyAction")
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 10
        empty.setViews([emptyLabel, emptyAction], in: .center)

        display.onOpenSimulator = { [weak self] in self?.openSimulator() }

        for view in [deviceButton, again, forward, zoomButton, close] as [NSView] {
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
            deviceButton.trailingAnchor.constraint(lessThanOrEqualTo: again.leadingAnchor, constant: -6),
            again.trailingAnchor.constraint(equalTo: forward.leadingAnchor, constant: -2),
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
        for view in [again, forward, zoomButton, close] {
            view.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
            view.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        view = root

        mirror.onFrame = { [weak self] contents, size in self?.display.show(contents, size: size) }
        mirror.onDamage = { [weak self] in self?.display.refresh() }
        display.maxPixels = { [weak self] pixels in self?.mirror.maxPixels = pixels }
        display.input = { [weak self] in self?.mirror.input }
        mirror.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.showStatus(status) }
            .store(in: &observers)
        showStatus(.stopped)
    }

    // MARK: Showing and hiding

    /// The column is showing the simulator: find the devices and read the
    /// booted one's screen. Nothing is read while it isn't showing — a
    /// frame is a `simctl` call, and they would go on for ever.
    func activate() {
        guard !isActive else { return }
        isActive = true
        reloadDevices()
        // Devices are booted and shut down outside Overterm; the picker
        // notices, and a simulator that comes up is shown.
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
            self.choose(found.first { $0.isBooted } ?? keep ?? found.first)
        }
    }

    private func choose(_ device: SimulatorDevice?) {
        selected = device
        setDeviceTitle(device?.label ?? "No simulator")
        guard let device, device.isBooted else {
            mirror.stop()
            display.clear()
            return showEmpty(devices.isEmpty ? .noXcode : .nothingBooted)
        }
        showEmpty(nil)
        mirror.start(device)
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
        choose(device)
        // A device that isn't up is booted — without Simulator.app, which
        // this pane doesn't need.
        guard !device.isBooted else { return }
        boot(device)
    }

    private func boot(_ device: SimulatorDevice) {
        note("Booting \(device.name)…", action: nil)
        Task { [weak self] in
            await SimulatorControl.boot(device.udid)
            self?.reloadDevices()
        }
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
            style(emptyAction, "Boot \(selected?.name ?? "one")")
        case nil:
            break
        }
    }

    private func showStatus(_ status: SimulatorMirror.Status) {
        switch status {
        case .stopped:
            note(nil, action: nil)
        case .live:
            // Live, but a guest that drops the taps would leave you
            // clicking at a picture and wondering.
            note(SimulatorHost.acceptsInput ? nil : "This Xcode's simulator ignores taps from other apps.", action: nil)
        case .polling:
            note("Xcode's simulator frameworks aren't here: a screenshot every half second, and no taps.", action: "Open Simulator")
        case .waiting:
            note("Waiting for the simulator's screen…", action: "Open Simulator")
        }
        view.window?.invalidateCursorRects(for: display)
    }

    private func note(_ text: String?, action: String?) {
        noteLabel.stringValue = text ?? ""
        noteHeight.constant = text == nil ? 0 : 24
        noteAction.isHidden = action == nil
        if let action { style(noteAction, action) }
    }

    private func style(_ button: NSButton, _ title: String) {
        button.attributedTitle = NSAttributedString(
            string: title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.info])
    }

    // MARK: Actions

    @objc private func bootSelected() {
        guard let device = selected ?? devices.first else { return }
        boot(device)
    }

    /// Simulator.app, in front: the picture here is a picture, and taps
    /// belong to the simulator's own window.
    @objc private func openSimulator() {
        Task { [weak self] in
            await SimulatorControl.openSimulator(device: self?.selected, activate: true)
        }
    }

    @objc private func lookAgain() {
        mirror.reconnect()
        reloadDevices()
    }

    @objc private func toggleZoom() { onToggleZoom?() }
    @objc private func closeColumn() { onClose?() }
}

/// The picture: a layer holding the device's own surface (or a polled
/// frame), kept to the device's proportions in the middle of the pane —
/// and, when the simulator takes input, where clicks and keys go.
final class SimulatorDisplayView: NSView {
    var onOpenSimulator: (() -> Void)?
    /// The pane's longest side in pixels, as it changes — polled frames
    /// are cut down to it and no further.
    var maxPixels: ((Int) -> Void)?
    /// Where a tap goes, while there is a live simulator to take it.
    var input: (() -> SimulatorInput?)?
    private let content = CALayer()
    private var natural: CGSize = .zero
    /// The frame a drag started in, so the whole gesture is measured
    /// against one geometry even if the pane is resized under it.
    private var dragging = false

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

    /// A frame — the device's IOSurface, or a CGImage of a screenshot.
    func show(_ contents: Any, size: CGSize) {
        let resized = size != natural
        natural = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = contents
        CATransaction.commit()
        if resized { place() }
    }

    /// The device drew into the surface the layer already holds: show it
    /// again. `setContentsChanged` is how a layer is told that — the API
    /// CoreAnimation has had since surfaces were first put in layers — and
    /// where it is missing, putting the surface back does the same for the
    /// price of a little more work.
    func refresh() {
        guard content.contents != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if content.responds(to: Self.contentsChanged) {
            content.perform(Self.contentsChanged)
        } else {
            let contents = content.contents
            content.contents = nil
            content.contents = contents
        }
        CATransaction.commit()
    }

    private static let contentsChanged = Selector(("setContentsChanged"))

    func clear() {
        content.contents = nil
        natural = .zero
    }

    override func layout() {
        super.layout()
        place()
        // A tall pane deserves a tall frame: a polled screenshot is cut
        // down to what this can show, measured in pixels.
        let scale = window?.backingScaleFactor ?? 2
        maxPixels?(max(320, Int(max(bounds.width, bounds.height) * scale)))
    }

    // MARK: Touching it

    /// Where a point in the pane lands on the device: a ratio from the
    /// device's top left, or nil for a click beside the picture. Pure, so
    /// the mapping is a test and not a thing to find out by tapping.
    static func ratio(of point: CGPoint, in picture: CGRect, flipped: Bool) -> CGPoint? {
        // Inclusive of the far edges, which `CGRect.contains` is not: the
        // right-hand and top rows of pixels are the device's too.
        guard picture.width > 0, picture.height > 0,
            point.x >= picture.minX, point.x <= picture.maxX, point.y >= picture.minY, point.y <= picture.maxY
        else { return nil }
        let x = (point.x - picture.minX) / picture.width
        let y = (point.y - picture.minY) / picture.height
        return CGPoint(x: x, y: flipped ? y : 1 - y)
    }

    private func ratio(for event: NSEvent) -> CGPoint? {
        Self.ratio(of: convert(event.locationInWindow, from: nil), in: content.frame, flipped: isFlipped)
    }

    override var acceptsFirstResponder: Bool { input?() != nil }

    /// A click in the pane is a tap on the device, and takes the keyboard
    /// so what you type next goes there too.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 && input?() == nil {
            onOpenSimulator?()
            return
        }
        guard let input = input?(), let point = ratio(for: event) else { return }
        window?.makeFirstResponder(self)
        dragging = true
        input.touchDown(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let input = input?(), let point = ratio(for: event) else { return }
        input.touchMoved(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging, let input = input?() else { return }
        dragging = false
        // A finger lifted outside the picture still lifted: the last point
        // inside it is where, so a swipe off the edge ends rather than
        // sticking.
        input.touchUp(at: ratio(for: event) ?? lastInside(event))
    }

    private func lastInside(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let clamped = CGPoint(
            x: min(max(point.x, content.frame.minX), content.frame.maxX),
            y: min(max(point.y, content.frame.minY), content.frame.maxY))
        return Self.ratio(of: clamped, in: content.frame, flipped: isFlipped) ?? CGPoint(x: 0.5, y: 0.5)
    }

    /// The wheel as a finger: iOS has no scroll, so a scroll here is a
    /// swipe that begins, follows the wheel and ends when it stops.
    override func scrollWheel(with event: NSEvent) {
        guard let input = input?(), let point = ratio(for: event) else { return }
        if !scrolling {
            scrolling = true
            scrollPoint = point
            input.touchDown(at: point)
        }
        // The wheel's units are points of the pane; the device's screen is
        // the picture's height.
        scrollPoint.y -= event.scrollingDeltaY / max(content.frame.height, 1)
        scrollPoint.x += event.scrollingDeltaX / max(content.frame.width, 1)
        scrollPoint.y = min(max(scrollPoint.y, 0), 1)
        scrollPoint.x = min(max(scrollPoint.x, 0), 1)
        input.touchMoved(to: scrollPoint)
        scrollEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self, self.scrolling else { return }
            self.scrolling = false
            self.input?()?.touchUp(at: self.scrollPoint)
        }
        scrollEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: end)
    }

    private var scrolling = false
    private var scrollPoint = CGPoint(x: 0.5, y: 0.5)
    private var scrollEnd: DispatchWorkItem?

    // MARK: Typing into it

    override func keyDown(with event: NSEvent) {
        guard let input = input?() else { return super.keyDown(with: event) }
        input.key(.down, code: event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        guard let input = input?() else { return super.keyUp(with: event) }
        input.key(.up, code: event.keyCode)
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
