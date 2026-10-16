import AppKit
import IOSurface

/// The device's screen as the simulator draws it: the IOSurface
/// CoreSimulator renders into, handed to a layer as it is — no capture, no
/// copy, no encoding, and no Screen Recording grant, because nothing of
/// the Mac's screen is read (`SimulatorHost`).
///
/// CoreSimulator says when it has drawn (its damage rectangles), and that
/// is what makes the layer pick the surface up again.
@MainActor
final class SimulatorScreen {
    /// The surface the device draws into; it is replaced on a rotation or
    /// a resize, which the surface callback reports.
    private(set) var surface: IOSurface?
    /// Drawn: the layer should show the surface again.
    var onDamage: (() -> Void)?
    /// A new surface (rotation, resize).
    var onSurface: ((IOSurface?) -> Void)?

    private let descriptor: NSObject
    private let uuid = UUID()
    private var registered = false
    /// What `deinit` needs, held where a nonisolated deinit may read it:
    /// taking the callbacks back needs the descriptor, and the descriptor
    /// is not Sendable.
    private nonisolated(unsafe) var teardown: (() -> Void)?

    /// The display port of a booted device, or nil when this Xcode's
    /// CoreSimulator doesn't offer one.
    init?(device: NSObject) {
        guard let renderable = NSProtocolFromString("SimDisplayIOSurfaceRenderable"),
            let io = device.perform(Selector(("io")))?.takeUnretainedValue() as? NSObject,
            let ports = io.perform(Selector(("ioPorts")))?.takeUnretainedValue() as? [NSObject]
        else { return nil }
        let displays = ports.compactMap { $0.perform(Selector(("descriptor")))?.takeUnretainedValue() as? NSObject }
            .filter { $0.conforms(to: renderable) }
        guard let first = displays.first else { return nil }
        descriptor = first
        surface = Self.surface(of: first)
        guard surface != nil else { return nil }
        register()
    }

    deinit {
        // CoreSimulator keeps the blocks until they are taken back. The
        // last reference can be dropped anywhere, so this must not assume
        // the main actor — a `MainActor.assumeIsolated` here would trap.
        teardown?()
    }

    /// The size the device draws at, in pixels.
    var size: CGSize {
        guard let surface else { return .zero }
        return CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
    }

    func stop() { unregister() }

    private func register() {
        guard !registered else { return }
        registered = true
        teardown = Self.teardown(descriptor, uuid)
        let damage = Self.block { [weak self] _ in self?.onDamage?() }
        let changed = Self.block { [weak self] _ in
            guard let self else { return }
            surface = Self.surface(of: descriptor)
            onSurface?(surface)
            onDamage?()
        }
        _ = descriptor.perform(Selector(("registerCallbackWithUUID:damageRectanglesCallback:")), with: uuid, with: damage)
        _ = descriptor.perform(Selector(("registerCallbackWithUUID:ioSurfacesChangeCallback:")), with: uuid, with: changed)
    }

    private func unregister() {
        guard registered else { return }
        registered = false
        teardown?()
        teardown = nil
    }

    /// Taking the two callbacks back, as a closure that owns what it needs
    /// — so `deinit` can run it wherever it is called.
    private nonisolated static func teardown(_ descriptor: NSObject, _ uuid: UUID) -> () -> Void {
        nonisolated(unsafe) let descriptor = descriptor
        return {
            _ = descriptor.perform(Selector(("unregisterDamageRectanglesCallbackWithUUID:")), with: uuid)
            _ = descriptor.perform(Selector(("unregisterIOSurfacesChangeCallbackWithUUID:")), with: uuid)
        }
    }

    private static func surface(of descriptor: NSObject) -> IOSurface? {
        descriptor.perform(Selector(("framebufferSurface")))?.takeUnretainedValue() as? IOSurface
    }

    /// A block CoreSimulator calls on its own queue — built outside the
    /// main actor on purpose: a closure written inside a `@MainActor` type
    /// is isolated to it, and Swift 6 traps when it is called elsewhere.
    private nonisolated static func block(_ body: @escaping @Sendable @MainActor (AnyObject?) -> Void) -> AnyObject {
        let block: @convention(block) (AnyObject?) -> Void = { argument in
            // An IOSurface is not Sendable; nothing of it crosses here.
            nonisolated(unsafe) let argument = argument
            DispatchQueue.main.async { body(argument) }
        }
        return block as AnyObject
    }
}
