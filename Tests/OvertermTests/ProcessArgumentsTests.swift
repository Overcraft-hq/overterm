import Darwin
import XCTest

@testable import Overterm

/// `KERN_PROCARGS2` as the census reads it (docs/design/activity/analysis.md,
/// 9.2, 9.3): argv masked at the read over its first 64 KB, the environment
/// scanned in place for four names, the region cleared.
final class ProcessArgumentsTests: XCTestCase {
    private let secrets = ["SENTINEL-AWS-9f2c", "SENTINEL-MCP-41ab", "SENTINEL-SSH-77d0", "SENTINEL-ARGV-c3e1", "SENTINEL-NOTE-5b6a"]

    private var bytes: [UInt8] {
        FakeActivityKernel.arguments(
            executable: "/usr/local/bin/acme-server",
            ["acme-server", "--token=SENTINEL-ARGV-c3e1", "OVERTERM_TAB_ID=in-an-argv-word"],
            environment: [
                "AWS_SECRET_ACCESS_KEY=SENTINEL-AWS-9f2c", "OVERTERM_MCP_TOKEN=SENTINEL-MCP-41ab", "OVERTERM_SSH_SECRET=SENTINEL-SSH-77d0",
                "ACME_NOTE=OVERTERM_TAB_ID=SENTINEL-NOTE-5b6a", "OVERTERM_TAB_IDX=not-the-tab", "OVERTERM_TAB_ID=tab-1",
                "OVERTERM_RUN=release.4242.1700000000000000", "OVERTERM_HELPER=kubectl-proxy", "XPC_SERVICE_NAME=homebrew.mxcl.postgresql@16",
            ])
    }

