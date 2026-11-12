import XCTest

@testable import Overterm

/// Stage 1a's pure parts: the environment and the command lines of the
/// editor's runs, validate's JSON, the block scan and the module's index.
final class TerraformEnvironmentTests: XCTestCase {
    private let scratch = TerraformGuards.Scratch(folder: URL(fileURLWithPath: "/private/tmp/acme-scratch"))
    private let root = URL(fileURLWithPath: "/work/acme-infra/envs/dev")

    /// A shell that sets everything that could change a run's target or
    /// leak a value: none of it reaches fmt or validate (5.13 rule 3).
    private let hostile = [
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": "/Users/acme", "LANG": "en_US.UTF-8", "SHELL": "/bin/zsh",
        "TF_CLI_ARGS": "-lock=false", "TF_CLI_ARGS_apply": "-auto-approve", "TF_CLI_ARGS_plan": "-refresh=false", "TF_LOG": "trace",
        "TF_LOG_PATH": "/tmp/acme.log", "TF_LOG_PROVIDER": "trace", "TF_LOG_CORE": "trace", "TF_REATTACH_PROVIDERS": "{\"acme\":{}}",
        "TF_WORKSPACE": "acme-prod", "TF_DATA_DIR": "/tmp/shared-data", "AWS_PROFILE": "acme-prod-admin",
        "AWS_SECRET_ACCESS_KEY": "acme-hunter2-SECRET", "GOOGLE_CREDENTIALS": "{}", "ARM_CLIENT_SECRET": "globex-BKPW",
        "TF_TOKEN_app_terraform_io": "tok-acme-123", "TF_VAR_db_password": "acme-hunter2-SECRET", "VAULT_TOKEN": "tok-acme-123",
        "KUBECONFIG": "/Users/acme/.kube/config", "GITHUB_TOKEN": "tok-acme-123", "TF_CLI_CONFIG_FILE": "/Users/acme/.terraformrc",
        "TF_HTTP_PASSWORD": "globex-BKPW", "TF_ENCRYPTION": "key_provider {}",
        // The kubernetes and helm providers' and backend's: a kubeconfig by absolute path, a key, a host.
        "KUBE_CONFIG_PATH": "/Users/acme/.kube/acme-prod", "KUBE_CONFIG_PATHS": "/Users/acme/.kube/acme-prod", "KUBE_CTX": "acme-prod",
        "KUBE_CLIENT_KEY_DATA": "acme-hunter2-SECRET", "KUBE_CLIENT_CERT_DATA": "globex-BKPW", "KUBE_HOST": "https://acme-prod.example",
        "HELM_KUBETOKEN": "tok-acme-123", "HELM_KUBECONTEXT": "acme-prod",
        // Spelt in lower case: still credentials.
        "aws_secret_access_key": "acme-hunter2-SECRET", "vault_token": "tok-acme-123",
    ]

    func testAHostileShellReachesNoRun() {
        for purpose in [TerraformEnvironment.Purpose.format, .validate] {
            let environment = TerraformEnvironment.build(base: hostile, purpose: purpose, root: root, scratch: scratch)
            XCTAssertEqual(
                Set(environment.keys), ["PATH", "HOME", "LANG", "SHELL", "TF_CLI_CONFIG_FILE", "CHECKPOINT_DISABLE", "TF_INPUT", "TF_IN_AUTOMATION", "TF_DATA_DIR"],
                "\(purpose)")
            XCTAssertEqual(environment["HOME"], "/private/tmp/acme-scratch/home")
            XCTAssertEqual(environment["TF_CLI_CONFIG_FILE"], "/private/tmp/acme-scratch/terraformrc")
            XCTAssertEqual(environment["TF_DATA_DIR"], "/work/acme-infra/envs/dev/.terraform", "the root's own, never the shell's")
            XCTAssertEqual(environment["CHECKPOINT_DISABLE"], "1")
            XCTAssertEqual(environment["TF_INPUT"], "0")
            XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/bin:/bin", "a shim still finds its versions")
            for value in ["acme-hunter2-SECRET", "tok-acme-123", "globex-BKPW", "-auto-approve", "-lock=false", "/Users/acme/.kube", "acme-prod"] {
                XCTAssertFalse(environment.values.contains { $0.contains(value) }, value)
            }
        }
    }

