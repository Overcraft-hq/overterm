import Foundation

/// The tar the engine's `archive` endpoint speaks, as little of it as a
/// file browser needs. Pure.
///
/// Written by hand rather than by the system's `tar`: macOS's adds each
/// file's extended attributes (`com.apple.provenance`) as PAX headers, and
/// the engine, failing to set them on Linux, answers 500 having written the
/// file (the spike). A plain ustar entry has nothing for it to fail on.
enum DockerTar {
    struct Entry: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case file, directory, symlink, other }

        var name: String
        var kind: Kind
        var size: Int
        var mode: Int
        var modified: Date
        var linkTarget: String
        var data: Data
        /// Its owner, as the header says it — the engine gives what it
        /// extracts this owner (`createTarFile`'s Lchown), so a file saved
        /// back keeps it. A base-256 id (past 2097151) reads as 0.
        var uid = 0
        var gid = 0
    }

    static let block = 512

    /// One file, as a ustar archive: a header, the contents padded to a
    /// block, two empty blocks. A name past ustar's 100 bytes goes to its
    /// 155-byte prefix (a path's folders); longer than that, nil. Its
    /// owner is root unless said.
    static func archive(name: String, data: Data, mode: Int = 0o644, modified: Date = Date(), uid: Int = 0, gid: Int = 0) -> Data? {
        guard let header = header(name: name, size: data.count, mode: mode, modified: modified, type: "0", uid: uid, gid: gid) else { return nil }
        var out = header
        out.append(data)
        let padding = (block - data.count % block) % block
        out.append(Data(count: padding + 2 * block))
        return out
    }

    static func header(name: String, size: Int, mode: Int, modified: Date, type: Character, uid: Int = 0, gid: Int = 0) -> Data? {
        var (prefix, short) = ("", name)
        if name.utf8.count > 100 {
            guard let slash = name.utf8.indices.last(where: { name.utf8[$0] == UInt8(ascii: "/") && name.utf8.distance(from: $0, to: name.utf8.endIndex) <= 101 }),
                name.utf8.distance(from: name.utf8.startIndex, to: slash) <= 155
            else { return nil }
            prefix = String(name[name.startIndex..<slash])
            short = String(name[name.index(after: slash)...])
        }
        var header = Data(count: block)
        func put(_ text: String, at offset: Int, length: Int) {
            for (i, byte) in text.utf8.prefix(length).enumerated() { header[offset + i] = byte }
        }
        func octal(_ value: Int, at offset: Int, length: Int) {
            put(String(String(value, radix: 8).suffix(length - 1)).leftPadded(to: length - 1) + "\0", at: offset, length: length)
        }
        put(short, at: 0, length: 100)
        octal(mode, at: 100, length: 8)
        octal(uid, at: 108, length: 8)
        octal(gid, at: 116, length: 8)
        octal(size, at: 124, length: 12)
        octal(Int(modified.timeIntervalSince1970), at: 136, length: 12)
        put("        ", at: 148, length: 8)  // checksum, as spaces while summing
        put(String(type), at: 156, length: 1)
        put("ustar\0", at: 257, length: 6)
        put("00", at: 263, length: 2)
        put(prefix, at: 345, length: 155)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(String(sum, radix: 8)).leftPadded(to: 6) + "\0 ", at: 148, length: 8)
        return header
    }

    /// Every entry of an archive (a file's, or a folder's listing).
    static func entries(of archive: Data) -> [Entry] {
        var entries: [Entry] = []
        var offset = archive.startIndex
        var longName: String?
        var paxPath: String?
        while archive.endIndex - offset >= block {
            let header = archive[offset..<offset + block]
            if header.allSatisfy({ $0 == 0 }) { break }
            func field(_ start: Int, _ length: Int) -> String {
                let bytes = header[header.startIndex + start..<header.startIndex + start + length].prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            func number(_ start: Int, _ length: Int) -> Int {
                Int(field(start, length).trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8) ?? 0
            }
            let size = number(124, 12)
            let type = field(156, 1)
            let dataStart = offset + block
            let dataEnd = min(dataStart + size, archive.endIndex)
            let data = Data(archive[dataStart..<dataEnd])
            offset = dataStart + (size + block - 1) / block * block
            switch type {
            case "L":  // GNU long name: the next entry's name.
                longName = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                continue
            case "x":  // PAX: its `path=` is the next entry's name.
                paxPath = paxField("path", in: data)
                continue
            case "g":
                continue
            default: break
            }
            let prefix = field(345, 155)
            var name = prefix.isEmpty ? field(0, 100) : prefix + "/" + field(0, 100)
            if let long = longName ?? paxPath { name = long }
            longName = nil
            paxPath = nil
            let kind: Entry.Kind =
                switch type {
                case "0", "", "7": .file
                case "5": .directory
                case "2": .symlink
                default: .other
                }
            entries.append(
                Entry(
                    name: name, kind: kind, size: size, mode: number(100, 8), modified: Date(timeIntervalSince1970: TimeInterval(number(136, 12))),
                    linkTarget: field(157, 100), data: kind == .file ? data : Data(), uid: number(108, 8), gid: number(116, 8)))
        }
        return entries
    }

    /// A PAX extended header's `<length> key=value\n` records.
    static func paxField(_ key: String, in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for record in text.split(separator: "\n") {
            guard let space = record.firstIndex(of: " ") else { continue }
            let pair = record[record.index(after: space)...]
            if pair.hasPrefix(key + "=") { return String(pair.dropFirst(key.count + 1)) }
        }
        return nil
    }

    /// What `X-Docker-Container-Path-Stat` says about a path: base64 JSON.
    struct PathStat: Codable, Equatable, Sendable {
        var name: String
        var size: Int
        /// Go's FileMode: the permission bits, and a high bit for a folder.
        var mode: UInt32
        var mtime: String
        var linkTarget: String

        var isDirectory: Bool { mode & (1 << 31) != 0 }
        var isSymlink: Bool { mode & (1 << 27) != 0 }
    }

    static func pathStat(_ header: String) -> PathStat? {
        guard let data = Data(base64Encoded: header) else { return nil }
        return try? JSONDecoder().decode(PathStat.self, from: data)
    }
}

extension String {
    fileprivate func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
