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

    /// The device in the pane: its screen centred with its own
    /// proportions, a body around it, and corners as round as the device's
    /// — a phone's, not an iPad's.
    @MainActor
    func testTheDeviceIsLaidOutWithItsBody() throws {
        let pane = CGRect(x: 0, y: 0, width: 420, height: 900)
        let phone = try XCTUnwrap(SimulatorDisplayView.layout(natural: CGSize(width: 1206, height: 2622), in: pane))
        XCTAssertEqual(phone.screen.midX, pane.midX, accuracy: 1, "centred")
        XCTAssertEqual(phone.screen.midY, pane.midY, accuracy: 1)
        XCTAssertEqual(phone.screen.width / phone.screen.height, 1206.0 / 2622.0, accuracy: 0.01, "the device's proportions")
        XCTAssertTrue(phone.body.contains(phone.screen), "the body is around the screen")
        XCTAssertTrue(pane.contains(phone.body), "and the body is in the pane")
        XCTAssertEqual(phone.radius / phone.screen.width, 0.135, accuracy: 0.01, "a phone's corners")

        let pad = try XCTUnwrap(SimulatorDisplayView.layout(natural: CGSize(width: 1640, height: 2360), in: pane))
        XCTAssertEqual(pad.radius / pad.screen.width, 0.045, accuracy: 0.01, "an iPad's barely")
        XCTAssertNil(SimulatorDisplayView.layout(natural: .zero, in: pane), "nothing to lay out yet")
        XCTAssertNil(
            SimulatorDisplayView.layout(natural: CGSize(width: 1206, height: 2622), in: CGRect(x: 0, y: 0, width: 10, height: 10)),
            "a pane too small for a body")
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
