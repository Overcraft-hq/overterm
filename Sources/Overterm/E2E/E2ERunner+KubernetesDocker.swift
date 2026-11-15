import AppKit
import Foundation

/// Stage 4's Docker page (3.12): Run Locally and Scan from a fake-dev pod,
/// against the fake API server and `FakeDockerEngine` — never the user's
/// cluster or Docker. Run Locally reads the pod once and lands on the
/// Docker page's Run window filled in: its image, its plain env, its port
/// on 127.0.0.1, its Secret-backed value and its secret-looking one
/// **asked**, named, their values nowhere — not in the window, not in the
/// command. Run in a Tab is recorded, not typed: a `sh -c` that asks in
/// the tab and passes them by name. Scan lands on the Images section, the
/// pod's image selected on its Vulnerabilities tab and scanned there; an
/// image the engine hasn't is asked before anything is pulled, and Cancel
/// pulls nothing. Nothing but GETs reaches the fake, no Secret among them.
extension E2ERunner {
    func kubernetesDocker(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let socket = "/tmp/ot-e2e-kdocker-\(UUID().uuidString.prefix(6)).sock"
        let engine = FakeDockerEngine(socket: socket)
        do { try engine.start() } catch { return check("the fake engine starts", false, "\(error)") }
        let nginx = engine.addImage("nginx:1.27", size: 20 << 20)
        let docker = DockerModel.shared
        docker.use(DockerEndpoint(address: .unix(socket), context: nil, source: "OVERTERM_DOCKER_HOST"))
        let dockerPage = app.dockerPage
        var ran: [String] = []
        /// The window's actions, made again when the page first opens: Run in a Tab recorded.
        func recordRuns() {
            var actions = app.dockerActions
            actions.run = { command, _ in ran.append(command) }
            dockerPage.actions = actions
        }
        recordRuns()
        let wasShowing = app.store.showingOverlay == .kubernetes
        defer {
            dockerPage.actions = app.dockerActions
            dockerPage.runSpec = nil
            dockerPage.scans.forget(nginx)
            if app.store.openOverlays.contains(.docker) { app.closeOverlay(.docker) }
            docker.use(nil)
            engine.stop()
            page.writeStatus = nil
            if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) }
        }
        if !wasShowing { app.showKubernetesPage() }
        check("the fake engine is reached", await eventually(10) { docker.connection.isRunning }, "\(docker.connection)")

        model.select("fake-dev")
        model.setScope(.namespace("shop"))
        if !page.filter.isEmpty {
            page.filter = ""
            page.applySelector()
        }
        var web = FakeKubeAPI.Pod()
        web.image = "nginx:1.27"
        web.env = ["PORT": "8080", "API_TOKEN": "tok-literal-e2e"]
        web.secretEnv = ["DB_PASSWORD": FakeKubeAPI.SecretKeyRef(name: "db-auth", key: "password")]
        web.ports = [FakeKubeAPI.ContainerPort(8080, name: "http")]
        fake.addPod("local-0", namespace: "shop", web)
        var other = FakeKubeAPI.Pod()
        other.image = "ghcr.io/acme/web:1.4.2"
        fake.addPod("local-1", namespace: "shop", other)
        guard await showKubernetesKind(model, page, "po", row: KubeRowID(namespace: "shop", name: "local-0")) else { return }
        _ = await eventually(10) { model.rows.sorted.contains { $0.id.description == "shop/local-1" } }
        func verb(_ title: String, _ id: String) -> ResourceVerb? { page.verbs(for: [id]).first { $0.title == title } }
        page.selection = ["shop/local-0"]
        fake.forgetRequests()
        let run = verb(KubernetesPageModel.runLocallyTitle, "shop/local-0")
        check("Run Locally is offered on read-only fake-dev: a read", run != nil && run?.unavailable == nil, run?.unavailable ?? "none")
        if let ref = page.ref(for: "shop/local-0") {
            let titles = page.detailVerbs(for: ref).map(\.title)
            check(
                "the pod's detail offers Run Locally and Scan",
                titles.contains(KubernetesPageModel.runLocallyTitle) && titles.contains(KubernetesPageModel.scanImageTitle), "\(titles)")
        }

        // Run Locally: the Docker page's Run window, filled in, secrets asked.
        run?.perform()
        check("it lands on the Docker page", await eventually(10) { self.app.store.showingOverlay == .docker && dockerPage.runSpec != nil })
        recordRuns()
        let spec = dockerPage.runSpec
        check("with the pod's image", spec?.image == "nginx:1.27", spec?.image ?? "none")
        check("its plain env copied", spec?.env == ["PORT=8080"], "\(spec?.env ?? [])")
        check("its port on 127.0.0.1", spec?.ports == ["127.0.0.1:8080:8080"], "\(spec?.ports ?? [])")
        check(
            "the Secret's key and the secret-looking value asked, not copied",
            spec?.asked.map(\.key).sorted() == ["API_TOKEN", "DB_PASSWORD"]
                && spec?.asked.first { $0.key == "DB_PASSWORD" }?.from == "Secret db-auth, key password" && spec?.asked.allSatisfy(\.secret) == true,
            "\(spec?.asked ?? [])")
        check("where it came from said", spec?.notes.first?.contains("pod shop/local-0, container app, in fake-dev · namespace shop") == true, "\(spec?.notes ?? [])")
        let sheet = await sheetLines(10) { $0.contains("Asked in the tab when it runs") }
        check("the Run window shows them asked", sheet.contains { $0.contains("Asked in the tab when it runs") }, "\(sheet)")
        check("naming the Secret", sheet.contains { $0.contains("db-auth") }, "\(sheet)")
        check("no secret value drawn", !sheet.joined(separator: "\n").contains("tok-literal-e2e"), "\(sheet)")
        check(
            "the pod was read once, no Secret", fake.requests.filter { $0.path == "/api/v1/namespaces/shop/pods/local-0" }.count == 1 && !fake.requests.contains { $0.path.contains("/secrets") },
            "\(fake.requests.map(\.path))")
        if let spec { dockerPage.run(spec) }
        check("Run in a Tab is recorded, not typed", await eventually(5) { ran.count == 1 }, "\(ran)")
        let line = ran.first ?? ""
        check(
            "a sh -c that asks in the tab, hidden, and passes them by name",
            line.hasPrefix("sh -c ") && line.contains("read -r DB_PASSWORD") && line.contains("stty -echo") && line.contains("-e DB_PASSWORD")
                && line.contains("-e API_TOKEN") && line.contains("-e PORT=8080") && line.contains("-p 127.0.0.1:8080:8080") && line.contains("export DOCKER_HOST="),
            line)
        check("no secret value in it", !line.contains("tok-literal-e2e"), line)
        check("the Run window closed", dockerPage.runSpec == nil)

        // Scan: the image here — its Vulnerabilities tab, scanned there.
        app.showKubernetesPage()
        page.selection = ["shop/local-0"]
        _ = await eventually(10) { verb(KubernetesPageModel.scanImageTitle, "shop/local-0") != nil }
        verb(KubernetesPageModel.scanImageTitle, "shop/local-0")?.perform()
        check(
            "Scan lands on Docker's Images, the image on its Vulnerabilities tab",
            await eventually(10) {
                self.app.store.showingOverlay == .docker && dockerPage.section == .images && dockerPage.imageSelection == [nginx]
                    && dockerPage.imageTab == .vulnerabilities
            }, "\(dockerPage.section) \(dockerPage.imageSelection) \(dockerPage.imageTab)")
        check("and scanned there, by the engine's name", await eventually(5) { dockerPage.scans.scan(for: nginx)?.image == "nginx:1.27" })

        // An image the engine hasn't: asked first; Cancel pulls nothing.
        app.showKubernetesPage()
        page.selection = ["shop/local-1"]
        // Shown again, the list is read again: the row back first.
        _ = await eventually(10) { verb(KubernetesPageModel.scanImageTitle, "shop/local-1") != nil }
        verb(KubernetesPageModel.scanImageTitle, "shop/local-1")?.perform()
        check(
            "an image not here is asked before it is pulled",
            await eventually(10) { self.sheetTexts().contains { $0.contains("Pull ghcr.io/acme/web:1.4.2 to scan it?") } },
            "\(sheetTexts()) \(String(describing: page.writeStatus)) \(dockerPage.error ?? "")")
        check("naming the pod that runs it", sheetTexts().contains { $0.contains("pod shop/local-1 (container app, in fake-dev) runs it") }, "\(sheetTexts())")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        _ = await eventually(3) { self.window.attachedSheet == nil }
        await pause(0.3)
        check("Cancel pulls nothing", dockerPage.pulls["ghcr.io/acme/web:1.4.2"] == nil, "\(dockerPage.pulls.keys)")
        check("only GETs reached the fake, no Secret", fake.writes.isEmpty && !fake.requests.contains { $0.path.contains("/secrets") }, "\(fake.writes)")
        app.showKubernetesPage()
    }

    /// What the sheet over the window says, read off its pixels (a SwiftUI
    /// sheet has no text fields to walk): once `match` is among it, or the
    /// last read when the time is up.
    private func sheetLines(_ timeout: TimeInterval, _ match: @escaping (String) -> Bool) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var lines: [String] = []
        repeat {
            if let sheet = window.attachedSheet, let image = app.windowImage(sheet) {
                let pixels = WindowPixels(image: image)
                let size = sheet.frame.size
                lines = await Task.detached { Self.recognize(pixels, size: size) }.value.map(\.text)
                if lines.contains(where: match) { return lines }
            }
            await pause(0.3)
        } while Date() < deadline
        return lines
    }
}
