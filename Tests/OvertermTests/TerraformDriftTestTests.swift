import XCTest

@testable import Overterm

/// Stage 2d (analysis 2.6, 2.9, 5.3, 5.10, D-19): drift — the
/// refresh-only plan, its age and staleness, Accept into State as the
/// apply of that plan with every check — and `terraform test`: the one
/// line it is run as, which files are mocked, the stream folded into
/// runs and failures at their lines, the run behind the recording
/// wrapper (no credential when every provider is mocked), and `tf_test`'s
/// answer. No real terraform runs.
final class TerraformDriftCommandTests: XCTestCase {
    private let out = "/tmp/ot-tf-501-77/1f2e/plan"

    func testTheDriftCheckIsAPlanWithRefreshOnly() throws {
        let line = try XCTUnwrap(TerraformCommands.plan(out: out, mode: .refreshOnly))
        XCTAssertEqual(
            line, ["plan", "-input=false", "-json", "-detailed-exitcode", "-lock=true", "-lock-timeout=10s", "-out=" + out, "-refresh-only"],
            "locked like any plan, written to the run folder")
        XCTAssertTrue(TerraformCommands.isPlan(line))
        XCTAssertNil(TerraformCommands.refusal(line))
        let withVars = try XCTUnwrap(TerraformCommands.plan(out: out, varFiles: ["dev.tfvars"], mode: .refreshOnly))
        XCTAssertTrue(TerraformCommands.isPlan(withVars), "with the person's plan flags (4.3)")
        XCTAssertFalse(TerraformCommands.isPlan(line + ["-destroy"]), "one mode at a time")
        XCTAssertFalse(TerraformCommands.isPlan(Array(line.dropLast()) + ["-refresh=false"]))
        XCTAssertEqual(TerraformPlanMode.refreshOnly.verb, .refreshOnlyApply)
        XCTAssertEqual(TerraformPlanMode.normal.verb, .apply)
        // Accepting it is the one apply, of the plan's descriptor: never `apply -refresh-only`.
        XCTAssertNotNil(TerraformCommands.refusal(["apply", "-refresh-only", "-auto-approve"]))
        XCTAssertNotNil(TerraformCommands.refusal(["refresh"]))
    }

    func testTheTestLines() throws {
        XCTAssertEqual(TerraformCommands.test(), ["test", "-json", "-no-color"])
        XCTAssertEqual(TerraformCommands.test(file: "tests/acme.tftest.hcl"), ["test", "-json", "-no-color", "-filter=tests/acme.tftest.hcl"])
        for built in [TerraformCommands.test(), TerraformCommands.test(file: "acme.tftest.hcl"), TerraformCommands.test(file: "tests/a b.tftest.json")] {
            let line = try XCTUnwrap(built)
            XCTAssertNil(TerraformCommands.refusal(line), "\(line)")
            XCTAssertTrue(TerraformCommands.isBuilt(line))
        }
        for file in ["../acme.tftest.hcl", "/tmp/acme.tftest.hcl", "-verbose.tftest.hcl", "tests/acme.tf", "tests/./acme.tftest.hcl", "tests//a.tftest.hcl", "a\n.tftest.hcl", ""] {
            XCTAssertNil(TerraformCommands.test(file: file), file.debugDescription)
        }
        let refused: [[String]] = [
            ["test"], ["test", "-json"], ["test", "-json", "-no-color", "-verbose"], ["test", "-json", "-no-color", "-var=a=1"],
            ["test", "-json", "-no-color", "-cloud-run=app.terraform.io/acme/net"], ["test", "-json", "-no-color", "-filter=../x.tftest.hcl"],
            ["test", "-json", "-no-color", "-var-file=prod.tfvars"], ["-chdir=envs/prod", "test", "-json", "-no-color"],
            ["test", "-json", "-no-color", "-filter=a.tftest.hcl", "-verbose"],
        ]
        for line in refused { XCTAssertNotNil(TerraformCommands.refusal(line), "\(line)") }
    }

    func testAMockedTestRunsAnywhereARealOneIsAWrite() {
        for rootClass in TerraformClass.allCases {
            XCTAssertNil(TerraformProcessCheck.refused(.test, rootClass: rootClass), "\(rootClass)")
        }
        // Writable unless its entry says no, production too: a real test is then asked, never locked.
        for rootClass in TerraformClass.allCases {
            XCTAssertNil(TerraformProcessCheck.refused(.testRealProviders, rootClass: rootClass), "\(rootClass)")
            XCTAssertNotNil(TerraformProcessCheck.refused(.testRealProviders, rootClass: rootClass, writable: false), "\(rootClass)")
        }
    }
}

final class TerraformTestFilesTests: XCTestCase {
    static let file = """
        mock_provider "random" {}

        provider "aws" {
          region = "eu-west-1"
        }

        run "acme_named" {
          command = plan

          assert {
            condition     = terraform_data.acme.input == "acme-dev"
            error_message = "the name is acme-dev"
          }
        }

        run "acme_net" {
          module {
            source = "./modules/acme-net"
          }
        }

        """

    func testAFileIsScanned() {
        let facts = TerraformTestFiles.scan(Self.file, path: "tests/acme.tftest.hcl")
        XCTAssertEqual(facts.runs, [.init(name: "acme_named", line: 7), .init(name: "acme_net", line: 16)])
        XCTAssertEqual(facts.mocked, ["random"])
        XCTAssertEqual(facts.providers, ["aws"])
        XCTAssertEqual(facts.moduleSources, ["./modules/acme-net"])
        XCTAssertEqual(TerraformTestFiles.scan("{", path: "tests/x.tftest.json").providers.count, 1, "a JSON test file isn't read: never counted mocked")
    }

    func testOnlyEveryProviderMockedIsMocked() {
        let mocked = TerraformTestFiles.Facts(path: "a.tftest.hcl", mocked: ["random", "aws"])
        XCTAssertEqual(TerraformTestFiles.mocking(mocked, providers: ["terraform", "random", "aws"]), .mocked)
        XCTAssertEqual(TerraformTestFiles.mocking(.init(path: "b.tftest.hcl"), providers: ["terraform"]), .mocked, "the builtin provider needs no mock")
        XCTAssertEqual(TerraformTestFiles.mocking(.init(path: "c.tftest.hcl", mocked: ["random"]), providers: ["random", "aws"]), .real("not mocked: aws"))
        XCTAssertEqual(
            TerraformTestFiles.mocking(.init(path: "d.tftest.hcl", mocked: ["random"], providers: ["google"]), providers: ["random"]), .real("not mocked: google"),
            "a provider block in the test file is real")
        if case .real(let why) = TerraformTestFiles.mocking(mocked, providers: nil) {
            XCTAssertTrue(why.contains("outside the checkout"), why)
        } else {
            XCTFail("unknown providers are never mocked")
        }
        XCTAssertFalse(TerraformTestFiles.mocking([mocked, .init(path: "e.tftest.hcl")]) { _ in ["aws"] }.isMocked, "one file with a real provider")
    }

