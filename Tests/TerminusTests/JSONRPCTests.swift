import XCTest

@testable import Terminus

/// Content-Length framing, as a pipe delivers it: in pieces, several at once.
final class JSONRPCTests: XCTestCase {
    private func frame(_ json: String) -> Data { JSONRPC.frame(Data(json.utf8)) }
    private func strings(_ messages: [Data]) -> [String] { messages.map { String(decoding: $0, as: UTF8.self) } }

    func testFrameHasTheByteLengthNotTheCharacterCount() {
        let framed = String(decoding: frame("{\"a\":\"ü\"}"), as: UTF8.self)
        XCTAssertEqual(framed, "Content-Length: 10\r\n\r\n{\"a\":\"ü\"}")
    }

    func testOneWholeMessage() {
        var decoder = JSONRPC.FrameDecoder()
        XCTAssertEqual(strings(decoder.feed(frame("{\"id\":1}"))), ["{\"id\":1}"])
        XCTAssertEqual(decoder.pendingByteCount, 0)
    }

    func testSeveralMessagesInOneChunk() {
        var decoder = JSONRPC.FrameDecoder()
        let chunk = frame("{\"id\":1}") + frame("{\"id\":2}") + frame("[]")
        XCTAssertEqual(strings(decoder.feed(chunk)), ["{\"id\":1}", "{\"id\":2}", "[]"])
    }

    func testByteByByte() {
        var decoder = JSONRPC.FrameDecoder()
        let data = frame("{\"method\":\"x\",\"params\":{\"text\":\"çok güzel 🎉\"}}") + frame("{}")
        var out: [Data] = []
        for byte in data { out += decoder.feed(Data([byte])) }
        XCTAssertEqual(strings(out), ["{\"method\":\"x\",\"params\":{\"text\":\"çok güzel 🎉\"}}", "{}"])
    }

    func testSplitInsideTheSeparatorAndTheBody() {
        var decoder = JSONRPC.FrameDecoder()
        XCTAssertEqual(decoder.feed(Data("Content-Length: 8\r\n\r".utf8)), [])
        XCTAssertEqual(decoder.feed(Data("\n{\"id\"".utf8)), [])
        XCTAssertEqual(strings(decoder.feed(Data(":1}Content-Len".utf8))), ["{\"id\":1}"])
        XCTAssertEqual(strings(decoder.feed(Data("gth: 2\r\n\r\n{}".utf8))), ["{}"])
    }

    func testOtherHeadersAndCaseAreIgnored() {
        var decoder = JSONRPC.FrameDecoder()
        let data = Data("content-type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length:   2\r\n\r\n{}".utf8)
        XCTAssertEqual(strings(decoder.feed(data)), ["{}"])
    }

    func testAHeaderWithoutALengthIsSkipped() {
        var decoder = JSONRPC.FrameDecoder()
        let data = Data("Starting server...\r\n\r\n".utf8) + frame("{}")
        XCTAssertEqual(strings(decoder.feed(data)), ["{}"])
    }

    func testAnEmptyBody() {
        var decoder = JSONRPC.FrameDecoder()
        XCTAssertEqual(decoder.feed(Data("Content-Length: 0\r\n\r\n".utf8)), [Data()])
    }

    func testABigBodyInChunks() {
        var decoder = JSONRPC.FrameDecoder()
        let body = "{\"text\":\"" + String(repeating: "x", count: 300_000) + "\"}"
        let data = frame(body)
        var out: [Data] = []
        var index = 0
        while index < data.count {
            let end = min(index + 65_536, data.count)
            out += decoder.feed(data.subdata(in: index..<end))
            index = end
        }
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.count, body.utf8.count)
    }

    func testGarbageWithoutASeparatorIsDroppedEventually() {
        var decoder = JSONRPC.FrameDecoder()
        _ = decoder.feed(Data(repeating: 0x41, count: JSONRPC.FrameDecoder.maxHeaderBytes + 1))
        XCTAssertEqual(decoder.pendingByteCount, 0)
        XCTAssertEqual(strings(decoder.feed(frame("{}"))), ["{}"])
    }

    func testJSONValueRoundTripsAndKeepsIntegers() throws {
        let value: JSONValue = ["id": 3, "ok": true, "none": nil, "list": [1, "two"], "pi": .double(3.5)]
        let data = try value.encoded()
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(JSONValue(foundation: object as Any), value)
        XCTAssertEqual(JSONValue(foundation: NSNumber(value: true)), .bool(true))
        XCTAssertEqual(JSONValue(foundation: NSNumber(value: 1)), .int(1))
    }
}
