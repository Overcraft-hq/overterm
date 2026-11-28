import XCTest

@testable import Overterm
@testable import OvertermShell

/// Onboarding 7.7, 3.1–3.2: "Tools the panels use" — each row from its
/// feature's own finder, called with injected closures; only the panels
/// that are on; every path touched is a look (existence, executability),
/// none under Documents, Desktop or iCloud Drive (risk 11); nothing run:
/// no Docker ping, kube proxy, credential plugin, terraform, mise or xcrun.
final class SetupProbeTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")
    private var empty: URL!

    override func setUpWithError() throws {
        // The language servers' finder looks at real folders: an empty one of the test's own.
        empty = FileManager.default.temporaryDirectory.appendingPathComponent("setup-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: empty)
    }

    private var discovery: ServerDiscovery {
        ServerDiscovery(home: empty, searchDirectories: [empty], toolchainDirectories: [empty], runsXcrun: false)
    }

    private func inputs(all on: Bool, contexts: [KubeContext]? = nil) -> SetupPanelProbe.Inputs {
        SetupPanelProbe.Inputs(
            home: home, appPath: "/usr/bin:/bin", docker: on, kubernetes: on, terraform: on, simulator: on, languageServers: on, database: on, api: on,
            contexts: contexts, ghosttyConfig: true)
    }

    private func context(_ name: String, production: Bool, plugin: String?) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: nil, namespace: nil, user: name, auth: plugin.map { command in KubeAuth.exec(KubeExec(command: command)) },
            file: nil, contextClass: production ? .production : .remote, settings: KubeContextSettings())
    }

    /// Every panel off: no finder is called, only the Ghostty config's row.
    func testPanelsOffLookAtNothing() {
        var touched: [String] = []
        let facts = SetupPanelProbe.facts(
            inputs(all: false), login: ["PATH": "/opt/homebrew/bin"],
            exists: { path in
                touched.append(path)
                return true
            },
            isExecutable: { path in
                touched.append(path)
                return true
            },
            dockerEndpoint: {
                XCTFail("Docker is off")
                return DockerEndpoint(address: .unix("/var/run/docker.sock"), source: "default")
            },
            kubeconfigs: {
                XCTFail("Kubernetes is off")
                return []
            },
            terraformBinary: { _ in
                XCTFail("Terraform is off")
                return nil
            }, discovery: discovery)
        XCTAssertTrue(touched.isEmpty, "\(touched)")
        XCTAssertNil(facts.docker)
        XCTAssertNil(facts.kubernetes)
        XCTAssertNil(facts.terraform)
        XCTAssertNil(facts.languageServers)
        XCTAssertNil(facts.simulator)
        XCTAssertNil(facts.gcloud)
        XCTAssertNil(facts.protoc)
        XCTAssertEqual(SetupCheck.panelRows(facts, home: home.path).map(\.id), [.ghosttyConfig])
    }

    /// Every panel on, nothing found: each feature's own words, and what each looked at.
    func testEveryPanelOnNothingFound() {
        var looked: [String] = []
        var executable: [String] = []
        var kubeconfigsAsked = 0
        let facts = SetupPanelProbe.facts(
            inputs(all: true), login: ["PATH": "/opt/homebrew/bin:\(home.path)/.local/bin"],
            exists: { path in
                looked.append(path)
                return false
            },
            isExecutable: { path in
                executable.append(path)
                return false
            },
            dockerEndpoint: { DockerEndpoint(address: .unix(self.home.path + "/.docker/run/docker.sock"), context: "desktop-linux", source: "context desktop-linux") },
            kubeconfigs: {
                kubeconfigsAsked += 1
                return [self.home.appendingPathComponent(".kube/config")]
            }, terraformBinary: { _ in nil }, discovery: discovery)

        XCTAssertEqual(kubeconfigsAsked, 1, "the Kubernetes page hasn't read them: only the files' existence")
        let forbidden = ["/Documents", "/Desktop", "/Library/Mobile Documents"]
        for path in looked + executable {
            XCTAssertFalse(forbidden.contains { path.contains($0) }, path)
        }
        XCTAssertTrue(
            looked.contains(home.path + "/.docker/run/docker.sock") && looked.contains(SetupPanelProbe.xcodePath)
                && looked.contains(SetupPanelProbe.coreSimulatorPath) && looked.contains(home.path + "/.kube/config"), "\(looked)")
        XCTAssertTrue(executable.contains("/usr/bin/docker"), "Docker's CLI looks on the app's PATH first")
        XCTAssertTrue(executable.contains(home.path + "/.local/bin/kubectl"), "kubectl on the login shell's PATH")

        let rows = Dictionary(uniqueKeysWithValues: SetupCheck.panelRows(facts, home: home.path).map { row in (row.id, row) })
        XCTAssertEqual(rows[.docker]?.detail, "docker isn't on this Mac, so Compose can't read the compose file.")
        XCTAssertEqual(rows[.dockerEngine]?.detail, "Docker Desktop isn't running — no socket at ~/.docker/run/docker.sock.")
        XCTAssertEqual(rows[.dockerPlugin("compose")]?.detail, "not found · Compose's verbs need it")
        XCTAssertEqual(rows[.kubectl]?.detail, "No kubectl found. Install it, or set Settings ▸ Kubernetes ▸ kubectl.")
        XCTAssertEqual(rows[.kubectl]?.action, .command("brew install kubectl"))
        XCTAssertEqual(rows[.kubeconfig]?.detail, "No kubeconfig")
        XCTAssertEqual(
            rows[.kubePlugins]?.detail, "Open Kubernetes once to check its contexts' plugins", "no context read: not looked for, and said so")
        XCTAssertEqual(rows[.kubePlugins]?.isProblem, false)
        XCTAssertEqual(
            rows[.gcloud]?.detail,
            "not found · BigQuery's and Cloud Storage's gcloud sign-in needs it · gke-gcloud-auth-plugin not on your PATH — a GKE context needs it")
        XCTAssertEqual(rows[.gcloud]?.action, SetupCheck.gcloudInstallPage.map(SetupRow.Action.page))
        XCTAssertTrue(executable.contains("/opt/homebrew/bin/gcloud") && executable.contains(home.path + "/google-cloud-sdk/bin/gcloud"), "where BigQuery looks")
        XCTAssertTrue(executable.contains("/opt/homebrew/bin/gke-gcloud-auth-plugin"), "where a GKE context's proxy looks")
        XCTAssertEqual(rows[.protoc]?.detail, "not found · a gRPC request from .proto files needs it; a server with reflection doesn't")
        XCTAssertEqual(rows[.protoc]?.action, .command("brew install protobuf"))
        XCTAssertTrue(executable.contains("/usr/local/bin/protoc"), "Homebrew's folders after the PATH")
        XCTAssertEqual(rows[.helm]?.detail, "helm isn't installed (or set kubernetes.helmPath in Settings ▸ Kubernetes).")
        XCTAssertEqual(rows[.terraform]?.detail, "No terraform found: set Settings ▸ Terraform ▸ terraform, or install it.")
        XCTAssertEqual(rows[.tofu]?.detail, "not looked for · set Settings ▸ Terraform ▸ terraform to tofu; untried until then")
        XCTAssertEqual(rows[.languageServers]?.detail, "0 of \(LanguageServers.specs.count) found")
        XCTAssertEqual(rows[.languageServers]?.more.count, LanguageServers.specs.count, "each server folded under it")
        XCTAssertEqual(rows[.simulator]?.detail, "No simulators on this Mac. They come with Xcode.")
        XCTAssertEqual(rows[.ghosttyConfig]?.detail, "~/.config/ghostty/config found: it applies as it is")
        XCTAssertTrue(rows.values.allSatisfy { row in row.looked != nil }, "every panel row says where Overterm looked")
    }

    /// Found: where; the contexts as the page read them — counts and
    /// plugin names only, each plugin looked for on the login shell's PATH.
    func testFoundAndTheContextsThePageRead() {
        let contexts = [
            context("prod", production: true, plugin: "aws"), context("staging", production: false, plugin: "gke-gcloud-auth-plugin"),
            context("dev", production: false, plugin: nil),
        ]
        let present: Set<String> = [
            "/usr/local/bin/docker", home.path + "/.docker/cli-plugins/docker-compose", "/opt/homebrew/bin/kubectl", "/opt/homebrew/bin/helm",
            "/opt/homebrew/bin/aws",
        ]
        let facts = SetupPanelProbe.facts(
            inputs(all: true, contexts: contexts), login: ["PATH": "/opt/homebrew/bin"], exists: { path in path == "/var/run/docker.sock" },
            isExecutable: { path in present.contains(path) },
            dockerEndpoint: { DockerEndpoint(address: .unix("/var/run/docker.sock"), source: "default") },
            kubeconfigs: {
                XCTFail("the page's contexts are used; the files aren't looked at again")
                return []
            }, terraformBinary: { _ in URL(fileURLWithPath: "/opt/homebrew/bin/terraform") }, discovery: discovery)
        let rows = Dictionary(uniqueKeysWithValues: SetupCheck.panelRows(facts, home: home.path).map { row in (row.id, row) })
        XCTAssertEqual(rows[.docker]?.detail, "/usr/local/bin/docker")
        XCTAssertEqual(rows[.dockerEngine]?.detail, "Docker Engine · socket at /var/run/docker.sock")
        XCTAssertEqual(rows[.dockerPlugin("compose")]?.detail, "found")
        XCTAssertEqual(rows[.kubectl]?.detail, "/opt/homebrew/bin/kubectl")
        XCTAssertEqual(rows[.kubeconfig]?.detail, "3 contexts, 1 production")
        XCTAssertEqual(rows[.kubePlugins]?.detail, "gke-gcloud-auth-plugin isn't installed.")
        XCTAssertEqual(rows[.helm]?.detail, "/opt/homebrew/bin/helm")
        XCTAssertEqual(rows[.terraform]?.detail, "/opt/homebrew/bin/terraform · a root with a version file may use mise's; not asked here")
    }

    /// `terraform.path` naming an executable is taken as the feature takes
    /// it, and `TerraformCLI.binary()` isn't asked.
    func testTerraformsSetting() {
        var given = inputs(all: false)
        given.terraform = true
        given.terraformPath = "/opt/tools/tofu"
        let facts = SetupPanelProbe.facts(
            given, login: nil, exists: { _ in false }, isExecutable: { path in path == "/opt/tools/tofu" },
            dockerEndpoint: { DockerEndpoint(address: .unix("/var/run/docker.sock"), source: "default") }, kubeconfigs: { [] },
            terraformBinary: { _ in
                XCTFail("the setting is taken first")
                return nil
            }, discovery: discovery)
        XCTAssertEqual(facts.terraform, SetupPanelFacts.Terraform(binary: URL(fileURLWithPath: "/opt/tools/tofu"), fromSetting: true))
        XCTAssertEqual(
            SetupCheck.panelRows(facts, home: home.path).first { $0.id == .terraform }?.detail, "/opt/tools/tofu · Settings ▸ Terraform ▸ terraform")
    }

    /// gcloud for the Database alone, and protoc on the PATH: each where its feature looks.
    func testGcloudAndProtocFound() {
        var given = inputs(all: false)
        given.database = true
        given.api = true
        let present: Set<String> = [home.path + "/google-cloud-sdk/bin/gcloud", "/opt/homebrew/bin/protoc"]
        let facts = SetupPanelProbe.facts(
            given, login: ["PATH": "/opt/homebrew/bin"], exists: { _ in false }, isExecutable: { path in present.contains(path) },
            dockerEndpoint: { DockerEndpoint(address: .unix("/var/run/docker.sock"), source: "default") }, kubeconfigs: { [] }, terraformBinary: { _ in nil },
            discovery: discovery)
        XCTAssertEqual(facts.gcloud?.gkePluginLooked, false, "Kubernetes is off: its plugin isn't looked for")
        let rows = Dictionary(uniqueKeysWithValues: SetupCheck.panelRows(facts, home: home.path).map { row in (row.id, row) })
        XCTAssertEqual(rows[.gcloud]?.detail, "~/google-cloud-sdk/bin/gcloud · BigQuery and Cloud Storage can sign in with it")
        XCTAssertEqual(rows[.gcloud]?.found, true)
        XCTAssertNil(rows[.gcloud]?.action)
        XCTAssertEqual(rows[.protoc]?.detail, "/opt/homebrew/bin/protoc · gRPC from .proto files")
        XCTAssertNil(rows[.kubectl], "Kubernetes off: no rows of its own")
    }

    /// The contexts read but the login shell silent: the plugins' row says why it didn't look.
    func testPluginsWithTheShellSilent() {
        let facts = SetupPanelProbe.facts(
            inputs(all: true, contexts: [context("dev", production: false, plugin: "aws")]), login: nil, exists: { _ in false },
            isExecutable: { _ in false }, dockerEndpoint: { DockerEndpoint(address: .unix("/var/run/docker.sock"), source: "default") },
            kubeconfigs: { [] }, terraformBinary: { _ in nil }, discovery: discovery)
        let row = SetupCheck.panelRows(facts, home: home.path).first { $0.id == .kubePlugins }
        XCTAssertEqual(row?.detail, "not looked for — your login shell didn't say its PATH")
    }


    /// A PATH folder under Documents, Desktop or iCloud Drive is passed over
    /// by every finder (macOS would ask the person before an app looks
    /// there) — but a path the person set themselves is looked at: they
    /// asked for it.
    func testProtectedPathFoldersArePassedOverButTheSettingsAreNot() {
        let documents = home.path + "/Documents/bin"
        let desktop = home.path + "/Desktop/tools"
        var given = inputs(all: true)
        given.kubectlPath = desktop + "/kubectl"
        given.terraformPath = desktop + "/terraform"
        var executable: [String] = []
        var terraformLooked: [String] = []
        let facts = SetupPanelProbe.facts(
            given, login: ["PATH": "\(documents):/opt/homebrew/bin:\(home.path)/Library/Mobile Documents/bin"], exists: { _ in false },
            isExecutable: { path in
                executable.append(path)
                return path.hasPrefix(self.home.path + "/Desktop/")
            },
            dockerEndpoint: { DockerEndpoint(address: .unix("/var/run/docker.sock"), source: "default") }, kubeconfigs: { [] },
            terraformBinary: { looks in
                for path in [documents + "/terraform", "/opt/homebrew/bin/terraform"] where looks(path) { terraformLooked.append(path) }
                return nil
            }, discovery: discovery)
        let protected = executable.filter { path in SetupProbe.isProtected(path, home: home.path) }
        XCTAssertEqual(Set(protected), [desktop + "/kubectl", desktop + "/terraform"], "only the settings' own paths: \(protected)")
        XCTAssertFalse(executable.contains(documents + "/kubectl"), "a PATH folder under Documents is passed over")
        XCTAssertFalse(executable.contains(documents + "/protoc"))
        XCTAssertTrue(executable.contains("/opt/homebrew/bin/kubectl"), "the rest of the PATH as before")
        XCTAssertEqual(facts.kubernetes?.kubectl, URL(fileURLWithPath: desktop + "/kubectl"), "the setting, though under Desktop")
        XCTAssertEqual(facts.terraform, SetupPanelFacts.Terraform(binary: URL(fileURLWithPath: desktop + "/terraform"), fromSetting: true))
        XCTAssertEqual(
            SetupPanelProbe.chosenPaths(given), [desktop + "/kubectl", desktop + "/terraform"], "the settings' paths, standardized")
        XCTAssertTrue(terraformLooked.isEmpty, "the setting is taken first: \(terraformLooked)")

        // Without the setting, TerraformCLI's search gets the same filter.
        given.terraformPath = ""
        var looked: [String] = []
        _ = SetupPanelProbe.facts(
            given, login: ["PATH": documents], exists: { _ in false }, isExecutable: { _ in true },
            dockerEndpoint: { DockerEndpoint(address: .unix("/var/run/docker.sock"), source: "default") }, kubeconfigs: { [] },
            terraformBinary: { looks in
                looked = [documents + "/terraform", "/opt/homebrew/bin/terraform"].filter { path in looks(path) }
                return nil
            }, discovery: discovery)
        XCTAssertEqual(looked, ["/opt/homebrew/bin/terraform"], "a protected PATH folder passed over")
    }

    /// A remote engine is never reached from here.
    func testARemoteEngine() {
        let docker = SetupPanelFacts.Docker(cli: nil, runtime: "Docker Engine", source: "DOCKER_HOST", socket: nil, socketExists: false, remoteHost: "build-box")
        let row = SetupCheck.panelRows(SetupPanelFacts(docker: docker), home: home.path).first { $0.id == .dockerEngine }
        XCTAssertEqual(row?.detail, "on build-box · not reached from here")
        XCTAssertEqual(row?.isProblem, false)
    }
}