    func testTheRootsFilesAndProvidersAreRead() throws {
        let checkout = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: checkout) }
        let root = checkout.appendingPathComponent("envs/dev", isDirectory: true)
        let files: [String: String] = [
            "envs/dev/main.tf": "resource \"random_pet\" \"acme\" {}\nmodule \"net\" {\n  source = \"../../modules/acme-net\"\n}\n",
            "envs/dev/acme.tftest.hcl": "mock_provider \"random\" {}\nmock_provider \"aws\" {}\nrun \"a\" {}\n",
            "envs/dev/tests/globex.tftest.hcl": "mock_provider \"random\" {}\nrun \"b\" {}\n",
            "envs/dev/tests/notes.txt": "",
            "modules/acme-net/main.tf": "resource \"aws_vpc\" \"acme\" {}\n",
        ]
        for (path, text) in files {
            let url = checkout.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(TerraformTestFiles.list(root: root), ["acme.tftest.hcl", "tests/globex.tftest.hcl"])
        XCTAssertEqual(try TerraformTestFiles.reach(root, checkout: checkout).get().providers, ["random", "aws"])
        let all = TerraformTestFiles.read(root: root, checkout: checkout, files: nil)
        XCTAssertEqual(all.files.map(\.path), ["acme.tftest.hcl", "tests/globex.tftest.hcl"])
        XCTAssertEqual(all.mocking, .real("tests/globex.tftest.hcl: not mocked: aws"), "the module's aws isn't mocked there")
        XCTAssertTrue(all.complete)
        let one = TerraformTestFiles.read(root: root, checkout: checkout, files: ["acme.tftest.hcl"])
        XCTAssertEqual(one.mocking, .mocked)
        XCTAssertEqual(one.providerNames, ["random", "aws"])
        // A module from outside the checkout: its providers can't be told.
        try "module \"x\" {\n  source = \"git::https://example.test/acme.git\"\n}\n".write(
            to: root.appendingPathComponent("remote.tf"), atomically: true, encoding: .utf8)
        guard case .failure(let unread) = TerraformTestFiles.reach(root, checkout: checkout) else { return XCTFail("a remote module is never known") }
        XCTAssertTrue(unread.why.contains("outside the checkout"), unread.why)
        XCTAssertFalse(TerraformTestFiles.read(root: root, checkout: checkout, files: ["acme.tftest.hcl"]).mocking.isMocked)
    }

    // MARK: What leans toward "mocked" never does (review of 2d)

    private func write(_ files: [String: String], in checkout: URL) throws {
        for (path, text) in files {
            let url = checkout.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func sandbox() -> URL {
        let checkout = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: checkout) }
        return checkout
    }

    /// An aliased mock covers only the runs that map it: the default
    /// provider every other run starts is real.
    func testAnAliasedMockMocksNothingByDefault() throws {
        let aliased = "mock_provider \"aws\" {\n  alias = \"fake\"\n}\n\nrun \"mapped\" {\n  providers = {\n    aws = aws.fake\n  }\n}\n\nrun \"unmocked\" {}\n"
        let facts = TerraformTestFiles.scan(aliased, path: "tests/acme.tftest.hcl")
        XCTAssertEqual(facts.mocked, [])
        XCTAssertEqual(facts.aliasedMocks, ["aws"])
        XCTAssertEqual(TerraformTestFiles.mocking(facts, providers: ["aws"]), .real("not mocked: aws"))
        let checkout = sandbox()
        try write(["envs/dev/main.tf": "resource \"aws_s3_bucket\" \"acme\" {}\n", "envs/dev/tests/acme.tftest.hcl": aliased], in: checkout)
        let read = TerraformTestFiles.read(root: checkout.appendingPathComponent("envs/dev"), checkout: checkout, files: nil)
        XCTAssertEqual(read.mocking, .real("tests/acme.tftest.hcl: not mocked: aws"))
        // The unaliased one does mock it.
        let plain = TerraformTestFiles.scan("mock_provider \"aws\" {}\nrun \"a\" {}\n", path: "a.tftest.hcl")
        XCTAssertEqual(TerraformTestFiles.mocking(plain, providers: ["aws"]), .mocked)
    }

    /// A test file that would run but wasn't read, JSON configuration, a
    /// file past the bound: real, never mocked.
    func testWhatIsntReadIsReal() throws {
        let checkout = sandbox()
        let root = checkout.appendingPathComponent("envs/dev")
        try write(
            [
                "envs/dev/main.tf": "resource \"terraform_data\" \"acme\" {}\n",
                "envs/dev/tests/a.tftest.hcl": "run \"a\" {}\n",
                "envs/dev/tests/big.tftest.hcl": "run \"b\" {}\n" + String(repeating: "# acme\n", count: (TerraformTestFiles.maxBytes / 7) + 10),
            ], in: checkout)
        let big = TerraformTestFiles.read(root: root, checkout: checkout, files: nil)
        XCTAssertEqual(big.unread, ["tests/big.tftest.hcl"])
        XCTAssertFalse(big.complete)
        guard case .real(let why) = big.mocking else { return XCTFail("an unread test file is never mocked") }
        XCTAssertTrue(why.contains("couldn't be read"), why)
        try FileManager.default.removeItem(at: root.appendingPathComponent("tests/big.tftest.hcl"))
        XCTAssertEqual(TerraformTestFiles.read(root: root, checkout: checkout, files: nil).mocking, .mocked)
        // A provider declared only in JSON configuration.
        try write(["envs/dev/extra.tf.json": #"{"resource":{"aws_s3_bucket":{"acme":{}}}}"#], in: checkout)
        guard case .real(let json) = TerraformTestFiles.read(root: root, checkout: checkout, files: nil).mocking else { return XCTFail("JSON configuration") }
        XCTAssertTrue(json.contains("JSON configuration"), json)
        try FileManager.default.removeItem(at: root.appendingPathComponent("extra.tf.json"))
        // A configuration file past the bound.
        try write(["envs/dev/huge.tf": String(repeating: "# acme\n", count: (TerraformRootGuess.maxBytesPerFile / 7) + 10)], in: checkout)
        XCTAssertFalse(TerraformTestFiles.read(root: root, checkout: checkout, files: nil).mocking.isMocked)
        // A missing file given: nothing to run, not "unread".
        try FileManager.default.removeItem(at: root.appendingPathComponent("huge.tf"))
        let missing = TerraformTestFiles.read(root: root, checkout: checkout, files: ["tests/none.tftest.hcl"])
        XCTAssertTrue(missing.files.isEmpty && missing.unread.isEmpty)
    }

    /// Local modules are followed past the first level, bounded.
    func testNestedLocalModulesAreFollowed() throws {
        let checkout = sandbox()
        let root = checkout.appendingPathComponent("envs/dev")
        try write(
            [
                "envs/dev/main.tf": "resource \"terraform_data\" \"acme\" {}\nmodule \"a\" {\n  source = \"../../modules/a\"\n}\n",
                "envs/dev/tests/acme.tftest.hcl": "run \"a\" {}\n",
                "modules/a/main.tf": "module \"b\" {\n  source = \"../b\"\n}\n",
                "modules/b/main.tf": "data \"external\" \"acme\" {\n  program = [\"/bin/echo\"]\n}\n",
            ], in: checkout)
        let reach = try TerraformTestFiles.reach(root, checkout: checkout).get()
        XCTAssertEqual(reach.providers, ["terraform", "external"], "two levels down")
        XCTAssertEqual(reach.risks.map(\.kind), [.command])
        let read = TerraformTestFiles.read(root: root, checkout: checkout, files: nil)
        guard case .real(let why) = read.mocking else { return XCTFail("b's external isn't mocked") }
        XCTAssertTrue(why.contains("not mocked: external"), why)
        XCTAssertTrue(read.providerNames.contains("external"))
        // Mocked, it still runs nothing it doesn't say: the command is a risk whatever is mocked.
        try write(["envs/dev/tests/acme.tftest.hcl": "mock_provider \"external\" {}\nrun \"a\" {}\n"], in: checkout)
        guard case .real(let risky) = TerraformTestFiles.read(root: root, checkout: checkout, files: nil).mocking else { return XCTFail("a command") }
        XCTAssertTrue(risky.contains("runs a command"), risky)
        // A chain deeper than the bound: not all read.
        var chain: [String: String] = ["envs/dev/main.tf": "module \"m0\" {\n  source = \"../../chain/m0\"\n}\n"]
        for level in 0...TerraformTestFiles.maxDepth {
            chain["chain/m\(level)/main.tf"] = "module \"next\" {\n  source = \"../m\(level + 1)\"\n}\n"
        }
        chain["chain/m\(TerraformTestFiles.maxDepth + 1)/main.tf"] = "resource \"terraform_data\" \"x\" {}\n"
        try write(chain, in: checkout)
        guard case .failure(let deep) = TerraformTestFiles.reach(root, checkout: checkout) else { return XCTFail("past the bound is never known") }
        XCTAssertTrue(deep.why.contains("deeper"), deep.why)
        XCTAssertFalse(TerraformTestFiles.read(root: root, checkout: checkout, files: nil).complete)
    }

    /// A provisioner runs a command whatever is mocked: never a read.
    func testAProvisionerIsNeverARead() throws {
        let checkout = sandbox()
        let root = checkout.appendingPathComponent("envs/dev")
        try write(
            [
                "envs/dev/main.tf": "resource \"terraform_data\" \"acme\" {\n  provisioner \"local-exec\" {\n    command = \"echo acme\"\n  }\n}\n",
                "envs/dev/tests/acme.tftest.hcl": "run \"a\" {}\n",
            ], in: checkout)
        let read = TerraformTestFiles.read(root: root, checkout: checkout, files: nil)
        XCTAssertEqual(read.risks.map(\.kind), [.provisioner])
        guard case .real(let why) = read.mocking else { return XCTFail("a provisioner") }
        XCTAssertTrue(why.contains("a provisioner runs a command"), why)
        // In a module a run loads, too.
        try write(
            [
                "envs/dev/main.tf": "resource \"terraform_data\" \"acme\" {}\n",
                "envs/dev/tests/acme.tftest.hcl": "run \"a\" {\n  module {\n    source = \"./setup\"\n  }\n}\n",
                "envs/dev/setup/main.tf": "resource \"terraform_data\" \"s\" {\n  provisioner \"local-exec\" {\n    command = \"echo acme\"\n  }\n}\n",
            ], in: checkout)
        XCTAssertFalse(TerraformTestFiles.read(root: root, checkout: checkout, files: nil).mocking.isMocked)
    }

    /// Every name that starts for its schema: the root's, the run
    /// modules', the tests' mocks.
    func testEveryProviderThatStartsIsNamed() throws {
        let checkout = sandbox()
        let root = checkout.appendingPathComponent("envs/dev")
        try write(
            [
                "envs/dev/main.tf": "resource \"terraform_data\" \"acme\" {}\n",
                "envs/dev/tests/acme.tftest.hcl": "mock_provider \"aws\" {}\nmock_provider \"google\" {}\nrun \"a\" {\n  module {\n    source = \"./setup\"\n  }\n}\n",
                "envs/dev/setup/main.tf": "resource \"google_storage_bucket\" \"acme\" {}\n",
            ], in: checkout)
        let read = TerraformTestFiles.read(root: root, checkout: checkout, files: nil)
        XCTAssertEqual(read.mocking, .mocked)
        XCTAssertEqual(read.providerNames, ["terraform", "aws", "google"])
    }

    /// A test file that is a link out of the checkout: refused, never read.
    @MainActor func testALinkOutOfTheCheckoutIsRefused() throws {
        let checkout = sandbox()
        let elsewhere = sandbox()
        let root = checkout.appendingPathComponent("envs/dev")
        try write(["envs/dev/main.tf": "resource \"terraform_data\" \"acme\" {}\n"], in: checkout)
        try write(["x.tftest.hcl": "run \"globex\" {}\n"], in: elsewhere)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("tests/x.tftest.hcl"), withDestinationURL: elsewhere.appendingPathComponent("x.tftest.hcl"))
        for files in [nil, ["tests/x.tftest.hcl"]] {
            let read = TerraformTestFiles.read(root: root, checkout: checkout, files: files)
            XCTAssertEqual(read.outside, ["tests/x.tftest.hcl"])
            XCTAssertTrue(read.files.isEmpty)
            let prepared = TerraformTestRun.Prepared(read: read)
            XCTAssertTrue(
                TerraformTestRun.refusal(prepared, file: files?.first, rootClass: .local, writable: true)?.contains("outside the checkout") == true)
        }
    }
}

