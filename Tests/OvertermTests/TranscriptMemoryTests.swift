import XCTest

@testable import Overterm

/// Reading a big transcript holds a chunk at a time, not the file: each
/// chunk's autoreleased buffer used to live until the whole read ended.
final class TranscriptMemoryTests: XCTestCase {
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Double(info.phys_footprint) / 1_048_576
    }

    func testReadingA64MBTranscriptDoesNotHoldIt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-big-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let line =
            #"{"type":"assistant","message":{"id":"m","model":"claude","usage":{"input_tokens":1,"output_tokens":2}},"timestamp":"2026-09-28T10:00:00Z"}"#
            + "\n"
        let block = Data(String(repeating: line, count: 10_000).utf8)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        while try handle.offset() < 64 << 20 { handle.write(block) }
        try handle.close()

        let before = footprintMB()
        XCTAssertNotNil(ClaudeUsageReader().usage(of: file))
        let grown = footprintMB() - before
        XCTAssertLessThan(grown, 32, "held \(Int(grown)) MB after reading 64 MB")
    }
}
