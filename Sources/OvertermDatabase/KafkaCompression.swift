import Compression
import Foundation

/// A compressed record batch's records, opened: gzip by the system's zlib
/// (its header read here), LZ4 frames and Snappy (raw, or in the Java
/// client's xerial framing) by decoders of ours — small, and an LZ4 frame's
/// blocks may reach back into earlier ones, which Apple's raw decoder can't
/// — and zstd by the zstd DuckDB's library carries (`DuckDBKit`, already in
/// the app), found by name; without it, said. Each capped at `limit` bytes.
package enum KafkaCompression {
    /// What one batch may open to: more is refused, not allocated.
    package static let limit = 64 << 20

    package static func inflate(_ codec: KafkaWire.Codec, _ bytes: [UInt8]) throws -> [UInt8] {
        switch codec {
        case .none: return bytes
        case .gzip: return try gunzip(bytes)
        case .snappy: return try unsnappy(bytes)
        case .lz4: return try unlz4Frame(bytes)
        case .zstd: return try unzstd(bytes)
        }
    }

    private static func failure(_ codec: String, _ why: String) -> KafkaWire.Failure {
        KafkaWire.Failure("A \(codec)-compressed batch couldn't be opened: \(why).")
    }

    // MARK: gzip

    /// RFC 1952: the header read here, the DEFLATE stream after it by zlib.
    package static func gunzip(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw failure("gzip", "no gzip header") }
        let flags = bytes[3]
        var at = 10
        if flags & 0x04 != 0 {
            guard at + 2 <= bytes.count else { throw failure("gzip", "its header is cut") }
            at += 2 + Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {
            while at < bytes.count, bytes[at] != 0 { at += 1 }
            at += 1
        }
        if flags & 0x02 != 0 { at += 2 }
        guard at < bytes.count else { throw failure("gzip", "its header is cut") }
        return try stream(COMPRESSION_ZLIB, Array(bytes[at...]), codec: "gzip")
    }

    private static func stream(_ algorithm: compression_algorithm, _ input: [UInt8], codec: String) throws -> [UInt8] {
        let state = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { state.deallocate() }
        guard compression_stream_init(state, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw failure(codec, "the decoder didn't start")
        }
        defer { compression_stream_destroy(state) }
        var output: [UInt8] = []
        let chunk = 64 << 10
        var buffer = [UInt8](repeating: 0, count: chunk)
        return try input.withUnsafeBufferPointer { source in
            state.pointee.src_ptr = source.baseAddress!
            state.pointee.src_size = source.count
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { out -> compression_status in
                    state.pointee.dst_ptr = out.baseAddress!
                    state.pointee.dst_size = chunk
                    return compression_stream_process(state, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                output += buffer[0..<(chunk - state.pointee.dst_size)]
                guard output.count <= limit else { throw failure(codec, "it opens to more than \(limit >> 20) MB") }
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK: continue
                default: throw failure(codec, "the stream is damaged")
                }
            }
        }
    }

    // MARK: LZ4

    /// An LZ4 frame (lz4's frame format, as Kafka writes it): its blocks,
    /// stored or compressed, decoded into one output so a block may refer
    /// to the ones before it.
    package static func unlz4Frame(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 7, Array(bytes[0..<4]) == [0x04, 0x22, 0x4D, 0x18] else { throw failure("lz4", "no LZ4 frame") }
        let flags = bytes[4]
        var at = 6 + (flags & 0x08 != 0 ? 8 : 0) + (flags & 0x01 != 0 ? 4 : 0) + 1
        let blockChecksum = flags & 0x10 != 0
        var output: [UInt8] = []
        while true {
            guard at + 4 <= bytes.count else { throw failure("lz4", "it ends before its end mark") }
            let word = UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
            at += 4
            if word == 0 { return output }
            let size = Int(word & 0x7FFF_FFFF)
            guard at + size <= bytes.count else { throw failure("lz4", "a block is cut") }
            if word & 0x8000_0000 != 0 {
                output += bytes[at..<at + size]
            } else {
                try lz4Block(bytes[at..<at + size], into: &output)
            }
            guard output.count <= limit else { throw failure("lz4", "it opens to more than \(limit >> 20) MB") }
            at += size + (blockChecksum ? 4 : 0)
        }
    }

    /// One LZ4 block's sequences: literals, then a match back into `output`.
    package static func lz4Block(_ block: ArraySlice<UInt8>, into output: inout [UInt8]) throws {
        var i = block.startIndex
        let end = block.endIndex
        func length(_ start: Int) throws -> Int {
            var n = start
            guard n == 15 else { return n }
            while true {
                guard i < end else { throw failure("lz4", "a length runs past the block") }
                let byte = Int(block[i])
                i += 1
                n += byte
                if byte != 255 { return n }
            }
        }
        while i < end {
            let token = Int(block[i])
            i += 1
            let literals = try length(token >> 4)
            guard i + literals <= end else { throw failure("lz4", "literals run past the block") }
            output += block[i..<i + literals]
            i += literals
            if i == end { return }
            guard i + 2 <= end else { throw failure("lz4", "a match's offset is cut") }
            let offset = Int(block[i]) | Int(block[i + 1]) << 8
            i += 2
            let count = try length(token & 0x0F) + 4
            guard offset > 0, offset <= output.count else { throw failure("lz4", "a match reaches before the start") }
            guard output.count + count <= limit else { throw failure("lz4", "it opens to more than \(limit >> 20) MB") }
            let from = output.count - offset
            for k in 0..<count { output.append(output[from + k]) }
        }
    }

    // MARK: Snappy

    private static let xerial: [UInt8] = [0x82, 0x53, 0x4E, 0x41, 0x50, 0x50, 0x59, 0x00]

    /// Snappy: the Java client's xerial framing (a header, then chunks a
    /// length each), or a raw block as librdkafka may write it.
    package static func unsnappy(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 16, Array(bytes[0..<8]) == xerial else { return try snappyBlock(bytes[...]) }
        var at = 16
        var output: [UInt8] = []
        while at < bytes.count {
            guard at + 4 <= bytes.count else { throw failure("snappy", "a chunk's length is cut") }
            let size = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            at += 4
            guard at + size <= bytes.count else { throw failure("snappy", "a chunk is cut") }
            output += try snappyBlock(bytes[at..<at + size])
            guard output.count <= limit else { throw failure("snappy", "it opens to more than \(limit >> 20) MB") }
            at += size
        }
        return output
    }

    /// One raw Snappy block: its length, then literals and copies.
    package static func snappyBlock(_ block: ArraySlice<UInt8>) throws -> [UInt8] {
        var i = block.startIndex
        let end = block.endIndex
        var expected = 0
        var shift = 0
        while true {
            guard i < end, shift < 35 else { throw failure("snappy", "its length is damaged") }
            let byte = Int(block[i])
            i += 1
            expected |= (byte & 0x7F) << shift
            if byte < 0x80 { break }
            shift += 7
        }
        guard expected <= limit else { throw failure("snappy", "it opens to more than \(limit >> 20) MB") }
        var output: [UInt8] = []
        output.reserveCapacity(expected)
        func copy(_ offset: Int, _ count: Int) throws {
            guard offset > 0, offset <= output.count, output.count + count <= expected else { throw failure("snappy", "a copy reaches outside") }
            let from = output.count - offset
            for k in 0..<count { output.append(output[from + k]) }
        }
        while i < end {
            let tag = Int(block[i])
            i += 1
            switch tag & 0x03 {
            case 0:
                var count = tag >> 2
                if count >= 60 {
                    let extra = count - 59
                    guard i + extra <= end else { throw failure("snappy", "a literal's length is cut") }
                    count = 0
                    for k in 0..<extra { count |= Int(block[i + k]) << (8 * k) }
                    i += extra
                }
                count += 1
                guard i + count <= end, output.count + count <= expected else { throw failure("snappy", "a literal runs past the block") }
                output += block[i..<i + count]
                i += count
            case 1:
                guard i < end else { throw failure("snappy", "a copy is cut") }
                try copy((tag >> 5) << 8 | Int(block[i]), ((tag >> 2) & 0x07) + 4)
                i += 1
            case 2:
                guard i + 2 <= end else { throw failure("snappy", "a copy is cut") }
                try copy(Int(block[i]) | Int(block[i + 1]) << 8, (tag >> 2) + 1)
                i += 2
            default:
                guard i + 4 <= end else { throw failure("snappy", "a copy is cut") }
                try copy(Int(block[i]) | Int(block[i + 1]) << 8 | Int(block[i + 2]) << 16 | Int(block[i + 3]) << 24, (tag >> 2) + 1)
                i += 4
            }
        }
        guard output.count == expected else { throw failure("snappy", "it opened to \(output.count) bytes, not the \(expected) it said") }
        return output
    }

    // MARK: zstd

    private struct InBuffer {
        var src: UnsafeRawPointer?
        var size: Int
        var pos: Int
    }

    private struct OutBuffer {
        var dst: UnsafeMutableRawPointer?
        var size: Int
        var pos: Int
    }

    private typealias Create = @convention(c) () -> OpaquePointer?
    private typealias Free = @convention(c) (OpaquePointer?) -> Int
    /// The buffers as `ZSTD_outBuffer*` and `ZSTD_inBuffer*`: `OutBuffer`'s and `InBuffer`'s layout.
    private typealias Stream = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int
    private typealias IsError = @convention(c) (Int) -> UInt32
    private typealias ErrorName = @convention(c) (Int) -> UnsafePointer<CChar>?

    /// zstd's streaming decoder, as DuckDB's library exports it (its own
    /// namespace, C's calling convention): found once, nil without it.
    private struct Zstd: @unchecked Sendable {
        let create: Create
        let free: Free
        let stream: Stream
        let isError: IsError
        let errorName: ErrorName

        static let shared: Zstd? = {
            let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
            func find<T>(_ name: String, _ type: T.Type) -> T? {
                guard let symbol = dlsym(handle, name) else { return nil }
                return unsafeBitCast(symbol, to: type)
            }
            guard let create = find("_ZN11duckdb_zstd15ZSTD_createDCtxEv", Create.self),
                let free = find("_ZN11duckdb_zstd13ZSTD_freeDCtxEPNS_11ZSTD_DCtx_sE", Free.self),
                let stream = find(
                    "_ZN11duckdb_zstd21ZSTD_decompressStreamEPNS_11ZSTD_DCtx_sEPNS_16ZSTD_outBuffer_sEPNS_15ZSTD_inBuffer_sE", Stream.self),
                let isError = find("_ZN11duckdb_zstd12ZSTD_isErrorEm", IsError.self),
                let errorName = find("_ZN11duckdb_zstd17ZSTD_getErrorNameEm", ErrorName.self)
            else { return nil }
            return Zstd(create: create, free: free, stream: stream, isError: isError, errorName: errorName)
        }()
    }

    /// Whether zstd batches can be opened in this build.
    package static var readsZstd: Bool { Zstd.shared != nil }

    package static func unzstd(_ bytes: [UInt8]) throws -> [UInt8] {
        guard let zstd = Zstd.shared else { throw failure("zstd", "this build has no zstd decoder") }
        guard let context = zstd.create() else { throw failure("zstd", "the decoder didn't start") }
        defer { _ = zstd.free(context) }
        var output: [UInt8] = []
        let chunk = 128 << 10
        var buffer = [UInt8](repeating: 0, count: chunk)
        try bytes.withUnsafeBytes { source in
            var input = InBuffer(src: source.baseAddress, size: source.count, pos: 0)
            while true {
                var produced = 0
                var result = 0
                buffer.withUnsafeMutableBytes { out in
                    var target = OutBuffer(dst: out.baseAddress, size: chunk, pos: 0)
                    result = withUnsafeMutablePointer(to: &target) { target in
                        withUnsafeMutablePointer(to: &input) { input in zstd.stream(context, UnsafeMutableRawPointer(target), UnsafeMutableRawPointer(input)) }
                    }
                    produced = target.pos
                }
                if zstd.isError(result) != 0 {
                    throw failure("zstd", zstd.errorName(result).map { String(cString: $0) } ?? "the stream is damaged")
                }
                output += buffer[0..<produced]
                guard output.count <= limit else { throw failure("zstd", "it opens to more than \(limit >> 20) MB") }
                // Done when the input is used up and nothing more came out.
                if input.pos == input.size, produced < chunk { return }
                if produced == 0, input.pos == input.size { return }
            }
        }
        return output
    }
}