    func testAlwaysRemovedNames() {
        for name in ["TF_CLI_ARGS", "TF_CLI_ARGS_apply", "TF_LOG", "TF_LOG_PATH", "TF_REATTACH_PROVIDERS", "TF_WORKSPACE", "TF_DATA_DIR"] {
            XCTAssertTrue(TerraformEnvironment.isAlwaysRemoved(name), name)
        }
        for name in ["TF_INPUT", "TF_PLUGIN_CACHE_DIR", "TF_CLI_ARGSX", "PATH"] {
            XCTAssertFalse(TerraformEnvironment.isAlwaysRemoved(name), name)
        }
    }

    /// The guarded base (a scenario's, a unit test's) keeps its own HOME and
    /// config: the build adds nothing of the user's.
    func testTheGuardedBaseStaysGuarded() {
        let guarded = scratch.environment
        let environment = TerraformEnvironment.build(base: guarded, purpose: .validate, root: root, scratch: scratch)
        XCTAssertEqual(environment["HTTPS_PROXY"], TerraformGuards.deadProxy)
        XCTAssertEqual(environment["HOME"], scratch.home.path)
        XCTAssertTrue(TerraformGuards.credentials(in: environment).isEmpty)
    }
}

final class TerraformCommandsTests: XCTestCase {
    func testEveryBuiltLineRuns() {
        for arguments in TerraformCommands.all {
            XCTAssertNil(TerraformCommands.refusal(arguments), "\(arguments)")
            XCTAssertFalse(arguments.contains { $0.hasPrefix("-chdir") })
        }
        XCTAssertEqual(TerraformCommands.validate, ["validate", "-json", "-no-color"])
        XCTAssertEqual(TerraformCommands.formatStandardInput, ["fmt", "-no-color", "-"])
        XCTAssertEqual(TerraformCommands.formatCheckFolder, ["fmt", "-check", "-list=true", "-no-color"], "one folder, not below it")
    }

    /// 5.13 rule 1, the editor's half: nothing that writes, no forbidden flag.
    func testWhatIsNeverRun() {
        let refused: [[String]] = [
            ["apply"], ["apply", "-auto-approve"], ["destroy"], ["init"], ["init", "-upgrade"], ["state", "rm", "acme.x"], ["force-unlock", "1"],
            ["workspace", "select", "acme-prod"], ["import", "a.b", "id"], ["taint", "a.b"], ["output", "-json"], ["show", "-json"], ["plan"],
            ["validate", "-json", "-no-color", "-lock=false"], ["fmt", "-no-color", "-", "-var=x=1"], ["-chdir=envs/prod", "validate", "-json", "-no-color"],
            ["validate", "-json"], ["fmt", "-write=true"], [], ["-help"], ["validate", "-var", "x=1"],
        ]
        for arguments in refused {
            XCTAssertNotNil(TerraformCommands.refusal(arguments), "\(arguments)")
        }
    }
}

final class TerraformValidationTests: XCTestCase {
    /// Terraform 1.17.1's own answer, in a sandbox: a misspelt variable.
    static let invalid = """
        {
          "format_version": "1.0",
          "valid": false,
          "error_count": 1,
          "warning_count": 0,
          "diagnostics": [
            {
              "severity": "error",
              "summary": "Reference to undeclared input variable",
              "detail": "An input variable with the name \\"acme_nme\\" has not been declared. Did you mean \\"acme_name\\"?",
              "range": {
                "filename": "main.tf",
                "start": { "line": 7, "column": 11, "byte": 113 },
                "end": { "line": 7, "column": 23, "byte": 125 }
              },
              "snippet": {
                "context": "resource \\"terraform_data\\" \\"acme\\"",
                "code": "  input = var.acme_nme",
                "start_line": 7,
                "highlight_start_offset": 10,
                "highlight_end_offset": 22,
                "values": [{ "traversal": "var.acme_secret", "statement": "is \\"acme-hunter2-SECRET\\"" }]
              }
            }
          ]
        }
        """