/// The stream of a real `terraform test -json` (1.17.1, a sandbox,
/// `terraform_data` only), one run failing, and a `test_plan` line
/// (`-verbose`'s, never passed) carrying a value.
final class TerraformTestStreamTests: XCTestCase {
    static let sentinel = "acme-hunter2-SECRET"
    static let lines = [
        #"{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","type":"version","terraform":"1.17.1","ui":"1.3"}"#,
        #"{"@level":"info","@message":"Found 1 file and 2 run blocks","@module":"terraform.ui","test_abstract":{"tests/acme.tftest.hcl":["acme_named","acme_upper"]},"type":"test_abstract"}"#,
        #"{"@level":"info","@message":"tests/acme.tftest.hcl... in progress","@testfile":"tests/acme.tftest.hcl","test_file":{"path":"tests/acme.tftest.hcl","progress":"starting"},"type":"test_file"}"#,
        #"{"@level":"info","@message":"  \"acme_named\"... in progress","@testfile":"tests/acme.tftest.hcl","@testrun":"acme_named","test_run":{"path":"tests/acme.tftest.hcl","run":"acme_named","progress":"starting","elapsed":0},"type":"test_run"}"#,
        #"{"@level":"info","@message":"  \"acme_named\"... pass","@testfile":"tests/acme.tftest.hcl","@testrun":"acme_named","test_run":{"path":"tests/acme.tftest.hcl","run":"acme_named","progress":"complete","status":"pass"},"type":"test_run"}"#,
        #"{"@level":"info","@message":"plan","@testfile":"tests/acme.tftest.hcl","@testrun":"acme_upper","test_plan":{"variables":{"acme_password":{"value":"acme-hunter2-SECRET"}}},"type":"test_plan"}"#,
        #"{"@level":"info","@message":"  \"acme_upper\"... fail","@testfile":"tests/acme.tftest.hcl","@testrun":"acme_upper","test_run":{"path":"tests/acme.tftest.hcl","run":"acme_upper","progress":"complete","status":"fail"},"type":"test_run"}"#,
        #"{"@level":"error","@message":"Error: Test assertion failed","@testfile":"tests/acme.tftest.hcl","@testrun":"acme_upper","diagnostic":{"severity":"error","summary":"Test assertion failed","detail":"the output is upper-cased acme","range":{"filename":"tests/acme.tftest.hcl","start":{"line":16,"column":21,"byte":252},"end":{"line":16,"column":48,"byte":279}},"snippet":{"context":"run \"acme_upper\"","code":"    condition     = output.acme_upper == \"ACME\"","start_line":16,"values":[{"traversal":"output.acme_upper","statement":"is \"acme-hunter2-SECRET\""}],"test_assertion_expr":{"lhs":"\"acme-hunter2-SECRET\"","rhs":"\"ACME\""}}},"type":"diagnostic"}"#,
        #"{"@level":"info","@message":"tests/acme.tftest.hcl... fail","@testfile":"tests/acme.tftest.hcl","test_file":{"path":"tests/acme.tftest.hcl","progress":"complete","status":"fail"},"type":"test_file"}"#,
        #"{"@level":"info","@message":"Failure! 1 passed, 1 failed.","test_summary":{"status":"fail","passed":1,"failed":1,"errored":0,"skipped":0},"type":"test_summary"}"#,
    ]

