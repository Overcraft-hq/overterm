import AppKit
import IOSurface
import ImageIO

/// Where the simulator's picture comes from. Two ways, and it takes the
/// better one it can get:
///
/// - **Live** (`SimulatorScreen`): the IOSurface CoreSimulator draws the
///   device into, in a layer as it is — what the device is doing, at the
///   rate it does it, and taps go back the same way (`SimulatorInput`).
///   This is Xcode's own private machinery; see `SimulatorHost`.
/// - **Screenshots** (`simctl io screenshot`): when that machinery isn't
///   there — no Xcode, or an Xcode that has moved it — the device's
///   framebuffer as a BMP three or four times a second. A picture, not a
///   simulator you can use, but never a blank pane.
@MainActor
final class SimulatorMirror: ObservableObject {
    enum Status: Equatable {
        case stopped
        /// Asked, nothing back yet — booting, or shutting down under us.
        case waiting
        /// Screenshots: no live screen to be had.
        case polling
        /// The device's own surface, and taps go back to it.
        case live
    }

    @Published private(set) var status: Status = .stopped
    /// A frame for the layer: an IOSurface (live) or a CGImage (polled).
    var onFrame: ((Any, CGSize) -> Void)?
    /// Live only: the device drew, so the layer should look again.
    var onDamage: (() -> Void)?
    /// Live only: where taps and keys go.
    private(set) var input: SimulatorInput?
    /// The longest side polled frames are cut down to, in pixels.
    var maxPixels = 1200

    private var device: SimulatorDevice?
    private var screen: SimulatorScreen?
    private var reading: Task<Void, Never>?

    /// One polled frame on its way to the layer. A CGImage is immutable
    /// and the decode is done off the main thread, so it crosses that hop.
    struct Frame: @unchecked Sendable {
        let image: CGImage
        var size: CGSize { CGSize(width: image.width, height: image.height) }
    }

    /// Shows `device`, from now until `stop()`.
    func start(_ device: SimulatorDevice) {
        guard self.device != device || status == .stopped else { return }
        stop()
        self.device = device
        status = .waiting
        reading = Task { [weak self] in await self?.connect(device) }
    }

    func stop() {
        reading?.cancel()
        reading = nil
        screen?.stop()
        screen = nil
        input = nil
        device = nil
        status = .stopped
    }

    /// Starts again on the same device — it may have been rebooted.
    func reconnect() {
        guard let device else { return }
        self.device = nil
        start(device)
    }

    // MARK: The device's own screen

    private func connect(_ device: SimulatorDevice) async {
        guard let developer = await SimulatorControl.developerDirectory(), !Task.isCancelled else { return await poll(device) }
        guard let simDevice = SimulatorHost.device(udid: device.udid, developerDirectory: developer),
            let screen = SimulatorScreen(device: simDevice)
        else { return await poll(device) }
        self.screen = screen
        input = SimulatorInput(device: simDevice)
        screen.onDamage = { [weak self] in self?.onDamage?() }
        screen.onSurface = { [weak self] surface in
            guard let self, let surface else { return }
            onFrame?(surface, self.screen?.size ?? .zero)
        }
        if let surface = screen.surface { onFrame?(surface, screen.size) }
        status = .live
    }

    // MARK: Screenshots, when there is no live screen

    private func poll(_ device: SimulatorDevice) async {
        guard !Task.isCancelled else { return }
        status = .polling
        let udid = device.udid
        while !Task.isCancelled {
            let shot = await SimulatorControl.screenshot(udid)
            guard !Task.isCancelled else { return }
            let size = maxPixels
            // 1206 × 2622 pixels of BMP: 40 ms of ImageIO, which is not the
            // main thread's to spend three times a second.
            let frame = shot == nil ? nil : await Task.detached { Self.frame(shot!, maxPixels: size) }.value
            guard !Task.isCancelled else { return }
            if let frame {
                status = .polling
                onFrame?(frame.image, frame.size)
            } else {
                // Shut down, or shutting down: keep asking, slowly.
                status = .waiting
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    nonisolated static func frame(_ data: Data, maxPixels: Int) -> Frame? {
        image(data, maxPixels: maxPixels).map(Frame.init)
    }

    /// The screenshot as a frame the pane's size, with the device's
    /// proportions kept.
    nonisolated static func image(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
    }
}