    func testDecodeKeepsTheAllowListOnly() throws {
        let validation = try TerraformValidation.decode(Data(Self.invalid.utf8))
        XCTAssertFalse(validation.valid)
        XCTAssertEqual(validation.errors, 1)
        XCTAssertFalse(validation.needsInit)
        let diagnostic = try XCTUnwrap(validation.diagnostics.first)
        XCTAssertEqual(diagnostic.summary, "Reference to undeclared input variable")
        XCTAssertEqual(diagnostic.file, "main.tf")
        XCTAssertEqual(diagnostic.start, .init(line: 7, column: 11, byte: 113))
        XCTAssertEqual(diagnostic.end, .init(line: 7, column: 23, byte: 125))
        XCTAssertEqual(diagnostic.code, "  input = var.acme_nme")
        // The snippet's values can hold a variable's value: never decoded (5.6 rule 10).
        XCTAssertFalse(String(reflecting: validation).contains("acme-hunter2-SECRET"))
    }

    func testScrubRunsOverKeptText() throws {
        let text = Self.invalid.replacingOccurrences(of: "has not been declared.", with: "has not been declared: postgres://acme:acme-hunter2-SECRET@db/acme.")
        let validation = try TerraformValidation.decode(Data(text.utf8), scrub: TerraformValidation.scrub)
        XCTAssertFalse(String(reflecting: validation).contains("acme-hunter2-SECRET"), "\(validation)")
    }