    static func report() -> TerraformTestReport {
        var report = TerraformTestReport(planned: [.init(path: "tests/acme.tftest.hcl", runs: [.init(name: "acme_named", line: 1), .init(name: "acme_upper", line: 10)])])
        for line in lines {
            if case .test(let message) = TerraformUIMessage.decode(line) { report.absorb(message) }
        }
        return report
    }

    func testTheStreamIsDecodedAsTestMessages() {
        guard case .test(.run(let path, let run, let progress, let status)) = TerraformUIMessage.decode(Self.lines[4]) else { return XCTFail() }
        XCTAssertEqual([path, run, progress, status], ["tests/acme.tftest.hcl", "acme_named", "complete", "pass"])
        guard case .test(.diagnostic(let file, let named, let diagnostic)) = TerraformUIMessage.decode(Self.lines[7]) else { return XCTFail() }
        XCTAssertEqual(file, "tests/acme.tftest.hcl")
        XCTAssertEqual(named, "acme_upper")
        XCTAssertEqual(diagnostic.start?.line, 16)
        XCTAssertEqual(TerraformUIMessage.decode(Self.lines[5]), .test(.other("test_plan")), "a plan's values dropped by type")
        let plain = TerraformUIMessage.decode(#"{"type":"diagnostic","diagnostic":{"severity":"error","summary":"x","detail":""}}"#)
        guard case .diagnostic = plain else { return XCTFail("a plan's diagnostic stays one: \(plain)") }
    }

    func testTheReportListsRunsAndPlacesTheFailure() {
        let report = Self.report()
        XCTAssertEqual(report.runs.map(\.name), ["acme_named", "acme_upper"])
        XCTAssertEqual(report.runs.map(\.status), [.pass, .fail])
        XCTAssertEqual(report.runs.map(\.line), [1, 10], "the lines read from the file kept")
        XCTAssertEqual(report.files.first?.status, .fail)
        XCTAssertEqual(report.summary?.said, "1 passed, 1 failed")
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.run, "acme_upper")
        XCTAssertEqual(report.placed["tests/acme.tftest.hcl"]?.map { $0.start?.line }, [16], "one failure, at its line")
        let text = report.text(root: "envs/dev", mocked: true)
        XCTAssertTrue(text.contains("run \"acme_upper\" (line 10): fail") && text.contains("tests/acme.tftest.hcl:16"), text)
        for said in [String(reflecting: report), text, Self.lines.map { TerraformUIMessage.decode($0).logLine }.joined(separator: "\n")] {
            XCTAssertFalse(said.contains(Self.sentinel), "never a snippet's values, the assertion's sides, or a test_plan")
        }
    }

    func testRunsTheStreamAddsAreKept() {
        var report = TerraformTestReport()
        report.absorb(.run(path: "tests/globex.tftest.hcl", run: "late", progress: "starting", status: nil))
        XCTAssertEqual(report.runs.first?.status, .running)
        report.absorb(.run(path: "tests/globex.tftest.hcl", run: "late", progress: "complete", status: "error"))
        XCTAssertEqual(report.runs.first?.status, .error)
        XCTAssertEqual(report.failures.count, 1)
    }
}

