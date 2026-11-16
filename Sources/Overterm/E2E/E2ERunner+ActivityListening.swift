import AppKit
import Darwin

/// Listening (docs/design/activity/analysis.md, 6.8, 10.3 checks 2–4) over
/// the run's own children and `FakeDockerEngine` — never the user's
/// Docker: a port split across 127.0.0.1 and ::1 by two of its processes,
/// two sharing one with `SO_REUSEPORT`, a UDP socket below the ephemeral
/// range, a connection between them paired end to end; a container's
/// published port held by one of them, and one nobody holds; `o` in the
/// tab's browser column. Every check says ports and pids of the run's own,
/// never another process's name or address.
extension E2ERunner {
    func activityListening(tab: Tab, server: ActivityPortRow?) async {
        let page = app.activityPage
        let pane = tab.terminal
        let portsFile = out("activity-listening.ports")
        let script = out("activity-listening.py")
        try? """
        import os, random, socket, sys, time
        out = sys.argv[1]
        def tcp(family, address, port, reuseport=False, v6only=False):
            s = socket.socket(family, socket.SOCK_STREAM)
            if reuseport: s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            if v6only: s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            s.bind((address, port))
            s.listen()
            return s
        split = tcp(socket.AF_INET, "127.0.0.1", 0)
        p = split.getsockname()[1]
        shared = tcp(socket.AF_INET, "127.0.0.1", 0, reuseport=True)
        r = shared.getsockname()[1]
        held = tcp(socket.AF_INET, "127.0.0.1", 0)
        h = held.getsockname()[1]
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u = 0
        for _ in range(500):
            u = random.randint(20000, 40000)
            try:
                udp.bind(("127.0.0.1", u))
                break
            except OSError:
                u = 0
        rd, wr = os.pipe()
        child = os.fork()
        if child == 0:
            for s in (split, shared, held, udp): s.close()
            os.close(rd)
            v6 = tcp(socket.AF_INET6, "::1", p, v6only=True)
            again = tcp(socket.AF_INET, "127.0.0.1", r, reuseport=True)
            client = socket.create_connection(("127.0.0.1", p))
            os.write(wr, b"ready")
            os.close(wr)
            time.sleep(150)
            os._exit(0)
        os.close(wr)
        os.read(rd, 16)
        accepted, _ = split.accept()
        open(out + ".tmp", "w").write(f"{p} {r} {h} {u} {os.getpid()} {child}")
        os.rename(out + ".tmp", out)
        time.sleep(150)
        """.write(to: script, atomically: true, encoding: .utf8)
        pane.insertText("python3 \(script.path) \(portsFile.path) &")
        pane.pressReturn()
        let written = await eventually(15) { FileManager.default.fileExists(atPath: portsFile.path) }
        let numbers = ((try? String(contentsOf: portsFile, encoding: .utf8)) ?? "").split(separator: " ").compactMap { Int($0) }
        guard written, numbers.count == 6, numbers[3] > 0 else { return check("the run's own listeners start", false, "\(numbers.count) numbers") }
        let (split, shared, held, udp) = (numbers[0], numbers[1], numbers[2], numbers[3])
        let (parent, child) = (pid_t(numbers[4]), pid_t(numbers[5]))
        check("the run's own listeners start: a parent and its child", true, "pids \(parent), \(child)")

        // A port split across 127.0.0.1 and ::1 by two processes.
        func listeners(_ port: Int, _ proto: String = "tcp") -> [ActivityPortRow] {
            page.content.ports.filter { $0.port == port && $0.proto == proto && $0.kind == .listener }
        }
        let splitSeen = await eventually(15) { listeners(split).count == 2 }
        let v4 = listeners(split).first { $0.families == .v4 }
        let v6 = listeners(split).first { $0.families == .v6 }
        check(
            "127.0.0.1 and ::1 on one port: two rows, v4 and v6, each its holder's, in its tab",
            splitSeen && v4?.holder?.pid == parent && v6?.holder?.pid == child && v4?.tab == tab.id && v6?.tab == tab.id,
            "port \(split): \(listeners(split).count) rows")
        check(
            "each opens where it listens: 127.0.0.1 and [::1]",
            v4?.url?.absoluteString == "http://127.0.0.1:\(split)" && v6?.url?.absoluteString == "http://[::1]:\(split)")
        check(
            "the collision is said on both rows: localhost may reach either",
            [v4, v6].allSatisfy { $0?.collisions.contains(.split) == true && $0?.note?.hasPrefix("localhost may reach either") == true })
        let sharedSeen = await eventually(10) {
            listeners(shared).count == 2 && listeners(shared).allSatisfy { $0.collisions.contains(.sharedPort) }
        }
        check("two holders' own sockets on one address and port: connections go to either", sharedSeen, "port \(shared)")
        let spoken = await eventually(5) { self.activityRowLabels().contains { $0.hasPrefix(":\(split) tcp") && $0.contains("localhost may reach either") } }
        check("and VoiceOver says the collision with the row", spoken)

        // UDP below the ephemeral range, with no Open.
        let udpRow = listeners(udp, "udp").first
        check("a UDP socket below the ephemeral range, in its tab, no URL", udpRow?.tab == tab.id && udpRow?.url == nil, "port \(udp)")

        // Connections (c): the child's connection to the parent, paired.
        check("c shows connections", page.press("c") && page.connections)
        let paired = await eventually(10) {
            page.content.ports.contains { $0.kind == .connection && $0.port == split && $0.holder?.pid == child }
        }
        check("the child's connection to the parent is one line, paired end to end", paired)
        check("and the listener counts it as a client", (v4?.clients ?? 0) >= 1 || listeners(split).contains { $0.clients >= 1 })
        check("c again hides them", page.press("c") && !page.connections)
        let hidden = await eventually(5) { !page.content.ports.contains { $0.kind == .connection } }
        check("no connection row then", hidden)

        // Containers from FakeDockerEngine: one publishing what the parent
        // holds — its owner the container, via the holder —, and one on a
        // port bound here and closed, so nothing of the user's can hold it.
        let socketPath = "/tmp/ot-e2e-activity-\(UUID().uuidString.prefix(6)).sock"
        let engine = FakeDockerEngine(socket: socketPath)
        do { try engine.start() } catch { return check("the fake engine starts", false, "\(error)") }
        let docker = DockerModel.shared
        defer {
            docker.use(nil)
            engine.stop()
        }
        let free = Self.activityFreePort()
        engine.add(name: "acme-held", ports: [DockerPort(IP: "127.0.0.1", PrivatePort: 80, PublicPort: held, Type: "tcp")])
        engine.add(name: "acme-db", ports: [DockerPort(IP: "127.0.0.1", PrivatePort: 5432, PublicPort: free, Type: "tcp")])
        docker.use(DockerEndpoint(address: .unix(socketPath), context: nil, source: "OVERTERM_DOCKER_HOST"))
        check("the fake engine is reached", await eventually(10) { docker.connection.isRunning })
        let attributed = await eventually(15) {
            listeners(held).first?.portOwner == .container(name: "acme-held", project: nil)
                && page.content.ports.contains { $0.port == free && $0.portOwner == .container(name: "acme-db", project: nil) }
        }
        let heldRow = listeners(held).first
        let unseen = page.content.ports.first { $0.port == free }
        check(
            "a published port the run's process holds is the container's, via its holder",
            attributed && heldRow?.holder?.pid == parent && heldRow?.ownerText.hasPrefix("container acme-held") == true
                && heldRow?.ownerText.hasSuffix("via \(heldRow?.process ?? "-")") == true,
            "port \(held)")
        check(
            "one nobody holds is the container's own row, via the engine, opening where it is published",
            unseen?.holder == nil && unseen?.ownerText == "container acme-db · via the engine"
                && unseen?.url?.absoluteString == "http://127.0.0.1:\(free)",
            "port \(free)")
        page.setFilter("owner:container")
        let filtered = await eventually(5) { Set(page.content.ports.map(\.port)) == [held, free] }
        page.setFilter("")
        check("owner:container lists exactly those two", filtered)

        // Open (o): the server's URL in its tab's browser column.
        guard let server else { return check("the server's row", false) }
        var opened: [(URL, Bool)] = []
        app.linkRecorder = { opened.append(($0, $1)) }
        defer { app.linkRecorder = nil }
        page.selection = [server.id]
        check("o opens the server's port", page.press("o"))
        check(
            "in its tab's browser column: the tab selected, the page stepped aside, the URL its bound address's",
            opened.first?.0 == server.url && opened.first?.1 == true && app.store.selected?.id == tab.id && app.store.showingOverlay != .activity,
            opened.first.map { "\($0.0.absoluteString) inside \($0.1)" } ?? "nothing opened")
        app.showActivityPage(.listening)
        check("the page shown again reads again", await eventually(15) { page.hasRead })
    }

    /// A TCP port the system gives on 127.0.0.1, closed at once: nobody of
    /// the user's holds it.
    static func activityFreePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : 0
    }
}
