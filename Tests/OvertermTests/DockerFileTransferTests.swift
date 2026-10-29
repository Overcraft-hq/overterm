import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import Overterm

/// Files and folders into and out of a container: the archive a drop
/// becomes, read back in any cut, written to the Mac without leaving its
/// folder; the app's copies and a dragged row's promise against the fake
/// engine. Folders under the temporary directory, removed after; never
/// the user's Docker.
@MainActor
final class DockerFileTransferTests: XCTestCase {
    private var root: URL!
    private var fake: FakeDockerEngine!
    private var engine: DockerEngine!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = "/tmp/ot-docker-\(UUID().uuidString.prefix(8)).sock"
        fake = FakeDockerEngine(socket: socket)
        try fake.start()
        engine = DockerEngine(endpoint: DockerEndpoint(address: .unix(socket), context: nil, source: "test"))
    }

    override func tearDown() async throws {
        fake.stop()
        // A folder made read-only by a test is writable again, so it goes.
        if let walk = FileManager.default.enumerator(atPath: root.path) {
            while let relative = walk.nextObject() as? String {
                guard walk.fileAttributes?[.type] as? FileAttributeType == .typeDirectory else { continue }
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(relative).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out: \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func write(_ text: String, _ path: String, mode: Int = 0o644) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    /// site/{index.html, css/app.css, run.sh, .env, .DS_Store, empty/,
    /// link → index.html, out → ../../etc}, and notes.txt beside it.
    private func site() throws -> (site: URL, notes: URL) {
        _ = try write("<h1>site</h1>\n", "drop/site/index.html")
        _ = try write("body {}\n", "drop/site/css/app.css")
        _ = try write("#!/bin/sh\necho hi\n", "drop/site/run.sh", mode: 0o755)
        _ = try write("SECRET=1\n", "drop/site/.env")
        _ = try write("finder", "drop/site/.DS_Store")
        let site = root.appendingPathComponent("drop/site")
        try FileManager.default.createDirectory(at: site.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: site.appendingPathComponent("link").path, withDestinationPath: "index.html")
        try FileManager.default.createSymbolicLink(atPath: site.appendingPathComponent("out").path, withDestinationPath: "../../etc")
        return (site, try write("notes\n", "drop/notes.txt"))
    }

    private func whole(_ writer: DockerTarWriter) throws -> Data {
        var out = Data()
        while let piece = try writer.next() { out += piece }
        return out
    }

    // MARK: The archive a drop becomes

    func testAFolderBecomesOneArchive() throws {
        let (site, notes) = try site()
        let plan = try DockerTar.Plan.make([site, notes])
        let names = plan.items.map(\.name)
        XCTAssertEqual(
            Set(names), ["notes.txt", "site/", "site/.env", "site/css/", "site/css/app.css", "site/empty/", "site/index.html", "site/link", "site/run.sh"])
        for (index, name) in names.enumerated() where name.hasSuffix("/") {
            XCTAssertFalse(names[..<index].contains { $0.hasPrefix(name) }, "\(name) comes before what is in it")
        }
        XCTAssertEqual(plan.skipped, ["site/out"], "a link above the drop stays on the Mac")
        XCTAssertFalse(names.contains { $0.hasSuffix(".DS_Store") })
        XCTAssertEqual(plan.items.first { $0.name == "site/run.sh" }?.mode, 0o755)
        XCTAssertEqual(plan.tops, ["site", "notes.txt"])
        XCTAssertEqual(plan.summary, "site and notes.txt")
        XCTAssertEqual(plan.bytes, plan.items.reduce(0) { $0 + $1.size })

        let archive = try whole(DockerTarWriter(plan))
        XCTAssertEqual(archive.count, plan.length, "as long as the request says")
        let entries = DockerTar.entries(of: archive)
        XCTAssertEqual(entries.map(\.name), names)
        XCTAssertEqual(entries.first { $0.name == "site/css/app.css" }?.data, Data("body {}\n".utf8))
        XCTAssertEqual(entries.first { $0.name == "site/link" }?.kind, .symlink)
        XCTAssertEqual(entries.first { $0.name == "site/link" }?.linkTarget, "index.html")
        XCTAssertEqual(entries.first { $0.name == "site/empty/" }?.kind, .directory)
        XCTAssertEqual(entries.first { $0.name == "site/run.sh" }?.mode, 0o755)
        XCTAssertEqual(entries.first { $0.name == "notes.txt" }?.uid, 0, "root's, as docker cp without -a")
    }

    func testTwoDroppedOfOneNameAreRefused() throws {
        let a = try write("a", "one/x.txt")
        let b = try write("b", "two/x.txt")
        XCTAssertThrowsError(try DockerTar.Plan.make([a, b])) { error in
            XCTAssertTrue(error.localizedDescription.contains("“x.txt”"), error.localizedDescription)
        }
    }

    func testLongNamesAndLinksGoAsGNUEntries() throws {
        let long = String(repeating: "d", count: 200) + "/" + String(repeating: "f", count: 99)
        XCTAssertEqual(long.utf8.count, 300)
        XCTAssertNil(DockerTar.split(long), "past what ustar's prefix holds")
        let target = String(repeating: "t", count: 150)
        let items = [
            DockerTar.Plan.Item(name: long + "/", kind: .directory, mode: 0o755),
            DockerTar.Plan.Item(name: long + "/link", kind: .symlink(target)),
            DockerTar.Plan.Item(name: String(repeating: "p", count: 100), kind: .directory, mode: 0o700),
        ]
        var archive = Data()
        for item in items {
            let headers = try XCTUnwrap(DockerTar.headers(for: item))
            XCTAssertEqual(headers.count, DockerTar.length(of: item))
            archive += headers
        }
        archive += Data(count: 2 * DockerTar.block)
        XCTAssertEqual(DockerTar.headers(for: items[2])?.count, DockerTar.block, "a name of 100 bytes stays plain ustar")
        let entries = DockerTar.entries(of: archive)
        XCTAssertEqual(entries.map(\.name), [long + "/", long + "/link", String(repeating: "p", count: 100)])
        XCTAssertEqual(entries[1].linkTarget, target)
        XCTAssertEqual(entries[1].kind, .symlink)
    }

    func testTheLargestFileUstarHolds() throws {
        XCTAssertNotNil(DockerTar.header(name: "big", size: DockerTar.maximumSize, mode: 0o644, modified: Date(), type: "0"))
        XCTAssertNil(DockerTar.header(name: "big", size: DockerTar.maximumSize + 1, mode: 0o644, modified: Date(), type: "0"))
        let big = try write("", "big.bin")
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(DockerTar.maximumSize + 1))  // sparse: nothing written
        try handle.close()
        XCTAssertThrowsError(try DockerTar.Plan.make([big])) { error in
            XCTAssertTrue(error.localizedDescription.contains("over 8 GB"), error.localizedDescription)
        }
    }

    func testWhatClimbsOut() {
        XCTAssertTrue(DockerTar.escapes("../x", from: "a"))
        XCTAssertFalse(DockerTar.escapes("..", from: "site/a"))
        XCTAssertTrue(DockerTar.escapes("../../y", from: "site/a"))
        XCTAssertFalse(DockerTar.escapes("/etc/x", from: "a"), "the engine joins an absolute one under the folder")
        XCTAssertFalse(DockerTar.escapes("css/./app.css", from: "site/a"))
    }

    func testAFileThatChangesSizeFails() throws {
        let file = try write("small", "grows.txt")
        let plan = try DockerTar.Plan.make([file])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" and then some".utf8))
        try handle.close()
        XCTAssertThrowsError(try whole(DockerTarWriter(plan))) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed while it was copied"), error.localizedDescription)
        }
    }

    func testABigFileGoesInPieces() throws {
        let file = root.appendingPathComponent("big.bin")
        let data = Data((0..<(3 << 20) + 17).map { UInt8($0 % 253) })
        try data.write(to: file)
        let plan = try DockerTar.Plan.make([file])
        let writer = DockerTarWriter(plan)
        var pieces: [Int] = []
        var archive = Data()
        while let piece = try writer.next() {
            pieces.append(piece.count)
            archive += piece
        }
        XCTAssertGreaterThanOrEqual(pieces.count, 4)
        XCTAssertTrue(pieces.allSatisfy { $0 <= DockerTarWriter.piece })
        XCTAssertEqual(archive.count, plan.length)
        XCTAssertEqual(DockerTar.entries(of: archive).first?.data, data)
    }

    // MARK: Reading what comes

    /// Data events of one entry, as one: a cut splits them.
    private func merged(_ events: [DockerTar.Reader.Event]) -> [DockerTar.Reader.Event] {
        var out: [DockerTar.Reader.Event] = []
        for event in events {
            if case .data(let more) = event, case .data(let some)? = out.last {
                out[out.count - 1] = .data(some + more)
            } else {
                out.append(event)
            }
        }
        return out
    }

    private func meta(_ type: Character, _ data: Data) throws -> Data {
        var out = try XCTUnwrap(DockerTar.header(name: "././@LongLink", size: data.count, mode: 0, modified: Date(timeIntervalSince1970: 0), type: type))
        out += data
        out += Data(count: DockerTar.padding(data.count))
        return out
    }

    func testTheReaderTakesAnyCut() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        var archive = Data()
        // PAX: a long path for the next entry.
        let path = "deep/" + String(repeating: "p", count: 140) + ".txt"
        let record = "path=\(path)\n"
        var length = record.utf8.count + 2
        while "\(length) \(record)".utf8.count != length { length += 1 }
        archive += try meta("x", Data("\(length) \(record)".utf8))
        archive += try XCTUnwrap(DockerTar.archive(name: "short", data: Data("pax".utf8), modified: when)).dropLast(2 * DockerTar.block)
        // GNU: a long name and a long link for a symlink.
        let name = String(repeating: "n", count: 130)
        let target = String(repeating: "t", count: 120)
        archive += try meta("L", Data(name.utf8) + Data([0]))
        archive += try meta("K", Data(target.utf8) + Data([0]))
        archive += try XCTUnwrap(DockerTar.header(name: "cut", size: 0, mode: 0o777, modified: when, type: "2"))
        // A hardlink, an empty file, a folder.
        archive += try XCTUnwrap(DockerTar.header(name: "hard", size: 0, mode: 0o644, modified: when, type: "1", link: "short"))
        archive += try XCTUnwrap(DockerTar.archive(name: "empty", data: Data(), modified: when)).dropLast(2 * DockerTar.block)
        archive += try XCTUnwrap(DockerTar.header(name: "dir/", size: 0, mode: 0o755, modified: when, type: "5"))
        // A size in base-256: the high bit set, big-endian after it.
        var base256 = try XCTUnwrap(DockerTar.header(name: "b256", size: 0, mode: 0o644, modified: when, type: "0"))
        for i in 124..<136 { base256[i] = 0 }
        base256[124] = 0x80
        base256[135] = 5
        archive += base256 + Data("12345".utf8) + Data(count: DockerTar.padding(5))
        archive += Data(count: 2 * DockerTar.block)

        var whole = DockerTar.Reader()
        let expected = whole.feed(archive)
        XCTAssertTrue(whole.finished)
        let headers = expected.compactMap { event -> DockerTar.Reader.Header? in
            if case .entry(let header) = event { header } else { nil }
        }
        XCTAssertEqual(headers.map(\.name), [path, name, "hard", "empty", "dir/", "b256"])
        XCTAssertEqual(headers.map(\.kind), [.file, .symlink, .hardlink, .file, .directory, .file])
        XCTAssertEqual(headers[1].linkTarget, target)
        XCTAssertEqual(headers[2].linkTarget, "short")
        XCTAssertEqual(headers[5].size, 5, "base-256 reads")
        XCTAssertEqual(expected.filter { $0 == .end }.count, 6, "an end after each, an empty one's too")
        XCTAssertTrue(expected.contains(.data(Data("12345".utf8))))
        for cut in [1, 7, 511, 512, 513, 4096] {
            var reader = DockerTar.Reader()
            var events: [DockerTar.Reader.Event] = []
            var at = 0
            while at < archive.count {
                events += reader.feed(archive.subdata(in: at..<min(at + cut, archive.count)))
                at += cut
            }
            XCTAssertEqual(merged(events), merged(expected), "cut every \(cut)")
            XCTAssertTrue(reader.finished)
        }
    }

    func testPlaces() {
        XCTAssertEqual(DockerTarExtractor.place("nginx/conf.d/a", folder: true), ["conf.d", "a"])
        XCTAssertEqual(DockerTarExtractor.place("nginx", folder: true), [])
        XCTAssertEqual(DockerTarExtractor.place("./nginx/./a", folder: true), ["a"])
        XCTAssertNil(DockerTarExtractor.place("nginx/../x", folder: true))
        XCTAssertNil(DockerTarExtractor.place("/etc/x", folder: true))
        XCTAssertNil(DockerTarExtractor.place("nginx/./../y", folder: true))
    }

    func testWhatComesOutStaysInItsFolder() throws {
        let when = Date(timeIntervalSince1970: 1_600_000_000)
        func file(_ name: String, _ text: String, mode: Int = 0o644) throws -> Data {
            try XCTUnwrap(DockerTar.archive(name: name, data: Data(text.utf8), mode: mode, modified: when)).dropLast(2 * DockerTar.block)
        }
        var archive = try XCTUnwrap(DockerTar.header(name: "top/", size: 0, mode: 0o750, modified: when, type: "5"))
        archive += try XCTUnwrap(DockerTar.header(name: "top/link", size: 0, mode: 0o777, modified: when, type: "2", link: "/"))
        archive += try file("top/link/evil", "through the link")
        archive += try file("top/../../evil", "above")
        archive += try file("/abs-evil", "absolute")
        archive += try file("top/a", "a\n", mode: 0o600)
        archive += try XCTUnwrap(DockerTar.header(name: "top/ro/", size: 0, mode: 0o555, modified: when, type: "5"))
        archive += try file("top/ro/child", "child\n")
        archive += try XCTUnwrap(DockerTar.header(name: "top/hard", size: 0, mode: 0o600, modified: when, type: "1", link: "top/a"))
        // A folder of a link's name: through the link, its mode and time
        // would go to the folder outside; the link is replaced instead.
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: when], ofItemAtPath: outside.path)
        // From box/out/door: the folder beside box, in a link's 100 bytes.
        let away = "../../outside"
        archive += try XCTUnwrap(DockerTar.header(name: "top/door", size: 0, mode: 0o777, modified: when, type: "2", link: away))
        archive += try XCTUnwrap(DockerTar.header(name: "top/door/", size: 0, mode: 0o700, modified: Date(), type: "5"))
        // A folder a later entry makes a link: its mode isn't set through it.
        archive += try XCTUnwrap(DockerTar.header(name: "top/turn/", size: 0, mode: 0o700, modified: Date(), type: "5"))
        archive += try XCTUnwrap(DockerTar.header(name: "top/turn", size: 0, mode: 0o777, modified: when, type: "2", link: away))
        archive += Data(count: 2 * DockerTar.block)

        let box = root.appendingPathComponent("box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let destination = box.appendingPathComponent("out", isDirectory: true)
        let extractor = DockerTarExtractor(destination: destination, folder: true)
        var reader = DockerTar.Reader()
        for event in reader.feed(archive) { try extractor.apply(event) }
        let summary = try extractor.finish()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: box.path), ["out"], "nothing beside it")
        XCTAssertEqual(Set(summary.skipped), ["top/link/evil", "top/../../evil", "/abs-evil"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("link").path), "/")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("ro/child"), encoding: .utf8), "child\n")
        let ro = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("ro").path)
        XCTAssertEqual((ro[.posixPermissions] as? NSNumber)?.intValue, 0o555, "set after what is in it")
        let top = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((top[.posixPermissions] as? NSNumber)?.intValue, 0o750, "the top's mode is the destination's")
        let a = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("a").path)
        XCTAssertEqual((a[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(a[.modificationDate] as? Date, when)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("hard"), encoding: .utf8), "a\n", "a hardlink is a copy")
        XCTAssertEqual(summary.files, 3)
        let door = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("door").path)
        XCTAssertEqual(door[.type] as? FileAttributeType, .typeDirectory, "the link replaced by the folder")
        XCTAssertEqual((door[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let turn = destination.appendingPathComponent("turn")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: turn.path), away)
        XCTAssertEqual(turn.resolvingSymlinksInPath().path, outside.resolvingSymlinksInPath().path, "a link to the folder outside, as the archive says")
        let untouched = try FileManager.default.attributesOfItem(atPath: outside.path)
        XCTAssertEqual((untouched[.posixPermissions] as? NSNumber)?.intValue, 0o755, "the folder outside keeps its mode")
        XCTAssertEqual(untouched[.modificationDate] as? Date, when, "and its time")
    }

    func testAFailedCopyLeavesNothing() throws {
        let destination = root.appendingPathComponent("gone", isDirectory: true)
        let extractor = DockerTarExtractor(destination: destination, folder: true)
        var reader = DockerTar.Reader()
        var archive = try XCTUnwrap(DockerTar.header(name: "top/", size: 0, mode: 0o755, modified: Date(), type: "5"))
        archive += try XCTUnwrap(DockerTar.archive(name: "top/a", data: Data("a".utf8)))
        for event in reader.feed(archive) { try extractor.apply(event) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        extractor.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDragSourceTakesOnlyALeftPress() {
        XCTAssertTrue(DockerFileDragSourceView.takes(.leftMouseDown, []))
        XCTAssertTrue(DockerFileDragSourceView.takes(.leftMouseDown, [.command]))
        XCTAssertFalse(DockerFileDragSourceView.takes(.rightMouseDown, []))
        XCTAssertFalse(DockerFileDragSourceView.takes(.leftMouseDown, [.control]), "⌃-click is the menu's")
        XCTAssertFalse(DockerFileDragSourceView.takes(.scrollWheel, []))
        XCTAssertFalse(DockerFileDragSourceView.takes(.mouseMoved, []))
    }

    func testCollisions() {
        let listed = [
            DockerFiles.Entry(name: "b", kind: .file, size: 1), DockerFiles.Entry(name: "c", kind: .file, size: 1),
            DockerFiles.Entry(name: "site", kind: .folder), DockerFiles.Entry(name: "html", kind: .link),
        ]
        let there = DockerFileTransfers.collisions(["a", "b", "site", "html"], listed: listed)
        XCTAssertEqual(there.names, ["b", "site", "html"])
        XCTAssertEqual(there.folders, ["site"], "a link to a folder isn't one to merge into")
        XCTAssertEqual(DockerFileTransfers.replacing(["index.html"], in: "/srv").title, "Replace “index.html” in /srv?")
        XCTAssertEqual(DockerFileTransfers.replacing(["a", "b", "c"], in: "/srv").title, "Replace 3 items in /srv?")
        XCTAssertEqual(DockerFileTransfers.place(of: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/x.conf")), "~/Desktop")
    }

    /// A folder dropped onto one of its name: its own entry left out, so
    /// the engine doesn't give the folder there root's owner and the
    /// Mac's mode — what is in it goes as it is.
    func testAFolderThereIsMergedIntoNotReplaced() throws {
        let (site, notes) = try site()
        let plan = try DockerTar.Plan.make([site, notes])
        let merged = plan.merging(into: ["site", "notes.txt"])
        XCTAssertFalse(merged.items.contains { $0.name == "site/" })
        XCTAssertEqual(Set(merged.items.map(\.name)), Set(plan.items.map(\.name)).subtracting(["site/"]), "only the folder's own entry")
        XCTAssertEqual(merged.tops, plan.tops)
        XCTAssertEqual(merged.length, plan.length - DockerTar.block)
        XCTAssertEqual(try whole(DockerTarWriter(merged)).count, merged.length)
        XCTAssertEqual(plan.merging(into: []), plan)
    }

    func testAFilesFileTypeIsData() {
        let web = DockerFileSource.container(id: "abc", name: "web")
        XCTAssertEqual(DockerFileItem(source: web, path: "/etc/nginx", isFolder: true).fileType, UTType.folder.identifier)
        XCTAssertEqual(DockerFileItem(source: web, path: "/etc/nginx/index.html", isFolder: false).fileType, UTType.html.identifier)
        let conf = UTType(DockerFileItem(source: web, path: "/etc/nginx/nginx.conf", isFolder: false).fileType)
        XCTAssertTrue(conf?.conforms(to: .data) == true)
        XCTAssertEqual(DockerFileItem(source: web, path: "/usr/bin/env", isFolder: false).fileType, UTType.data.identifier)
    }

    // MARK: The app's copies

    func testAPromiseWritesThroughTheArchive() async throws {
        let id = fake.add(name: "nginx")
        fake.setFile(id, "/etc/nginx/nginx.conf", Data("worker_processes 1;\n".utf8))
        fake.setFile(id, "/etc/nginx/conf.d/default.conf", Data("server {}\n".utf8))
        let engine = engine!
        let transfers = DockerFileTransfers(engine: { engine }, linger: .milliseconds(400))
        let source = DockerFileSource.container(id: id, name: "nginx")
        let waiting = DockerFilePromise.waiting

        let (folder, folderPromise) = DockerFileDragSourceView.provider(for: DockerFileItem(source: source, path: "/etc/nginx", isFolder: true), transfers: transfers)
        XCTAssertEqual(folder.fileType, "public.folder")
        XCTAssertEqual(folderPromise.filePromiseProvider(folder, fileNameForType: folder.fileType), "nginx")
        XCTAssertEqual(DockerFilePromise.waiting, waiting + 1, "kept: the provider holds it weakly")
        let out = root.appendingPathComponent("finder/nginx")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrote = expectation(description: "the folder is written")
        var failure: (any Error)?
        folderPromise.filePromiseProvider(folder, writePromiseTo: out) { error in
            failure = error
            wrote.fulfill()
        }
        await fulfillment(of: [wrote], timeout: 5)
        XCTAssertNil(failure)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("nginx.conf"), encoding: .utf8), "worker_processes 1;\n")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("conf.d/default.conf"), encoding: .utf8), "server {}\n")
        XCTAssertEqual(DockerFilePromise.waiting, waiting, "let go once written")
        try await eventually("the row finishes and goes") { transfers.transfers.isEmpty }

        let (file, filePromise) = DockerFileDragSourceView.provider(
            for: DockerFileItem(source: source, path: "/etc/nginx/nginx.conf", isFolder: false), transfers: transfers)
        XCTAssertEqual(filePromise.filePromiseProvider(file, fileNameForType: file.fileType), "nginx.conf")
        let copy = root.appendingPathComponent("finder/nginx.conf")
        let wroteFile = expectation(description: "the file is written")
        filePromise.filePromiseProvider(file, writePromiseTo: copy) { _ in wroteFile.fulfill() }
        await fulfillment(of: [wroteFile], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: copy), Data("worker_processes 1;\n".utf8))
        let row = transfers.transfers(for: source).first
        XCTAssertEqual(row?.direction, .out, "a row in its pane's strip")
        XCTAssertEqual(row?.finished, true)
        XCTAssertEqual(row?.done, 20, "all of it")
        XCTAssertEqual(row?.total, 20)
        try await eventually("and it goes") { transfers.transfers.isEmpty }
    }

    func testACopyInAsksBeforeReplacing() async throws {
        let id = fake.add(name: "web")
        fake.setFile(id, "/srv/index.html", Data("<h1>hi</h1>\n".utf8))
        let engine = engine!
        let transfers = DockerFileTransfers(engine: { engine }, linger: .milliseconds(50))
        let source = DockerFileSource.container(id: id, name: "web")
        let index = try write("<h1>new</h1>\n", "drop/index.html")
        var asked: [String] = []
        var accept = false
        let confirm: (String, String, String, @escaping () -> Void) -> Void = { title, _, button, then in
            asked.append(title + " " + button)
            if accept { then() }
        }
        var done = 0
        let listed = [DockerFiles.Entry(name: "index.html", kind: .file, size: 12)]
        transfers.copyIn([index], into: "/srv", of: source, listed: listed, confirm: confirm) { done += 1 }
        try await eventually("asked") { !asked.isEmpty }
        XCTAssertEqual(asked, ["Replace “index.html” in /srv? Replace"])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fake.requests.contains { $0.hasPrefix("PUT") }, "declined: nothing sent")
        XCTAssertEqual(fake.file(id, "/srv/index.html"), Data("<h1>hi</h1>\n".utf8))

        accept = true
        transfers.copyIn([index], into: "/srv", of: source, listed: listed, confirm: confirm) { done += 1 }
        try await eventually("replaced") { self.fake.file(id, "/srv/index.html") == Data("<h1>new</h1>\n".utf8) }
        try await eventually("its row finishes") { transfers.transfers.first?.finished == true || done == 1 }
        try await eventually("and goes") { transfers.transfers.isEmpty }
        XCTAssertEqual(done, 1)

        // Not listed (a folder row's drop): looked at one by one.
        asked = []
        accept = false
        transfers.copyIn([index], into: "/srv", of: source, listed: nil, confirm: confirm)
        try await eventually("asked from a stat") { !asked.isEmpty }

        // Refused: the engine's words stay to be read.
        fake.setReadOnly(id, true)
        let notes = try write("notes\n", "drop/notes.txt")
        transfers.copyIn([notes], into: "/srv", of: source, listed: [], confirm: confirm)
        try await eventually("refused") { transfers.transfers.first?.error != nil }
        XCTAssertTrue(transfers.transfers.first?.error?.contains("read-only") == true, transfers.transfers.first?.error ?? "")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transfers.transfers.count, 1, "a failed one stays past its linger")
        if let row = transfers.transfers.first { transfers.dismiss(row.id) }
        XCTAssertTrue(transfers.transfers.isEmpty)
    }

    func testASaveReplacesWhatIsThere() async throws {
        let id = fake.add(name: "web")
        fake.setFile(id, "/etc/app.conf", Data("new\n".utf8))
        let engine = engine!
        let transfers = DockerFileTransfers(engine: { engine }, linger: .milliseconds(50))
        let there = try write("old\n", "saved/app.conf")
        let saved = expectation(description: "saved")
        transfers.copyOut("/etc/app.conf", of: .container(id: id, name: "web"), to: there, replacing: true) { _ in saved.fulfill() }
        await fulfillment(of: [saved], timeout: 5)
        XCTAssertEqual(try String(contentsOf: there, encoding: .utf8), "new\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: there.deletingLastPathComponent().path), ["app.conf"], "nothing left beside it")

        // An executable saved over a plain file of its name: the copy's
        // mode, not the one it replaced.
        try await engine.copyIn(try DockerTar.Plan.make([try write("#!/bin/sh\n", "in/entrypoint.sh", mode: 0o755)]), into: "/etc", of: id)
        let script = try write("old\n", "saved/entrypoint.sh", mode: 0o644)
        let savedScript = expectation(description: "the script saved")
        transfers.copyOut("/etc/entrypoint.sh", of: .container(id: id, name: "web"), to: script, replacing: true) { _ in savedScript.fulfill() }
        await fulfillment(of: [savedScript], timeout: 5)
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), "#!/bin/sh\n")
        let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755, "it still runs")
    }

    /// A container renamed while a copy runs: its rows stay in its strip
    /// — matched by its id — to be stopped or read.
    func testARenameKeepsItsRows() async throws {
        let transfers = DockerFileTransfers(engine: { nil }, linger: .milliseconds(50))
        transfers.copyOut("/etc/app.conf", of: .container(id: "abc", name: "web"), to: root.appendingPathComponent("app.conf"))
        XCTAssertEqual(transfers.transfers(for: .container(id: "abc", name: "web2")).count, 1, "its new name")
        XCTAssertEqual(transfers.transfers(for: .container(id: "def", name: "web")).count, 0, "another of its old name")
        XCTAssertEqual(transfers.transfers(for: .volume("web")).count, 0)
    }

    /// An `.into` row's bar moves while the copy runs: a value between
    /// none and all of it is shown before it finishes.
    func testACopyInShowsItsProgress() async throws {
        let id = fake.add(name: "web")
        fake.setFile(id, "/srv/keep", Data("kept\n".utf8))
        let engine = engine!
        let transfers = DockerFileTransfers(engine: { engine }, linger: .milliseconds(50))
        let big = root.appendingPathComponent("drop/big.bin")
        try FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<(6 << 20)).map { UInt8($0 % 251) }).write(to: big)
        var shown: [(done: Int, total: Int?)] = []
        let watching = transfers.$transfers.sink { rows in
            for row in rows where row.direction == .into && row.running { shown.append((row.done, row.total)) }
        }
        defer { watching.cancel() }
        transfers.copyIn([big], into: "/srv", of: .container(id: id, name: "web"), listed: [], confirm: { _, _, _, _ in XCTFail("nothing there") })
        try await eventually("copied") { self.fake.file(id, "/srv/big.bin")?.count == 6 << 20 }
        try await eventually("its row finishes") { transfers.transfers.first?.finished == true || transfers.transfers.isEmpty }
        XCTAssertNil(transfers.transfers.first?.error)
        let total = try XCTUnwrap(shown.first?.total)
        XCTAssertGreaterThan(total, 6 << 20)
        XCTAssertTrue(shown.contains { $0.done > 0 && $0.done < total }, "\(shown)")
    }

    /// A drop while the folder is still being listed — the list another
    /// folder's, or this one's before the last copy — is looked at, not
    /// read off the list.
    func testADropWhileListingLooksAtTheFolder() async throws {
        let id = fake.add(name: "web")
        fake.setFile(id, "/srv/index.html", Data("<h1>hi</h1>\n".utf8))
        let engine = engine!
        let transfers = DockerFileTransfers(engine: { engine }, linger: .milliseconds(50))
        let source = DockerFileSource.container(id: id, name: "web")
        let index = try write("<h1>new</h1>\n", "drop/index.html")
        var asked: [String] = []
        let actions = DockerActions(run: { _, _ in }, confirm: { title, _, _, _ in asked.append(title) }, open: { _ in }, copy: { _ in }, settings: {})
        // /'s names, /srv opened and not listed yet.
        let browser = Browser(folder: "/srv", entries: [DockerFiles.Entry(name: "srv", kind: .folder)], listing: true)
        browser.copyIn([index], into: "/srv", of: source, actions: actions, transfers: transfers)
        try await eventually("asked, from a stat") { !asked.isEmpty }
        XCTAssertEqual(asked, ["Replace “index.html” in /srv?"])
        XCTAssertTrue(fake.requests.contains { $0.hasPrefix("HEAD") && $0.contains("path=/srv/index.html") }, "\(fake.requests)")
        XCTAssertEqual(fake.file(id, "/srv/index.html"), Data("<h1>hi</h1>\n".utf8), "nothing replaced unasked")

        // Listed: the list is read, nothing looked at.
        asked = []
        let heads = fake.requests.filter { $0.hasPrefix("HEAD") }.count
        browser.entries = [DockerFiles.Entry(name: "index.html", kind: .file, size: 12)]
        browser.listing = false
        browser.copyIn([index], into: "/srv", of: source, actions: actions, transfers: transfers)
        try await eventually("asked, from the list") { !asked.isEmpty }
        XCTAssertEqual(fake.requests.filter { $0.hasPrefix("HEAD") }.count, heads)
    }

    /// A folder dropped onto one of its name, through the engine: what is
    /// in it goes into the one there, whose own mode no entry changes.
    func testADroppedFolderMergesIntoTheOneThere() async throws {
        let id = fake.add(name: "web")
        fake.setFile(id, "/srv/site/x", Data("x".utf8))
        let engine = engine!
        let transfers = DockerFileTransfers(engine: { engine }, linger: .milliseconds(50))
        let (site, _) = try site()
        var asked: [String] = []
        transfers.copyIn(
            [site], into: "/srv", of: .container(id: id, name: "web"), listed: [DockerFiles.Entry(name: "site", kind: .folder)],
            confirm: { title, _, _, then in
                asked.append(title)
                then()
            })
        try await eventually("merged") { self.fake.file(id, "/srv/site/css/app.css") == Data("body {}\n".utf8) }
        XCTAssertEqual(asked, ["Replace “site” in /srv?"])
        XCTAssertEqual(fake.file(id, "/srv/site/x"), Data("x".utf8), "what was there stays")
        XCTAssertNil(fake.folderMode(id, "/srv/site"), "the folder there keeps its own owner and mode")
        XCTAssertNotNil(fake.folderMode(id, "/srv/site/css"), "one made in it has the Mac's")
    }
}

/// A Files tab's list, as the test says it is.
@MainActor
private final class Browser: DockerFolderBrowsing {
    @Published var folder: String?
    @Published var entries: [DockerFiles.Entry]
    @Published var filesError: String?
    @Published var listing: Bool
    private(set) var opened: [String] = []

    init(folder: String?, entries: [DockerFiles.Entry], listing: Bool) {
        self.folder = folder
        self.entries = entries
        self.listing = listing
    }

    func open(_ folder: String) { opened.append(folder) }
}
