import Darwin

/// The four environment names the census reads (docs/design/activity/
/// analysis.md, 9.2) — Overterm's three markers and launchd's job label,
/// none a secret — and nothing else. The type holds these four values:
/// no other entry of a process's environment ever becomes a `String`.
struct ProcessMarkers: Hashable, Sendable {
    /// `OVERTERM_TAB_ID`: the pane it was started in.
    var tab: String?
    /// `OVERTERM_RUN`: the Overterm run that started it.
    var run: String?
    /// `OVERTERM_HELPER`: which of Overterm's children it is.
    var helper: String?
    /// `XPC_SERVICE_NAME`: a launchd job's label ("0" is none).
    var service: String?

    /// Matched exactly at an entry's start — never an `OVERTERM_` prefix:
    /// `OVERTERM_SSH_SECRET` is a database's password in the tunnel's ssh,
    /// `OVERTERM_MCP_TOKEN` a pane's token. In `subscript(name:)`'s order.
    static let names = ["OVERTERM_TAB_ID", "OVERTERM_RUN", "OVERTERM_HELPER", "XPC_SERVICE_NAME"]

    /// The value of `names[index]`.
    subscript(name index: Int) -> String? {
        get { [tab, run, helper, service][index] }
        set {
            switch index {
            case 0: tab = newValue
            case 1: run = newValue
            case 2: helper = newValue
            default: service = newValue
            }
        }
    }

    /// A value longer than this is no marker of Overterm's or launchd's.
    static let valueLimit = 512

    var isEmpty: Bool { tab == nil && run == nil && helper == nil && service == nil }
}

/// What `KERN_PROCARGS2` gives the census of one of the user's processes
/// (9.2, 9.3): argv, masked as it is read, and the markers.
///
/// - **One region**: the kernel writes argv and the environment into one
///   manually allocated buffer, never an `Array` or a `String` copy of it,
///   cleared with `memset_s` before it is freed. It is larger than the
///   kernel said the area is (`slack`), so a whole read never fills it: a
///   region the kernel fills holds the area's tail, or zeros, never its
///   head — the area grew (an `exec` between the two calls), or is larger
///   than `kern.argmax` — and is never parsed.
/// - **argv** over its first 64 KB (`kern.argmax` is 1 MB): words beyond
///   it dropped whole and the command said "…cut" — a word cut in the
///   middle could leave half a password a mask no longer recognises. The
///   words are masked (`ActivityText.command`) inside the read, the label
///   taken from the masked ones; the raw words are never kept.
/// - **A title** a process wrote over its argv in place (libuv's
///   `process.title`, setproctitle) is argv[0], alone (`isTitle`): what
///   argc counts after it is padding and the environment's first entries,
///   never decoded.
/// - **The environment** only for a target that isn't `CS_RESTRICT` — the
///   kernel hides those anyway — scanned as bytes in place for the four
///   names of `ProcessMarkers`, at entry starts, after argv's words and
///   any padding a title left.
///
/// A plain synchronous read for the sampler's queue.
struct ProcessArguments: Hashable, Sendable {
    /// argv masked (`ActivityText.command`); "…cut" ends it when argv ran
    /// past `argumentLimit`.
    let command: String
    /// An interpreter's or a package runner's label (`ActivityText.label`).
    let label: String?
    /// argv ran past `argumentLimit`.
    let isCut: Bool
    /// argv[0] is a title the process wrote over its argv: `command` is
    /// that title, its arguments gone.
    let isTitle: Bool
    /// The markers, when the environment was scanned.
    let markers: ProcessMarkers?

    /// argv is read this far (7.3).
    static let argumentLimit = 64 * 1024
    /// What a cut command ends with.
    static let cutMark = "…cut"
    /// The room a region has past the length the kernel gave: an area that
    /// grows less than this between the two calls is still read whole.
    static let slack = 4_096