/// The run itself, against a stand-in behind the recording wrapper.
@MainActor
final class TerraformTestRunTests: XCTestCase {
    private var checkout: URL!

    override func setUp() async throws {
        checkout = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-testrun-\(UUID().uuidString)", isDirectory: true)
        let root = checkout.appendingPathComponent("envs/dev", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try "resource \"terraform_data\" \"acme\" {\n  input = \"acme-dev\"\n}\n".write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try "run \"acme_named\" {}\n\nrun \"acme_upper\" {}\n".write(to: root.appendingPathComponent("tests/acme.tftest.hcl"), atomically: true, encoding: .utf8)
        TerraformTestResults.shared.reset()
    }

    override func tearDown() async throws {
        TerraformTestResults.shared.reset()
        try? FileManager.default.removeItem(at: checkout)
    }

    private func card(_ rootClass: TerraformClass = .local) -> TerraformRootCard {
        TerraformRootCard(
            path: "envs/dev", name: "envs/dev", folder: checkout.appendingPathComponent("envs/dev"), kind: .root, facts: TerraformRootFacts(),
            backendSummary: "local", identity: nil, verdict: .init(rootClass: rootClass, reason: "a test's"))
    }

    private func recorder() throws -> TerraformRecorder {
        let folder = checkout.appendingPathComponent(".tf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let standIn = folder.appendingPathComponent("stand-in/terraform")
        try FileManager.default.createDirectory(at: standIn.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stream = folder.appendingPathComponent("stand-in/stream.jsonl")
        try Data((TerraformTestStreamTests.lines.joined(separator: "\n") + "\n").utf8).write(to: stream)
        let script = """
            #!/bin/bash -p
            case "$1" in
              test) /bin/cat \(TerraformRecorder.quoted(stream.path)); exit 1 ;;
              *) exit 9 ;;
            esac

            """
        try Data(script.utf8).write(to: standIn)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: standIn.path)
        return try TerraformRecorder.make(in: folder.appendingPathComponent("recorder"), target: standIn.path)
    }

    func testAMockedTestRunsStrippedAndItsFailureReachesTheEditor() async throws {
        let recorder = try recorder()
        let card = card()
        let prepared = await TerraformTestRun.prepare(card: card, checkout: checkout, file: nil, settingPath: "", binary: recorder.wrapper)
        XCTAssertEqual(prepared.read.mocking, .mocked, "terraform_data alone: nothing to mock")
        XCTAssertNil(TerraformTestRun.refusal(prepared, file: nil, rootClass: .production, writable: false), "a read on any class")
        let run = TerraformTestRun(checkout: checkout, card: card)
        await run.start(prepared)
        guard case .failed(let said) = run.phase else { return XCTFail("\(run.phase)") }
        XCTAssertTrue(said.hasPrefix("1 passed, 1 failed — Test assertion failed"), said)
        let calls = recorder.calls()
        XCTAssertEqual(calls.map(\.arguments), [TerraformCommands.test()!])
        let scratch = try TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory)
        XCTAssertEqual(calls.first?.values["HOME"], scratch.home.path, "validate's environment: a scratch HOME")
        XCTAssertFalse(calls.first?.names.contains(where: TerraformGuards.isCredential) ?? true)
        XCTAssertNil(calls.first?.values["TF_WORKSPACE"], "a test touches no workspace of the root's")
        let file = card.folder.appendingPathComponent("tests/acme.tftest.hcl")
        XCTAssertEqual(TerraformTestResults.shared.diagnostics(for: file).map { $0.start?.line }, [16])
        XCTAssertTrue(TerraformTestResults.shared.latest(checkout: checkout, root: "envs/dev") === run)
        XCTAssertFalse(String(reflecting: run.report).contains(TerraformTestStreamTests.sentinel))
        XCTAssertFalse(run.log.joined(separator: "\n").contains(TerraformTestStreamTests.sentinel))
        let answer = await TerraformMCP.answer(run, waitingFor: 0)
        XCTAssertTrue(answer.hasPrefix("Failed — 1 passed, 1 failed") && answer.contains("tests/acme.tftest.hcl:16"), answer)
        XCTAssertFalse(answer.contains(TerraformTestStreamTests.sentinel))
    }

    func testARealProviderIsAWrite() async throws {
        try "mock_provider \"random\" {}\nrun \"a\" {}\n".write(
            to: checkout.appendingPathComponent("envs/dev/tests/acme.tftest.hcl"), atomically: true, encoding: .utf8)
        try "resource \"aws_s3_bucket\" \"acme\" {}\n".write(to: checkout.appendingPathComponent("envs/dev/s3.tf"), atomically: true, encoding: .utf8)
        let prepared = await TerraformTestRun.prepare(card: card(), checkout: checkout, file: nil, settingPath: "", binary: URL(fileURLWithPath: "/usr/bin/false"))
        XCTAssertEqual(prepared.read.mocking, .real("tests/acme.tftest.hcl: not mocked: aws"))
        let refused = TerraformTestRun.refusal(prepared, file: nil, rootClass: .production, writable: false)
        XCTAssertTrue(refused?.contains("creates real infrastructure") == true, refused ?? "")
        XCTAssertNotNil(TerraformTestRun.refusal(prepared, file: nil, rootClass: .remote, writable: false))
        XCTAssertNotNil(TerraformTestRun.refusal(prepared, file: nil, rootClass: .local, writable: false), "plan only on any class")
        XCTAssertNil(TerraformTestRun.refusal(prepared, file: nil, rootClass: .local, writable: true), "asked, by the caller")
        XCTAssertNil(TerraformTestRun.refusal(prepared, file: nil, rootClass: .production, writable: true), "production too: asked, its name typed")
    }

    // MARK: The question (review of 2d)

    private func realProviderRoot() throws {
        try "resource \"aws_s3_bucket\" \"acme\" {}\n".write(to: checkout.appendingPathComponent("envs/dev/s3.tf"), atomically: true, encoding: .utf8)
    }

    /// A real provider: asked on every call, the files listed, nothing
    /// run when declined; never an agent's on production; the root's name
    /// typed on production.
    func testARealProviderTestIsAskedEveryTimeAndRunsNothingDeclined() async throws {
        try realProviderRoot()
        let recorder = try recorder()
        var asked: [TerraformPlanGate.Question] = []
        var shown = 0
        for _ in 0..<2 {
            let outcome = await TerraformTestRun.begin(
                card: card(), checkout: checkout, file: nil, agent: nil, writable: true, settingPath: "", binary: recorder.wrapper,
                ask: {
                    asked.append($0); return false
                }, show: { _ in shown += 1 })
            guard case .failure(let declined) = outcome else { return XCTFail("declined, nothing started") }
            XCTAssertEqual(declined.message, "", "declined: a failure with no message")
        }
        XCTAssertEqual(asked.count, 2, "asked on every call")
        XCTAssertEqual(shown, 0)
        XCTAssertTrue(recorder.calls().isEmpty, "no terraform test ran")
        let detail = asked.first?.detail ?? ""
        XCTAssertTrue(detail.contains("Files: tests/acme.tftest.hcl") && detail.contains("not mocked: aws"), detail)
        XCTAssertTrue(detail.contains("Quitting Overterm while it runs interrupts it"), detail)
        XCTAssertNil(asked.first?.typedName, "no name typed off production")
        XCTAssertTrue(TerraformTestResults.shared.starting.isEmpty)
    }

    func testOnProductionAnAgentsRealTestIsRefusedAndThePersonTypesTheName() async throws {
        try realProviderRoot()
        let recorder = try recorder()
        let registry = TerraformRunRegistry()
        var asked: [TerraformPlanGate.Question] = []
        let agent = await TerraformTestRun.begin(
            card: card(.production), checkout: checkout, file: nil, agent: "Claude Code in “acme”", writable: true, settingPath: "", binary: recorder.wrapper,
            registry: registry,
            ask: {
                asked.append($0); return true
            }, show: { _ in })
        guard case .failure(let refused) = agent else { return XCTFail("an agent never writes to production") }
        XCTAssertTrue(refused.message.contains("is production"), refused.message)
        XCTAssertTrue(asked.isEmpty)
        let person = await TerraformTestRun.begin(
            card: card(.production), checkout: checkout, file: nil, agent: nil, writable: true, settingPath: "", binary: recorder.wrapper,
            registry: registry,
            ask: {
                asked.append($0); return false
            }, show: { _ in })
        guard case .failure(let declined) = person, declined.message.isEmpty else { return XCTFail("declined") }
        XCTAssertEqual(asked.first?.typedName, "envs/dev", "the root's name typed on production (D-21)")
        XCTAssertEqual(asked.first?.production, true)
        XCTAssertTrue(recorder.calls().isEmpty)
        // Set plan-only (`writable: false`): refused before any question.
        let off = await TerraformTestRun.begin(
            card: card(.production), checkout: checkout, file: nil, agent: nil, writable: false, settingPath: "", binary: recorder.wrapper,
            registry: TerraformRunRegistry(),
            ask: {
                asked.append($0); return true
            }, show: { _ in })
        guard case .failure(let without) = off else { return XCTFail("refused") }
        XCTAssertTrue(without.message.contains("creates real infrastructure"), without.message)
        XCTAssertEqual(asked.count, 1)
    }

    /// The owner's decision makes roots writable by default for a person;
    /// an agent's real-provider test keeps the rule agents had: a remote
    /// root only where its terraform.roots entry sets writable true.
    func testAnAgentsRealTestOnAnUnsetRemoteRootIsRefused() async throws {
        XCTAssertTrue(TerraformTestRun.writable(rootClass: .remote, setting: nil, agent: false), "a person's: writable by default")
        XCTAssertTrue(TerraformTestRun.writable(rootClass: .production, setting: nil, agent: false), "production too, for a person")
        XCTAssertFalse(TerraformTestRun.writable(rootClass: .remote, setting: nil, agent: true), "an agent's: unset remote is plan only")
        XCTAssertTrue(TerraformTestRun.writable(rootClass: .remote, setting: true, agent: true))
        XCTAssertFalse(TerraformTestRun.writable(rootClass: .production, setting: nil, agent: true))
        XCTAssertTrue(TerraformTestRun.writable(rootClass: .local, setting: nil, agent: true), "local as before")
        XCTAssertFalse(TerraformTestRun.writable(rootClass: .local, setting: false, agent: true))
        try realProviderRoot()
        let recorder = try recorder()
        var asked: [TerraformPlanGate.Question] = []
        let agent = await TerraformTestRun.begin(
            card: card(.remote), checkout: checkout, file: nil, agent: "Claude Code in “acme”",
            writable: TerraformTestRun.writable(rootClass: .remote, setting: nil, agent: true), settingPath: "", binary: recorder.wrapper,
            registry: TerraformRunRegistry(),
            ask: {
                asked.append($0); return true
            }, show: { _ in })
        guard case .failure(let refused) = agent else { return XCTFail("an agent's real test on an unset remote root is refused") }
        XCTAssertTrue(refused.message.contains("only where its terraform.roots entry sets writable to true"), refused.message)
        XCTAssertTrue(asked.isEmpty, "refused before any question")
        let person = await TerraformTestRun.begin(
            card: card(.remote), checkout: checkout, file: nil, agent: nil,
            writable: TerraformTestRun.writable(rootClass: .remote, setting: nil, agent: false), settingPath: "", binary: recorder.wrapper,
            registry: TerraformRunRegistry(),
            ask: {
                asked.append($0); return false
            }, show: { _ in })
        guard case .failure(let declined) = person, declined.message.isEmpty else { return XCTFail("a person's is asked") }
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(recorder.calls().isEmpty)
    }

    /// An agent's mocked test starts the mocked providers for their
    /// schemas: only where a committed lock file pins them.
    func testAnAgentsMockedTestNeedsTheLockFileForItsMocks() async throws {
        try "mock_provider \"aws\" {}\nrun \"a\" {}\n".write(
            to: checkout.appendingPathComponent("envs/dev/tests/acme.tftest.hcl"), atomically: true, encoding: .utf8)
        let recorder = try recorder()
        let outcome = await TerraformTestRun.begin(
            card: card(), checkout: checkout, file: nil, agent: "Claude Code in “acme”", writable: true, settingPath: "", binary: recorder.wrapper,
            ask: { _ in
                XCTFail("a mocked test isn't asked"); return true
            }, show: { _ in })
        guard case .failure(let refused) = outcome else { return XCTFail("no lock file: refused") }
        XCTAssertTrue(refused.message.hasPrefix("needs init:"), refused.message)
        XCTAssertTrue(recorder.calls().isEmpty)
    }

    /// One test of a root at a time: a going run, whatever its file, is
    /// shown again; one being prepared refuses another.
    func testATestIsNeverStartedTwice() async throws {
        let recorder = try recorder()
        let going = TerraformTestRun(checkout: checkout, card: card(), file: "tests/acme.tftest.hcl")
        TerraformTestResults.shared.add(going)
        var shown: [TerraformTestRun] = []
        let again = await TerraformTestRun.begin(
            card: card(), checkout: checkout, file: nil, agent: nil, writable: true, settingPath: "", binary: recorder.wrapper,
            ask: { _ in true }, show: { shown.append($0) })
        XCTAssertTrue((try? again.get()) === going, "every file while one file's run goes: that run, shown")
        XCTAssertTrue(shown.first === going)
        TerraformTestResults.shared.reset()
        TerraformTestResults.shared.starting.insert(TerraformRootStore.key(checkout: checkout, root: "envs/dev"))
        let twice = await TerraformTestRun.begin(
            card: card(), checkout: checkout, file: nil, agent: nil, writable: true, settingPath: "", binary: recorder.wrapper,
            ask: { _ in true }, show: { _ in })
        guard case .failure(let starting) = twice else { return XCTFail("a second press while the first prepares") }
        XCTAssertTrue(starting.message.contains("starting already"), starting.message)
        XCTAssertTrue(recorder.calls().isEmpty)
    }

    /// Quitting while a real-provider test runs asks: its cleanup would be cut off.
    func testQuittingAsksWhileARealTestRuns() {
        let mocked = TerraformTestRun(checkout: checkout, card: card(), mocking: .mocked)
        let real = TerraformTestRun(checkout: checkout, card: card(), mocking: .real("not mocked: aws"))
        TerraformTestResults.shared.add(mocked)
        XCTAssertTrue(TerraformTestResults.shared.goingReal.isEmpty, "a mocked test creates nothing")
        TerraformTestResults.shared.add(real)
        XCTAssertTrue(TerraformTestResults.shared.goingReal.first === real)
        let question = TerraformCloseGuard.testQuestion(TerraformTestResults.shared.goingReal.map { (name: $0.card.name, since: $0.started) })
        XCTAssertEqual(question?.title, "A terraform test with real providers in envs/dev is running.")
        XCTAssertTrue(question?.detail.contains("the resources it created stay") == true)
        XCTAssertEqual(TerraformCloseGuard.testButtons, ["Interrupt", "Quit Anyway", "Cancel"])
        XCTAssertNil(TerraformCloseGuard.testQuestion([]))
        real.refuse("stopped")
        XCTAssertTrue(TerraformTestResults.shared.goingReal.isEmpty)
    }

    func testNoTestFilesIsSaid() async throws {
        try FileManager.default.removeItem(at: checkout.appendingPathComponent("envs/dev/tests"))
        let prepared = await TerraformTestRun.prepare(card: card(), checkout: checkout, file: nil, settingPath: "", binary: nil)
        XCTAssertTrue(
            TerraformTestRun.refusal(prepared, file: nil, rootClass: .local, writable: false)?.hasPrefix("No test files") == true)
        XCTAssertNotNil(TerraformTestRun.refusal(prepared, file: "../x.tftest.hcl", rootClass: .local, writable: false))
    }
}

/// Drift: what a check found, said with its age; Accept into State as an apply.
final class TerraformDriftTests: XCTestCase {
    static let sentinel = "acme-hunter2-SECRET"

