#if E2E
import AppKit
import Darwin

/// Agents' reads (docs/design/activity/analysis.md, 8.2–8.5, 10.1's
/// `ActivityMCPTests` in the real app): the MCP server's own dispatch, as
/// `databaseAgent` calls it, from the run's own pane — its server's port is
/// the pane's, `proc_mine` finds the stand-in agent and the server, a port
/// nobody of the run holds is "not listed", a pane no window has gets
/// nothing, and switched off every tool says where to switch it on. Every
/// check says ports, pids of the run's own and counts, never an answer's
/// text: a test run lists only its own tabs' processes, but a check's
/// message stays clear of the Mac's all the same.
extension E2ERunner {
    package func activityAgentReadChecks(tab: Tab, port: Int) async {
        let pane = tab.terminal.processTag
        func call(_ name: String, _ arguments: [String: Any] = [:], from: String? = nil) async -> (object: [String: Any]?, isError: Bool) {
            let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            let answer = await BrowserMCP.handle(message, browser: { nil }, pane: from ?? pane)
            if answer?["error"] != nil { return (nil, true) }
            let result = answer?["result"] as? [String: Any]
            let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            return (object, result?["isError"] as? Bool == true)
        }
        func listed() async -> [String] {
            let answer = await BrowserMCP.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], browser: { nil })
            return ((answer?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        }

        let tools = await listed()
        check("agents are offered Activity's five reads", ActivityMCP.names.allSatisfy(tools.contains), "\(tools.count) tools")
        check("and the instructions tell them to ask before assuming a port", BrowserMCP.instructions.contains("port_holder"))

        let holder = await call("port_holder", ["port": port])
        let holders = holder.object?["holders"] as? [[String: Any]] ?? []
        check(
            "port_holder: the tab's server holds its port, and it is the pane's own",
            !holder.isError && holder.object?["state"] as? String == "held" && holder.object?["yours"] as? Bool == true
                && holders.first?["class"] as? String == "your pane",
            "\(holders.count) holders")
        let command = (holders.first?["holder"] as? [String: Any])?["command"] as? String
        check("with its masked command, inside its own checkout", command != nil)

        let mine = await call("proc_mine")
        let servers = (mine.object?["servers"] as? [[String: Any]])?.compactMap { $0["port"] as? Int } ?? []
        let you = mine.object?["you"] as? [String: Any]
        check("proc_mine lists the pane's server", !mine.isError && servers.contains(port), "\(servers.count) servers")
        // The stand-in is `exec -a claude /bin/sh`: Claude by its argv, `sh` by its name.
        let agentPID = app.activityPage.content.processes.first { $0.tab == tab.id && $0.owner?.paneRole == .agent }?.identity.pid
        check(
            "and names the stand-in agent as the caller, the pane's agent",
            you?["agent"] as? String == "Claude" && (you?["pid"] as? Int).map(pid_t.init) == agentPID && agentPID != nil,
            "you \(you == nil ? "missing" : "said"), agent pid \(agentPID ?? -1), its pid \(you?["pid"] as? Int ?? -1)")

        let list = await call("port_list", ["scope": "mine"])
        let ports = (list.object?["ports"] as? [[String: Any]])?.compactMap { $0["port"] as? Int } ?? []
        check("port_list mine has the port", !list.isError && ports.contains(port), "\(ports.count) ports")

        // A port none of the run's own holds: bound once by the scenario, closed.
        let free = Self.freePort()
        let unheld = await call("port_holder", ["port": free])
        check(
            "a port no process of the run holds is \"not listed\", never \"free\", in a test run's words",
            unheld.object?["state"] as? String == "not listed" && (unheld.object?["advice"] as? String)?.contains("test run") == true)

        let left = await call("proc_left_behind", ["scope": "all"])
        check("proc_left_behind answers", !left.isError && left.object?["checkout"] is [Any])
        let busiest = await call("proc_list", ["sort": "memory", "limit": 5])
        let named = (busiest.object?["checkout"] as? [[String: Any]]) ?? []
        check("proc_list answers, at most the limit", !busiest.isError && named.count <= 5, "\(named.count) rows")

        let lost = await call("proc_mine", from: "pane-\(UUID().uuidString)")
        check("a pane no window has gets nothing", lost.isError && lost.object == nil)
        let bad = await call("port_holder", ["port": 70_000])
        check("an argument out of range is refused, never guessed", bad.isError)

        Settings.shared.set("activity.agentAccess", .bool(false))
        let off = await listed()
        check("switched off, the tools go", ActivityMCP.names.allSatisfy { !off.contains($0) })
        let refused = await call("port_holder", ["port": port])
        check("and a call is refused", refused.isError)
        Settings.shared.set("activity.agentAccess", nil)

        // Activity's access alone keeps the bridge serving: with every other
        // group's off, turning it off stops the server and on starts it.
        let others = [
            "browser.agentControl", "api.agentControl", "notes.agentAccess", "database.agentAccess", "docker.agentAccess",
            "kubernetes.agentAccess", "terraform.agentAccess",
        ]
        let before = others.map { Settings.shared.fileValue($0) }
        for key in others { Settings.shared.set(key, .bool(false)) }
        check("Activity's access alone keeps the bridge serving", await eventually(5) { BrowserBridge.shared.port != nil })
        Settings.shared.set("activity.agentAccess", .bool(false))
        check("turned off, with nothing else on, the bridge stops", await eventually(5) { BrowserBridge.shared.port == nil })
        Settings.shared.set("activity.agentAccess", nil)
        check("turned on again, it serves for Activity alone", await eventually(5) { BrowserBridge.shared.isServing })
        for (key, value) in zip(others, before) { Settings.shared.set(key, value) }
    }

    /// A TCP port on 127.0.0.1 nothing holds now: bound and closed.
    package static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 1 }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : 1
    }
}
#endif
