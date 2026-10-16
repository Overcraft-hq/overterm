import AppKit
import CoreMedia
import IOSurface
import ImageIO
import ScreenCaptureKit

/// The simulator's screen, live, inside Overterm's window.
///
/// Two ways in, because neither covers everything:
///
/// - **ScreenCaptureKit** mirrors Simulator.app's own window at 30 fps,
///   occluded or on another Space — what you see is what the simulator is
///   doing, now. It wants the Screen Recording grant, and macOS only hands
///   a new grant to the next launch, so the first answer is always "ask,
///   then fall back".
/// - **`simctl io screenshot`** reads the device's framebuffer through
///   CoreSimulator: no grant, no window, but half a second a frame. The
///   fallback — and the only picture when the grant is refused or
///   Simulator.app isn't showing the device.
@MainActor
final class SimulatorMirror: NSObject, ObservableObject {
    /// Why the picture looks the way it does — the pane says it in words.
    enum Status: Equatable {
        case stopped
        case connecting
        /// Mirroring Simulator.app's window.
        case live
        /// Polling the device's framebuffer, and why.
        case polling(Reason)

        enum Reason: Equatable {
            /// The grant isn't given (or isn't in force until a relaunch).
            case denied
            /// Simulator.app isn't showing this device.
            case noWindow
        }
    }

    @Published private(set) var status: Status = .stopped
    /// A frame to put in a layer: an IOSurface from the stream, a CGImage
    /// from a screenshot — `CALayer.contents` takes either.
    var onFrame: ((Any, CGSize) -> Void)?

    private var device: SimulatorDevice?
    private var stream: SCStream?
    private var polling: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private let output = SimulatorFrameOutput()
    private let queue = DispatchQueue(label: "overterm.simulator-mirror")
    /// What the polled screenshots are scaled down to (points × scale).
    var pointSize: CGSize = CGSize(width: 420, height: 900)

    /// Whether the Screen Recording grant is in force for this launch.
    static var isAllowedToRecord: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for the grant (once per app install — after that the
    /// prompt is the Settings pane, and the grant lands on a relaunch).
    static func requestRecording() {
        if CGRequestScreenCaptureAccess() { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Shows `device`: the stream if it can, the framebuffer if it can't.
    func start(_ device: SimulatorDevice) {
        guard self.device != device || status == .stopped else { return }
        stop()
        self.device = device
        status = .connecting
        connecting = Task { [weak self] in await self?.connect(device) }
    }

    func stop() {
        connecting?.cancel()
        connecting = nil
        polling?.cancel()
        polling = nil
        device = nil
        status = .stopped
        guard let stream else { return }
        self.stream = nil
        // SCStream's own queue: nothing here waits for it.
        Task { try? await stream.stopCapture() }
    }

    /// Tries again — the grant may have landed, or Simulator.app opened.
    func reconnect() {
        guard let device else { return }
        self.device = nil
        start(device)
    }

    // MARK: The stream

    private func connect(_ device: SimulatorDevice) async {
        guard Self.isAllowedToRecord else { return fallBack(to: device, .denied) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard !Task.isCancelled else { return }
            guard let window = Self.window(for: device, in: content) else { return fallBack(to: device, .noWindow) }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let configuration = SCStreamConfiguration()
            configuration.width = max(2, Int(window.frame.width * scale))
            configuration.height = max(2, Int(window.frame.height * scale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: self)
            output.onFrame = { [weak self] frame in
                Task { @MainActor in self?.deliver(frame.surface, frame.size) }
            }
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            guard !Task.isCancelled else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
            status = .live
        } catch {
            // -3801 is the refused grant; anything else (no window, a stream
            // that won't start) still leaves the framebuffer.
            fallBack(to: device, Self.isAllowedToRecord ? .noWindow : .denied)
        }
    }

    /// Simulator.app's window for this device: by its title ("iPhone 17 Pro
    /// — iOS 26.2"), else the biggest window it has.
    static func window(for device: SimulatorDevice, in content: SCShareableContent) -> SCWindow? {
        let windows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator" && window.windowLayer == 0
                && window.frame.width > 80 && window.frame.height > 80
        }
        return windows.first { ($0.title ?? "").contains(device.name) }
            ?? windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func deliver(_ frame: Any, _ size: CGSize) {
        guard status == .live || stream != nil else { return }
        onFrame?(frame, size)
    }

    // MARK: The framebuffer

    private func fallBack(to device: SimulatorDevice, _ reason: Status.Reason) {
        guard !Task.isCancelled else { return }
        stream = nil
        status = .polling(reason)
        polling?.cancel()
        let maxPixels = Int(max(pointSize.width, pointSize.height) * (NSScreen.main?.backingScaleFactor ?? 2))
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let png = await SimulatorControl.screenshot(device.udid)
                guard !Task.isCancelled else { return }
                if let png, let image = Self.image(png, maxPixels: maxPixels) {
                    self?.onFrame?(image, CGSize(width: image.width, height: image.height))
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    /// The PNG as a layer-sized image — a phone's screenshot is 1206 × 2622,
    /// and the pane is a fifth of that.
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

extension SimulatorMirror: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            // The simulator's window closed, or the display went away.
            guard let self, let device = self.device else { return }
            self.stream = nil
            self.fallBack(to: device, .noWindow)
        }
    }
}

/// One frame on its way to the layer. An IOSurface is a buffer two
/// processes share, so it is not Sendable by nature; this carries it over
/// the single hop from the stream's queue to the main actor, retained the
/// whole way so ScreenCaptureKit can't recycle it underneath the layer.
struct SimulatorFrame: @unchecked Sendable {
    let surface: IOSurface
    let size: CGSize
}

/// The stream's frames, taken on its own queue and handed on. Its own
/// class, not the mirror: ScreenCaptureKit calls this from a background
/// queue, and a method written inside a `@MainActor` type traps there.
final class SimulatorFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    /// Called on the stream's queue.
    var onFrame: (@Sendable (SimulatorFrame) -> Void)?

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        // A frame arrives even when nothing changed; only a complete one
        // carries pixels.
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[SCStreamFrameInfo.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
            let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        onFrame?(SimulatorFrame(surface: unsafeBitCast(surface, to: IOSurface.self), size: size))
    }
}
