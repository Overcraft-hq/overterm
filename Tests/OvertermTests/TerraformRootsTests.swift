import XCTest

@testable import Overterm

/// Stage 1b's pure parts (analysis 4.11, 4.12, 5.1, 3.2): what a folder's
/// files say, the backends' identities, the classes, the roots and
/// modules of a checkout, the version pill, and the command lines a pane runs.
final class TerraformConfigFactsTests: XCTestCase {
    func testLiteralValuesAndNestedBlocks() {
        let text = """
            terraform {
              required_version = ">= 1.5, < 2.0"
              backend "s3" {
                bucket = "acme-tfstate"
                key    = "prod/network.tfstate"
                region = "eu-west-1"
                secret_key = "acme-hunter2-SECRET"
                dynamodb_table = var.table
              }
            }
            """
        let blocks = TerraformBlocks.scan(text)
        let terraform = blocks.blocks[0]
        XCTAssertEqual(terraform.attributes.first?.value, ">= 1.5, < 2.0")
        let backend = TerraformBlocks.nested(in: terraform, of: text).blocks.first
        XCTAssertEqual(backend?.type, "backend")
        XCTAssertEqual(backend?.labels, ["s3"])
        XCTAssertEqual(backend?.attributes.first { $0.name == "bucket" }?.value, "acme-tfstate")
        XCTAssertNil(backend?.attributes.first { $0.name == "dynamodb_table" }?.value, "an expression is no literal")

        let facts = TerraformConfigFacts.read([text])
        XCTAssertEqual(facts.backend?.type, "s3")
        XCTAssertEqual(facts.backend?.settings, ["bucket": "acme-tfstate", "key": "prod/network.tfstate", "region": "eu-west-1"])
        XCTAssertFalse(String(reflecting: facts).contains("acme-hunter2-SECRET"), "secret_key is never decoded")
        XCTAssertEqual(facts.requiredVersion, ">= 1.5, < 2.0")
    }

    func testProvidersTypesCommandsAndStates() {
        let text = """
            terraform {
              required_providers {
                aws = {
                  source  = "hashicorp/aws"
                  version = "~> 5.0"
                }
                random = { source = "hashicorp/random" }
              }
            }

            provider "aws" {
              profile = "acme-prod-admin"
              assume_role {
                role_arn = "arn:aws:iam::123456789012:role/acme-deploy"
              }
            }

            resource "null_resource" "acme" {
              provisioner "local-exec" {
                command = "echo acme"
              }
            }

            data "terraform_remote_state" "net" {
              backend = "local"
              config = {
                path = "../net/terraform.tfstate"
              }
            }

            data "local_command" "acme" {
              command = "date"
            }

            module "net" {
              source = "../../modules/acme-net"
            }
            """
        let facts = TerraformConfigFacts.read([text])
        XCTAssertEqual(facts.requiredProviders, ["aws": "hashicorp/aws", "random": "hashicorp/random"])
        XCTAssertEqual(facts.providers.first?.settings["profile"], "acme-prod-admin")
        XCTAssertEqual(facts.providers.first?.settings["role_arn"], "arn:aws:iam::123456789012:role/acme-deploy")
        XCTAssertTrue(facts.hasProvisioner)
        XCTAssertEqual(facts.remoteStates, [TerraformConfigFacts.RemoteState(backend: "local", path: "../net/terraform.tfstate")])
        XCTAssertTrue(facts.types.contains("data.local_command"))
        XCTAssertEqual(facts.moduleSources, ["../../modules/acme-net"])
        XCTAssertEqual(facts.accountIDs, ["123456789012"])
        XCTAssertEqual(facts.providerNames, ["aws", "random", "null", "terraform", "local"])
    }

    func testCloudBlock() {
        let text = """
            terraform {
              cloud {
                organization = "globex"
                workspaces {
                  name = "net-prod"
                }
              }
            }
            """
        let backend = TerraformConfigFacts.read([text]).backend
        XCTAssertEqual(backend?.type, "cloud")
        XCTAssertEqual(backend?.settings["organization"], "globex")
        XCTAssertEqual(backend?.workspaceName, "net-prod")
    }

    /// `init` keeps the backend's whole configuration, `-backend-config`
    /// passwords included (spike 4): only the allow-listed keys are decoded.
    func testTheInitRecordIsReadThroughTheAllowList() throws {
        let record = """
            {"version":3,"terraform_version":"1.17.1","backend":{"type":"http","config":{
              "address":"http://127.0.0.1:8080/state/acme","username":"acme","password":"globex-BKPW",
              "lock_address":"http://127.0.0.1:8080/lock","skip_cert_verification":false},"hash":1}}
            """
        let backend = try XCTUnwrap(TerraformInitRecord.backend(from: Data(record.utf8)))
        XCTAssertEqual(backend.type, "http")
        XCTAssertEqual(backend.settings, ["address": "http://127.0.0.1:8080/state/acme"])
        XCTAssertFalse(String(reflecting: backend).contains("globex-BKPW"))
        XCTAssertNil(TerraformInitRecord.backend(from: Data("not json".utf8)))
    }

    func testLockFileAndModulesManifest() {
        let lock = """
            # This file is maintained automatically by "terraform init".
            provider "registry.terraform.io/hashicorp/random" {
              version = "3.6.3"
              hashes = ["h1:acme"]
            }
            provider "registry.opentofu.org/hashicorp/null" {
              version = "3.2.1"
            }
            """
        XCTAssertEqual(TerraformLockFile.providers(in: lock).map(\.type), ["random", "null"])
        let manifest = #"{"Modules":[{"Key":"","Source":"","Dir":"."},{"Key":"net","Source":"../../modules/acme-net","Dir":"../../modules/acme-net"}]}"#
        XCTAssertEqual(TerraformModulesManifest.directories(from: Data(manifest.utf8)), ["../../modules/acme-net"])
    }
}

