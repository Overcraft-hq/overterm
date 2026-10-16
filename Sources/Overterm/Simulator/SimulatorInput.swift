import AppKit

/// Taps and keys into the simulator.
///
/// SimulatorKit builds the events itself — `IndigoHIDMessageForMouseNSEvent`
/// and `IndigoHIDMessageForKeyboardArbitrary` are C functions in it, the
/// same ones Simulator.app's own window calls when you click in it — and
/// `SimDeviceLegacyHIDClient` carries the message to the device. So the
/// wire format is never written here, only asked for: nothing to go stale
/// but the two signatures (documented by idb, which found them).
///
/// A point is a ratio of the screen (0…1, from the top left), which is
/// what the builder wants when it is handed a unit size.
@MainActor
final class SimulatorInput {
    enum Direction: Int32 {
        case down = 1, up = 2
    }

    /// What a drag's middle is to AppKit, and so to the builder.
    private static let dragged: UInt = 6

    private let client: AnyObject
    /// Kept to ask whether the device is still up: CoreSimulator raises an
    /// Objective-C exception when it is sent to after a shutdown, and that
    /// unwinding through Swift would take the app down rather than fail.
    private let device: NSObject
    private let queue = DispatchQueue(label: "overterm.simulator-input")
    private let mouse: MouseBuilder
    private let keyboard: KeyboardBuilder

    private typealias MouseBuilder =
        @convention(c) (
            UnsafeMutablePointer<CGPoint>?, UnsafeMutablePointer<CGPoint>?, UInt32, UInt, CGSize, UInt32
        ) -> UnsafeMutableRawPointer?
    private typealias KeyboardBuilder = @convention(c) (Int32, Int32) -> UnsafeMutableRawPointer?

    /// Nil unless this Xcode has the class and both builders.
    init?(device: NSObject) {
        guard SimulatorHost.isBooted(device),
            let clientClass = NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient") as? NSObject.Type,
            let allocated = (clientClass as AnyObject).perform(Selector(("alloc")))?.takeUnretainedValue() as? NSObject,
            let client = allocated.perform(Selector(("initWithDevice:error:")), with: device, with: nil)?.takeUnretainedValue(),
            let mouse = SimulatorHost.symbol("IndigoHIDMessageForMouseNSEvent"),
            let keyboard = SimulatorHost.symbol("IndigoHIDMessageForKeyboardArbitrary")
        else { return nil }
        self.client = client
        self.device = device
        self.mouse = unsafeBitCast(mouse, to: MouseBuilder.self)
        self.keyboard = unsafeBitCast(keyboard, to: KeyboardBuilder.self)
    }

    // MARK: Touch

    /// Whether the device is still booted — asked at the start of a
    /// gesture, not on every point of it (each ask is a round trip).
    var isUsable: Bool { SimulatorHost.isBooted(device) }

    /// A finger put down at `point` (a ratio of the screen).
    func touchDown(at point: CGPoint) {
        guard isUsable else { return }
        touch(point, UInt(Direction.down.rawValue))
    }
    /// The finger moved, still down.
    func touchMoved(to point: CGPoint) { touch(point, Self.dragged) }
    /// The finger lifted.
    func touchUp(at point: CGPoint) { touch(point, UInt(Direction.up.rawValue)) }

    /// Down and up in one, for a tap nothing is dragging.
    func tap(at point: CGPoint) {
        touchDown(at: point)
        // A tap with no time in it is dropped by some controls.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.touchUp(at: point) }
    }

    private func touch(_ point: CGPoint, _ event: UInt) {
        var point = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        // 0x32 is the main digitizer; the unit size leaves the ratio alone;
        // 0 is "not an edge gesture".
        guard let message = mouse(&point, nil, 0x32, event, CGSize(width: 1, height: 1), 0) else { return }
        send(message)
    }

    // MARK: Keys

    /// A key, by the virtual key code AppKit gives (`NSEvent.keyCode`) —
    /// the hardware-independent codes of `<HIToolbox/Events.h>`, which is
    /// what the builder takes.
    func key(_ direction: Direction, code: UInt16) {
        guard direction == .up || isUsable, let message = keyboard(Int32(code), direction.rawValue) else { return }
        send(message)
    }

    // MARK: The wire

    private func send(_ message: UnsafeMutableRawPointer) {
        // The client is messaged only from this queue, and the message is
        // the client's to free once it is handed over.
        nonisolated(unsafe) let client = client
        nonisolated(unsafe) let message = message
        queue.async {
            // The client frees the message when it is done with it.
            unsafeBitCast(client, to: LegacyHIDClient.self)
                .send(message: message, freeWhenDone: true, completionQueue: DispatchQueue.global(qos: .utility)) { _ in }
        }
    }
}

/// `SimDeviceLegacyHIDClient`, as far as this needs it. Messaged by name
/// rather than linked: the class has moved between Xcodes, and a link-time
/// reference to it would stop the app launching where it is absent.
@objc private protocol LegacyHIDClient {
    @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
    func send(
        message: UnsafeMutableRawPointer, freeWhenDone: Bool, completionQueue: DispatchQueue,
        completion: @escaping @Sendable (Error?) -> Void)
}
