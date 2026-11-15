import XCTest

@testable import Overterm

/// What keeps Terraform off the user's own in isolated runs and unit tests
/// (analysis 4.5, 5.13 rule 8).
final class TerraformGuardsTests: XCTestCase {
    func testAGuardedRunFindsNoTerraformButOvertermTerraforms() {
        let executable: (String) -> Bool = { $0 == "/tmp/acme/bin/terraform" }
        XCTAssertEqual(TerraformGuards.binary(variable: nil, guarded: true, isExecutable: executable), .none)
        XCTAssertEqual(TerraformGuards.binary(variable: "  ", guarded: true, isExecutable: executable), .none)
        XCTAssertEqual(
            TerraformGuards.binary(variable: "/tmp/acme/bin/terraform", guarded: true, isExecutable: executable), .variable("/tmp/acme/bin/terraform"))
        // A name or a relative path would be resolved by a PATH search or
        // against the run's folder (a checkout): the guard wouldn't decide.
        XCTAssertEqual(TerraformGuards.binary(variable: "terraform", guarded: true, isExecutable: { _ in true }), .none)
        XCTAssertEqual(TerraformGuards.binary(variable: "bin/terraform", guarded: true, isExecutable: { _ in true }), .none)
        XCTAssertEqual(TerraformGuards.binary(variable: "./terraform", guarded: true, isExecutable: { _ in true }), .none)
        // Absolute, but nothing that runs there.
        XCTAssertEqual(TerraformGuards.binary(variable: "/tmp/acme/bin/missing", guarded: true, isExecutable: executable), .none)
        // The user's app searches for theirs whatever the variable says:
        // a stray one never redirects their plans and applies.
        XCTAssertEqual(TerraformGuards.binary(variable: nil, guarded: false, isExecutable: executable), .search)
        XCTAssertEqual(TerraformGuards.binary(variable: "/tmp/acme/bin/terraform", guarded: false, isExecutable: executable), .search)
        XCTAssertEqual(TerraformGuards.binary(variable: "terraform", guarded: false, isExecutable: executable), .search)
    }

    /// A scenario refuses to start with a credential variable in its own
    /// environment, naming it — never its value; outside a scenario
    /// nothing is refused here.
    func testAScenarioRefusesCredentialVariablesByName() {
        let environment = ["AWS_PROFILE": "acme-prod-admin", "TF_TOKEN_app_terraform_io": "tok-acme-123", "PATH": "/usr/bin", "HOME": "/Users/acme"]
        let refused = TerraformGuards.refusedCredentials(scenario: "terraform", environment: environment)
        XCTAssertEqual(refused, ["AWS_PROFILE", "TF_TOKEN_app_terraform_io"])
        XCTAssertFalse(refused.joined().contains("acme-prod-admin"))
        XCTAssertFalse(refused.joined().contains("tok-acme-123"))
        XCTAssertEqual(TerraformGuards.refusedCredentials(scenario: "terraform", environment: ["PATH": "/usr/bin", "OVERTERM_E2E": "terraform"]), [])
        XCTAssertEqual(TerraformGuards.refusedCredentials(scenario: nil, environment: environment), [])
        // The unit tests are no scenario.
        XCTAssertEqual(AppEnvironment.terraformRefusedCredentials, [])
    }

    /// The unit tests are guarded: every folder Terraform will keep
    /// anything in is this run's own, and the binary is none unless the
    /// test's environment names one.
    func testUnitTestsAreGuarded() throws {
        XCTAssertTrue(AppEnvironment.guardsTerraform)
        let named = ProcessInfo.processInfo.environment["OVERTERM_TERRAFORM"] ?? ""
        if named.isEmpty { XCTAssertEqual(AppEnvironment.terraformBinary, .none) }
        let support = AppEnvironment.supportDirectory.standardizedFileURL.path
        for folder in [
            AppEnvironment.terraformDirectory, AppEnvironment.terraformCacheDirectory, AppEnvironment.terraformScratchDirectory,
            AppEnvironment.terraformRunsBase, AppEnvironment.terraformRootsFile,
        ] {
            XCTAssertTrue(folder.standardizedFileURL.path.hasPrefix(support + "/"), folder.path)
        }
        XCTAssertFalse(AppEnvironment.terraformCacheDirectory.path.contains("/Library/Caches/"))
        XCTAssertFalse(AppEnvironment.terraformUserConfiguresCLI(shell: ["TF_CLI_CONFIG_FILE": "/somewhere"]))
    }

    /// Nothing of the user's shell: no credential, no PATH of theirs, a HOME
    /// and CLI config of the run's own, proxies at a dead port.
    func testTheGuardedEnvironmentCarriesNothingOfTheUsers() throws {
        let environment = try AppEnvironment.terraformBaseEnvironment()
        XCTAssertEqual(TerraformGuards.credentials(in: environment), [])
        let scratch = AppEnvironment.terraformScratchDirectory.standardizedFileURL.path
        XCTAssertTrue(try XCTUnwrap(environment["HOME"]).hasPrefix(scratch))
        XCTAssertNotEqual(environment["HOME"], FileManager.default.homeDirectoryForCurrentUser.path)
        let config = try XCTUnwrap(environment["TF_CLI_CONFIG_FILE"])
        XCTAssertTrue(config.hasPrefix(scratch))
        XCTAssertEqual(environment["CHECKPOINT_DISABLE"], "1")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        for proxy in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] { XCTAssertEqual(environment[proxy], TerraformGuards.deadProxy) }
        XCTAssertEqual(environment["NO_PROXY"], "127.0.0.1,localhost")
        let guarded = TerraformGuards.guardedEnvironment(home: URL(fileURLWithPath: "/h"), cliConfig: URL(fileURLWithPath: "/c"))
        XCTAssertEqual(Set(environment.keys), Set(guarded.keys))