final class TerraformStateIdentityTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/work/acme-infra/envs/dev")

    private func backend(_ type: String, _ settings: [String: String]) -> TerraformConfigFacts.Backend {
        TerraformConfigFacts.Backend(type: type, settings: settings)
    }

    func testEveryBackend() {
        // local: `path` for default only; others under terraform.tfstate.d (spike 28).
        let local = backend("local", ["path": "acme.tfstate"])
        XCTAssertEqual(TerraformStateIdentity.of(backend: local, workspace: "default", root: root)?.location, "/work/acme-infra/envs/dev/acme.tfstate")
        XCTAssertEqual(
            TerraformStateIdentity.of(backend: local, workspace: "acme-stage", root: root)?.location,
            "/work/acme-infra/envs/dev/terraform.tfstate.d/acme-stage/terraform.tfstate")
        XCTAssertEqual(TerraformStateIdentity.of(backend: nil, workspace: "default", root: root)?.location, "/work/acme-infra/envs/dev/terraform.tfstate")
        let s3 = backend("s3", ["bucket": "acme-tfstate", "key": "net.tfstate"])
        XCTAssertEqual(TerraformStateIdentity.of(backend: s3, workspace: "default", root: root)?.location, "acme-tfstate/net.tfstate")
        XCTAssertEqual(TerraformStateIdentity.of(backend: s3, workspace: "acme-stage", root: root)?.location, "acme-tfstate/env:/acme-stage/net.tfstate")
        let prefixed = backend("s3", ["bucket": "acme-tfstate", "key": "net.tfstate", "workspace_key_prefix": "ws"])
        XCTAssertEqual(TerraformStateIdentity.of(backend: prefixed, workspace: "eu", root: root)?.location, "acme-tfstate/ws/eu/net.tfstate")
        XCTAssertEqual(
            TerraformStateIdentity.of(backend: backend("gcs", ["bucket": "globex-state", "prefix": "net"]), workspace: "default", root: root)?.location,
            "globex-state/net/default.tfstate")
        let azure = backend("azurerm", ["storage_account_name": "acmesa", "container_name": "tfstate", "key": "net.tfstate"])
        XCTAssertEqual(TerraformStateIdentity.of(backend: azure, workspace: "dev", root: root)?.location, "acmesa/tfstate/net.tfstateenv:dev")
        XCTAssertEqual(
            TerraformStateIdentity.of(backend: backend("kubernetes", ["secret_suffix": "acme"]), workspace: "default", root: root)?.location,
            "tfstate-default-acme")
        XCTAssertEqual(
            TerraformStateIdentity.of(backend: backend("http", ["address": "https://u:p@state.acme.test:8443/s/acme?x=1"]), workspace: "default", root: root)?
                .location, "state.acme.test:8443/s/acme", "host and path only")
        var cloud = backend("cloud", ["organization": "globex"])
        cloud.workspaceName = "net-prod"
        XCTAssertEqual(TerraformStateIdentity.of(backend: cloud, workspace: "default", root: root)?.location, "globex/net-prod")
        XCTAssertNil(TerraformStateIdentity.of(backend: backend("s3", ["bucket": "acme-tfstate"]), workspace: "default", root: root), "partial")
        XCTAssertNil(TerraformStateIdentity.of(backend: backend("pg", [:]), workspace: "default", root: root), "its location is a secret")
    }

    func testTheChipSaysTheBackend() {
        XCTAssertEqual(
            TerraformStateIdentity.summary(of: backend("s3", ["bucket": "acme-tfstate", "key": "prod/network.tfstate", "region": "eu-west-1"]), workspace: "default"),
            "s3 · acme-tfstate/prod/network.tfstate · eu-west-1")
        XCTAssertEqual(TerraformStateIdentity.summary(of: nil, workspace: "default"), "local · terraform.tfstate")
        var cloud = backend("cloud", ["organization": "globex"])
        cloud.workspaceName = "net-prod"
        XCTAssertEqual(TerraformStateIdentity.summary(of: cloud, workspace: "default"), "cloud · globex/net-prod")
    }

    func testTheBackendChangedSinceInit() {
        let hcl = backend("s3", ["bucket": "acme-tfstate", "key": "a.tfstate"])
        XCTAssertFalse(TerraformStateIdentity.changedSinceInit(config: hcl, record: hcl))
        XCTAssertTrue(TerraformStateIdentity.changedSinceInit(config: hcl, record: backend("s3", ["bucket": "acme-tfstate", "key": "b.tfstate"])))
        XCTAssertTrue(TerraformStateIdentity.changedSinceInit(config: hcl, record: backend("local", [:])))
        XCTAssertFalse(TerraformStateIdentity.changedSinceInit(config: hcl, record: nil), "not initialised: nothing to compare")
    }
}

final class TerraformClassifierTests: XCTestCase {
    private let pattern = TerraformClassifier.pattern("")
    private let folder = URL(fileURLWithPath: "/work/acme-infra/x")

    private func classify(
        path: String = "envs/x", workspace: String = "default", backend: TerraformConfigFacts.Backend = .init(type: "local"),
        config: TerraformConfigFacts = .init(), lock: [TerraformLockFile.Provider]? = [], varFiles: [String] = [], profile: String? = nil,
        set: TerraformClass? = nil, seen: Set<TerraformStateIdentity> = [], accounts: Set<String> = [], terragrunt: Bool = false
    ) -> TerraformClass {
        let signals = TerraformSignals(
            workspace: workspace, path: path, backends: [backend], varFiles: varFiles, awsProfile: profile, config: config, terragruntTree: terragrunt)
        let identity = TerraformStateIdentity.of(backend: backend, workspace: workspace, root: folder)
        return TerraformClassifier.classify(
            signals, backend: backend, lockProviders: lock, identity: identity, productionIdentities: seen, set: set, pattern: pattern, accounts: accounts
        ).rootClass
    }

    /// 5.1's names, pinned as Kubernetes' are.
    func testProductionByName() {
        for path in ["acme-api/prod", "infra/envs/prd/eks", "prod1", "prd01", "envs/production2", "envs/prod-copy", "envs/prod2-eu"] {
            XCTAssertEqual(classify(path: path), .production, path)
        }
        XCTAssertEqual(classify(backend: .init(type: "s3", settings: ["bucket": "acme-tfstate-production", "key": "a"])), .production)
        XCTAssertEqual(classify(backend: .init(type: "gcs", settings: ["bucket": "globex-live"])), .production)
        XCTAssertEqual(classify(workspace: "production"), .production)
        XCTAssertEqual(classify(varFiles: ["prod.tfvars"]), .production)
        XCTAssertEqual(classify(profile: "acme-prod-admin"), .production, "AWS_PROFILE's name")
        var config = TerraformConfigFacts()
        config.providers = [.init(name: "google", settings: ["project": "globex-prd"])]
        XCTAssertEqual(classify(config: config), .production, "a literal project")
        var account = TerraformConfigFacts()
        account.accountIDs = ["123456789012"]
        XCTAssertEqual(classify(config: account, accounts: ["123456789012"]), .production, "an account listed")
        for path in ["product-catalog", "delivery", "envs/staging", "reproduce", "envs/dev"] {
            XCTAssertNotEqual(classify(path: path), .production, path)
        }
    }

    /// Terragrunt's `live/<account>/…` layout: `live` is structure there.
    func testTerragruntsLiveIsStructure() {
        XCTAssertEqual(classify(path: "live/acme-dev/net", terragrunt: true), .local)
        XCTAssertEqual(classify(path: "live/acme-dev/net"), .production, "outside a Terragrunt tree it is a word like any")
        XCTAssertEqual(classify(path: "live/acme-prod/net", terragrunt: true), .production)
    }

