import Darwin
import Foundation

/// The four environment names the census reads (docs/design/activity/
/// analysis.md, 9.2) — Overterm's three markers and launchd's job label,
/// none a secret — and nothing else. The type holds these four values:
/// no other entry of a process's environment ever becomes a `String`.
package struct ProcessMarkers: Hashable, Sendable {
    /// `OVERTERM_TAB_ID`: the pane it was started in.
    package var tab: String?
    /// `OVERTERM_RUN`: the Overterm run that started it.
    package var run: String?
    /// `OVERTERM_HELPER`: which of Overterm's children it is.
    package var helper: String?
    /// `XPC_SERVICE_NAME`: a launchd job's label ("0" is none).
    package var service: String?

    /// Matched exactly at an entry's start — never an `OVERTERM_` prefix:
    /// `OVERTERM_SSH_SECRET` is a database's password in the tunnel's ssh,
    /// `OVERTERM_MCP_TOKEN` a pane's token. In `subscript(name:)`'s order.
    package static let names = ["OVERTERM_TAB_ID", "OVERTERM_RUN", "OVERTERM_HELPER", "XPC_SERVICE_NAME"]

    /// The value of `names[index]`.
    package subscript(name index: Int) -> String? {
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
    package static let valueLimit = 512

    package var isEmpty: Bool { tab == nil && run == nil && helper == nil && service == nil }
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
package struct ProcessArguments: Hashable, Sendable {
    /// argv masked (`ActivityText.command`); "…cut" ends it when argv ran
    /// past `argumentLimit`.
    package let command: String
    /// An interpreter's or a package runner's label (`ActivityText.label`).
    package let label: String?
    /// argv ran past `argumentLimit`.
    package let isCut: Bool
    /// argv[0] is a title the process wrote over its argv: `command` is
    /// that title, its arguments gone.
    package let isTitle: Bool
    /// The agent argv names (`Agent.of(arguments:)`: argv[0]'s file —
    /// `claude`, `/opt/homebrew/bin/codex` — or the script an interpreter
    /// runs, Gemini CLI's under `node`), taken off the raw words before masking: masked, a long relative
    /// path reads as a base64 blob and the agent would be missed.
    package var agent: Agent? = nil
    /// The session id after argv's first `--resume` or `-r`, hex and dashes
    /// only (`ClaudeSession.isValidID`), taken off the raw words: masked,
    /// the `-r` of `--fork-session -r <id>` goes — a session flag's value
    /// looks secret. Whose it is, a Claude's, its reader decides.
    package var resumes: String? = nil
    /// The markers, when the environment was scanned.
    package let markers: ProcessMarkers?

    /// argv is read this far (7.3).
    package static let argumentLimit = 64 * 1024
    /// What a cut command ends with.
    package static let cutMark = "…cut"
    /// The room a region has past the length the kernel gave: an area that
    /// grows less than this between the two calls is still read whole.
    package static let slack = 4_096

    /// `pid`'s, now; nil when the kernel refuses (another user's: EINVAL)
    /// or it is gone, or the area can't be read whole: larger than
    /// `kern.argmax`, or still growing. `markers`: scan the environment —
    /// never for a `CS_RESTRICT` target (`codeSigning`), whose environment
    /// the kernel leaves out anyway (3.9); unknown flags are scanned.
    package static func read(_ pid: pid_t, kernel: some ActivityKernel, markers: Bool, codeSigning: ActivityCodeSigning?) -> ProcessArguments? {
        read(pid, kernel: kernel, markers: markers && codeSigning?.isRestricted != true, words: true)
    }

    /// `pid`'s markers alone (7.3): the region read and cleared as `read`
    /// reads it, argv walked past in place — never decoded, never masked —
    /// and the environment scanned. What the light level reads of a
    /// process no pane's tree places, to learn whether it carries a tag:
    /// the masking is most of a read's cost (0.7 ms for an Electron
    /// helper's line). Nil when refused or gone, unreadable whole, or a
    /// `CS_RESTRICT` target's, whose environment the kernel leaves out.
    package static func markers(_ pid: pid_t, kernel: some ActivityKernel, codeSigning: ActivityCodeSigning?) -> ProcessMarkers? {
        guard codeSigning?.isRestricted != true else { return nil }
        return read(pid, kernel: kernel, markers: true, words: false)?.markers
    }

    private static func read(_ pid: pid_t, kernel: some ActivityKernel, markers scan: Bool, words: Bool) -> ProcessArguments? {
        read(pid, kernel: kernel) { parse($0, markers: scan, words: words) }
    }

    /// `body` over `pid`'s whole area, read into a region of its own that
    /// is cleared before this returns; nil when the kernel refuses (another
    /// user's: EINVAL) or it is gone, or the area can't be read whole.
    private static func read<T>(_ pid: pid_t, kernel: some ActivityKernel, _ body: (UnsafeRawBufferPointer) -> T?) -> T? {
        guard let length = kernel.argumentsLength(of: pid), length > 0 else { return nil }
        // A region the kernel filled was too small: read once more, at the
        // most it gives (an exec between the calls changed the area).
        let first = min(length + slack, argumentMaximum)
        for size in first < argumentMaximum ? [first, argumentMaximum] : [first] {
            let region = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 8)
            defer { region.deallocate() }
            switch read(pid, kernel: kernel, filling: region, body) {
            case .whole(let found): return found
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
    package static func read(_ pid: pid_t, kernel: some ActivityKernel, markers: Bool, in region: UnsafeMutableRawBufferPointer) -> ProcessArguments? {
        guard case .whole(let arguments) = read(pid, kernel: kernel, filling: region, { parse($0, markers: markers) }) else { return nil }
        return arguments
    }

    /// What one read into a region gave.
    private enum RegionRead<T> {
        /// Less than the region holds: the whole area, parsed — nil when
        /// it isn't `KERN_PROCARGS2`'s layout.
        case whole(T?)
        /// The region came back full: whatever it holds isn't the area's head.
        case full
        /// Refused, or gone.
        case refused
    }

    private static func read<T>(
        _ pid: pid_t, kernel: some ActivityKernel, filling region: UnsafeMutableRawBufferPointer, _ body: (UnsafeRawBufferPointer) -> T?
    ) -> RegionRead<T> {
        defer { clear(region) }
        guard let written = kernel.readArguments(of: pid, into: region), written > 0 else { return .refused }
        guard written < region.count else { return .full }
        return .whole(body(UnsafeRawBufferPointer(rebasing: region.prefix(written))))
    }

    // MARK: A reader's own names

    /// The names a reader may ask of an environment besides the markers
    /// (9.2, 7.8): Terraform's header's three — the workspace a run
    /// selects, its data folder, its AWS profile —, none a secret. A closed
    /// set, so 9.2's promise is the type's, as `ProcessMarkers` keeps the
    /// markers', and not each caller's: a name not here can't be asked for,
    /// and no later reader turns an AWS key or a pane's MCP token into a
    /// `String` by naming it. A new name is a case here, which
    /// `ProcessArgumentsTests` holds to 9.2's rule: not `Secrets.isSecret`,
    /// no `OVERTERM_` name.
    package enum ReaderName: String, CaseIterable, Sendable {
        case terraformWorkspace = "TF_WORKSPACE"
        case terraformDataFolder = "TF_DATA_DIR"
        case awsProfile = "AWS_PROFILE"
    }

    /// What a reader of one of the user's processes takes from one read of
    /// its area (9.2, 9.3) — Terraform's header, its three names: argv's
    /// words as the kernel gave them, handed to `facts` inside the read and
    /// dropped with the region, so only what `facts` makes of them is kept
    /// (a parsed command line, never the words); and the values of `names`
    /// in its environment, in `names`' order, matched exactly at entry
    /// starts as the markers are — no other entry ever becomes a `String`,
    /// and a value longer than `valueLimit` is none. A `CS_RESTRICT`
    /// target's environment is the kernel's to hide (`codeSigning`): its
    /// values nil, unscanned; unknown flags are scanned. Nil when refused or
    /// gone, or the area can't be read whole.
    package static func facts<Facts>(
        of pid: pid_t, kernel: some ActivityKernel, names: [ReaderName], codeSigning: ActivityCodeSigning?, valueLimit: Int = 1_024,
        _ facts: ([String], [String?]) -> Facts
    ) -> Facts? {
        let scan = codeSigning?.isRestricted != true
        let names = names.map(\.rawValue)
        return read(pid, kernel: kernel) { bytes -> Facts? in
            guard let layout = layout(of: bytes) else { return nil }
            var words: [String] = []
            for range in layout.words { words.append(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[range]), as: UTF8.self)) }
            let values = scan ? self.scan(bytes, from: layout.environment, names: names, valueLimit: valueLimit) : names.map { _ in nil }
            let made = facts(words, values)
            words.removeAll()
            return made
        }
    }

    /// The file argv's first word names (`claude` of `/opt/acme/bin/claude
    /// --resume …`), as `Agent.of` reads a command: argv[0] alone decoded,
    /// to its first space — a title's first word —, nothing after it made a
    /// `String` and nothing masked, the masking being most of a read's cost
    /// (7.7: ⌘V asks this inside the key equivalent). A name longer than
    /// `nameLimit` bytes is none. Nil when refused or gone, or unreadable
    /// whole.
    package static func executableName(of pid: pid_t, kernel: some ActivityKernel, nameLimit: Int = 255) -> String? {
        read(pid, kernel: kernel) { bytes -> String? in
            guard let first = layout(of: bytes)?.words.first else { return nil }
            var end = first.lowerBound
            while end < first.upperBound, bytes[end] != UInt8(ascii: " ") { end += 1 }
            var start = end
            while start > first.lowerBound, bytes[start - 1] != UInt8(ascii: "/") { start -= 1 }
            guard start < end, end - start <= nameLimit else { return nil }
            return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
        }
    }

    /// `kern.argmax`: the largest region a read uses — the kernel gives no
    /// more. 1 MB when it can't be read.
    package static let argumentMaximum: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.argmax", &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : 1 << 20
    }()

    /// Every byte of `region` zeroed, in a way the compiler keeps.
    package static func clear(_ region: UnsafeMutableRawBufferPointer) {
        guard let base = region.baseAddress, region.count > 0 else { return }
        _ = memset_s(base, region.count, 0, region.count)
    }

    /// The layout (`argc`; the executable's path, NUL-padded to 8 bytes;
    /// argv's words; the environment's entries; an empty string; launchd's
    /// own strings), read in place. Pure over `bytes`; nil for a buffer
    /// that isn't that. `words` false walks past argv without making a
    /// word of it: `command` is empty, no label, nothing masked.
    package static func parse(_ bytes: UnsafeRawBufferPointer, markers scanEnvironment: Bool, words decode: Bool = true) -> ProcessArguments? {
        guard let layout = layout(of: bytes) else { return nil }
        let markers = scanEnvironment ? scan(bytes, from: layout.environment) : nil
        guard decode else { return ProcessArguments(command: "", label: nil, isCut: layout.isCut, isTitle: layout.isTitle, markers: markers) }
        var words = layout.words.map { String(decoding: UnsafeRawBufferPointer(rebasing: bytes[$0]), as: UTF8.self) }
        let agent = Agent.of(arguments: words)
        let resumes = resumedSession(in: words)
        let masked = Secrets.maskArguments(words)
        words.removeAll()
        let command = ActivityText.command(masked: masked) + (layout.isCut ? (masked.isEmpty ? "" : " ") + cutMark : "")
        let label = ActivityText.label(masked)
        return ProcessArguments(
            command: command, label: label, isCut: layout.isCut, isTitle: layout.isTitle, agent: agent, resumes: resumes, markers: markers)
    }

    /// The word after the first `--resume` or `-r` of `words` — argv's, or
    /// a command line's split at spaces —, when it is a session id
    /// (`ClaudeSession.isValidID`); every session Sessions lists is. Pure.
    package static func resumedSession(in words: [String]) -> String? {
        guard let flag = words.firstIndex(where: { $0 == "--resume" || $0 == "-r" }), flag + 1 < words.count else { return nil }
        let id = words[flag + 1]
        return ClaudeSession.isValidID(id) ? id : nil
    }

    /// Where the layout's parts lie, found in place — no byte of it made a
    /// word yet: argv's words over `argumentLimit` (one, a title; a word
    /// cut there dropped whole: half a password no mask recognises), and
    /// where the environment's first entry starts.
    package struct Layout {
        package var words: [Range<Int>]
        /// argv ran past `argumentLimit`.
        package var isCut: Bool
        package var isTitle: Bool
        /// The environment's first entry: past argv's words and the NULs a
        /// title shorter than the words' area left.
        package var environment: Int
    }

    /// `bytes` read as the layout; nil for a buffer that isn't it.
    package static func layout(of bytes: UnsafeRawBufferPointer) -> Layout? {
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
        var words: [Range<Int>] = []
        var cut = false
        let argumentsEnd = min(bytes.count, position + argumentLimit)
        for _ in 0..<(title ? 1 : argc) {
            guard position < bytes.count else { break }
            let end = index(of: 0, in: bytes, from: position) ?? bytes.count
            if end >= argumentsEnd {
                cut = true
            } else if !cut {
                words.append(position..<end)
            }
            position = end + 1
        }
        // The environment starts at the next entry: past the NULs a title
        // shorter than the words' area left.
        while position < bytes.count, bytes[position] == 0 { position += 1 }
        return Layout(words: words, isCut: cut, isTitle: title, environment: position)
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
    package static func scan(_ bytes: UnsafeRawBufferPointer, from start: Int) -> ProcessMarkers {
        var markers = ProcessMarkers()
        for (index, value) in scan(bytes, from: start, names: ProcessMarkers.names, valueLimit: ProcessMarkers.valueLimit).enumerated() {
            markers[name: index] = value
        }
        return markers
    }

    /// The values of `names` in the environment from `start`, in `names`'
    /// order: each entry compared with them at its start only, exactly
    /// (`NAME=`), and only a match's value copied out — at most
    /// `valueLimit` bytes, a longer one none. Private: the names come from
    /// the closed sets only, the markers' and `ReaderName`'s.
    private static func scan(_ bytes: UnsafeRawBufferPointer, from start: Int, names: [String], valueLimit: Int) -> [String?] {
        var values = [String?](repeating: nil, count: names.count)
        var position = start
        while position < bytes.count, bytes[position] != 0 {
            let end = index(of: 0, in: bytes, from: position) ?? bytes.count
            for (index, name) in names.enumerated() where values[index] == nil {
                let prefix = name.utf8.count
                guard end - position > prefix, bytes[position + prefix] == UInt8(ascii: "="),
                    name.utf8.elementsEqual(UnsafeRawBufferPointer(rebasing: bytes[position..<(position + prefix)]))
                else { continue }
                let value = UnsafeRawBufferPointer(rebasing: bytes[(position + prefix + 1)..<end])
                if value.count <= valueLimit { values[index] = String(decoding: value, as: UTF8.self) }
                break
            }
            position = end + 1
        }
        return values
    }

    /// The first `byte` at or after `start`.
    private static func index(of byte: UInt8, in bytes: UnsafeRawBufferPointer, from start: Int) -> Int? {
        guard start < bytes.count, let base = bytes.baseAddress else { return nil }
        guard let found = memchr(base + start, Int32(byte), bytes.count - start) else { return nil }
        return base.distance(to: UnsafeRawPointer(found))
    }
}