    /// A refresh-only plan's JSON: no `resource_changes` (spike 25), one
    /// object deleted outside Terraform, another updated (its old value
    /// sensitive), an output changed.
    static var plan: [String: Any] {
        [
            "format_version": "1.2", "terraform_version": "1.17.1", "applyable": true, "complete": true, "errored": false,
            "resource_drift": [
                [
                    "address": "local_file.acme_config", "mode": "managed", "type": "local_file", "name": "acme_config",
                    "provider_name": "registry.terraform.io/hashicorp/local",
                    "change": ["actions": ["delete"], "before": ["content": "acme"], "after": NSNull(), "before_sensitive": [:], "after_sensitive": false],
                ],
                [
                    "address": "random_password.acme_db", "mode": "managed", "type": "random_password", "name": "acme_db",
                    "provider_name": "registry.terraform.io/hashicorp/random",
                    "change": [
                        "actions": ["update"], "before": ["result": sentinel, "length": 24], "after": ["result": sentinel, "length": 32],
                        "before_sensitive": ["result": true], "after_sensitive": ["result": true],
                    ],
                ],
            ],
            "output_changes": ["acme_upper": ["actions": ["update"], "before": "ACME", "after": "acme", "before_sensitive": false, "after_sensitive": false]],
            "prior_state": ["format_version": "1.0", "terraform_version": "1.17.1"],
        ]
    }