    /// `pid`'s, now; nil when the kernel refuses (another user's: EINVAL)
    /// or it is gone, or the area can't be read whole: larger than
    /// `kern.argmax`, or still growing. `markers`: scan the environment —
    /// never for a `CS_RESTRICT` target (`codeSigning`), whose environment
    /// the kernel leaves out anyway (3.9); unknown flags are scanned.
    static func read(_ pid: pid_t, kernel: some ActivityKernel, markers: Bool, codeSigning: ActivityCodeSigning?) -> ProcessArguments? {
        guard let length = kernel.argumentsLength(of: pid), length > 0 else { return nil }
        let scan = markers && codeSigning?.isRestricted != true
        // A region the kernel filled was too small: read once more, at the
        // most it gives (an exec between the calls changed the area).
        let first = min(length + slack, argumentMaximum)
        for size in first < argumentMaximum ? [first, argumentMaximum] : [first] {
            let region = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 8)
            defer { region.deallocate() }
            switch read(pid, kernel: kernel, markers: scan, filling: region) {
            case .whole(let arguments): return arguments
            case .full: continue
            case .refused: return nil
            }
        }
        return nil
    }

    /// The read into `region`, which is cleared before this returns,
    /// whatever it found; nil when refused, or when the region came back
    /// full — the kernel fills a region too small for the area with the
    /// area's tail, or zeros, and says nothing.
    static func read(_ pid: pid_t, kernel: some ActivityKernel, markers: Bool, in region: UnsafeMutableRawBufferPointer) -> ProcessArguments? {
        guard case .whole(let arguments) = read(pid, kernel: kernel, markers: markers, filling: region) else { return nil }
        return arguments
    }

    /// What one read into a region gave.
    private enum RegionRead {
        /// Less than the region holds: the whole area, parsed — nil when
        /// it isn't `KERN_PROCARGS2`'s layout.
        case whole(ProcessArguments?)
        /// The region came back full: whatever it holds isn't the area's head.
        case full
        /// Refused, or gone.
        case refused
    }

    private static func read(_ pid: pid_t, kernel: some ActivityKernel, markers: Bool, filling region: UnsafeMutableRawBufferPointer) -> RegionRead {
        defer { clear(region) }
        guard let written = kernel.readArguments(of: pid, into: region), written > 0 else { return .refused }
        guard written < region.count else { return .full }
        return .whole(parse(UnsafeRawBufferPointer(rebasing: region.prefix(written)), markers: markers))
    }

    /// `kern.argmax`: the largest region a read uses — the kernel gives no
    /// more. 1 MB when it can't be read.
    static let argumentMaximum: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.argmax", &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : 1 << 20
    }()

    /// Every byte of `region` zeroed, in a way the compiler keeps.
    static func clear(_ region: UnsafeMutableRawBufferPointer) {
        guard let base = region.baseAddress, region.count > 0 else { return }
        _ = memset_s(base, region.count, 0, region.count)
    }

    /// The layout (`argc`; the executable's path, NUL-padded to 8 bytes;
    /// argv's words; the environment's entries; an empty string; launchd's
    /// own strings), read in place. Pure over `bytes`; nil for a buffer
    /// that isn't that.
    static func parse(_ bytes: UnsafeRawBufferPointer, markers scanEnvironment: Bool) -> ProcessArguments? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes.loadUnaligned(as: Int32.self))
        guard argc >= 0, argc <= bytes.count else { return nil }
        guard let pathEnd = index(of: 0, in: bytes, from: 4) else { return nil }
        // argv[0] starts at the next 8-byte boundary past the path's NUL
        // (relative to the path): skipping every NUL instead would eat an
        // empty argv[0] and take the environment's first entry for argv.
        var position = 4 + (pathEnd - 4 + 1 + 7) / 8 * 8
        if position > bytes.count || (pathEnd..<position).contains(where: { bytes[$0] != 0 }) {
            position = pathEnd
            while position < bytes.count, bytes[position] == 0 { position += 1 }
        }

        // Decided on the bytes, before any word becomes a String: a title
        // leaves the environment where argc counts arguments.
        let title = argc > 1 && isTitle(bytes, at: position, count: argc, path: 4..<pathEnd)
        var words: [String] = []
        var cut = false
        let argumentsEnd = min(bytes.count, position + argumentLimit)
        for _ in 0..<(title ? 1 : argc) {
            guard position < bytes.count else { break }
            let end = index(of: 0, in: bytes, from: position) ?? bytes.count
            if end >= argumentsEnd {
                cut = true
            } else if !cut {
                words.append(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[position..<end]), as: UTF8.self))
            }
            position = end + 1
        }
        let masked = Secrets.maskArguments(words)
        words.removeAll()
        let command = ActivityText.command(masked: masked) + (cut ? (masked.isEmpty ? "" : " ") + cutMark : "")
        let label = ActivityText.label(masked)
        // The environment starts at the next entry: past the NULs a title
        // shorter than the words' area left.
        while position < bytes.count, bytes[position] == 0 { position += 1 }
        let markers = scanEnvironment ? scan(bytes, from: position) : nil
        return ProcessArguments(command: command, label: label, isCut: cut, isTitle: title, markers: markers)
    }

    /// Whether argv[0], at `start`, is a title written over argv's words in
    /// place — libuv's `process.title`, setproctitle: the title, then NULs
    /// to the end of the words' area, or one NUL when it filled it. Then
    /// what argc counts past argv[0] is that padding and the environment's
    /// first entries. Such an argv[0] doesn't name the executable at
    /// `path`, and the `count - 1` words after it are only empty or
    /// `NAME=value`; an argv[0] that names it, or any other word, is argv.
    private static func isTitle(_ bytes: UnsafeRawBufferPointer, at start: Int, count: Int, path: Range<Int>) -> Bool {
        guard start < bytes.count else { return false }
        let firstEnd = index(of: 0, in: bytes, from: start) ?? bytes.count
        guard !namesExecutable(bytes, start..<firstEnd, path: path) else { return false }
        var position = firstEnd + 1
        for _ in 1..<count {
            guard position < bytes.count else { break }
            let end = index(of: 0, in: bytes, from: position) ?? bytes.count
            guard end == position || isEnvironmentEntry(bytes, position..<end) else { return false }
            position = end + 1
        }
        return true
    }

    /// Whether `word` names the executable at `path`: the path, a path or
    /// a name ending in its file's name (`node`, `/usr/local/bin/node`), or
    /// a login shell's `-zsh`. An empty path names nothing to compare: argv
    /// stands.
    private static func namesExecutable(_ bytes: UnsafeRawBufferPointer, _ word: Range<Int>, path: Range<Int>) -> Bool {
        let slash = UInt8(ascii: "/")
        func name(_ range: Range<Int>) -> Range<Int> {
            var start = range.upperBound
            while start > range.lowerBound, bytes[start - 1] != slash { start -= 1 }
            return start..<range.upperBound
        }
        func same(_ one: Range<Int>, _ other: Range<Int>) -> Bool {
            one.count == other.count && zip(one, other).allSatisfy { bytes[$0] == bytes[$1] }
        }
        let executable = name(path)
        guard !executable.isEmpty else { return true }
        if same(name(word), executable) { return true }
        return word.count == executable.count + 1 && bytes[word.lowerBound] == UInt8(ascii: "-")
            && same((word.lowerBound + 1)..<word.upperBound, executable)
    }

    /// `NAME=value`, as an environment entry is: a name before an `=`, with
    /// no space or `/` in it and no `-` before it.
    private static func isEnvironmentEntry(_ bytes: UnsafeRawBufferPointer, _ word: Range<Int>) -> Bool {
        guard let first = word.first, bytes[first] != UInt8(ascii: "-") else { return false }
        for index in word {
            switch bytes[index] {
            case UInt8(ascii: "="): return index > first
            case UInt8(ascii: "/"), UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"): return false
            default: continue
            }
        }
        return false
    }

    /// The environment from `start` to the empty string that ends it, in
    /// place: an entry is compared with the four names at its start only,
    /// and only a match's value is copied out.
    static func scan(_ bytes: UnsafeRawBufferPointer, from start: Int) -> ProcessMarkers {
        var markers = ProcessMarkers()
        var position = start
        while position < bytes.count, bytes[position] != 0 {
            let end = index(of: 0, in: bytes, from: position) ?? bytes.count
            for (index, name) in ProcessMarkers.names.enumerated() where markers[name: index] == nil {
                let prefix = name.utf8.count
                guard end - position > prefix, bytes[position + prefix] == UInt8(ascii: "="),
                    name.utf8.elementsEqual(UnsafeRawBufferPointer(rebasing: bytes[position..<(position + prefix)]))
                else { continue }
                let value = UnsafeRawBufferPointer(rebasing: bytes[(position + prefix + 1)..<end])
                if value.count <= ProcessMarkers.valueLimit { markers[name: index] = String(decoding: value, as: UTF8.self) }
                break
            }
            position = end + 1
        }
        return markers
    }

    /// The first `byte` at or after `start`.
    private static func index(of byte: UInt8, in bytes: UnsafeRawBufferPointer, from start: Int) -> Int? {
        guard start < bytes.count, let base = bytes.baseAddress else { return nil }
        guard let found = memchr(base + start, Int32(byte), bytes.count - start) else { return nil }
        return base.distance(to: UnsafeRawPointer(found))
    }
}
