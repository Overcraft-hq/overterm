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
