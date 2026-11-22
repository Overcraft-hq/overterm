#if E2E
import AppKit

/// A GraphQL request against the echo server's `/graphql`: its schema read
/// by introspection with the request's own URL, the Schema tab, the query
/// completed from it, and the request sent.
extension E2ERunner {
    func apiGraphQLScenario() async {
        let server = E2EEchoServer()
        do { try server.start() } catch { return check("the echo server starts", false, "\(error)") }
        defer { server.stop() }
        let checkout = out("graphql-shop")
        let root = checkout.appendingPathComponent("bruno", isDirectory: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("environments"), withIntermediateDirectories: true)
        try? #"{"version":"1","name":"GraphQL API","type":"collection"}"#.write(to: root.appendingPathComponent("bruno.json"), atomically: true, encoding: .utf8)
        try? "vars {\n  baseUrl: \(server.baseURL)\n}\n".write(to: root.appendingPathComponent("environments/Local.bru"), atomically: true, encoding: .utf8)
        let api = app.apiWorkspace
        api.setRoot(checkout)
        app.showAPIClient(nil)
        check("the collection is read", await eventually(3) { api.collection?.name == "GraphQL API" })
        api.environmentName = "Local"

        guard let draft = try? api.newDraft(in: root, url: "{{baseUrl}}/graphql", kind: .graphql) else { return check("a GraphQL draft", false) }
        app.openInEditor(draft)
        guard let editor = app.editor else { return check("the editor", false) }
        check("New GraphQL Request opens as a request", await eventually(3) { editor.active?.url == draft && editor.active?.request != nil })
        guard let model = editor.active?.request else { return }
        check("it is Bruno's GraphQL request", model.file.requestType == "graphql" && model.file.bodyMode == .graphql && model.isGraphQL)
        check("it has a Schema tab", model.tabs.contains(.schema))

        model.requestTab = .schema
        let read = await eventually(5) {
            if case .loaded(let schema)? = api.graphQLSchema(model.file, at: model.url) { return schema.queryType == "Query" }
            return false
        }
        check("the schema is read by introspection, from the request's URL", read, "\(String(describing: api.graphQLSchema(model.file, at: model.url)))")
        await pause(0.5)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.captureWindow(to: (png as NSString).appendingPathComponent("graphql-schema.png"))
        }
        check(
            "the query completes from it", model.graphQLCompletions(before: "query { user(id: 1) { po") == ["posts"],
            "\(model.graphQLCompletions(before: "query { user(id: 1) { po"))")

        model.update { $0.setBody(.graphql, "query {\n  user(id: 1) {\n    name\n    posts { title }\n  }\n}") }
        model.send()
        check("the query is sent", await eventually(5) { model.result?.response?.status == 200 }, model.result?.error ?? "")
        check(
            "as GraphQL's JSON — the query in it", model.result?.plan?.body.map { String(decoding: $0, as: UTF8.self).contains("posts { title }") } == true)
        check("and the answer is read", model.result?.response?.display.contains("Ada") == true)
        model.requestTab = .body
        await pause(0.5)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.captureWindow(to: (png as NSString).appendingPathComponent("graphql-body.png"))
        }
    }
}
#endif