    /// Local is strict: "local backend and local providers" is not local (spike 21).
    func testLocalIsStrict() {
        var local = TerraformConfigFacts()
        local.types = ["random_pet", "local_file"]
        let lock = [TerraformLockFile.Provider("registry.terraform.io/hashicorp/random")!, .init("registry.terraform.io/hashicorp/local")!]
        XCTAssertEqual(classify(config: local, lock: lock), .local, "random + local + a lock file")
        XCTAssertEqual(classify(config: local, lock: nil), .remote, "no lock file")
        var exec = local
        exec.hasProvisioner = true
        XCTAssertEqual(classify(config: exec, lock: lock), .remote, "a local-exec")
        var command = local
        command.types.insert("data.local_command")
        XCTAssertEqual(classify(config: command, lock: lock), .remote, "data \"local_command\"")
        var remote = local
        remote.remoteStates = [.init(backend: "s3", path: nil)]
        XCTAssertEqual(classify(config: remote, lock: lock), .remote, "terraform_remote_state")
        var kube = local
        kube.types.insert("kubernetes_namespace")
        XCTAssertEqual(classify(config: kube, lock: lock), .remote, "a kubernetes provider with no literal context")
        XCTAssertEqual(classify(backend: .init(type: "local", settings: ["path": "/var/acme.tfstate"]), config: local, lock: lock), .remote)
        XCTAssertEqual(classify(backend: .init(type: "s3", settings: ["bucket": "acme-dev", "key": "a"]), config: local, lock: lock), .remote)
        var builtin = TerraformConfigFacts()
        builtin.types = ["terraform_data"]
        XCTAssertEqual(classify(config: builtin, lock: nil), .local, "the builtin provider needs no lock file")
    }

    /// A class set by hand only raises; production sticks to its identity.
    func testPrecedenceAndStickiness() {
        var local = TerraformConfigFacts()
        local.types = ["terraform_data"]
        XCTAssertEqual(classify(config: local, set: .remote), .remote)
        XCTAssertEqual(classify(config: local, set: .production), .production)
        XCTAssertEqual(classify(path: "envs/prod", config: local, set: .local), .production, "a hand-set class lowers nothing")
        let s3 = TerraformConfigFacts.Backend(type: "s3", settings: ["bucket": "acme-tfstate", "key": "net/a.tfstate"])
        let identity = TerraformStateIdentity.of(backend: s3, workspace: "default", root: folder)!
        XCTAssertEqual(classify(path: "envs/p", backend: s3), .remote)
        XCTAssertEqual(classify(path: "envs/p", backend: s3, seen: [identity]), .production, "renamed, on a key with no prod in it")
    }

    func testABrokenPatternIsTheDefault() {
        XCTAssertEqual(TerraformClassifier.pattern("(").pattern, TerraformClassifier.defaultPattern)
        XCTAssertEqual(TerraformClassifier.pattern("  ").pattern, TerraformClassifier.defaultPattern)
        XCTAssertTrue(TerraformClassifier.matches("acme-blue", TerraformClassifier.pattern("blue")))
    }

    func testInside() {
        XCTAssertTrue(TerraformClassifier.isInside("../net/terraform.tfstate", rootPath: "envs/dev"))
        XCTAssertTrue(TerraformClassifier.isInside("../../x.tfstate", rootPath: "envs/dev"))
        XCTAssertFalse(TerraformClassifier.isInside("../../../x.tfstate", rootPath: "envs/dev"))
        XCTAssertFalse(TerraformClassifier.isInside("/tmp/x", rootPath: "envs/dev"))
        XCTAssertFalse(TerraformClassifier.isInside("~/x", rootPath: ""))
    }

    func testRootSettings() {
        let settings = TerraformRootSettings.all(from: .entries(["envs/p": ["class": .string("production"), "displayName": .string("Acme prod")]]))
        XCTAssertEqual(settings["envs/p"], TerraformRootSettings(rootClass: .production, displayName: "Acme prod"))
        XCTAssertNil(TerraformRootSettings(fields: ["class": .string("bogus")]).rootClass)
        var exec = TerraformConfigFacts()
        exec.hasProvisioner = true
        XCTAssertEqual(classify(config: exec, set: .local), .remote, "local by hand is not a class the rule gave")
    }
}

final class TerraformRootGuessTests: XCTestCase {
    private func facts(_ text: String) -> TerraformConfigFacts { TerraformConfigFacts.read([text]) }

