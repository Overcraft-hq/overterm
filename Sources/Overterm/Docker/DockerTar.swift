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
        enum Kind: Equatable, Sendable { case file, directory, symlink, hardlink, other }

        var name: String
        var kind: Kind
        var size: Int
        var mode: Int
        var modified: Date
        var linkTarget: String
        var data: Data
        /// Its owner, as the header says it — the engine gives what it
        /// extracts this owner (`createTarFile`'s Lchown), so a file saved
        /// back keeps it.
        var uid = 0
        var gid = 0
    }

    static let block = 512
    /// The largest file a ustar header holds: 11 octal digits, 8 GiB less
    /// one byte. A larger one would need GNU's base-256 or a PAX size.
    static let maximumSize = 0o77777777777

    /// One file, as a ustar archive: a header, the contents padded to a
    /// block, two empty blocks. A name past ustar's 100 bytes goes to its
    /// 155-byte prefix (a path's folders); longer than that, nil. Its
    /// owner is root unless said.
    static func archive(name: String, data: Data, mode: Int = 0o644, modified: Date = Date(), uid: Int = 0, gid: Int = 0) -> Data? {
        guard let header = header(name: name, size: data.count, mode: mode, modified: modified, type: "0", uid: uid, gid: gid) else { return nil }
        var out = header
        out.append(data)
        out.append(Data(count: padding(data.count) + 2 * block))
        return out
    }

    /// One header block. Nil for a name ustar can't hold (`split`), or a
    /// size past `maximumSize`: the field would be cut, and the engine
    /// would read another size than the one sent.
    static func header(
        name: String, size: Int, mode: Int, modified: Date, type: Character, uid: Int = 0, gid: Int = 0, link: String = ""
    ) -> Data? {
        guard let (prefix, short) = split(name) else { return nil }
        return block(name: short, prefix: prefix, size: size, mode: mode, modified: modified, type: type, uid: uid, gid: gid, link: link)
    }

    /// A name as ustar holds it: up to 100 bytes as it is, else its
    /// folders in the 155-byte prefix and the rest in the name. Nil when
    /// neither fits.
    static func split(_ name: String) -> (prefix: String, name: String)? {
        guard name.utf8.count > 100 else { return ("", name) }
        guard
            let slash = name.utf8.indices.last(where: { name.utf8[$0] == UInt8(ascii: "/") && name.utf8.distance(from: $0, to: name.utf8.endIndex) <= 101 }),
            name.utf8.distance(from: name.utf8.startIndex, to: slash) <= 155
        else { return nil }
        return (String(name[name.startIndex..<slash]), String(name[name.index(after: slash)...]))
    }

    private static func block(
        name: String, prefix: String, size: Int, mode: Int, modified: Date, type: Character, uid: Int, gid: Int, link: String
    ) -> Data? {
        guard size >= 0, size <= maximumSize else { return nil }
        var header = Data(count: block)
        func put(_ text: String, at offset: Int, length: Int) {
            for (i, byte) in text.utf8.prefix(length).enumerated() { header[offset + i] = byte }
        }
        func octal(_ value: Int, at offset: Int, length: Int) {
            put(String(String(value, radix: 8).suffix(length - 1)).leftPadded(to: length - 1) + "\0", at: offset, length: length)
        }
        put(name, at: 0, length: 100)
        octal(mode, at: 100, length: 8)
        octal(uid, at: 108, length: 8)
        octal(gid, at: 116, length: 8)
        octal(size, at: 124, length: 12)
        // Before 1970, or past what 11 digits hold: the nearest it can say.
        octal(min(max(Int(modified.timeIntervalSince1970), 0), maximumSize), at: 136, length: 12)
        put("        ", at: 148, length: 8)  // checksum, as spaces while summing
        put(String(type), at: 156, length: 1)
        put(link, at: 157, length: 100)
        put("ustar\0", at: 257, length: 6)
        put("00", at: 263, length: 2)
        put(prefix, at: 345, length: 155)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(String(sum, radix: 8)).leftPadded(to: 6) + "\0 ", at: 148, length: 8)
        return header
    }

    /// The zeros that take `size` bytes to the end of their block.
    static func padding(_ size: Int) -> Int { (block - size % block) % block }

    // MARK: Files and folders, sent as they are read

    /// What a drop sends, an item at a time in the order it goes: each
    /// folder before what is in it. Made from the Mac's files
    /// (`Plan.make`), sent by `DockerTarWriter` — read as it is sent, so
    /// nothing is held in memory, and its length is known before.
    struct Plan: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            enum Kind: Equatable, Sendable {
                case file(URL)
                case directory
                /// A link, kept a link: its target as the Mac has it.
                case symlink(String)
            }

            /// Its name in the archive, a folder's ending in `/`:
            /// `site/`, `site/css/app.css`.
            var name: String
            var kind: Kind
            var size = 0
            var mode = 0o644
            var modified = Date(timeIntervalSince1970: 0)
        }

        var items: [Item] = []
        /// What stays on the Mac, by its name in the archive: sockets,
        /// pipes, devices, and links that point above the drop.
        var skipped: [String] = []
        /// The names dropped, as they land in the folder.
        var tops: [String] = []

        /// The archive's bytes, its two end blocks too: said before it is
        /// sent.
        var length: Int { items.reduce(2 * DockerTar.block) { $0 + DockerTar.length(of: $1) } }

        /// The files' bytes.
        var bytes: Int {
            items.reduce(0) { total, item in
                if case .file = item.kind { total + item.size } else { total }
            }
        }

        /// `site`, `index.html and site`, `3 items`.
        var summary: String { Self.summary(tops) }

        static func summary(_ names: [String]) -> String {
            switch names.count {
            case 0: "nothing"
            case 1: names[0]
            case 2: "\(names[0]) and \(names[1])"
            default: "\(names.count) items"
            }
        }
    }

    /// The blocks that come before an item's data: GNU's long name ('L')
    /// when ustar's name and prefix can't hold its name, GNU's long link
    /// ('K') for a target past 100 bytes, then its header — owned by root,
    /// as `docker cp` without `-a` sends it. GNU's rather than PAX's: Go's
    /// archive/tar, which the engine extracts with, reads both, and so does
    /// `Reader`. Nil for a file past `maximumSize`.
    static func headers(for item: Plan.Item) -> Data? {
        let (type, size, mode, link): (Character, Int, Int, String) =
            switch item.kind {
            case .file: ("0", item.size, item.mode, "")
            case .directory: ("5", 0, item.mode, "")
            case .symlink(let target): ("2", 0, 0o777, target)
            }
        var out = Data()
        var parts = split(item.name)
        if parts == nil {
            guard let long = longEntry(item.name, type: "L") else { return nil }
            out += long
            parts = ("", item.name)  // cut to 100 bytes: the long name is the one read
        }
        if link.utf8.count > 100 {
            guard let long = longEntry(link, type: "K") else { return nil }
            out += long
        }
        guard let (prefix, name) = parts,
            let header = block(name: name, prefix: prefix, size: size, mode: mode, modified: item.modified, type: type, uid: 0, gid: 0, link: link)
        else { return nil }
        return out + header
    }

    /// GNU's long name or long link: the text, NUL ended, as the next
    /// entry's.
    private static func longEntry(_ text: String, type: Character) -> Data? {
        let bytes = Data(text.utf8) + Data([0])
        guard
            var out = block(
                name: "././@LongLink", prefix: "", size: bytes.count, mode: 0, modified: Date(timeIntervalSince1970: 0), type: type, uid: 0, gid: 0,
                link: "")
        else { return nil }
        out += bytes
        out += Data(count: padding(bytes.count))
        return out
    }

    /// An item's bytes in the archive: its headers, its data, padded.
    static func length(of item: Plan.Item) -> Int {
        func rounded(_ size: Int) -> Int { size + padding(size) }
        var length = block
        if split(item.name) == nil { length += block + rounded(item.name.utf8.count + 1) }
        switch item.kind {
        case .file: length += rounded(item.size)
        case .symlink(let target) where target.utf8.count > 100: length += block + rounded(target.utf8.count + 1)
        default: break
        }
        return length
    }

    /// Whether a link's target, read from the link's own folder without
    /// touching the disk, climbs above the archive's top: the engine
    /// refuses the whole archive for one (`invalid symlink`). An absolute
    /// target doesn't climb: the engine joins it under the folder.
    static func escapes(_ target: String, from name: String) -> Bool {
        guard !target.hasPrefix("/") else { return false }
        var depth = name.split(separator: "/").dropLast().filter { $0 != "." }.count
        for part in target.split(separator: "/") where part != "." {
            if part == ".." {
                guard depth > 0 else { return true }
                depth -= 1
            } else {
                depth += 1
            }
        }
        return false
    }

    // MARK: Reading

    /// An archive read as it comes, in pieces of any size: each entry's
    /// header, a file's data, then its end. GNU's long names and links,
    /// PAX's `path`, `linkpath` and `size`, and base-256 numbers are read;
    /// xattrs and global headers passed over. It ends at a zero block.
    struct Reader: Sendable {
        struct Header: Equatable, Sendable {
            var name: String
            var kind: Entry.Kind
            var size: Int
            var mode: Int
            var modified: Date
            var linkTarget: String
            var uid = 0
            var gid = 0
        }

        enum Event: Equatable, Sendable {
            case entry(Header)
            /// A file's bytes, in order.
            case data(Data)
            /// After every entry, one with no data too.
            case end
        }

        private enum State: Sendable {
            case header
            /// An entry's data: what is left of it, its padding, and whether
            /// it is handed on (a file's).
            case data(left: Int, padding: Int, handed: Bool)
            /// A meta entry ('L', 'K', 'x', 'g'), read whole.
            case meta(type: UInt8, size: Int)
            case skip(Int)
            case done
        }

        private var state = State.header
        private var carry = Data()
        private var longName: String?
        private var longLink: String?
        private var pax: [String: String] = [:]

        init() {}

        /// The archive's end was read.
        var finished: Bool {
            if case .done = state { true } else { false }
        }

        /// Nothing half read: the end, or between two entries — what an
        /// archive cut there without its end blocks leaves.
        var atBoundary: Bool {
            switch state {
            case .done: true
            case .header: carry.isEmpty && longName == nil && longLink == nil && pax.isEmpty
            default: false
            }
        }

        mutating func feed(_ bytes: Data) -> [Event] {
            let input = carry.isEmpty ? bytes : carry + bytes
            carry = Data()
            var at = input.startIndex
            var events: [Event] = []
            reading: while true {
                switch state {
                case .done:
                    break reading
                case .header:
                    guard input.endIndex - at >= DockerTar.block else { break reading }
                    let block = input[at..<at + DockerTar.block]
                    at += DockerTar.block
                    if block.allSatisfy({ $0 == 0 }) {
                        state = .done
                        break reading
                    }
                    events += header(Data(block))
                case .data(let left, let padding, let handed):
                    guard at < input.endIndex else { break reading }
                    let count = min(left, input.endIndex - at)
                    if handed { events.append(.data(Data(input[at..<at + count]))) }
                    at += count
                    if count == left {
                        events.append(.end)
                        state = padding > 0 ? .skip(padding) : .header
                    } else {
                        state = .data(left: left - count, padding: padding, handed: handed)
                    }
                case .meta(let type, let size):
                    let whole = size + DockerTar.padding(size)
                    guard input.endIndex - at >= whole else { break reading }
                    meta(type, Data(input[at..<at + size]))
                    at += whole
                    state = .header
                case .skip(let count):
                    guard at < input.endIndex else { break reading }
                    let skipped = min(count, input.endIndex - at)
                    at += skipped
                    state = skipped == count ? .header : .skip(count - skipped)
                }
            }
            if at < input.endIndex, !finished { carry = Data(input[at...]) }
            return events
        }

        private mutating func header(_ block: Data) -> [Event] {
            func field(_ start: Int, _ length: Int) -> String {
                String(decoding: block[start..<start + length].prefix { $0 != 0 }, as: UTF8.self)
            }
            func number(_ start: Int, _ length: Int) -> Int {
                let bytes = block[start..<start + length]
                // Base-256, the high bit its mark: big-endian. A negative
                // one (0xff first) reads as 0.
                if let first = bytes.first, first & 0x80 != 0 {
                    guard first != 0xff else { return 0 }
                    var value = Int(first & 0x7f)
                    for byte in bytes.dropFirst() {
                        guard value <= Int.max >> 8 else { return 0 }
                        value = value << 8 | Int(byte)
                    }
                    return value
                }
                return Int(field(start, length).trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8) ?? 0
            }
            let type = block[156]
            var size = number(124, 12)
            switch type {
            case UInt8(ascii: "L"), UInt8(ascii: "K"), UInt8(ascii: "x"), UInt8(ascii: "g"):
                // Past a megabyte it is no name: passed over, as Go caps them.
                if size > 1 << 20 {
                    state = .skip(size + DockerTar.padding(size))
                } else {
                    state = size == 0 ? .header : .meta(type: type, size: size)
                }
                return []
            default:
                break
            }
            if let said = pax["size"].flatMap({ Int($0) }) { size = said }
            let prefix = field(345, 155)
            var name = prefix.isEmpty ? field(0, 100) : prefix + "/" + field(0, 100)
            if let long = longName ?? pax["path"] { name = long }
            let link = longLink ?? pax["linkpath"] ?? field(157, 100)
            longName = nil
            longLink = nil
            pax = [:]
            let kind: Entry.Kind =
                switch type {
                case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): .file
                case UInt8(ascii: "5"): .directory
                case UInt8(ascii: "2"): .symlink
                case UInt8(ascii: "1"): .hardlink
                default: .other
                }
            let header = Header(
                name: name, kind: kind, size: size, mode: number(100, 8), modified: Date(timeIntervalSince1970: TimeInterval(number(136, 12))),
                linkTarget: link, uid: number(108, 8), gid: number(116, 8))
            // As Go reads them: links, devices, folders and pipes have no
            // data, whatever their size says; anything else has its size's.
            let headerOnly = (UInt8(ascii: "1")...UInt8(ascii: "6")).contains(type)
            let follows = headerOnly ? 0 : size
            guard follows > 0 else {
                state = .header
                return [.entry(header), .end]
            }
            state = .data(left: follows, padding: DockerTar.padding(follows), handed: kind == .file)
            return [.entry(header)]
        }

        private mutating func meta(_ type: UInt8, _ data: Data) {
            switch type {
            case UInt8(ascii: "L"): longName = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "K"): longLink = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "x"): pax.merge(DockerTar.paxRecords(data)) { $1 }
            default: break  // 'g': for every entry after; nothing here reads one
            }
        }
    }

    /// Every entry of an archive (a file's, or a folder's), read by
    /// `Reader`: one parser. An entry cut short keeps what came of it.
    static func entries(of archive: Data) -> [Entry] {
        var reader = Reader()
        var entries: [Entry] = []
        var current: Entry?
        for event in reader.feed(archive) {
            switch event {
            case .entry(let header):
                current = Entry(
                    name: header.name, kind: header.kind, size: header.size, mode: header.mode, modified: header.modified,
                    linkTarget: header.linkTarget, data: Data(), uid: header.uid, gid: header.gid)
            case .data(let data):
                current?.data.append(data)
            case .end:
                if let current { entries.append(current) }
                current = nil
            }
        }
        if let current { entries.append(current) }
        return entries
    }

    /// A PAX extended header's `<length> key=value\n` records, by key.
    static func paxRecords(_ data: Data) -> [String: String] {
        var records: [String: String] = [:]
        var at = data.startIndex
        while at < data.endIndex {
            guard let space = data[at...].firstIndex(of: 0x20), let length = Int(String(decoding: data[at..<space], as: UTF8.self)),
                length > space - at, at + length <= data.endIndex
            else { break }
            var record = data[(space + 1)..<(at + length)]
            if record.last == 0x0A { record = record.dropLast() }
            if let equals = record.firstIndex(of: UInt8(ascii: "=")) {
                records[String(decoding: record[..<equals], as: UTF8.self)] = String(decoding: record[(equals + 1)...], as: UTF8.self)
            }
            at += length
        }
        return records
    }

    static func paxField(_ key: String, in data: Data) -> String? { paxRecords(data)[key] }

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
