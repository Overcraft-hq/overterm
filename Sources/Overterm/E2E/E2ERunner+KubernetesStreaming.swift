import AppKit
import Foundation

/// Stage 4's streaming lists (docs/design/kubernetes/analysis.md, Sections
/// 1 and 4): on `fake-dev`, whose server says 1.34, the Pods list the page
/// opened on was a streaming list — a watch with `sendInitialEvents`,
/// `resourceVersionMatch=NotOlderThan` and bookmarks, as a Table, no list
/// before it. The fake then says 1.33 with the gate off: read again (a
/// retry reads the version first), the page lists and watches, the same
/// rows drawn. Back on 1.34 it streams again. Reads only.
extension E2ERunner {
    func kubernetesStreamingLists(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let path = "/api/v1/namespaces/shop/pods"
        func streamed(_ requests: ArraySlice<FakeKubeAPI.Request>) -> [FakeKubeAPI.Request] {
            requests.filter {
                $0.path == path && $0.isWatch && $0.query["sendInitialEvents"] == "true" && $0.query["resourceVersionMatch"] == "NotOlderThan"
                    && $0.query["allowWatchBookmarks"] == "true" && $0.query["resourceVersion"] == nil
            }
        }
        func listed(_ requests: ArraySlice<FakeKubeAPI.Request>) -> [FakeKubeAPI.Request] {
            requests.filter { $0.path == path && !$0.isWatch }
        }
        // The rows and their cells but Age (counted while the run goes on).
        func shown() -> [String] {
            let age = model.rows.columns.firstIndex { $0.name == "Age" }
            return model.rows.sorted.map { row in "\(row.id) \(row.cells.indices.filter { $0 != age }.map { row.cells[$0] })" }
        }

        let first = fake.requests[...]
        check("a 1.34 server's list is a streaming list", streamed(first).count == 1, "\(first.filter { $0.path == path })")
        check("as a Table, rows only", streamed(first).first.map { $0.accept.contains("as=Table") && $0.query["includeObject"] == "None" } == true)
        check("with no list before it", listed(first).isEmpty, "\(listed(first))")
        check("the context is known to serve them", model.streamingLists.state(of: "fake-dev") == .served)
        let rows = shown()

        // A server that doesn't: 1.33, the gate off.
        fake.minor = "33"
        fake.streamingLists = false
        let mark = fake.requests.count
        model.retry()
        check(
            "read again, a 1.33 is listed and watched",
            await eventually(15) {
                model.version?.minorNumber == 33 && model.listState == .live && listed(fake.requests[mark...]).count == 1
                    && fake.requests[mark...].contains { $0.path == path && $0.isWatch && $0.query["resourceVersion"] != nil }
            }, "\(fake.requests[mark...].filter { $0.path == path }) \(model.listState)")
        let after = fake.requests[mark...]
        check("never asked for a streaming list", after.allSatisfy { $0.query["sendInitialEvents"] == nil }, "\(after.filter { $0.path == path })")
        check(
            "its watch from the list's version",
            after.contains { $0.path == path && $0.isWatch && $0.query["resourceVersion"] != nil && $0.query["sendInitialEvents"] == nil })
        check("the same rows", shown() == rows, "\(shown()) \(rows)")
        check("drawn", await shownText(15) { $0.contains("worker-5c") } != nil)
        check("the context isn't served them", model.streamingLists.state(of: "fake-dev") == .notServed)

        // 1.34 again: streamed again, the same rows.
        fake.minor = "34"
        fake.streamingLists = true
        let again = fake.requests.count
        model.retry()
        check(
            "back on 1.34 it streams again",
            await eventually(15) { model.listState == .live && streamed(fake.requests[again...]).count == 1 && shown() == rows },
            "\(fake.requests[again...].filter { $0.path == path })")
        check("and lists nothing", listed(fake.requests[again...]).isEmpty)
        check("it wrote nothing", fake.writes.isEmpty)
    }
}
