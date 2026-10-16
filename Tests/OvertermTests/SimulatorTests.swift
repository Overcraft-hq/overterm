import AppKit
import ImageIO
import XCTest

@testable import Overterm

/// The simulator pane's pure halves: what `simctl list` says there is, and
/// the screenshot a polled frame is cut down to.
final class SimulatorTests: XCTestCase {
    private let listing = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
              { "udid": "AAA", "name": "iPhone 16 Pro", "state": "Shutdown", "isAvailable": true },
              { "udid": "OLD", "name": "iPhone 8", "state": "Shutdown", "isAvailable": false }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
              { "udid": "BBB", "name": "iPad Air 11-inch (M3)", "state": "Shutdown", "isAvailable": true },
              { "udid": "CCC", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-2": [
              { "udid": "DDD", "name": "Apple Watch Series 11 (46mm)", "state": "Shutdown", "isAvailable": true }
            ]
          }
        }
        """

    func testBootedComesFirstThenTheNewestRuntime() {
        let devices = SimulatorList.devices(fromJSON: Data(listing.utf8))
        XCTAssertEqual(devices.map(\.udid), ["CCC", "BBB", "DDD", "AAA"], "booted first, then iOS 26.2, watchOS 26.2, iOS 18.6")
        XCTAssertEqual(devices.first?.label, "iPhone 17 Pro — iOS 26.2")
        XCTAssertTrue(devices.first?.isBooted == true)
        XCTAssertFalse(devices.dropFirst().contains { $0.isBooted })
    }

    func testARuntimeThatIsGoneLeavesItsDevicesOut() {
        let devices = SimulatorList.devices(fromJSON: Data(listing.utf8))
        XCTAssertFalse(devices.contains { $0.udid == "OLD" }, "isAvailable false: it can't be booted")
    }

    func testRuntimeNames() {
        XCTAssertEqual(SimulatorList.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-26-2"), "iOS 26.2")
        XCTAssertEqual(SimulatorList.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-11-0"), "watchOS 11.0")
        XCTAssertEqual(SimulatorList.runtimeName("something-else"), "something-else")
    }

    func testNonsenseIsNoDevices() {
        XCTAssertTrue(SimulatorList.devices(fromJSON: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(SimulatorList.devices(fromJSON: Data(#"{"devices":{}}"#.utf8)).isEmpty)
    }

    /// A polled frame is a phone's whole screen — 1206 × 2622 — and the
    /// pane is a fifth of that: it is cut down before it reaches the layer.
    func testAPolledFrameIsCutDownToThePane() throws {
        let png = try XCTUnwrap(makePNG(width: 1206, height: 2622))
        let image = try XCTUnwrap(SimulatorMirror.image(png, maxPixels: 600))
        XCTAssertEqual(max(image.width, image.height), 600)
        XCTAssertEqual(Double(image.width) / Double(image.height), 1206.0 / 2622.0, accuracy: 0.01, "the phone's proportions stay")
        XCTAssertNil(SimulatorMirror.image(Data("not a png".utf8), maxPixels: 600))
    }

    /// From Xcode 27 (CoreSimulator 1155.4) the guest drops the input this
    /// sends — the bytes arrive and nothing happens — so the pane says so
    /// instead of letting you tap at a picture. Numeric comparison: 1155.10
    /// is newer than 1155.4, which a string comparison has backwards.
    @MainActor
    func testWhichCoreSimulatorsStillTakeTheInput() {
        XCTAssertFalse(SimulatorHost.suppressesLegacyInput("1051.17.7"), "Xcode 26 takes it")
        XCTAssertFalse(SimulatorHost.suppressesLegacyInput("1155.3"))
        XCTAssertTrue(SimulatorHost.suppressesLegacyInput("1155.4"))
        XCTAssertTrue(SimulatorHost.suppressesLegacyInput("1155.10"), "newer than 1155.4, not older")
        XCTAssertTrue(SimulatorHost.suppressesLegacyInput("1200.1"))
        XCTAssertFalse(SimulatorHost.suppressesLegacyInput(nil), "nothing loaded: nothing to say")
    }

    /// Where a click in the pane lands on the device. The picture is
    /// centred in the pane with the device's proportions, and AppKit's
    /// origin is the bottom left while the device's is the top left.
    @MainActor
    func testAClickMapsToAPointOnTheDevice() {
        let picture = CGRect(x: 50, y: 20, width: 200, height: 400)
        let topLeft = SimulatorDisplayView.ratio(of: CGPoint(x: 50, y: 420), in: picture, flipped: false)
        XCTAssertEqual(topLeft?.x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft?.y ?? -1, 0, accuracy: 0.001)
        let middle = SimulatorDisplayView.ratio(of: CGPoint(x: 150, y: 220), in: picture, flipped: false)
        XCTAssertEqual(middle?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(middle?.y ?? -1, 0.5, accuracy: 0.001)
        let bottomRight = SimulatorDisplayView.ratio(of: CGPoint(x: 250, y: 20), in: picture, flipped: false)
        XCTAssertEqual(bottomRight?.x ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(bottomRight?.y ?? -1, 1, accuracy: 0.001)
        // A flipped view counts down from the top itself.
        let flipped = SimulatorDisplayView.ratio(of: CGPoint(x: 150, y: 20), in: picture, flipped: true)
        XCTAssertEqual(flipped?.y ?? -1, 0, accuracy: 0.001)
        XCTAssertNil(SimulatorDisplayView.ratio(of: CGPoint(x: 10, y: 220), in: picture, flipped: false), "beside the picture")
        XCTAssertNil(SimulatorDisplayView.ratio(of: CGPoint(x: 150, y: 220), in: .zero, flipped: false), "no picture yet")
    }

    private func makePNG(width: Int, height: Int) -> Data? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = context.makeImage()
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