    static func decoded(_ object: [String: Any] = plan) throws -> TerraformPlan {
        try TerraformPlan.decode(object, scrub: TerraformPlan.scrub)
    }

    func testWhatACheckFoundIsSaid() throws {
        let plan = try Self.decoded()
        XCTAssertTrue(plan.resourceChanges.isEmpty)
        XCTAssertEqual(TerraformDrift.count(plan), 3)
        XCTAssertEqual(TerraformDrift.said(plan), "2 objects changed outside Terraform, 1 output changed")
        XCTAssertFalse(String(reflecting: plan).contains(Self.sentinel), "masked at decode")
        var none = Self.plan
        none["resource_drift"] = nil
        none["output_changes"] = ["acme_upper": ["actions": ["no-op"], "before": "ACME", "after": "ACME"]]
        none["applyable"] = false
        let clean = try Self.decoded(none)
        XCTAssertEqual(TerraformDrift.said(clean), "no drift")
        XCTAssertEqual(TerraformDrift.nothingToAccept(clean, mode: .refreshOnly), "No drift to accept: the state already matches what the providers read.")
        XCTAssertNil(TerraformDrift.nothingToAccept(clean, mode: .normal))
        XCTAssertNil(TerraformDrift.nothingToAccept(plan, mode: .refreshOnly))
    }

    /// Its age always; once stale, its count is then, never now.
    func testACheckSaysItsAgeAndNeverAStaleCountAsCurrent() throws {
        let plan = try Self.decoded()
        let current = TerraformDrift.line(phase: .planned, plan: plan, age: "4 min ago", stale: nil)
        XCTAssertEqual(current.text, "Drift: 2 objects changed outside Terraform, 1 output changed · checked 4 min ago")
        XCTAssertTrue(current.drifted && !current.stale)
        let stale = TerraformDrift.line(phase: .planned, plan: plan, age: "2 h ago", stale: "older than 30 minutes: plan again")
        XCTAssertEqual(stale.text, "Drift checked 2 h ago: 2 objects changed outside Terraform, 1 output changed then — older than 30 minutes: plan again")
        XCTAssertTrue(stale.stale && !stale.drifted)
        XCTAssertEqual(TerraformDrift.line(phase: .noChanges, plan: nil, age: "just now", stale: nil).text, "No drift · checked just now")
        XCTAssertEqual(TerraformDrift.line(phase: .running, plan: nil, age: "just now", stale: nil).text, "Checking drift…")
    }

