import Foundation

/// A log line as the engine sends it: which stream it came on and its
/// text (a timestamp first, when asked for).
struct DockerLogChunk: Equatable, Sendable {
    enum Stream: UInt8, Sendable {
        case stdin = 0, stdout = 1, stderr = 2
    }

    var stream: Stream
    var text: String
}

/// Docker's log stream for a container without a TTY: frames of an 8-byte
/// header — the stream (0, 1, 2), three zeros, the length big-endian — then
/// that many bytes. A container with a TTY sends its bytes plain. Fed in
/// whatever pieces the socket gives; a frame cut in two waits for the rest.
/// Pure.
struct DockerLogDemuxer: Sendable {
    /// False for a TTY's plain bytes (ContainerDetail.Config.Tty).
    let framed: Bool
    private var pending = Data()

    init(framed: Bool) {
        self.framed = framed
    }

    mutating func feed(_ data: Data) -> [DockerLogChunk] {
        guard framed else {
            // Plain bytes come in whatever pieces the socket reads: up to the
            // last newline out, decoded whole, the rest kept. Each piece as
            // its own text cut lines in two (the half without a timestamp
            // then dropped as already shown) and a character in two.
            pending.append(data)
            guard let newline = pending.lastIndex(of: 0x0A) else { return [] }
            let text = String(decoding: pending[pending.startIndex...newline], as: UTF8.self)
            pending = Data(pending[pending.index(after: newline)...])
            return [DockerLogChunk(stream: .stdout, text: text)]
        }
        pending.append(data)
        var chunks: [DockerLogChunk] = []
        var offset = pending.startIndex
        while pending.endIndex - offset >= 8 {
            let header = pending[offset..<offset + 8]
            let kind = header[header.startIndex]
            let length = header.dropFirst(4).reduce(0) { $0 << 8 | Int($1) }
            guard pending.endIndex - offset - 8 >= length else { break }
            let body = pending[offset + 8..<offset + 8 + length]
            chunks.append(DockerLogChunk(stream: DockerLogChunk.Stream(rawValue: kind) ?? .stdout, text: String(decoding: body, as: UTF8.self)))
            offset += 8 + length
        }
        pending = Data(pending[offset...])
        return chunks
    }

    /// What a TTY's stream ended with after its last newline; a frame cut
    /// short is no line.
    mutating func flush() -> [DockerLogChunk] {
        defer { pending = Data() }
        guard !framed, !pending.isEmpty else { return [] }
        return [DockerLogChunk(stream: .stdout, text: String(decoding: pending, as: UTF8.self))]
    }
}

/// Newline-delimited JSON (events, stats, a pull's progress), fed in
/// pieces: whole lines out, the last half line kept. Pure.
struct DockerLineSplitter: Sendable {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }

    /// The half line left at the end, if any — emptied: what a stream that
    /// ended without a last newline still said.
    mutating func finish() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

extension DockerLogChunk.Stream {
    /// The line's stream: stdin's (never sent in a log) read as stdout's.
    var log: LogLine.Stream { self == .stderr ? .stderr : .stdout }
}

extension LogLine {
    /// One chunk may hold several lines (and the engine's timestamp starts
    /// each one). Split on any newline: `\r\n` is one Character, which a
    /// split on `\n` leaves whole.
    static func lines(of chunk: DockerLogChunk, timestamps: Bool, source: String? = nil) -> [LogLine] {
        chunk.text.split(whereSeparator: \.isNewline).map {
            parse(String($0), stream: chunk.stream.log, timestamps: timestamps, source: source)
        }
    }
}
