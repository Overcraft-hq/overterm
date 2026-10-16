import AppKit
import ImageIO

/// The simulator's screen, in Overterm's own window.
///
/// `simctl io <device> screenshot` reads the device's framebuffer through
/// CoreSimulator: nothing of the Mac's screen is captured, so there is no
/// Screen Recording grant to ask for, and Simulator.app needn't be showing
/// the device — or running at all. The price is the frame rate: a shot
/// costs a quarter of a second as a BMP (0.25 s, against 0.62 s for a PNG —
/// the encoding is most of it), so this is three or four frames a second,
/// not a video.
///
/// A phone's framebuffer is 1206 × 2622; ImageIO cuts each one down to the
/// pane's size before it reaches the layer, which is 40 ms and keeps the
/// 12 MB out of the window server.
@MainActor
final class SimulatorMirror: ObservableObject {
    enum Status: Equatable {
        case stopped
        /// Asked, nothing back yet — booting, or shutting down under us.
        case waiting
        case showing
    }

    @Published private(set) var status: Status = .stopped
    /// A frame for the layer (`CALayer.contents` takes a CGImage).
    var onFrame: ((Any, CGSize) -> Void)?
    /// The longest side the frames are cut down to, in pixels.
    var maxPixels = 1200

    private var device: SimulatorDevice?
    private var reading: Task<Void, Never>?

    /// One frame on its way to the layer. A CGImage is immutable and the
    /// decode is done off the main thread, so it crosses that one hop.
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
        let udid = device.udid
        reading = Task { [weak self] in
            while !Task.isCancelled {
                let shot = await SimulatorControl.screenshot(udid)
                guard !Task.isCancelled, let self else { return }
                let size = self.maxPixels
                // 1206 × 2622 pixels of BMP: 40 ms of ImageIO, which is not
                // the main thread's to spend three times a second.
                let frame = shot == nil ? nil : await Task.detached { Self.frame(shot!, maxPixels: size) }.value
                guard !Task.isCancelled else { return }
                if let frame {
                    self.status = .showing
                    self.onFrame?(frame.image, frame.size)
                } else {
                    // Shut down, or shutting down: keep asking, slowly.
                    self.status = .waiting
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    func stop() {
        reading?.cancel()
        reading = nil
        device = nil
        status = .stopped
    }

    /// Starts again on the same device — it may have been rebooted.
    func reconnect() {
        guard let device else { return }
        self.device = nil
        start(device)
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