    private func facts(_ plan: TerraformPlan, rootClass: TerraformClass, writable: Bool = true) -> TerraformApplyFacts {
        let environment = ["PATH": "/usr/bin", "TF_WORKSPACE": "default"]
        var facts = TerraformApplyFacts(
            plan: plan, mode: .refreshOnly, recordSHA: "abc", recordBinary: "/opt/acme/terraform", recordVersion: "1.17.1", recordWorkspace: "default",
            recordDataDir: "/acme/envs/dev/.terraform", recordEnvironment: environment, zipLockSHA: "lock1", rootName: "envs/prod", rootClass: rootClass,
            writable: writable)
        facts.descriptorSHA = "abc"
        facts.binaryNow = "/opt/acme/terraform"
        facts.versionNow = "1.17.1"
        facts.environmentNow = environment
        facts.dataDirNow = "/acme/envs/dev/.terraform"
        facts.lockSHANow = "lock1"
        return facts
    }

    /// Accept into State is an apply of the plan shown: refused on a
    /// read-only root, the root's name typed on production, never "creates
    /// everything" (it records, creates nothing).
    func testAcceptingIsAnApplyWithEveryCheck() throws {
        let plan = try Self.decoded()
        XCTAssertNotNil(
            TerraformApplyCheck.greyed(
                plan: plan, rootClass: .production, writable: false, mode: .refreshOnly, devOverrides: false, staleReason: nil, busy: nil))
        guard case .refused(let why) = TerraformApplyCheck.check(facts(plan, rootClass: .production, writable: false)) else {
            return XCTFail("refused where the root is set plan only")
        }
        XCTAssertTrue(why.contains("plan only"), why)
        XCTAssertEqual(
            TerraformApplyCheck.check(facts(plan, rootClass: .production)),
            .ask(typed: true, versionMove: nil, partial: false, createsEverything: false))
        var empty = Self.plan
        empty["prior_state"] = nil
        let local = TerraformApplyCheck.check(facts(try Self.decoded(empty), rootClass: .local))
        XCTAssertEqual(local, .ask(typed: false, versionMove: nil, partial: false, createsEverything: false), "nothing is created")
        var stale = facts(plan, rootClass: .local)
        stale.staleReason = "applied from bump-eks at 14:52: plan again"
        if case .refused(let said) = TerraformApplyCheck.check(stale) { XCTAssertTrue(said.hasPrefix("Stale"), said) } else { XCTFail("stale refused") }
    }

    func testTheAcceptSheet() throws {
        let plan = try Self.decoded()
        let sheet = TerraformApplySheet.make(
            root: .init(name: "envs/prod", path: "envs/prod", rootClass: .production, backend: "local · terraform.tfstate", workspace: "default", worktree: "acme"),
            plan: plan, mode: .refreshOnly, typed: true, versionMove: nil, partial: false, createsEverything: false, risks: [], profile: "acme-prod-admin",
            region: nil)
        XCTAssertEqual(sheet.title, "Accept the drift into production envs/prod's state?")
        XCTAssertEqual(sheet.button, "Accept into State")
        XCTAssertEqual(sheet.typedName, "envs/prod")
        XCTAssertTrue(sheet.detail.contains("no infrastructure changes"), sheet.detail)
        XCTAssertTrue(sheet.detail.contains("local_file.acme_config  deleted outside Terraform: the state forgets it"), sheet.detail)
        XCTAssertTrue(sheet.detail.contains("Outputs: acme_upper"), sheet.detail)
        XCTAssertTrue(sheet.detail.contains("terraform apply -input=false -json -lock=true -lock-timeout=60s /dev/fd/3"), sheet.detail)
        XCTAssertFalse(sheet.detail.contains(Self.sentinel))
        // Every apply sheet lists what the code runs (5.4 item 9): the providers start with your credentials.
        let risky = TerraformApplySheet.make(
            root: .init(name: "envs/dev", path: "envs/dev", rootClass: .local, backend: "local", workspace: "default", worktree: "acme"), plan: plan,
            mode: .refreshOnly, typed: false, versionMove: nil, partial: false, createsEverything: false,
            risks: ["data.external runs a command on this Mac when planned"], profile: nil, region: nil)
        XCTAssertTrue(risky.detail.contains("Its code: data.external runs a command on this Mac when planned"), risky.detail)
    }

    /// The drift line on a clock: past 30 minutes, said stale, its count as then.
    @MainActor func testTheDriftLineGoesStaleOnTheClock() throws {
        let card = TerraformRootCard(
            path: "envs/dev", name: "envs/dev", folder: URL(fileURLWithPath: "/tmp/acme-drift/envs/dev"), kind: .root, facts: TerraformRootFacts(),
            backendSummary: "local", identity: nil, verdict: .init(rootClass: .local, reason: "a test's"))
        let run = TerraformPlanRun(kind: .plan, checkout: URL(fileURLWithPath: "/tmp/acme-drift"), card: card, mode: .refreshOnly)
        let finished = Date(timeIntervalSinceNow: -60)
        run.landed(try TerraformPlanReadingTests.record(try Self.decoded()), at: finished)
        let registry = TerraformRunRegistry()
        let fresh = run.driftLine(registry, now: finished.addingTimeInterval(5))
        XCTAssertFalse(fresh.stale)
        XCTAssertTrue(fresh.text.hasSuffix("checked just now"), fresh.text)
        let later = run.driftLine(registry, now: finished.addingTimeInterval(31 * 60))
        XCTAssertTrue(later.stale && !later.drifted, later.text)
        XCTAssertTrue(later.text.hasPrefix("Drift checked 31 min ago:") && later.text.hasSuffix("older than 30 minutes: plan again"), later.text)
        let test = TerraformTestRun(checkout: URL(fileURLWithPath: "/tmp/acme-drift"), card: card)
        test.refuse("acme")
        XCTAssertTrue(test.line(now: Date().addingTimeInterval(2 * 3_600)).hasPrefix("Test not run 2 h ago"))
    }
}