        // Private, and the config fetches nothing.
        let attributes = try FileManager.default.attributesOfItem(atPath: scratch)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let text = try String(contentsOfFile: config, encoding: .utf8)
        XCTAssertTrue(text.contains("direct {\n    exclude = [\"*/*/*\"]"), text)
        XCTAssertFalse(text.contains("credentials"))
    }

    func testCredentialVariablesAreKnownByName() {
        let environment = [
            "AWS_PROFILE": "acme-prod-admin", "AWS_SECRET_ACCESS_KEY": "x", "GOOGLE_APPLICATION_CREDENTIALS": "/k.json", "CLOUDSDK_CONFIG": "/c",
            "ARM_CLIENT_SECRET": "x", "AZURE_TENANT_ID": "t", "TF_TOKEN_app_terraform_io": "tok-acme-123", "TF_CLOUD_ORGANIZATION": "globex",
            "TF_VAR_db_password": "acme-hunter2-SECRET", "VAULT_TOKEN": "x", "KUBECONFIG": "/k", "TF_REATTACH_PROVIDERS": "{}",
            "PATH": "/usr/bin", "HOME": "/Users/acme", "TF_WORKSPACE": "prod", "TF_DATA_DIR": "/d", "LANG": "C",
        ]
        XCTAssertEqual(
            TerraformGuards.credentials(in: environment),
            [
                "ARM_CLIENT_SECRET", "AWS_PROFILE", "AWS_SECRET_ACCESS_KEY", "AZURE_TENANT_ID", "CLOUDSDK_CONFIG", "GOOGLE_APPLICATION_CREDENTIALS",
                "KUBECONFIG", "TF_CLOUD_ORGANIZATION", "TF_REATTACH_PROVIDERS", "TF_TOKEN_app_terraform_io", "TF_VAR_db_password", "VAULT_TOKEN",
            ])
    }

    /// Backends' credentials (the http backend's, GitLab's managed state;
    /// pg's; consul's), OpenTofu's encryption keys, providers' tokens, and
    /// any name that ends like a credential.
    func testBackendAndProviderCredentialsAreKnownToo() {
        for name in [
            "TF_HTTP_USERNAME", "TF_HTTP_PASSWORD", "TF_HTTP_ADDRESS", "TF_ENCRYPTION", "PG_CONN_STR", "PGPASSWORD", "CONSUL_HTTP_TOKEN",
            "CONSUL_HTTP_AUTH", "TFE_TOKEN", "GITHUB_TOKEN", "GH_TOKEN", "CLOUDFLARE_API_TOKEN", "DIGITALOCEAN_TOKEN", "HCLOUD_TOKEN",
            "OCI_PRIVATE_KEY_PATH", "ALICLOUD_ACCESS_KEY", "DATADOG_API_KEY", "MYSQL_PASSWORD", "ACME_CLIENT_SECRET_ID", "SECRET_KEY_BASE",
            "GLOBEX_CREDENTIALS",
        ] {
            XCTAssertTrue(TerraformGuards.isCredential(name), name)
        }
        for name in ["PATH", "HOME", "LANG", "TF_WORKSPACE", "TF_DATA_DIR", "TF_IN_AUTOMATION", "SSH_AUTH_SOCK", "TERM", "TOKENIZERS", "PGHOST"] {
            XCTAssertFalse(TerraformGuards.isCredential(name), name)
        }
    }

    /// `~/.terraformrc` is looked at only for whether it exists, and a
    /// guarded run doesn't look at all.
    func testTheUsersCLIConfigIsCheckedForExistenceOnly() {
        let home = URL(fileURLWithPath: "/Users/acme")
        var looked: [String] = []
        func exists(_ path: String) -> Bool {
            looked.append(path)
            return path == "/Users/acme/.terraformrc"
        }
        XCTAssertFalse(TerraformGuards.userConfiguresCLI(environment: ["TF_CLI_CONFIG_FILE": "/x"], home: home, guarded: true, exists: exists))
        XCTAssertEqual(looked, [])
        XCTAssertTrue(TerraformGuards.userConfiguresCLI(environment: [:], home: home, guarded: false, exists: exists))
        XCTAssertEqual(looked, ["/Users/acme/.terraformrc"])
        XCTAssertTrue(TerraformGuards.userConfiguresCLI(environment: ["TF_PLUGIN_CACHE_DIR": "/c"], home: home, guarded: false, exists: { _ in false }))
        XCTAssertTrue(TerraformGuards.userConfiguresCLI(environment: ["TF_CLI_CONFIG_FILE": "/c"], home: home, guarded: false, exists: { _ in false }))
        XCTAssertFalse(TerraformGuards.userConfiguresCLI(environment: ["TF_CLI_CONFIG_FILE": ""], home: home, guarded: false, exists: { _ in false }))
    }

    func testTheCLIConfigsMirrorIsQuotedAsHCL() {
        let text = TerraformGuards.cliConfig(mirror: URL(fileURLWithPath: "/tmp/acme \"m\"/${x}"))
        XCTAssertTrue(text.contains(#"path    = "/tmp/acme \"m\"/$${x}""#), text)
        XCTAssertEqual(TerraformGuards.hclString("a\\b\n%{c}"), #""a\\b\n%%{c}""#)
        XCTAssertEqual(TerraformGuards.hclString("$5"), #""$5""#)
    }
}