    /// Every string a value holds, however deep.
    private func strings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        return Mirror(reflecting: value).children.flatMap { strings(in: $0.value) }
    }

    private func parse(_ bytes: [UInt8], markers: Bool = true) -> ProcessArguments? {
        bytes.withUnsafeBytes { ProcessArguments.parse($0, markers: markers) }
    }

    func testOnlyTheFourNamesAreReadAndArgvIsMasked() throws {
        let read = try XCTUnwrap(parse(bytes))
        XCTAssertEqual(read.command, "acme-server --token=•••••• OVERTERM_TAB_ID=in-an-argv-word")
        let markers = try XCTUnwrap(read.markers)
        XCTAssertEqual(markers.tab, "tab-1", "at an entry's start, exactly: not in argv, not in a value, not OVERTERM_TAB_IDX")
        XCTAssertEqual(markers.run, "release.4242.1700000000000000")
        XCTAssertEqual(markers.helper, "kubectl-proxy")
        XCTAssertEqual(markers.service, "homebrew.mxcl.postgresql@16")
        for string in strings(in: read) {
            for secret in secrets { XCTAssertFalse(string.contains(secret), "a secret in the read's \(string.count)-character string") }
        }
        XCTAssertNil(try XCTUnwrap(parse(bytes, markers: false)).markers, "not asked, not scanned")
    }

    /// The result types hold the four values and the masked command —
    /// nothing a later field could carry an environment entry in.
    func testTheTypesHoldNothingElse() {
        XCTAssertEqual(Mirror(reflecting: ProcessMarkers()).children.map(\.label), ["tab", "run", "helper", "service"])
        let read = ProcessArguments(command: "", label: nil, isCut: false, isTitle: false, markers: nil)
        XCTAssertEqual(Mirror(reflecting: read).children.map(\.label), ["command", "label", "isCut", "isTitle", "markers"])
        XCTAssertEqual(ProcessMarkers.names, ["OVERTERM_TAB_ID", "OVERTERM_RUN", "OVERTERM_HELPER", "XPC_SERVICE_NAME"])
    }

    /// A region too small for the area comes back full from the kernel —
    /// the area's tail, or zeros, never its head, and no error — so a full
    /// region is never parsed: its words would be environment entries and
    /// launchd's strings.
    func testAFullRegionIsNeverParsed() {
        let kernel = FakeActivityKernel()
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 4242, start: 1, parent: 1))
        process.arguments = bytes
        kernel.add(process)
        for size in [bytes.count, bytes.count - 1, bytes.count / 2, 64] {
            let region = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 8)
            defer { region.deallocate() }
            XCTAssertNil(ProcessArguments.read(4242, kernel: kernel, markers: true, in: region), "a \(size)-byte region")
            XCTAssertTrue(region.allSatisfy { $0 == 0 }, "cleared")
        }
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count + 1, alignment: 8)
        defer { region.deallocate() }
        XCTAssertEqual(ProcessArguments.read(4242, kernel: kernel, markers: true, in: region)?.markers?.tab, "tab-1", "room left: whole")
    }

    /// An `exec` between the size query and the read — `sh -c 'exec …'`,
    /// a shim — keeps the identity and changes the area. Grown past the
    /// room a region has, it is read once more at `kern.argmax` and parsed
    /// whole; never from its tail.
    func testAnAreaThatGrewIsReadAgainWhole() throws {
        let kernel = FakeActivityKernel()
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 4242, start: 1, parent: 1))
        process.arguments = FakeActivityKernel.arguments(executable: "/bin/sh", ["sh", "-c", "exec acme-server"], environment: ["OVERTERM_TAB_ID=tab-sh"])
        let long = (0..<400).map { "--acme-option-\($0)" }
        process.argumentsAfterExec = FakeActivityKernel.arguments(
            executable: "/usr/local/bin/acme-server", ["acme-server"] + long,
            environment: ["ACME_NOTE=SENTINEL-GREW-71c0", "OVERTERM_TAB_ID=tab-grown"] + (0..<200).map { "ACME_\($0)=SENTINEL-GREW-\($0)" })
        kernel.add(process)
        XCTAssertGreaterThan(try XCTUnwrap(process.argumentsAfterExec).count, try XCTUnwrap(process.arguments).count + ProcessArguments.slack)
        let read = try XCTUnwrap(ProcessArguments.read(4242, kernel: kernel, markers: true, codeSigning: nil))
        XCTAssertEqual(read.command, (["acme-server"] + long).joined(separator: " "))
        XCTAssertEqual(read.markers?.tab, "tab-grown")
        XCTAssertFalse(read.isTitle)
        for string in strings(in: read) { XCTAssertFalse(string.contains("SENTINEL"), "an environment entry in the read") }
        XCTAssertEqual(kernel.count("arguments"), 2, "the full region, then kern.argmax")

        // Grown within the room: one read.
        kernel.resetCounts()
        kernel.update(4242) {
            $0.argumentsAfterExec = FakeActivityKernel.arguments(
                executable: "/usr/local/bin/acme-server", ["acme-server", "--port", "8080"], environment: ["OVERTERM_TAB_ID=tab-small"])
        }
        XCTAssertEqual(ProcessArguments.read(4242, kernel: kernel, markers: true, codeSigning: nil)?.command, "acme-server --port 8080")
        XCTAssertEqual(kernel.count("arguments"), 1)
    }

    /// An area past `kern.argmax` can't be read whole: refused, every
    /// time, never parsed from its tail.
    func testAnAreaPastTheMaximumIsRefused() throws {
        let kernel = FakeActivityKernel()
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 4242, start: 1, parent: 1))
        let entry = "ACME_FILL=SENTINEL-" + String(repeating: "x", count: 4_000)
        process.arguments = FakeActivityKernel.arguments(
            executable: "/usr/local/bin/acme", ["acme"], environment: Array(repeating: entry, count: ProcessArguments.argumentMaximum / 4_000 + 2))
        kernel.add(process)
        XCTAssertGreaterThan(try XCTUnwrap(process.arguments).count, ProcessArguments.argumentMaximum)
        XCTAssertNil(ProcessArguments.read(4242, kernel: kernel, markers: true, codeSigning: nil))
        XCTAssertEqual(kernel.count("arguments"), 1, "kern.argmax at once: no second read")

        // Grown past it between the calls: the second read is full too.
        kernel.resetCounts()
        kernel.update(4242) {
            $0.argumentsAfterExec = $0.arguments
            $0.arguments = FakeActivityKernel.arguments(executable: "/bin/sh", ["sh"])
        }
        XCTAssertNil(ProcessArguments.read(4242, kernel: kernel, markers: true, codeSigning: nil))
        XCTAssertEqual(kernel.count("arguments"), 2)
    }

    /// A title a process wrote over its argv in place — libuv's
    /// `process.title`, setproctitle — fills the words' area: when it
    /// filled it, one NUL and then the environment, which argc would count
    /// as arguments; when shorter, NULs to the area's end. Either way
    /// argv[0] alone is read, and the environment from after the padding.
    func testATitleWrittenOverArgvKeepsTheEnvironmentOut() throws {
        let environment = [
            "ACME_NOTE=SENTINEL-TITLE-1d", "AWS_SECRET_ACCESS_KEY=SENTINEL-TITLE-2e", "OVERTERM_TAB_ID=tab-titled", "ACME_LAST=SENTINEL-TITLE-3f",
        ]
        let cases: [(words: [String], title: String, command: String)] = [
            // Longer than the area: cut to it, one NUL, the environment.
            (["node", "-e", "x"], String(repeating: "t", count: 300), String(repeating: "t", count: 9)),
            // Shorter: NULs to the area's end.
            (["node", "/Users/acme/dev/globex/node_modules/npm/bin/npm-cli.js", "run", "dev"], "npm run dev", "npm run dev"),
            // Shorter, but fewer NULs left than argc's words: the last two would be entries.
            (["n", "a", "b", "c", "d"], "acme-wor", "acme-wor"),
        ]
        for (words, title, command) in cases {
            let bytes = FakeActivityKernel.arguments(executable: "/usr/local/bin/node", words, environment: environment, title: title)
            let read = try XCTUnwrap(parse(bytes), title)
            XCTAssertTrue(read.isTitle, title)
            XCTAssertEqual(read.command, command)
            XCTAssertEqual(read.markers?.tab, "tab-titled", "the environment from its first entry: \(command)")
            for string in strings(in: read) { XCTAssertFalse(string.contains("SENTINEL"), "an environment entry in \(command)'s read") }
        }
        // A title naming itself as the program would: not one.
        let named = FakeActivityKernel.arguments(executable: "/usr/local/bin/node", ["node", "a"], environment: environment, title: "node")
        XCTAssertEqual(try XCTUnwrap(parse(named)).markers?.tab, "tab-titled", "found past the padding")
    }

    /// argv[0] that names its executable is argv, whatever follows; one
    /// that doesn't, followed by arguments, too.
    func testArgvIsNoTitle() throws {
        let cases: [(executable: String, words: [String])] = [
            ("/usr/bin/make", ["make", "CC=clang", "CFLAGS=-O2"]),
            ("/usr/bin/env", ["/usr/bin/env", "ACME_MODE=dev"]),
            ("/bin/zsh", ["-zsh", ""]),
            ("/opt/acme/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python", ["python3.12", "manage.py", "runserver"]),
            ("/opt/acme/bin/acme-real", ["acme", "", "--flag"]),
        ]
        for (executable, words) in cases {
            let read = try XCTUnwrap(parse(FakeActivityKernel.arguments(executable: executable, words, environment: ["OVERTERM_TAB_ID=tab-plain"])))
            XCTAssertFalse(read.isTitle, words.joined(separator: " "))
            XCTAssertEqual(read.command, words.joined(separator: " "))
            XCTAssertEqual(read.markers?.tab, "tab-plain")
        }
    }

    /// The region the kernel wrote into is zeroed before the read returns —
    /// a refused read's too.
    func testTheRegionIsCleared() throws {
        let kernel = FakeActivityKernel()
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 4242, start: 1, parent: 1))
        process.arguments = bytes
        kernel.add(process)
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: 4_096, alignment: 8)
        defer { region.deallocate() }
        region.initializeMemory(as: UInt8.self, repeating: 0xAA)
        let read = ProcessArguments.read(4242, kernel: kernel, markers: true, in: region)
        XCTAssertEqual(read?.markers?.tab, "tab-1")
        XCTAssertTrue(region.allSatisfy { $0 == 0 }, "every byte cleared")
        region.initializeMemory(as: UInt8.self, repeating: 0xAA)
        XCTAssertNil(ProcessArguments.read(9999, kernel: kernel, markers: true, in: region))
        XCTAssertTrue(region.allSatisfy { $0 == 0 }, "cleared after a refused read too")
    }

    /// A `CS_RESTRICT` target's environment is never scanned; unknown flags
    /// are (the kernel hides a restricted one's anyway).
    func testARestrictedTargetIsNotScanned() {
        let kernel = FakeActivityKernel()
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 4242, start: 1, parent: 1))
        process.arguments = bytes
        kernel.add(process)
        let restricted = ActivityCodeSigning(flags: ActivityCodeSigning.restrict | ActivityCodeSigning.platformBinary)
        XCTAssertNil(ProcessArguments.read(4242, kernel: kernel, markers: true, codeSigning: restricted)?.markers)
        XCTAssertEqual(ProcessArguments.read(4242, kernel: kernel, markers: true, codeSigning: ActivityCodeSigning(flags: 1))?.markers?.tab, "tab-1")
        XCTAssertEqual(ProcessArguments.read(4242, kernel: kernel, markers: true, codeSigning: nil)?.markers?.tab, "tab-1")
        XCTAssertNotNil(ProcessArguments.read(4242, kernel: kernel, markers: true, codeSigning: restricted)?.command, "argv is still read")
    }

    /// The markers alone (7.3), what the light level reads of a process no
    /// tree places: argv walked past, never a word of it made — nothing
    /// masked, no string of it at all — the environment found past a
    /// title's padding too, and a `CS_RESTRICT` target not read at all.
    func testTheMarkersAloneMakeNoWord() throws {
        let read = try XCTUnwrap(bytes.withUnsafeBytes { ProcessArguments.parse($0, markers: true, words: false) })
        XCTAssertEqual(read.command, "")
        XCTAssertNil(read.label)
        XCTAssertEqual(read.markers?.tab, "tab-1")
        XCTAssertEqual(read.markers?.service, "homebrew.mxcl.postgresql@16")
        for string in strings(in: read) {
            for secret in secrets { XCTAssertFalse(string.contains(secret), "a secret in the read's \(string.count)-character string") }
        }
        let titled = FakeActivityKernel.arguments(
            executable: "/opt/acme/bin/node", ["node", "acme-a", "acme-b"], environment: ["OVERTERM_TAB_ID=tab-titled"], title: "acme")
        XCTAssertEqual(titled.withUnsafeBytes { ProcessArguments.parse($0, markers: true, words: false) }?.markers?.tab, "tab-titled")

        let kernel = FakeActivityKernel()
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 4242, start: 1, parent: 1))
        process.arguments = bytes
        kernel.add(process)
        XCTAssertEqual(ProcessArguments.markers(4242, kernel: kernel, codeSigning: nil)?.tab, "tab-1")
        XCTAssertEqual(kernel.count("arguments"), 1)
        let restricted = ActivityCodeSigning(flags: ActivityCodeSigning.restrict)
        XCTAssertNil(ProcessArguments.markers(4242, kernel: kernel, codeSigning: restricted))
        XCTAssertEqual(kernel.count("arguments"), 1, "the kernel hides it: not read")
        XCTAssertNil(ProcessArguments.markers(9999, kernel: kernel, codeSigning: nil), "gone")
    }

    /// argv over its first 64 KB: the words past it dropped whole — a word
    /// cut in the middle could leave half a password a mask misses — and
    /// the environment still found after them.
    func testArgvIsReadOverItsFirst64KB() throws {
        var words = ["acme-linker"]
        var size = 12
        while size < ProcessArguments.argumentLimit - 40 {
            let word = "obj/" + String(repeating: "x", count: 40) + "-\(words.count).o"
            words.append(word)
            size += word.utf8.count + 1
        }
        // Straddles the limit: whole, it would be masked; cut, it wouldn't.
        words.append("postgres://acme:SENTINEL-CROSS-1f@db.acme.test/shop")
        words += ["--password", "SENTINEL-LATE-2e"]
        let read = try XCTUnwrap(
            parse(FakeActivityKernel.arguments(executable: "/usr/bin/ld", words, environment: ["OVERTERM_TAB_ID=tab-after-a-long-argv"])))
        XCTAssertTrue(read.isCut)
        XCTAssertTrue(read.command.hasSuffix(ProcessArguments.cutMark))
        XCTAssertFalse(read.command.contains("SENTINEL"))
        XCTAssertFalse(read.command.contains("postgres://acme:"), "the straddling word is dropped whole")
        XCTAssertLessThanOrEqual(read.command.utf8.count, ProcessArguments.argumentLimit + 16)
        XCTAssertEqual(read.markers?.tab, "tab-after-a-long-argv")
    }

    /// An empty argv[0] isn't taken for the path's padding: skipping every
    /// NUL there would read the environment's first entry as argv.
    func testAnEmptyFirstWordKeepsTheEnvironmentOutOfArgv() throws {
        let bytes = FakeActivityKernel.arguments(
            executable: "/usr/local/bin/acme", ["", "--flag"], environment: ["ACME_VALUE=SENTINEL-EMPTY-0a", "OVERTERM_TAB_ID=tab-2"])
        let read = try XCTUnwrap(parse(bytes))
        XCTAssertEqual(read.command, " --flag")
        XCTAssertEqual(read.markers?.tab, "tab-2")
        for path in ["/a", "/acme/b", "/acme/bin/c", "/acme/globex/initech/tool"] {
            let read = try XCTUnwrap(parse(FakeActivityKernel.arguments(executable: path, ["tool", "x"], environment: ["OVERTERM_RUN=r"])))
            XCTAssertEqual(read.command, "tool x", path)
            XCTAssertEqual(read.markers?.run, "r", path)
        }
    }

    func testWhatIsntTheLayoutIsRefused() {
        XCTAssertNil(parse([1, 0, 0]))
        XCTAssertNil(parse([0xFF, 0xFF, 0xFF, 0x7F, 0x2F, 0x61]), "argc past the buffer")
        XCTAssertNil(parse([1, 0, 0, 0, 0x2F, 0x61, 0x62]), "no NUL after the path")
        XCTAssertEqual(parse(FakeActivityKernel.arguments(executable: "/a", []))?.command, "")
    }

    /// A real child of the test's (10.2): a sentinel planted in its
    /// environment never appears in any string the read makes, its tag is
    /// found, its argv's secret masked. python3 is no `CS_RESTRICT` binary:
    /// the kernel gives its environment.
    func testARealChildsEnvironmentGivesItsTagAndNothingElse() throws {
        let sentinel = "SENTINEL-\(UUID().uuidString)"
        let tab = "acme-tab-\(UUID().uuidString)"
        var environment = TestChild.cleanEnvironment
        environment["AWS_SECRET_ACCESS_KEY"] = sentinel + "-aws"
        environment["OVERTERM_MCP_TOKEN"] = sentinel + "-mcp"
        environment["OVERTERM_SSH_SECRET"] = sentinel + "-ssh"
        environment["OVERTERM_TAB_ID"] = tab
        let child = try TestChild(
            "/usr/bin/python3", ["-c", "import time; time.sleep(60)", "--token=\(sentinel)-argv"], environment: environment)
        defer { child.stop() }
        let kernel = LiveActivityKernel()
        var read: ProcessArguments?
        // /usr/bin/python3 execs the real one, whose environment is readable.
        XCTAssertTrue(
            TestChild.eventually {
                var fallbacks = 0
                read = ProcessArguments.read(child.pid, kernel: kernel, markers: true, codeSigning: kernel.codeSigning(of: child.pid, fallbacks: &fallbacks))
                return read?.markers?.tab == tab
            }, "the child's tag is read")
        let found = try XCTUnwrap(read)
        XCTAssertTrue(found.command.contains("--token=••••••"))
        for string in strings(in: found) { XCTAssertFalse(string.contains(sentinel), "a sentinel in the read") }
        XCTAssertNil(found.markers?.run)
    }

    /// A real child of the test's that writes a title over its argv in
    /// place, as libuv's `uv_set_process_title` does — longer than the
    /// words' area, so one NUL and then its environment follow it: the
    /// kernel's layout, read as a title, its environment never in a string.
    func testARealChildsTitleKeepsItsEnvironmentOutOfArgv() throws {
        let sentinel = "SENTINEL-\(UUID().uuidString)"
        let tab = "acme-tab-\(UUID().uuidString)"
        var environment = TestChild.cleanEnvironment
        environment["ACME_NOTE"] = sentinel + "-note"
        environment["AWS_SECRET_ACCESS_KEY"] = sentinel + "-aws"
        environment["OVERTERM_TAB_ID"] = tab
        let script = """
            import ctypes, time
            libc = ctypes.CDLL(None)
            libc._NSGetArgc.restype = ctypes.POINTER(ctypes.c_int)
            libc._NSGetArgv.restype = ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))
            argc = libc._NSGetArgc()[0]
            argv = libc._NSGetArgv()[0]
            start = argv[0]
            area = argv[argc - 1] + len(ctypes.string_at(argv[argc - 1])) + 1 - start
            title = b"t" * 4096
            length = min(len(title), area - 1)
            ctypes.memmove(start, title, length)
            ctypes.memset(start + length, 0, area - length)
            time.sleep(60)
            """
        let child = try TestChild("/usr/bin/python3", ["-c", script, "acme-argument"], environment: environment)
        defer { child.stop() }
        let kernel = LiveActivityKernel()
        var read: ProcessArguments?
        XCTAssertTrue(
            TestChild.eventually {
                read = ProcessArguments.read(child.pid, kernel: kernel, markers: true, codeSigning: nil)
                return read?.isTitle == true
            }, "the child's title is read as one")
        let found = try XCTUnwrap(read)
        XCTAssertFalse(found.command.isEmpty)
        XCTAssertTrue(found.command.allSatisfy { $0 == "t" }, "the title alone")
        XCTAssertEqual(found.markers?.tab, tab, "its environment from its first entry")
        for string in strings(in: found) { XCTAssertFalse(string.contains(sentinel), "a sentinel in the read") }
    }

    /// A platform binary is `CS_RESTRICT`: its environment isn't scanned,
    /// and the kernel gives none anyway.
    func testARestrictedChildsEnvironmentIsHidden() throws {
        var environment = TestChild.cleanEnvironment
        environment["OVERTERM_TAB_ID"] = "acme-tab-hidden"
        let child = try TestChild("/bin/sleep", ["60"], environment: environment)
        defer { child.stop() }
        let kernel = LiveActivityKernel()
        var fallbacks = 0
        let signing = try XCTUnwrap(kernel.codeSigning(of: child.pid, fallbacks: &fallbacks))
        XCTAssertTrue(signing.isRestricted)
        XCTAssertTrue(signing.isPlatformBinary)
        XCTAssertNil(ProcessArguments.read(child.pid, kernel: kernel, markers: true, codeSigning: signing)?.markers)
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: ProcessArguments.argumentMaximum, alignment: 8)
        defer { region.deallocate() }
        let forced = try XCTUnwrap(ProcessArguments.read(child.pid, kernel: kernel, markers: true, in: region))
        XCTAssertEqual(forced.command, "/bin/sleep 60")
        XCTAssertEqual(forced.markers, ProcessMarkers(), "the kernel left it out")
    }

    /// Another user's process: the kernel refuses argv (EINVAL).
    func testAnotherUsersArgvIsRefused() {
        XCTAssertNil(ProcessArguments.read(1, kernel: LiveActivityKernel(), markers: false, codeSigning: nil))
    }
}
