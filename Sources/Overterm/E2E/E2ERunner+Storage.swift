import AppKit

/// Buckets in the Database panel, against the S3 server of
/// Scripts/database-test-servers.sh (RustFS on :59000). Without it running,
/// the scenario says so and checks nothing.
extension E2ERunner {
    func storageScenario() async {
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:59000/")!)
        probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            print("E2E INFO storage: no S3 server on :59000 — Scripts/database-test-servers.sh starts one")
            return
        }
        let model = DatabaseModel.shared
        var connection = DatabaseConnection(name: "Local S3", kind: .s3)
        connection.apply(.minio)
        connection.host = "127.0.0.1"
        connection.port = 59000
        connection.user = "otadmin"
        try? model.store.save(connection, password: "otpass12345")
        app.showDatabase(nil)
        let session = model.storage(connection)
        await session.open()
        check("an S3 connection opens", session.state == .open, "\(session.state)")

        let bucket = "ot-e2e-\(UInt32.random(in: 0...UInt32.max))"
        await session.newBucket(bucket)
        check("New Bucket makes one", session.buckets.contains { $0.name == bucket }, "\(session.buckets.map(\.name)) \(session.lastError ?? "")")

        // Files and a folder from Finder, uploaded with their progress.
        let local = scratch.appendingPathComponent("upload", isDirectory: true)
        try? FileManager.default.createDirectory(at: local.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try? "id,city\n1,İzmir\n2,\"New York, NY\"\n".write(to: local.appendingPathComponent("cities.csv"), atomically: true, encoding: .utf8)
        try? "first line\nsecond line\n".write(to: local.appendingPathComponent("logs/app.log"), atomically: true, encoding: .utf8)
        await session.upload([local.appendingPathComponent("cities.csv"), local.appendingPathComponent("logs")], to: bucket, prefix: "")
        await session.load(bucket, "")
        let root = session.listing(bucket, "")
        check("a dropped file and folder are uploaded", root?.objects.map(\.key) == ["cities.csv"] && root?.folders == ["logs/"], "\(String(describing: root))")
        check("each with its progress, done", session.transfers.allSatisfy { $0.done && $0.error == nil }, "\(session.transfers)")

        // A CSV opens as rows; a log as text.
        if let csv = root?.objects.first {
            app.openStorageObject(session, bucket, csv)
            check("a file opens in the right-hand pane", app.rightPane.mode == .object && app.diffItem?.isCollapsed == false)
            let rows = await eventually(5) {
                if case .table(let result) = self.app.storageObject.preview { return result.rows == [["1", "İzmir"], ["2", "New York, NY"]] }
                return false
            }
            check("a CSV previews as rows", rows, "\(app.storageObject.preview) \(app.storageObject.phase)")
            if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
                model.expanded.formUnion([connection.id.uuidString, "\(connection.id.uuidString)/\(bucket)"])
                await pause(0.8)
                app.captureWindow(to: png)
            }
        }
        await session.load(bucket, "logs/")
        if let log = session.listing(bucket, "logs/")?.objects.first {
            app.openStorageObject(session, bucket, log)
            check(
                "a log previews as text",
                await eventually(5) { self.app.storageObject.preview == .text("first line\nsecond line\n", truncated: false) })
        }

        // A new folder, then the folder deleted with what is in it.
        await session.newFolder("empty", in: bucket, prefix: "")
        check("New Folder makes one", session.listing(bucket, "")?.folders.contains("empty/") == true, "\(String(describing: session.listing(bucket, "")))")
        let keys = await session.keys(for: "logs/", in: bucket)
        check("a folder's delete takes every file in it", keys == ["logs/app.log"], "\(keys)")
        await session.delete(keys, in: bucket, refreshing: "")
        check("and it goes", session.listing(bucket, "")?.folders.contains("logs/") == false)

        // Read-only: nothing is uploaded or deleted.
        var reader = connection
        reader.id = UUID()
        reader.readOnly = true
        try? model.store.save(reader, password: "otpass12345")
        let readOnly = model.storage(reader)
        await readOnly.open()
        await readOnly.upload([local.appendingPathComponent("cities.csv")], to: bucket, prefix: "again/")
        check("a read-only connection uploads nothing", readOnly.lastError == "This connection only reads." && readOnly.transfers.isEmpty)

        let all = await session.keys(for: "", in: bucket)
        await session.delete(all, in: bucket, refreshing: "")
    }
}
