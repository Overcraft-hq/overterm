import Compression
import CryptoKit
import Darwin
import Foundation

/// What Overterm reads of a saved plan file itself (analysis 4.6, 5.4):
/// the prior state's `lineage` and `serial` (its `tfstate` entry) and the
/// SHA-256 of its `.terraform.lock.hcl` — nothing else, and nothing kept
/// of the state but those two: the entry holds every secret in the state,
/// decoded once and dropped. A plan is a zip (spike 3); its central
/// directory is read with `pread` from the descriptor Overterm holds, an
/// entry stored or deflated. An encrypted plan (OpenTofu) is no zip:
/// "unknown". Bounded: 64 MB an entry, 4,096 entries. Pure over the bytes
/// it is given by `read`.
struct TerraformPlanZip: Equatable, Sendable {
    var lineage: String?
    var serial: Int?
    var lockFileSHA256: String?

    struct Entry: Equatable, Sendable {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var localHeader: Int
    }

    enum Failure: Error, Equatable { case notZip, tooLarge, unreadable }

    static let maxEntry = 64 << 20
    static let maxEntries = 4_096

    /// The entries of a zip, from its end of central directory.
    static func entries(size: Int, read: (Int, Int) -> Data?) throws -> [Entry] {
        let tail = min(size, 65_557)
        guard tail >= 22, let end = read(size - tail, tail) else { throw Failure.notZip }
        var found: Int?
        var index = end.count - 22
        while index >= 0 {
            if end.uint32(at: index) == 0x0605_4B50 {
                found = index
                break
            }
            index -= 1
        }
        guard let eocd = found else { throw Failure.notZip }
        let count = Int(end.uint16(at: eocd + 10))
        let directorySize = Int(end.uint32(at: eocd + 12))
        let directoryOffset = Int(end.uint32(at: eocd + 16))
        guard count <= maxEntries, directoryOffset + directorySize <= size, directorySize <= 16 << 20 else { throw Failure.tooLarge }
        guard let directory = read(directoryOffset, directorySize) else { throw Failure.unreadable }
        var entries: [Entry] = []
        var at = 0
        for _ in 0..<count {
            guard at + 46 <= directory.count, directory.uint32(at: at) == 0x0201_4B50 else { throw Failure.notZip }
            let method = directory.uint16(at: at + 10)
            let compressed = Int(directory.uint32(at: at + 20))
            let uncompressed = Int(directory.uint32(at: at + 24))
            let nameLength = Int(directory.uint16(at: at + 28))
            let extraLength = Int(directory.uint16(at: at + 30))
            let commentLength = Int(directory.uint16(at: at + 32))
            let local = Int(directory.uint32(at: at + 42))
            guard at + 46 + nameLength <= directory.count else { throw Failure.notZip }
            let name = String(decoding: directory.subdata(in: (at + 46)..<(at + 46 + nameLength)), as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: compressed, size: uncompressed, localHeader: local))
            at += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// An entry's bytes, inflated.
    static func contents(of entry: Entry, read: (Int, Int) -> Data?) throws -> Data {
        guard entry.size <= maxEntry, entry.compressedSize <= maxEntry else { throw Failure.tooLarge }
        guard let header = read(entry.localHeader, 30), header.uint32(at: 0) == 0x0403_4B50 else { throw Failure.notZip }
        let start = entry.localHeader + 30 + Int(header.uint16(at: 26)) + Int(header.uint16(at: 28))
        guard let raw = read(start, entry.compressedSize), raw.count == entry.compressedSize else { throw Failure.unreadable }
        switch entry.method {
        case 0:
            return raw
        case 8:
            if entry.size == 0 { return Data() }
            var output = Data(count: entry.size)
            let written = output.withUnsafeMutableBytes { out in
                raw.withUnsafeBytes { input in
                    compression_decode_buffer(
                        out.bindMemory(to: UInt8.self).baseAddress!, entry.size, input.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil,
                        COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw Failure.unreadable }
            return output
        default:
            throw Failure.unreadable
        }
    }

    /// The facts of a plan whose bytes `read` gives (`offset`, `length`).
    static func read(size: Int, read: (Int, Int) -> Data?) -> TerraformPlanZip? {
        guard let entries = try? entries(size: size, read: read) else { return nil }
        var facts = TerraformPlanZip()
        if let state = entries.first(where: { $0.name == "tfstate" }), let data = try? contents(of: state, read: read),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            facts.lineage = (object["lineage"] as? String).map { String($0.prefix(64)) }
            facts.serial = (object["serial"] as? NSNumber)?.intValue
        }
        if let lock = entries.first(where: { $0.name == ".terraform.lock.hcl" }), let data = try? contents(of: lock, read: read) {
            facts.lockFileSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return facts
    }

    /// The facts of the plan open as `descriptor`. Blocking.
    static func read(descriptor: Int32) -> TerraformPlanZip? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return read(size: Int(info.st_size)) { offset, length in
            guard offset >= 0, length >= 0 else { return nil }
            var data = Data(count: length)
            let got = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, length, off_t(offset)) }
            return got == length ? data : nil
        }
    }
}

extension Data {
    fileprivate func uint16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    fileprivate func uint32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }
}
