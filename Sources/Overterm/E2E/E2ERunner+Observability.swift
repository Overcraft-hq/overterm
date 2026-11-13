import AppKit

/// Prometheus, Loki and Tempo in the Database panel, against the fake of
/// their APIs (E2EObservabilityServer) — a metric graphed, log lines
/// followed live, a log line's trace opened as its waterfall.
extension E2ERunner {
    func observabilityScenario() async {
        let server = E2EObservabilityServer()
        do {
            try server.start()
        } catch {
            return check("the fake servers start", false, "\(error)")
        }
        defer { server.stop() }
        let model = DatabaseModel.shared
        let prometheus = server.connection(.prometheus, name: "Metrics")
        let loki = server.connection(.loki, name: "Logs")
        let tempo = server.connection(.tempo, name: "Traces")
        for connection in [prometheus, loki, tempo] { try? model.store.save(connection, password: nil) }
        app.showDatabase(nil)

        // The panel: each opens, its names read.
        for connection in [prometheus, loki, tempo] {
            model.expanded.insert(connection.id.uuidString)
            model.expanded.insert("\(connection.id.uuidString)/names")
            let session = model.session(connection)
            await session.open()
            check("\(connection.kind.title) connects", session.state == .open, "\(session.state)")
            await session.observabilityCatalog().load()
        }
        check(
            "Prometheus lists its metrics", model.session(prometheus).observabilityCatalog().names.contains("http_requests_total"),
            "\(model.session(prometheus).observabilityCatalog().names)")
        let lokiCatalog = model.session(loki).observabilityCatalog()
        await lokiCatalog.loadValues("app")
        model.expanded.insert("\(loki.id.uuidString)/names/app")
        check("a Loki label's values", lokiCatalog.values["app"] == ["api", "worker"])

        // A metric graphed, from the panel.
        model.session(prometheus).range = .m15
        app.runInDatabaseConsole(prometheus, "sum(rate(http_requests_total[5m])) by (code)")
        guard let editor = app.editor else { return check("the editor", false) }
        guard await eventually(5, { editor.active?.sqlConsole?.connection?.id == prometheus.id }), let promConsole = editor.active?.sqlConsole else {
            return check("the Prometheus console opens", false)
        }
        let graphed = await eventually(5) {
            if case .series(let series)? = promConsole.current?.result?.payload { return series.count == 2 }
            return false
        }
        check("a PromQL query graphs its series", graphed, "\(String(describing: promConsole.current?.error))")
        check("the tab is named after the query", promConsole.current.map { SQLConsoleView.title($0, index: 0, kind: .prometheus) } == "sum")
        await pause(0.8)
        dumpObservability("prometheus")

        // Log lines, then followed live.
        app.runInDatabaseConsole(loki, "{app=~\".+\"}")
        guard await eventually(5, { editor.active?.sqlConsole?.connection?.id == loki.id }), let lokiConsole = editor.active?.sqlConsole else {
            return check("the Loki console opens", false)
        }
        let logged = await eventually(5) {
            if case .logs(let lines)? = lokiConsole.current?.result?.payload { return lines.count == 3 }
            return false
        }
        check("a LogQL query lists its lines, newest first", logged, "\(String(describing: lokiConsole.current?.error))")
        await pause(0.6)
        dumpObservability("loki")
        if let run = lokiConsole.current {
            lokiConsole.follow(run)
            let tailed = await eventually(6) {
                if case .logs(let lines)? = lokiConsole.current?.result?.payload { return lines.first?.line == "tailed line" }
                return false
            }
            check("Live puts new lines on top", tailed)
            lokiConsole.stopFollowing()
            check("and stops when asked", lokiConsole.live == nil)
        }

        // A log line's trace, opened in Tempo's console as its waterfall.
        app.openTrace(E2EObservabilityServer.traceID)
        guard await eventually(5, { editor.active?.sqlConsole?.connection?.id == tempo.id }), let tempoConsole = editor.active?.sqlConsole else {
            return check("a log line's trace opens Tempo's console", false)
        }
        let traced = await eventually(5) {
            if case .trace(let trace)? = tempoConsole.current?.result?.payload { return trace.spans.count == 3 }
            return false
        }
        check("its waterfall: the trace's spans", traced, "\(String(describing: tempoConsole.current?.error))")
        await pause(0.6)
        dumpObservability("tempo-trace")
        tempoConsole.run(["{ resource.service.name = \"api\" }"])
        let searched = await eventually(5) {
            if case .traces(let traces)? = tempoConsole.current?.result?.payload { return traces.count == 2 }
            return false
        }
        check("a TraceQL search lists traces", searched)

        // Completion: a metric's name from the catalog.
        editor.replaceText(of: editor.active!, with: "")
        promConsole.use(prometheus)
        app.runInDatabaseConsole(prometheus, "up")
        _ = await eventually(5) { editor.active?.sqlConsole?.connection?.id == prometheus.id }
        editor.replaceText(of: editor.active!, with: "rate(http_re")
        editor.textView.setSelectedRange(NSRange(location: 12, length: 0))
        _ = editor.updateSQLCompletion()
        let names = editor.completion.map { state in state.shown.map { state.candidates[$0].label } } ?? []
        check("a metric completes from the catalog", names.first == "http_requests_total", "\(names)")
        editor.dismissCompletion()

        // A query saved from the console sits under its connection, and runs from there.
        model.save("API errors", text: "{app=\"api\"} |= \"error\"", on: loki.id)
        model.expanded.insert("\(loki.id.uuidString)/saved")
        check("a saved query is listed under its connection", model.saved(for: loki.id).map(\.name) == ["API errors"])
        app.runInDatabaseConsole(loki, model.saved(for: loki.id)[0].text)
        let ranSaved = await eventually(5) { editor.active?.sqlConsole?.current?.sql == "{app=\"api\"} |= \"error\"" }
        check("and runs in its console", ranSaved)
        await pause(0.6)
        dumpObservability("saved")

        for connection in [prometheus, loki, tempo] {
            await model.session(connection).close()
            try? model.delete(connection)
        }
    }

    private func dumpObservability(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !folder.isEmpty else { return }
        app.captureWindow(to: (folder as NSString).appendingPathComponent("\(name).png"))
    }
}