    func testValidAndNeedsInit() throws {
        let valid = try TerraformValidation.decode(Data(#"{"format_version":"1.0","valid":true,"error_count":0,"warning_count":0,"diagnostics":[]}"#.utf8))
        XCTAssertTrue(valid.valid)
        XCTAssertEqual(valid.diagnostics, [])
        let missing = """
            {"format_version":"1.0","valid":false,"diagnostics":[{"severity":"error","summary":"Missing required provider",
            "detail":"This configuration requires provider registry.terraform.io/hashicorp/random, but that provider isn't available. You may be able to install it automatically by running:\\n  terraform init"}]}
            """
        XCTAssertTrue(try TerraformValidation.decode(Data(missing.utf8)).needsInit)
        let module = #"{"format_version":"1.0","valid":false,"diagnostics":[{"severity":"error","summary":"Module not installed","detail":"This module is not yet installed."}]}"#
        XCTAssertTrue(try TerraformValidation.decode(Data(module.utf8)).needsInit)
        let warning = #"{"format_version":"1.0","valid":true,"diagnostics":[{"severity":"warning","summary":"Deprecated attribute","detail":""}]}"#
        let decoded = try TerraformValidation.decode(Data(warning.utf8))
        XCTAssertEqual(decoded.warnings, 1)
        XCTAssertFalse(decoded.needsInit)
        XCTAssertEqual(decoded.diagnostics.first?.message, "Deprecated attribute")
    }

    func testAnUnknownMajorAndNotJSONAreRefused() {
        XCTAssertThrowsError(try TerraformValidation.decode(Data(#"{"format_version":"2.0","valid":true}"#.utf8))) {
            XCTAssertEqual($0 as? TerraformValidation.DecodeError, .unknownFormat("2.0"))
        }
        XCTAssertNoThrow(try TerraformValidation.decode(Data(#"{"format_version":"1.3","valid":true}"#.utf8)), "a minor is read")
        XCTAssertThrowsError(try TerraformValidation.decode(Data("panic: runtime error".utf8)))
    }

    /// Columns are characters, as HCL counts them; the range is UTF-16, the editor's.
    func testRangesByLineAndCharacterColumn() {
        let text = "variable \"acme\" {}\n\nresource \"terraform_data\" \"acme\" {\n  input = var.acme_nme\n}\n" as NSString
        let range = TerraformValidation.range(from: .init(line: 4, column: 11, byte: 0), to: .init(line: 4, column: 23, byte: 0), in: text)
        XCTAssertEqual(text.substring(with: range), "var.acme_nme")
        // An emoji and an accent before it: one character each, two and one UTF-16 units.
        let wide = "locals {\n  a = \"🌍é\" + var.acme\n}\n" as NSString
        let after = TerraformValidation.range(from: .init(line: 2, column: 14, byte: 0), to: .init(line: 2, column: 22, byte: 0), in: wide)
        XCTAssertEqual(wide.substring(with: after), "var.acme")
        // Past the text: clamped, never out of bounds.
        let past = TerraformValidation.range(from: .init(line: 40, column: 3, byte: 0), to: nil, in: text)
        XCTAssertLessThanOrEqual(NSMaxRange(past), text.length)
        let longColumn = TerraformValidation.range(from: .init(line: 1, column: 400, byte: 0), to: nil, in: text)
        XCTAssertLessThanOrEqual(NSMaxRange(longColumn), text.length)
        XCTAssertEqual(TerraformValidation.range(from: .init(line: 1, column: 1, byte: 0), to: nil, in: "" as NSString), NSRange(location: 0, length: 0))
    }

    func testFirstErrorOfFmt() {
        let stderr = "\nError: Invalid expression\n\n  on <stdin> line 2, in locals:\n   2:  a  =  \n\nExpected the start of an expression.\n"
        XCTAssertEqual(TerraformEditorModel.firstError(stderr), "line 2: Invalid expression")
        XCTAssertEqual(TerraformEditorModel.firstError("something odd\n"), "something odd")
        XCTAssertNil(TerraformEditorModel.firstError(""))
    }

    func testWhichFilesAreTerraforms() {
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/acme/envs/dev/\(name)") }
        for name in ["main.tf", "prod.tfvars", "main.tofu", "acme.tftest.hcl"] {
            XCTAssertTrue(TerraformEditorModel.isFormattable(url(name)), name)
            XCTAssertTrue(TerraformEditorModel.isTerraform(url(name)), name)
        }
        for name in [".terraform.lock.hcl", "terragrunt.hcl", "main.tf.json", "README.md", "nomad.hcl"] {
            XCTAssertFalse(TerraformEditorModel.isFormattable(url(name)), name)
        }
        XCTAssertTrue(TerraformEditorModel.isFormattable(url("acme.tfmock.hcl")))
        XCTAssertFalse(TerraformEditorModel.isTerraform(url("acme.tfmock.hcl")))
    }

    /// Where `fmt -check` looks: a git top narrower than the home folder,
    /// all of it; anything wider, or no git top, the file's own folder
    /// alone — never a recursive walk of `~`, `/` or a volume.
    func testTheFormatCheckScope() {
        let home = "/Users/acme"
        func scope(_ file: String, top: String?) -> TerraformEditorModel.FormatScope {
            TerraformEditorModel.formatScope(of: URL(fileURLWithPath: file), gitRoot: top.map { URL(fileURLWithPath: $0) }, home: home)
        }
        let checkout = scope("/Users/acme/work/acme-infra/envs/dev/main.tf", top: "/Users/acme/work/acme-infra")
        XCTAssertEqual(checkout.folder.path, "/Users/acme/work/acme-infra")
        XCTAssertTrue(checkout.recursive)
        XCTAssertEqual(checkout.arguments, TerraformCommands.formatCheck)
        let cases: [(file: String, top: String?, folder: String)] = [
            ("/Users/acme/work/acme-infra/envs/dev/main.tf", home, "/Users/acme/work/acme-infra/envs/dev"),  // a dotfiles repository at ~
            ("/Users/acme/main.tf", home, "/Users/acme"),
            ("/Users/acme/main.tf", nil, "/Users/acme"),
            ("/Volumes/Acme/main.tf", "/Volumes/Acme", "/Volumes/Acme"),
            ("/Volumes/Acme/envs/prod/main.tf", "/Volumes/Acme", "/Volumes/Acme/envs/prod"),
            ("/main.tf", "/", "/"),
            ("/Users/main.tf", "/Users", "/Users"),
            ("/tmp/globex/main.tf", nil, "/tmp/globex"),
        ]
        for (file, top, folder) in cases {
            let found = scope(file, top: top)
            XCTAssertEqual(found.folder.path, folder, "\(file) in \(top ?? "no checkout")")
            XCTAssertFalse(found.recursive, "\(file) in \(top ?? "no checkout")")
            XCTAssertEqual(found.arguments, TerraformCommands.formatCheckFolder)
        }
        XCTAssertNotEqual(checkout.key, TerraformEditorModel.FormatScope(folder: checkout.folder, recursive: false).key)
    }

    func testTheBinary() {
        let none = TerraformCLI.resolve(.none, wrapper: URL(fileURLWithPath: "/w/terraform"), shellEnvironment: { [:] }, isExecutable: { _ in true })
        XCTAssertNil(none, "guarded with no OVERTERM_TERRAFORM: nothing, wrapper or not")
        XCTAssertEqual(
            TerraformCLI.resolve(.variable("/opt/acme/terraform"), wrapper: URL(fileURLWithPath: "/w/terraform"), shellEnvironment: { [:] }, isExecutable: { _ in true }),
            URL(fileURLWithPath: "/w/terraform"), "a scenario's wrapper in front")
        XCTAssertEqual(
            TerraformCLI.resolve(.variable("/opt/acme/terraform"), wrapper: nil, shellEnvironment: { [:] }, isExecutable: { _ in true }),
            URL(fileURLWithPath: "/opt/acme/terraform"))
        let onPath = TerraformCLI.resolve(
            .search, wrapper: URL(fileURLWithPath: "/w/terraform"), shellEnvironment: { ["PATH": "/acme/bin:/usr/bin"] },
            isExecutable: { $0 == "/acme/bin/terraform" || $0 == "/opt/homebrew/bin/terraform" })
        XCTAssertEqual(onPath, URL(fileURLWithPath: "/acme/bin/terraform"), "the shell's PATH first; the wrapper never in the user's app")
        let homebrew = TerraformCLI.resolve(.search, wrapper: nil, shellEnvironment: { ["PATH": "/usr/bin"] }, isExecutable: { $0 == "/opt/homebrew/bin/terraform" })
        XCTAssertEqual(homebrew, URL(fileURLWithPath: "/opt/homebrew/bin/terraform"))
        XCTAssertNil(TerraformCLI.resolve(.search, wrapper: nil, shellEnvironment: { [:] }, isExecutable: { _ in false }))
    }
}

final class TerraformBlocksTests: XCTestCase {
    func testBlocksLabelsAndLocals() {
        let text = """
            # a comment with a { brace
            terraform {
              required_version = ">= 1.9"
            }

            variable "acme_name" {
              type    = string
              default = "acme-${"dev"}" // } not a close
            }

            locals {
              tags = { team = "acme", "x" = "}" }
              prefix = "${var.acme_name}-${join("-", ["a", "}"])}"
              /* } */ region = "eu-west-1"
              policy = <<-EOT
                { "Statement": [ { "Effect": "Allow" } }
                EOT
              after_heredoc = 1
            }

            resource "terraform_data" "acme" {
              input = var.acme_name
              lifecycle {
                create_before_destroy = true
              }
            }

            data "aws_ami" "globex" {}
            module "acme_net" { source = "./modules/acme-net" }
            """
        let scanned = TerraformBlocks.scan(text)
        XCTAssertEqual(scanned.blocks.map(\.type), ["terraform", "variable", "locals", "resource", "data", "module"])
        XCTAssertEqual(scanned.blocks.map(\.labels), [[], ["acme_name"], [], ["terraform_data", "acme"], ["aws_ami", "globex"], ["acme_net"]])
        let locals = scanned.blocks[2]
        XCTAssertEqual(locals.attributes.map(\.name), ["tags", "prefix", "region", "policy", "after_heredoc"])
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: scanned.blocks[3].nameRange), "acme")
        XCTAssertEqual(ns.substring(with: scanned.blocks[1].nameRange), "acme_name")
        XCTAssertTrue(ns.substring(with: scanned.blocks[3].range).hasPrefix("resource \"terraform_data\""))
        XCTAssertTrue(ns.substring(with: scanned.blocks[3].range).hasSuffix("}\n}"), ns.substring(with: scanned.blocks[3].range))
        XCTAssertEqual(ns.substring(with: scanned.blocks[2].attributes[1].nameRange), "prefix")
        XCTAssertTrue(scanned.attributes.isEmpty)
    }

    func testTfvarsAttributesAndAnUnclosedBlock() {
        let scanned = TerraformBlocks.scan("acme_name = \"acme-prod\"\nacme_count = 3\ntags = {\n  a = 1\n}\n")
        XCTAssertEqual(scanned.attributes.map(\.name), ["acme_name", "acme_count", "tags"])
        let open = TerraformBlocks.scan("resource \"terraform_data\" \"acme\" {\n  input = \"x\"\n")
        XCTAssertEqual(open.blocks.map(\.labels), [["terraform_data", "acme"]])
        XCTAssertEqual(NSMaxRange(open.blocks[0].range), ("resource \"terraform_data\" \"acme\" {\n  input = \"x\"\n" as NSString).length)
        XCTAssertEqual(TerraformBlocks.scan(""), TerraformBlocks())
        // Comparisons and arrows are not assignments.
        let compare = TerraformBlocks.scan("locals {\n  a = 1 == 2\n  b = { for k, v in x : k => v }\n  c = 1 <= 2\n}\n")
        XCTAssertEqual(compare.blocks.first?.attributes.map(\.name), ["a", "b", "c"])
    }

    /// Whatever it is fed, it ends — a quote never closed, a heredoc never ended.
    func testGarbageEnds() {
        for text in ["\"", "<<EOF\n{", "${", "resource \"a", "/* {", "{{{{", "}}}}", "x = \"${\"", "<<", "<<-"] {
            _ = TerraformBlocks.scan(text)
        }
    }
}

final class TerraformConfigIndexTests: XCTestCase {
    private let main = URL(fileURLWithPath: "/acme/envs/dev/main.tf")
    private let variables = URL(fileURLWithPath: "/acme/envs/dev/variables.tf")

    func testReferencesAtTheCaret() {
        let text =
            "x = var.acme_name\ny = local.tags.team\nz = module.acme_net.vpc_id\nw = data.aws_ami.globex.id\nv = terraform_data.acme.output\nu = each.key\nt = path.module\ns = aws_s3_bucket.logs[0].arn\n"
        let ns = text as NSString
        func at(_ word: String, offset: Int = 2) -> String? {
            TerraformConfigIndex.reference(at: ns.range(of: word).location + offset, in: text)
        }
        XCTAssertEqual(at("var.acme_name", offset: 6), "var.acme_name")
        XCTAssertEqual(at("var.acme_name", offset: 0), "var.acme_name", "on the var part too")
        XCTAssertEqual(at("local.tags"), "local.tags")
        XCTAssertEqual(at("module.acme_net"), "module.acme_net")
        XCTAssertEqual(at("data.aws_ami"), "data.aws_ami.globex")
        XCTAssertEqual(at("terraform_data.acme"), "terraform_data.acme")
        XCTAssertEqual(at("aws_s3_bucket.logs"), "aws_s3_bucket.logs")
        XCTAssertNil(at("each.key"))
        XCTAssertNil(at("path.module"))
        XCTAssertNil(TerraformConfigIndex.reference(at: 0, in: "x = 1\n"))
        XCTAssertEqual(TerraformConfigIndex.reference(at: 2, in: "acme_name = \"acme-prod\"\n", tfvars: true), "var.acme_name")
        XCTAssertNil(TerraformConfigIndex.reference(at: 0, in: ""))
    }

    func testTheIndexAcrossTheModulesFiles() throws {
        let mainText = """
            locals {
              tags = {}
            }
            resource "terraform_data" "acme" {
              input = var.acme_name
            }
            module "acme_net" {
              source = "./modules/acme-net"
            }
            data "aws_ami" "globex" {}
            output "acme_url" { value = 1 }
            """
        let variablesText = "variable \"acme_name\" {\n  default = \"acme-dev\"\n}\n"
        let index = TerraformConfigIndex(files: [(main, mainText), (variables, variablesText)])
        let variable = try XCTUnwrap(index.definition(of: "var.acme_name"))
        XCTAssertEqual(variable.file, variables)
        XCTAssertEqual((variablesText as NSString).substring(with: variable.nameRange), "acme_name")
        XCTAssertEqual(index.definition(of: "local.tags")?.file, main)
        XCTAssertEqual(index.definition(of: "module.acme_net")?.kind, "module")
        XCTAssertEqual(index.definition(of: "data.aws_ami.globex")?.kind, "data")
        XCTAssertEqual(index.definition(of: "terraform_data.acme")?.kind, "resource")
        XCTAssertEqual(index.definition(of: "output.acme_url")?.kind, "output")
        XCTAssertNil(index.definition(of: "var.globex_missing"))
        let symbols = TerraformConfigIndex.definitions(in: mainText, file: main).map(\.address)
        XCTAssertEqual(symbols, ["local.tags", "terraform_data.acme", "module.acme_net", "data.aws_ami.globex", "output.acme_url"])
        let tfvars = TerraformConfigIndex.definitions(in: "acme_name = \"x\"\n", file: URL(fileURLWithPath: "/acme/envs/dev/prod.tfvars"))
        XCTAssertEqual(tfvars.map(\.address), ["tfvars.acme_name"])
    }

    /// F12's index from the folder: open texts over the files, and what is
    /// read from disk bounded in all, not only a file.
    func testLoadingAFolderIsBounded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let padding = String(repeating: "# acme\n", count: 20_000)
        for name in ["a", "b", "c"] {
            try (padding + "variable \"acme_\(name)\" {}\n").write(to: folder.appendingPathComponent("\(name).tf"), atomically: true, encoding: .utf8)
        }
        try "not terraform".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let open = [folder.appendingPathComponent("c.tf").standardizedFileURL.path: "variable \"acme_open\" {}\n"]
        let all = TerraformConfigIndex.load(folder: folder, open: open)
        XCTAssertNotNil(all.definition(of: "var.acme_a"))
        XCTAssertNotNil(all.definition(of: "var.acme_b"))
        XCTAssertNotNil(all.definition(of: "var.acme_open"), "an open file as it is on screen")
        XCTAssertNil(all.definition(of: "var.acme_c"))
        let bounded = TerraformConfigIndex.load(folder: folder, open: [:], byteLimit: padding.utf8.count + 100)
        XCTAssertNotNil(bounded.definition(of: "var.acme_a"))
        XCTAssertNil(bounded.definition(of: "var.acme_b"), "past the budget, not read")
    }
}
