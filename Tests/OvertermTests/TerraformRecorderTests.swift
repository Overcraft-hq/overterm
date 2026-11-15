import XCTest

@testable import Overterm

/// The recording wrapper, in front of a stand-in: what it records, what it
/// passes on, and what it never writes down.
final class TerraformRecorderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-recorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func run(_ executable: URL, _ arguments: [String], cwd: URL, environment: [String: String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        let out = folder.appendingPathComponent("out-\(UUID().uuidString)")
        let err = folder.appendingPathComponent("err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, try String(contentsOf: out, encoding: .utf8), try String(contentsOf: err, encoding: .utf8))
    }

    func testACallIsRecordedThenRunAsIs() throws {
        let standIn = folder.appendingPathComponent("stand-in/terraform")
        try TerraformRecorder.writeStandIn(at: standIn, stdout: "{\"@level\":\"info\"}\n", stderr: "acme warning\n", exitCode: 2)
        let recorder = try TerraformRecorder.make(in: folder.appendingPathComponent("recorder"), target: standIn.path)
        XCTAssertEqual(recorder.wrapper.lastPathComponent, "terraform")

        let root = folder.appendingPathComponent("envs/acme prod", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scratch = try TerraformGuards.prepareScratch(at: folder.appendingPathComponent("scratch"))
        var environment = scratch.environment
        environment["TF_WORKSPACE"] = "acme-stage"
        environment["TF_INPUT"] = "0"
        // Hostile and secret: names recorded, never values.
        environment["TF_CLI_ARGS_apply"] = "-auto-approve"
        environment["TF_VAR_db_password"] = "acme-hunter2-SECRET"
        environment["TF_TOKEN_app_terraform_io"] = "tok-acme-123"
        let arguments = ["plan", "-input=false", "-out=/tmp/a b/plan", "-var-file=it's.tfvars", "", "line\nbreak", "-target=aws_instance.web[\"a b\"]"]

        let (status, out, err) = try run(recorder.wrapper, arguments, cwd: root, environment: environment)
        XCTAssertEqual(status, 2)
        XCTAssertEqual(out, "{\"@level\":\"info\"}\n")
        XCTAssertEqual(err, "acme warning\n")

        let calls = recorder.calls()
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.arguments, arguments)
        XCTAssertEqual(call.subcommand, "plan")
        XCTAssertEqual(call.cwd, try XCTUnwrap(realpath(root.path, nil).map { String(cString: $0) }))
        XCTAssertTrue(call.names.contains("TF_CLI_ARGS_apply"))
        XCTAssertTrue(call.names.contains("TF_VAR_db_password"))
        XCTAssertFalse(call.names.contains("SHLVL"))
        XCTAssertEqual(call.values["TF_WORKSPACE"], "acme-stage")
        XCTAssertEqual(call.values["TF_INPUT"], "0")
        XCTAssertEqual(call.values["HOME"], scratch.home.path)
        XCTAssertEqual(call.values["CHECKPOINT_DISABLE"], "1")
        XCTAssertNil(call.values["TF_CLI_ARGS_apply"])
        XCTAssertNil(call.values["TF_DATA_DIR"])

        // No value but those few reached the disk.
        let records = FileManager.default.enumerator(at: recorder.records, includingPropertiesForKeys: nil)
        while let file = records?.nextObject() as? URL {
            let data = (try? Data(contentsOf: file)) ?? Data()
            for sentinel in ["acme-hunter2-SECRET", "tok-acme-123", "-auto-approve"] {
                XCTAssertNil(data.range(of: Data(sentinel.utf8)), "\(sentinel) in \(file.lastPathComponent)")
            }
        }

        recorder.reset()
        XCTAssertEqual(recorder.calls(), [])
    }

    func testCallsComeInTheOrderTheyWereMade() throws {
        let standIn = folder.appendingPathComponent("stand-in/terraform")
        try TerraformRecorder.writeStandIn(at: standIn)
        let recorder = try TerraformRecorder.make(in: folder.appendingPathComponent("recorder"), target: standIn.path)
        let scratch = try TerraformGuards.prepareScratch(at: folder.appendingPathComponent("scratch"))
        for verb in ["version", "init", "plan", "show"] {
            XCTAssertEqual(try run(recorder.wrapper, [verb], cwd: folder, environment: scratch.environment).0, 0)
        }
        _ = try run(recorder.wrapper, [], cwd: folder, environment: scratch.environment)
        XCTAssertEqual(recorder.calls().map(\.arguments), [["version"], ["init"], ["plan"], ["show"], []])
    }

    func testTheWrapperIsPrivateAndQuotesItsPaths() throws {
        let target = folder.appendingPathComponent("it's here/terraform")
        try TerraformRecorder.writeStandIn(at: target, stdout: "ok\n")
        let recorder = try TerraformRecorder.make(in: folder.appendingPathComponent("rec $HOME `x`"), target: target.path)
        let mode = try FileManager.default.attributesOfItem(atPath: recorder.wrapper.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        XCTAssertEqual(try run(recorder.wrapper, ["version"], cwd: folder, environment: ["PATH": "/usr/bin:/bin"]).1, "ok\n")
        XCTAssertEqual(recorder.calls().count, 1)
        XCTAssertThrowsError(try TerraformRecorder.make(in: folder, target: "terraform"))
    }
}