    func testRootsModulesExamplesAndTerragrunt() {
        let listing = TerraformRootScan.listing(
            [
                "envs/dev/main.tf", "envs/dev/dev.tfvars", "envs/prod/main.tf", "envs/prod/.terraform.lock.hcl", "modules/acme-net/main.tf",
                "shared/tags/main.tf", "examples/basic/main.tf", "envs/dev/.terraform/modules/net/main.tf", "x/.terragrunt-cache/a/main.tf",
                "node_modules/a/main.tf", "root.hcl", "live/acme-dev/net/terragrunt.hcl", "envs/dev/tests/a.tftest.hcl",
            ].joined(separator: "\0"))
        XCTAssertFalse(listing.capped)
        XCTAssertNil(listing.folders["envs/dev/.terraform/modules/net"], ".terraform is init's")
        XCTAssertNil(listing.folders["x/.terragrunt-cache/a"])
        XCTAssertNil(listing.folders["node_modules/a"])
        let folders = TerraformRootGuess.classify(
            folders: listing.folders,
            facts: [
                "envs/dev": facts("module \"net\" {\n  source = \"../../modules/acme-net\"\n}\nmodule \"tags\" {\n  source = \"../../shared/tags\"\n}\n"),
                "envs/prod": facts("terraform {\n  backend \"s3\" {\n    bucket = \"acme-tfstate\"\n  }\n}\n"),
            ],
            terragrunt: ["live/acme-dev/net": "terraform {\n  source = \"../../../modules/acme-net\"\n}\n"])
        let kinds = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0.kind) })
        XCTAssertEqual(kinds["envs/dev"], .root)
        XCTAssertEqual(kinds["envs/prod"], .root)
        XCTAssertEqual(kinds["modules/acme-net"], .module)
        XCTAssertEqual(kinds["shared/tags"], .module, "called by a root")
        XCTAssertEqual(kinds["examples/basic"], .example)
        XCTAssertEqual(kinds[""], .terragruntConfig, "root.hcl")
        XCTAssertEqual(kinds["live/acme-dev/net"], .terragruntUnit)
        XCTAssertNil(kinds["envs/dev/tests"], "only test files: no configuration")
        XCTAssertEqual(folders.first { $0.path == "envs/dev" }?.autoVarFiles, [], "dev.tfvars is chosen, not auto-loaded")
    }

    func testModulesAndTheRootsThatCallThem() {
        let calls: [String: Set<String>] = ["envs/dev": ["modules/net"], "envs/prod": ["modules/net"], "modules/net": ["modules/subnet"]]
        let callers = TerraformRootGuess.callers(of: ["modules/net", "modules/subnet", "modules/unused"], roots: ["envs/dev", "envs/prod"], calls: calls)
        XCTAssertEqual(callers["modules/net"], ["envs/dev", "envs/prod"])
        XCTAssertEqual(callers["modules/subnet"], ["envs/dev", "envs/prod"], "through another module")
        XCTAssertEqual(callers["modules/unused"], [])
        let touched = TerraformRootGuess.touched(roots: ["envs/dev", "envs/prod"], changed: ["modules/subnet/main.tf"], moduleCallers: callers)
        XCTAssertEqual(touched, ["envs/dev", "envs/prod"], "a shared module's edit touches every root that calls it")
        XCTAssertEqual(TerraformRootGuess.touched(roots: ["envs/dev", "envs/prod"], changed: ["envs/dev/main.tf"], moduleCallers: callers), ["envs/dev"])
    }

    func testLocalSources() {
        XCTAssertEqual(TerraformRootGuess.localSource("../../modules/net", from: "envs/dev"), "modules/net")
        XCTAssertEqual(TerraformRootGuess.localSource("./net", from: "envs/dev"), "envs/dev/net")
        XCTAssertNil(TerraformRootGuess.localSource("../../../x", from: "envs/dev"), "climbs out")
        XCTAssertNil(TerraformRootGuess.localSource("hashicorp/consul/aws", from: "envs/dev"))
        XCTAssertNil(TerraformRootGuess.localSource("git::https://example.test/acme.git", from: ""))
    }

    func testTheListingIsCapped() {
        let many = (0..<(TerraformRootScan.maxFolders + 5)).map { "f\($0)/main.tf" }.joined(separator: "\0")
        let listing = TerraformRootScan.listing(many)
        XCTAssertTrue(listing.capped)
        XCTAssertEqual(listing.folders.count, TerraformRootScan.maxFolders)
    }

    /// The facts on disk: the workspace `.terraform/environment` selects, a
    /// local backend's workspaces and state, the init record, the version
    /// file found walking up — never above the checkout.
    func testFactsOnDisk() throws {
        let checkout = FileManager.default.temporaryDirectory.appendingPathComponent("acme-facts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: checkout) }
        let root = checkout.appendingPathComponent("envs/dev", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".terraform"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("terraform.tfstate.d/acme-stage"), withIntermediateDirectories: true)
        try "terraform {\n  required_version = \"~> 1.9\"\n}\nresource \"terraform_data\" \"acme\" {}\n".write(
            to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try "acme-stage\n".write(to: root.appendingPathComponent(".terraform/environment"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("terraform.tfstate.d/acme-stage/terraform.tfstate"), atomically: true, encoding: .utf8)
        try "terraform 1.9.8\n".write(to: checkout.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        // Above the checkout: never read.
        let facts = TerraformRootFacts.read(root: root, checkout: checkout)
        XCTAssertEqual(facts.workspace, "acme-stage")
        XCTAssertTrue(facts.workspaceFromFile)
        XCTAssertEqual(facts.localWorkspaces, ["acme-stage"])
        XCTAssertTrue(facts.localStateExists)
        XCTAssertEqual(facts.pins, TerraformVersionPins(required: "~> 1.9", pin: "1.9.8", pinFile: ".tool-versions"))
        XCTAssertEqual(facts.backend.type, "local")
        let none = TerraformRootFacts.pins(from: URL(fileURLWithPath: "/"), checkout: URL(fileURLWithPath: "/"), required: nil)
        XCTAssertNil(none.pin, "the walk ends at /")
    }
}

final class TerraformVersionTests: XCTestCase {
    private let v = TerraformVersion("1.17.1")!

    func testConstraints() {
        XCTAssertEqual(v.satisfies(">= 1.5, < 2.0"), true)
        XCTAssertEqual(v.satisfies("~> 1.9"), true, "1.x from 1.9")
        XCTAssertEqual(v.satisfies("~> 1.9.0"), false, "1.9.x only")
        XCTAssertEqual(v.satisfies("= 1.17.1"), true)
        XCTAssertEqual(v.satisfies("1.17.1"), true)
        XCTAssertEqual(v.satisfies("!= 1.17.1"), false)
        XCTAssertEqual(v.satisfies("< 1.10"), false)
        XCTAssertNil(v.satisfies(">= banana"))
        XCTAssertTrue(TerraformVersion("1.10.0-rc1")! < TerraformVersion("1.10.0")!)
        XCTAssertTrue(TerraformVersion("1.9")! < TerraformVersion("1.10")!)
    }

    func testPinsAndThePill() {
        XCTAssertEqual(v.matchesPin("1.17"), true)
        XCTAssertEqual(v.matchesPin("1.9.0"), false)
        XCTAssertNil(v.matchesPin("latest"))
        XCTAssertEqual(TerraformVersionPins(required: "~> 1.9.0").mismatch(v), "1.17.1 ≠ required ~> 1.9.0")
        XCTAssertNil(TerraformVersionPins(required: ">= 1.5").mismatch(v))
        XCTAssertEqual(TerraformVersionPins(pin: "1.9.0", pinFile: ".terraform-version").mismatch(v), "1.17.1 ≠ 1.9.0 (.terraform-version)")
        XCTAssertEqual(TerraformVersionPins.toolVersions("nodejs 22\nterraform 1.9.0\n"), "1.9.0")
        XCTAssertEqual(TerraformVersionPins.miseToml("[env]\nterraform = \"x\"\n[tools]\nnode = \"22\"\nterraform = \"1.9\"\n"), "1.9")
        XCTAssertEqual(TerraformVersionPins.terraformVersionFile("1.9.3\n"), "1.9.3")
        XCTAssertEqual(TerraformCLI.parseVersion(Data(#"{"terraform_version":"1.17.1","platform":"darwin_arm64","terraform_outdated":false}"#.utf8)), "1.17.1")
        XCTAssertNil(TerraformCLI.parseVersion(Data("Terraform v1.17.1".utf8)))
    }

    /// `version -json` is the one terraform 1b runs; it is a line the builders make.
    func testVersionIsBuilt() {
        XCTAssertEqual(TerraformCommands.version, ["version", "-json"])
        XCTAssertNil(TerraformCommands.refusal(TerraformCommands.version))
        XCTAssertNotNil(TerraformCommands.refusal(["version", "-json", "-chdir=x"]))
    }
}

final class TerraformCommandLineTests: XCTestCase {
    func testWhatALineSays() {
        let line = TerraformCommandLine.parse("env TF_WORKSPACE=prod terraform -chdir=envs/prod apply")
        XCTAssertEqual(line?.tool, "terraform")
        XCTAssertEqual(line?.operation, "apply")
        XCTAssertEqual(line?.chdir, "envs/prod")
        XCTAssertEqual(line?.workspace, "prod")
        XCTAssertEqual(line?.isWrite, true)
        XCTAssertEqual(TerraformCommandLine.parse("sudo terraform state rm aws_instance.web")?.operation, "state rm")
        XCTAssertEqual(TerraformCommandLine.parse("sudo terraform state rm aws_instance.web")?.isWrite, true)
        XCTAssertEqual(TerraformCommandLine.parse("terraform state list")?.isWrite, false)
        XCTAssertEqual(TerraformCommandLine.parse("cd envs/dev && terraform plan -out=x | tee log")?.operation, "plan")
        XCTAssertEqual(TerraformCommandLine.parse("terraform plan -auto-approve")?.isWrite, true, "-auto-approve anywhere")
        XCTAssertEqual(TerraformCommandLine.parse("aws-vault exec acme-prod -- tofu destroy")?.tool, "tofu")
        XCTAssertEqual(TerraformCommandLine.parse("bash -c 'terraform workspace delete acme'")?.operation, "workspace delete")
        let all = TerraformCommandLine.parse("terragrunt run --all apply")
        XCTAssertEqual(all?.operation, "run --all apply")
        XCTAssertEqual(all?.isWrite, true)
        XCTAssertEqual(TerraformCommandLine.parse("terragrunt run-all destroy")?.isWrite, true)
        XCTAssertEqual(TerraformCommandLine.parse("terragrunt apply-all")?.isWrite, true)
        XCTAssertEqual(TerraformCommandLine.parse("terragrunt run --all plan")?.isWrite, false)
        XCTAssertNil(TerraformCommandLine.parse("echo terraform apply"))
        XCTAssertNil(TerraformCommandLine.parse("git status"))
    }

    func testProbably() {
        let make = TerraformCommandLine.parse("make apply")
        XCTAssertEqual(make?.probably, true)
        XCTAssertEqual(make?.operation, "apply")
        XCTAssertEqual(TerraformCommandLine.parse("./deploy-prod.sh")?.probably, true)
        XCTAssertNil(TerraformCommandLine.parse("make apply", probable: false))
    }

    func testWhatAProcessSays() {
        XCTAssertEqual(TerraformCommandLine.parse(arguments: ["/opt/homebrew/bin/terraform", "apply", "-input=false"])?.operation, "apply")
        XCTAssertEqual(TerraformCommandLine.parse(arguments: ["/bin/bash", "-p", "/tmp/acme/bin/terraform", "console"])?.operation, "console")
        XCTAssertNil(TerraformCommandLine.parse(arguments: ["/bin/bash", "/tmp/acme/build.sh"]))
        XCTAssertNil(TerraformCommandLine.parse(arguments: ["/usr/bin/git", "status"]))
    }
}

final class TerraformPaneWarningTests: XCTestCase {
    func testTheHeaderSaysWhereAndWhat() {
        var facts = TerraformRootFacts()
        facts.config.backend = .init(type: "s3", settings: ["bucket": "acme-tfstate", "key": "prod/network.tfstate", "region": "eu-west-1"])
        let warning = TerraformPaneWarning.make(
            tool: "terraform", operation: "apply", isWrite: true, folder: URL(fileURLWithPath: "/work/acme-infra/envs/prod"),
            checkout: URL(fileURLWithPath: "/work/acme-infra"), facts: facts, workspaceVariable: nil, dataDirVariable: nil,
            awsProfile: "acme-prod-admin", probably: false, settings: TerraformClassSettings(), identities: [])
        XCTAssertEqual(warning.label, "⛰ envs/prod · workspace default · s3 · acme-tfstate/prod/network.tfstate · eu-west-1 · AWS_PROFILE acme-prod-admin · apply")
        XCTAssertTrue(warning.isProduction)
        XCTAssertTrue(warning.help.contains("A notice, not a guard"))
        let inherited = TerraformPaneWarning.make(
            tool: "terraform", operation: "plan", isWrite: false, folder: URL(fileURLWithPath: "/work/acme-infra/envs/dev"),
            checkout: URL(fileURLWithPath: "/work/acme-infra"), facts: TerraformRootFacts(), workspaceVariable: "acme-ws", dataDirVariable: "/tmp/x",
            awsProfile: nil, probably: true, settings: TerraformClassSettings(), identities: [])
        XCTAssertEqual(inherited.workspace, "acme-ws", "TF_WORKSPACE decides")
        XCTAssertTrue(inherited.help.contains("TF_WORKSPACE=acme-ws"))
        XCTAssertTrue(inherited.inheritedDataDir)
        XCTAssertTrue(inherited.label.hasPrefix("⛰ probably envs/dev"))
    }

    /// Only the names the header shows are kept from a process's environment.
    func testOnlyTheNamesAreRead() {
        let names = TerraformProcess.environmentNames([
            "TF_WORKSPACE": "acme-ws", "AWS_PROFILE": "acme-dev", "AWS_SECRET_ACCESS_KEY": "acme-hunter2-SECRET", "TF_DATA_DIR": "",
        ])
        XCTAssertEqual(names.workspace, "acme-ws")
        XCTAssertEqual(names.profile, "acme-dev")
        XCTAssertNil(names.dataDir)
        XCTAssertFalse(String(reflecting: names).contains("acme-hunter2-SECRET"))
    }

    /// terraform changes its own folder to `-chdir`'s: a running one's cwd is the root already.
    func testTheFolderOfAProcess() {
        let line = TerraformCommandLine.parse(arguments: ["terraform", "-chdir=envs/prod", "plan"])!
        var process = TerraformProcess(pid: 1, line: line, cwd: "/work/acme-infra")
        XCTAssertEqual(process.folder?.path, "/work/acme-infra/envs/prod", "before it changed folder")
        process.cwd = "/work/acme-infra/envs/prod"
        XCTAssertEqual(process.folder?.path, "/work/acme-infra/envs/prod", "after")
        process.line = TerraformCommandLine.parse(arguments: ["terraform", "-chdir=../dev", "plan"])!
        process.cwd = "/work/acme-infra/envs/prod"
        XCTAssertEqual(process.folder?.path, "/work/acme-infra/envs/dev")
    }

    func testInheritedNotes() {
        XCTAssertEqual(TerraformInheritedEnvironment([:]).notes, [])
        XCTAssertEqual(TerraformInheritedEnvironment(["TF_WORKSPACE": "acme", "TF_DATA_DIR": "/x"]).notes.count, 2)
    }

    func testElapsed() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(TerraformInfoRow.elapsed(since: 990 * 1_000_000, now: now), "10s")
        XCTAssertEqual(TerraformInfoRow.elapsed(since: 866 * 1_000_000, now: now), "2m 14s")
    }

    /// A terraform in this process's tree is found by pid, its folder, its
    /// operation and its workspace variable read; nothing else of its
    /// environment. A stand-in script, never the real terraform.
    func testAProcessInTheTreeIsFound() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acme-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("terraform")
        try "#!/bin/bash\nsleep 20\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "apply", "-chdir=envs/prod"]
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "TF_WORKSPACE": "acme-ws", "AWS_SECRET_ACCESS_KEY": "acme-hunter2-SECRET"]
        try process.run()
        defer {
            // The exact pid, never a pattern (CLAUDE.md).
            kill(process.processIdentifier, SIGTERM)
            process.waitUntilExit()
        }
        var found: TerraformProcess?
        for _ in 0..<50 {
            found = TerraformProcesses.find(under: getpid()).first { $0.pid == process.processIdentifier }
            if found != nil { break }
            usleep(100_000)
        }
        let terraform = try XCTUnwrap(found)
        XCTAssertEqual(terraform.line.operation, "apply")
        // macOS hides an Apple-signed binary's environment (bash here); a
        // real terraform's TF_WORKSPACE is read (the scenario's).
        XCTAssertTrue(terraform.workspaceVariable == nil || terraform.workspaceVariable == "acme-ws")
        XCTAssertTrue(terraform.folder?.path.hasSuffix(folder.lastPathComponent + "/envs/prod") == true, terraform.folder?.path ?? "")
        XCTAssertFalse(String(reflecting: terraform).contains("acme-hunter2-SECRET"))
    }
}

final class TerraformDiffNoiseTests: XCTestCase {
    /// `init` writes ~50 MB under `.terraform/providers`: the changes pane
    /// doesn't count it; the selection and modules do.
    func testInitsWritesAreNoise() {
        XCTAssertTrue(DiffModel.isNoise("/work/acme/envs/dev/.terraform/providers/registry.terraform.io/hashicorp/null/3.2.1/darwin_arm64"))
        XCTAssertTrue(DiffModel.isNoise("/work/acme/x/.terragrunt-cache/abc/def"))
        XCTAssertFalse(DiffModel.isNoise("/work/acme/envs/dev/.terraform"), "environment, terraform.tfstate")
        XCTAssertFalse(DiffModel.isNoise("/work/acme/envs/dev/.terraform/"), "as FSEvents says a folder")
        XCTAssertTrue(DiffModel.isNoise("/work/acme/envs/dev/.terraform/providers/"))
        XCTAssertFalse(DiffModel.isNoise("/work/acme/envs/dev/.terraform/modules"))
        XCTAssertFalse(DiffModel.isNoise("/work/acme/envs/dev/.terraform/modules/net"))
        XCTAssertFalse(DiffModel.isNoise("/work/acme/envs/dev"))
    }

    func testATerminalInARootIsATerraformTab() {
        XCTAssertEqual(TabKind.of(agent: nil, title: "zsh", hasPort: false, terraform: true), .terraform)
        XCTAssertEqual(TabKind.of(agent: nil, title: "ssh acme", hasPort: false, terraform: true), .ssh, "it went elsewhere")
        XCTAssertEqual(TabKind.terraform.symbol, "square.stack.3d.up")
    }

    @MainActor func testProductionIdentitiesAreKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acme-roots-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let identity = TerraformStateIdentity(product: "terraform", backend: "s3", location: "acme-tfstate/net.tfstate")
        TerraformRootStore(url: url).rememberProduction(identity)
        XCTAssertEqual(TerraformRootStore(url: url).productionIdentities, [identity])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("acme-tfstate/net.tfstate"))
    }
}

/// The review of stage 1b: the run's own files as signals, Kubernetes'
/// contexts, credentials in an address, what is remembered as production,
/// which files matter, the nearest root, the walk outside git.
final class TerraformRootsReviewTests: XCTestCase {
    private let checkout = URL(fileURLWithPath: "/work/acme-infra")

    /// 5.1's signal 4 from argv: the var files and backend-config files the run names.
    func testTheRunsVarFilesAndBackendConfigFiles() {
        let line = TerraformCommandLine.parse("terraform -chdir=infra/net plan -var-file=prod.tfvars -backend-config=backend/prod.s3.tfbackend")
        XCTAssertEqual(line?.operation, "plan")
        XCTAssertEqual(line?.chdir, "infra/net")
        XCTAssertEqual(line?.varFiles, ["prod.tfvars"])
        XCTAssertEqual(line?.backendConfigFiles, ["backend/prod.s3.tfbackend"])
        let spaced = TerraformCommandLine.parse(arguments: ["terraform", "apply", "-var-file", "globex-prod.tfvars", "--var-file=common.tfvars"])
        XCTAssertEqual(spaced?.operation, "apply", "the value after -var-file is no operation")
        XCTAssertEqual(spaced?.varFiles, ["globex-prod.tfvars", "common.tfvars"])
        let pairs = TerraformCommandLine.parse(arguments: [
            "terraform", "init", "-backend-config=password=acme-SECRET-PW", "-backend-config", "token=acme-SECRET-TK", "-backend-config", "prod.hcl",
        ])
        XCTAssertEqual(pairs?.operation, "init")
        XCTAssertEqual(pairs?.backendConfigFiles, ["prod.hcl"], "a key=value pair is never kept")
        XCTAssertFalse(String(reflecting: pairs).contains("SECRET"))
    }

    /// `terraform -chdir=infra/net plan -var-file=prod.tfvars` in a neutral
    /// root on a neutral key: production, by the run's own file.
    func testTheHeaderUsesTheRunsFiles() {
        var facts = TerraformRootFacts()
        facts.config.backend = .init(type: "s3", settings: ["bucket": "acme-tfstate", "key": "net/terraform.tfstate"])
        let folder = checkout.appendingPathComponent("infra/net")
        func header(_ argv: [String]) -> TerraformPaneWarning {
            let line = TerraformCommandLine.parse(arguments: argv)!
            return TerraformPaneWarning.make(
                tool: line.tool, operation: line.operation, isWrite: line.isWrite, folder: folder, checkout: checkout, facts: facts,
                workspaceVariable: nil, dataDirVariable: nil, awsProfile: nil, runFiles: line.namedFiles, probably: false,
                settings: TerraformClassSettings(), identities: [])
        }
        XCTAssertEqual(header(["terraform", "-chdir=infra/net", "plan"]).rootClass, .remote)
        let byVarFile = header(["terraform", "-chdir=infra/net", "plan", "-var-file=prod.tfvars"])
        XCTAssertTrue(byVarFile.isProduction)
        XCTAssertEqual(byVarFile.reason, "var file prod.tfvars")
        XCTAssertNotNil(byVarFile.rememberIdentity, "the run's file is the state's: kept")
        let byBackendConfig = header(["terraform", "-chdir=infra/net", "init", "-backend-config=backend/prod.s3.tfbackend"])
        XCTAssertTrue(byBackendConfig.isProduction, byBackendConfig.reason)
    }

    /// The tab's checkout contains a folder only below a `/`.
    func testASiblingWorktreeIsNotTheCheckout() {
        let tab = URL(fileURLWithPath: "/w/acme-live")
        XCTAssertFalse(TerraformPaneWarning.contains(tab, URL(fileURLWithPath: "/w/acme-live-bump/envs/staging")))
        XCTAssertTrue(TerraformPaneWarning.contains(tab, URL(fileURLWithPath: "/w/acme-live/envs/staging")))
        XCTAssertTrue(TerraformPaneWarning.contains(tab, URL(fileURLWithPath: "/w/acme-live")))
    }

    /// An http backend's address loses its userinfo and query at decode,
    /// from the HCL and from the init record; nothing shown carries them.
    func testAnAddressKeepsNoCredential() throws {
        let address = "https://ci:glpat" + "-acme-SECRET1@gitlab.example/api/v4/projects/1/terraform/state/prod?access_token=globex-SECRET2#x"
        let hcl = TerraformConfigFacts.read(["terraform {\n  backend \"http\" {\n    address = \"\(address)\"\n  }\n}\n"]).backend
        XCTAssertEqual(hcl?.settings["address"], "https://gitlab.example/api/v4/projects/1/terraform/state/prod")
        let record = try XCTUnwrap(
            TerraformInitRecord.backend(from: Data(#"{"backend":{"type":"http","config":{"address":"\#(address)"}}}"#.utf8)))
        XCTAssertEqual(record.settings["address"], "https://gitlab.example/api/v4/projects/1/terraform/state/prod")
        XCTAssertEqual(TerraformConfigFacts.addressWithoutCredentials("https://tok-acme-SECRET3@gitlab.example:8443/state"), "https://gitlab.example:8443/state")
        var facts = TerraformRootFacts()
        facts.initRecord = record
        let folder = TerraformRootFolder(path: "infra/shared", kind: .root, files: ["main.tf"])
        let card = TerraformRootCard.make(
            folder: folder, at: checkout.appendingPathComponent("infra/shared"), facts: facts, awsProfile: nil, terragruntTree: false,
            settings: TerraformClassSettings(), productionIdentities: [])
        XCTAssertTrue(card.isProduction, "…/state/prod")
        let warning = TerraformPaneWarning.make(
            tool: "terraform", operation: "plan", isWrite: false, folder: card.folder, checkout: checkout, facts: facts, workspaceVariable: nil,
            dataDirVariable: nil, awsProfile: nil, probably: false, settings: TerraformClassSettings(), identities: [])
        let shown = [
            card.verdict.reason, card.backendSummary, "\(card.rootClass.title): \(card.verdict.reason)", "\(card.name), \(card.rootClass.title)",
            warning.label, warning.help, String(reflecting: card), String(reflecting: warning),
        ]
        for text in shown {
            for sentinel in ["SECRET", "glpat", "access_token", "ci:"] { XCTAssertFalse(text.contains(sentinel), "\(sentinel) in \(text)") }
        }
    }

    /// A Kubernetes backend's or provider's literal context, classified as
    /// Kubernetes does; its namespace and a cloud hostname are names too.
    func testKubernetesContextsAndNamespaces() {
        let text = """
            terraform {
              backend "kubernetes" {
                secret_suffix  = "net"
                config_context = "acme-main"
              }
            }
            provider "kubernetes" {
              config_context = "globex-main"
            }
            """
        let config = TerraformConfigFacts.read([text])
        XCTAssertEqual(config.backend?.settings["config_context"], "acme-main")
        func verdict(_ backend: TerraformConfigFacts.Backend, _ config: TerraformConfigFacts = .init(), _ kube: [String: KubeContextClass] = [:])
            -> TerraformClass
        {
            let signals = TerraformSignals(workspace: "default", path: "infra/k8s", backends: [backend], config: config)
            return TerraformClassifier.classify(
                signals, backend: backend, lockProviders: [], identity: nil, productionIdentities: [], set: nil, pattern: TerraformClassifier.pattern(""),
                accounts: [], kubeContexts: kube
            ).rootClass
        }
        let backend = config.backend!
        XCTAssertEqual(verdict(backend), .remote)
        XCTAssertEqual(verdict(backend, .init(), ["acme-main": .production]), .production, "kubernetes.contexts says so")
        var provider = TerraformConfigFacts()
        provider.providers = config.providers
        let local = TerraformConfigFacts.Backend(type: "local")
        XCTAssertEqual(verdict(local, provider, ["globex-main": .production]), .production, "the provider's context")
        XCTAssertNotEqual(verdict(local, provider, [:]), .production)
        provider.providers = [.init(name: "kubernetes", settings: ["config_context": "arn:aws:eks:eu-west-1:1:cluster/acme-prod"])]
        XCTAssertEqual(verdict(local, provider), .production, "KubeClassifier's names")
        XCTAssertEqual(verdict(.init(type: "kubernetes", settings: ["secret_suffix": "net", "namespace": "acme-prod"])), .production)
        XCTAssertEqual(verdict(.init(type: "cloud", settings: ["hostname": "tfe.prod.globex.example", "organization": "globex"])), .production)
        let reason = TerraformClassifier.productionSignal(
            TerraformSignals(workspace: "default", path: "x", backends: [backend]), pattern: TerraformClassifier.pattern(""), accounts: [],
            kubeContexts: ["acme-main": .production])
        XCTAssertEqual(reason, "backend config_context acme-main, a production Kubernetes context")
    }

    /// Production by the shell's AWS_PROFILE alone is shown, never kept:
    /// one export would otherwise make every state production for good.
    func testAProfileOnlyVerdictIsNotRemembered() {
        let folder = TerraformRootFolder(path: "sandbox", kind: .root, files: ["main.tf"])
        let url = checkout.appendingPathComponent("sandbox")
        let byProfile = TerraformRootCard.make(
            folder: folder, at: url, facts: TerraformRootFacts(), awsProfile: "acme-prod-admin", terragruntTree: false,
            settings: TerraformClassSettings(), productionIdentities: [])
        XCTAssertTrue(byProfile.isProduction, "while it is set")
        XCTAssertEqual(byProfile.rememberedIdentities, [])
        let prod = TerraformRootFolder(path: "envs/prod", kind: .root, files: ["main.tf"])
        let byPath = TerraformRootCard.make(
            folder: prod, at: checkout.appendingPathComponent("envs/prod"), facts: TerraformRootFacts(), awsProfile: "acme-prod-admin",
            terragruntTree: false, settings: TerraformClassSettings(), productionIdentities: [])
        XCTAssertEqual(byPath.rememberedIdentities.count, 1, "the root's own path")
        // A process's AWS_PROFILE alone, in the header: not kept either.
        let header = TerraformPaneWarning.make(
            tool: "terraform", operation: "apply", isWrite: true, folder: url, checkout: checkout, facts: TerraformRootFacts(), workspaceVariable: nil,
            dataDirVariable: nil, awsProfile: "acme-prod-admin", probably: false, settings: TerraformClassSettings(), identities: [])
        XCTAssertTrue(header.isProduction)
        XCTAssertNil(header.rememberIdentity)
        XCTAssertTrue(TerraformInheritedEnvironment(["AWS_PROFILE": "acme-prod-admin"]).notes.first?.contains("AWS_PROFILE=acme-prod-admin") == true)
    }

    /// Every production workspace of a root is kept, not only the selected one.
    func testEveryProductionWorkspaceIsRemembered() {
        var facts = TerraformRootFacts()
        facts.localWorkspaces = ["acme-dev", "prod"]
        let folder = TerraformRootFolder(path: "infra/net", kind: .root, files: ["main.tf"])
        let card = TerraformRootCard.make(
            folder: folder, at: checkout.appendingPathComponent("infra/net"), facts: facts, awsProfile: nil, terragruntTree: false,
            settings: TerraformClassSettings(), productionIdentities: [])
        XCTAssertFalse(card.isProduction, "default is selected")
        XCTAssertEqual(card.workspaceClasses["prod"], .production)
        XCTAssertEqual(card.rememberedIdentities.map(\.location), [checkout.appendingPathComponent("infra/net/terraform.tfstate.d/prod/terraform.tfstate").path])
    }

    /// Never evicted: a bound that dropped the oldest would lower a state once production.
    @MainActor func testProductionIdentitiesAreNeverEvicted() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acme-roots-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let many = (0..<2_100).map { TerraformStateIdentity(product: "terraform", backend: "s3", location: "acme-tfstate/\($0).tfstate") }
        let store = TerraformRootStore(url: url)
        store.rememberProduction(many)
        store.rememberProduction(TerraformStateIdentity(product: "terraform", backend: "s3", location: "globex/last.tfstate"))
        let kept = TerraformRootStore(url: url).productionIdentities
        XCTAssertEqual(kept.count, 2_101)
        XCTAssertTrue(kept.contains(many[0]), "the oldest stays")
    }

    /// 4.12 step 5: a file belongs to the nearest root above it.
    func testAFileBelowARootTouchesIt() {
        let roots = ["envs/prod", "envs/prod/regional", "envs/dev"]
        XCTAssertEqual(TerraformRootGuess.touched(roots: roots, changed: ["envs/prod/templates/user_data.sh"], moduleCallers: [:]), ["envs/prod"])
        XCTAssertEqual(TerraformRootGuess.touched(roots: roots, changed: ["envs/prod/policies/admin.json"], moduleCallers: [:]), ["envs/prod"])
        XCTAssertEqual(TerraformRootGuess.touched(roots: roots, changed: ["envs/prod/regional/x/y.json"], moduleCallers: [:]), ["envs/prod/regional"])
        XCTAssertEqual(TerraformRootGuess.touched(roots: roots, changed: ["src/app.swift", "envs/devx/a.tf"], moduleCallers: [:]), [])
        XCTAssertEqual(TerraformRootGuess.touched(roots: [""], changed: ["templates/a.sh"], moduleCallers: [:]), [""], "the top as a root")
    }

    /// Only what can change the panel redoes its read (10, Monorepos) —
    /// files, or folders as the diff's watcher says them.
    func testOnlyTerraformsFilesMatter() {
        let listed: Set<String> = ["envs/dev", "envs/prod", "modules/net"]
        func relevant(_ path: String, _ terraformIn: Set<String> = []) -> Bool {
            TerraformPanelModel.isRelevant(path, listed: listed) { terraformIn.contains($0) }.relevant
        }
        for path in [
            "envs/prod/main.tf", "new/root/main.tf", "envs/dev/terraform.tfstate", "envs/dev/.terraform/environment", "envs/dev/.terraform/terraform.tfstate",
            "envs/dev/.terraform/modules/modules.json", "envs/dev/terraform.tfstate.d/acme/terraform.tfstate", "envs/prod", "envs/prod/", "envs",
            ".tool-versions", "envs/prod/.terraform.lock.hcl", "envs/dev/.terraform/", "envs/dev/.terraform/modules/net/",
        ] {
            XCTAssertTrue(relevant(path), path)
        }
        XCTAssertTrue(relevant("new/root/", ["new/root"]), "a new folder with a configuration in it")
        XCTAssertTrue(TerraformPanelModel.isRelevant("new/root/", listed: listed) { $0 == "new/root" }.terraform, "and the checkout's roots are open again")
        for path in [
            "Sources/App.swift", "Sources/", "node_modules/x/index.js", "node_modules/x/main.tf", "build/out.o", "build/",
            "envs/dev/.terraform/providers/x/terraform-provider-null", "envs/dev/.terraform/providers/", ".git/index", ".git/", "", "web/dist/app.js",
        ] {
            XCTAssertFalse(relevant(path), path)
        }
        XCTAssertFalse(TerraformPanelModel.isRelevant("envs/dev/terraform.tfstate", listed: listed).terraform, "a state is no configuration")
    }

    /// The window's worktree list: the others of this repository, none when it is another's.
    func testTheWindowsWorktrees() {
        let main = Worktree(path: URL(fileURLWithPath: "/w/acme-live"), head: "3f2a91c0", branch: "main", isBare: false, isDetached: false, isLocked: false, isMain: true)
        let bump = Worktree(
            path: URL(fileURLWithPath: "/w/acme-live-bump"), head: "1", branch: "bump-acme", isBare: false, isDetached: false, isLocked: false, isMain: false)
        var gone = Worktree(path: URL(fileURLWithPath: "/w/acme-gone"), head: "2", branch: "gone", isBare: false, isDetached: false, isLocked: false, isMain: false)
        gone.isPrunable = true
        let others = TerraformWorktree.others([main, bump, gone], of: URL(fileURLWithPath: "/w/acme-live"))
        XCTAssertEqual(others, [TerraformWorktree(url: URL(fileURLWithPath: "/w/acme-live-bump"), name: "bump-acme")])
        XCTAssertEqual(TerraformWorktree.others([main, bump], of: URL(fileURLWithPath: "/w/globex")), [], "another repository's list")
    }

    /// Outside git, a repository's top folder is walked, bounded; any other folder isn't.
    func testTheWalkWhereGitCantList() async throws {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent("acme-walk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: top) }
        for path in ["envs/prod/main.tf", "envs/prod/.terraform.lock.hcl", "node_modules/x/main.tf", ".hidden/main.tf", "envs/prod/.terraform/modules/n/main.tf", "README.md"] {
            let url = top.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# acme\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let walked = TerraformRootScan.walk(top)
        XCTAssertEqual(walked.folders, ["envs/prod": [".terraform.lock.hcl", "main.tf"]])
        XCTAssertTrue(TerraformCheckouts.mayHaveRoots(walked))
        let notARepository = await TerraformRootScan.list(top)
        XCTAssertNil(notARepository, "no .git: never walked")
        try FileManager.default.createDirectory(at: top.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let listed = await TerraformRootScan.list(top)
        XCTAssertEqual(listed?.folders["envs/prod"]?.sorted(), [".terraform.lock.hcl", "main.tf"])
    }

    /// The header's walk settles a checkout once, and forgets it when a configuration appears.
    @MainActor func testCheckoutsSettleAndForget() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acme-settle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let checkouts = TerraformCheckouts.shared
        XCTAssertNil(checkouts.hasRoots(folder))
        checkouts.settle(folder)
        for _ in 0..<100 where checkouts.hasRoots(folder) == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(checkouts.hasRoots(folder), false, "not a repository: no roots, never walked")
        checkouts.forget(folder)
        XCTAssertNil(checkouts.hasRoots(folder))
        XCTAssertNil(checkouts.hasRoots(nil), "a tab with no checkout")
    }

    func testTheProcessTreeWalk() {
        let mine = TerraformProcesses.descendants(of: getpid())
        XCTAssertEqual(mine.count, Set(mine).count, "each pid once")
        XCTAssertEqual(TerraformProcesses.descendants(of: 999_999), [])
    }
}
