#if E2E
import AppKit
import Foundation

/// The Docker page's Apple Containers section against a stand-in
/// `container` (a script answering as 1.7.1 does, writing down every
/// call): never the user's tool. An isolated run without the stand-in
/// finds none, and lists no section for it.
extension E2ERunner {
    func appleContainersChecks() async {
        let page = app.dockerPage
        let apple = page.apple
        AppleContainerCLI.override = nil
        apple.relocate()
        check("an isolated run finds no container tool of the user's", !apple.isInstalled, apple.tool?.path ?? "")
        check("and 7 goes nowhere without it", !page.press("7") && page.section != .apple, "\(page.section)")

        let folder = scratch.appendingPathComponent("apple-container", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent("container")
        do {
            try Self.appleStandIn.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            for (name, text) in [("web", "running"), ("service", "running")] { try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        } catch {
            return check("the stand-in container", false, "\(error)")
        }
        let calls = { ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        var commands: [String] = []
        var asked: [String] = []
        let actions = page.actions
        page.actions?.run = { command, _ in commands.append(command) }
        page.actions?.confirm = { title, _, _, then in
            asked.append(title)
            then()
        }
        let interval = apple.interval
        apple.interval = .milliseconds(300)
        defer {
            page.actions = actions
            apple.interval = interval
            AppleContainerCLI.override = nil
            apple.relocate()
        }

        AppleContainerCLI.override = tool
        apple.relocate()
        check("with the tool there, 7 is Apple Containers", page.press("7") && page.section == .apple, "\(page.section)")
        check(
            "its containers are listed, the running one first",
            await eventually(5) { page.appleContainers.map(\.id) == ["ot-apple-web", "ot-apple-job"] }, "\(page.appleContainers.map(\.id)) \(apple.error ?? "")")
        check("as its service says it runs", apple.service == .running(version: "1.7.1"), "\(String(describing: apple.service))")
        check("images aren't read while containers show", !calls().contains("image list --format json"), "\(calls())")
        page.showDetail = true
        page.appleSelection = ["ot-apple-web"]
        if let web = page.appleDetailed {
            check("a container's detail has Stop, Shell and Logs", page.verbs(for: web).filter { $0.place == .button }.map(\.title) == ["Stop", "Shell in a Tab", "Logs"])
            check("its port opens in the browser", web.ports.first?.url?.absoluteString == "http://127.0.0.1:18080")
            check("a secret in its env is masked", !web.environment.joined().contains("e2e-not-a-secret") && web.environment.contains("MODE=demo"), "\(web.environment)")
        } else {
            check("the selected container's detail", false)
        }
        _ = page.press("e")
        check("e is a shell in it, in a tab", commands.last == tool.path + " exec -it ot-apple-web sh", commands.last ?? "")
        _ = page.press("l")
        check("l shows its log", page.appleDetailTab == .logs)
        check("followed from the tool", await eventually(5) { page.appleSession?.feed.lines.map(\.message) == ["listening on :80"] }, "\(calls())")
        await pause(0.3)

        _ = page.press("s")
        check("s stops it, through the tool", await eventually(5) { calls().contains("stop ot-apple-web") })
        check("and the list follows", await eventually(5) { page.appleDetailed?.state == .stopped }, "\(String(describing: page.appleDetailed?.state))")
        if let web = page.appleDetailed {
            check("a stopped one has no shell", page.verbs(for: web).first { $0.key == "e" }?.unavailable != nil)
        }
        _ = page.press("s")
        check("s again starts it", await eventually(5) { calls().contains("start ot-apple-web") && page.appleDetailed?.state == .running })

        page.appleSelection = ["ot-apple-job"]
        _ = page.press("\u{7F}")
        check("⌫ asks first", asked.last == "Remove “ot-apple-job”?", asked.last ?? "")
        check("then removes it", await eventually(5) { calls().contains("delete --force ot-apple-job") && page.appleContainers.map(\.id) == ["ot-apple-web"] }, "\(calls())")

        page.appleTab = .images
        check("Images are read when shown", await eventually(5) { page.appleImages.map(\.shortName) == ["nginx:alpine"] }, "\(apple.error ?? "")")
        if let nginx = page.appleImages.first {
            check("an image a container runs can't be removed", page.verbs(for: nginx).first { $0.place == .remove }?.unavailable != nil)
        }
        page.appleTab = .containers

        try? "stopped".write(to: folder.appendingPathComponent("service"), atomically: true, encoding: .utf8)
        check("its service stopped, the lists go", await eventually(5) { apple.service == .stopped && apple.containers.isEmpty }, "\(String(describing: apple.service))")
        page.startAppleService()
        check("Start the Service runs it in a tab", commands.last == tool.path + " system start", commands.last ?? "")

        page.section = .containers
        let before = calls().count
        await pause(1)
        check("hidden, it isn't read", calls().count == before, "\(calls().suffix(calls().count - before))")
        page.press("1")
    }

    /// The tool as 1.7.1 answers, from three files: `web` (running or
    /// stopped), `service`, and whether `job` is gone.
    private static let appleStandIn = #"""
        #!/bin/sh
        dir="$(dirname "$0")"
        echo "$*" >> "$dir/calls"
        web="$(cat "$dir/web")"
        container='{"id":"ot-apple-web","configuration":{"id":"ot-apple-web","image":{"reference":"docker.io/library/nginx:alpine"},"initProcess":{"executable":"/docker-entrypoint.sh","arguments":["nginx"],"environment":["MODE=demo","API_TOKEN=e2e-not-a-secret"],"workingDirectory":"/"},"publishedPorts":[{"containerPort":80,"count":1,"hostAddress":"127.0.0.1","hostPort":18080,"proto":"tcp"}],"mounts":[],"labels":{},"platform":{"architecture":"arm64","os":"linux"},"resources":{"cpus":4,"memoryInBytes":1073741824},"creationDate":"2026-11-26T10:12:56Z"},"status":{"state":"'"$web"'","networks":[{"network":"default","hostname":"ot-apple-web","ipv4Address":"192.168.64.2/24"}],"startedDate":"2026-11-26T10:12:57Z"}}'
        job='{"id":"ot-apple-job","configuration":{"id":"ot-apple-job","image":{"reference":"docker.io/library/alpine:latest"},"initProcess":{"executable":"echo","arguments":["hi"]}},"status":{"state":"stopped","networks":[]}}'
        case "$*" in
          "system status --format json")
            if [ "$(cat "$dir/service")" = running ]; then echo '{"status":"running","server":{"version":"1.7.1"}}'; else echo '{"status":"not running"}'; exit 1; fi ;;
          "list --all --format json")
            if [ -f "$dir/job-gone" ]; then echo "[$container]"; else echo "[$container,$job]"; fi ;;
          "image list --format json")
            echo '[{"id":"7fc0","configuration":{"name":"docker.io/library/nginx:alpine","descriptor":{"digest":"sha256:7fc0"}},"variants":[{"platform":{"os":"linux","architecture":"arm64"},"size":29058963}]}]' ;;
          "volume list --format json") echo '[]' ;;
          "stop ot-apple-web") echo stopped > "$dir/web" ;;
          "start ot-apple-web") echo running > "$dir/web" ;;
          "delete --force ot-apple-job") touch "$dir/job-gone" ;;
          "logs --follow -n 500 ot-apple-web") echo "listening on :80"; n=0; while [ $n -lt 40 ]; do sleep 0.05; n=$((n+1)); done ;;
          *) echo "unexpected: $*" >&2; exit 1 ;;
        esac
        """#
}
#endif
