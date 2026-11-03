import XCTest

@testable import Overterm

/// Kubeconfigs as kubectl reads them, the contexts' classes, and the guard
/// that keeps tests and isolated runs off the user's own kubeconfig — whose
/// current context, on this Mac, is production. Nothing here runs kubectl
/// or reaches a cluster.
final class KubeconfigTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-kube-\(UUID().uuidString)")
    /// A home of the test's own, so `~/.kube/config` is never the user's.
    private var home: URL { dir.appendingPathComponent("home", isDirectory: true) }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func write(_ text: String, to path: String) throws -> URL {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// This Mac's five contexts, as `aws eks update-kubeconfig`, kubelogin
    /// and kubeadm write them — the account, addresses and keys made up.
    static let thisMac = """
        apiVersion: v1
        kind: Config
        current-context: arn:aws:eks:eu-west-1:111122223333:cluster/acme-prod
        preferences: {}
        clusters:
        - cluster:
            certificate-authority-data: Q0FDRVJU
            server: https://ABC.gr7.eu-west-1.eks.amazonaws.com
          name: arn:aws:eks:eu-west-1:111122223333:cluster/acme-dev
        - cluster:
            certificate-authority-data: Q0FDRVJU
            server: https://DEF.gr7.eu-west-1.eks.amazonaws.com
          name: arn:aws:eks:eu-west-1:111122223333:cluster/acme-prod
        - cluster:
            server: https://GHI.eks.amazonaws.com
          name: globex-eu-west-1-dev
        - cluster:
            server: https://JKL.eks.amazonaws.com
          name: globex-eu-west-1-prod
        - cluster:
            certificate-authority-data: Q0FDRVJU
            server: https://10.0.0.10:6443
          name: k8s-cluster
        contexts:
        - context:
            cluster: arn:aws:eks:eu-west-1:111122223333:cluster/acme-dev
            user: arn:aws:eks:eu-west-1:111122223333:cluster/acme-dev
          name: arn:aws:eks:eu-west-1:111122223333:cluster/acme-dev
        - context:
            cluster: arn:aws:eks:eu-west-1:111122223333:cluster/acme-prod
            user: arn:aws:eks:eu-west-1:111122223333:cluster/acme-prod
          name: arn:aws:eks:eu-west-1:111122223333:cluster/acme-prod
        - context:
            cluster: globex-eu-west-1-dev
            namespace: globex
            user: oidc-dev
          name: globex-eu-west-1-dev
        - context:
            cluster: globex-eu-west-1-prod
            namespace: globex
            user: oidc-prod
          name: globex-eu-west-1-prod
        - context:
            cluster: k8s-cluster
            user: kubernetes-admin
          name: kubernetes-admin@k8s-cluster
        users:
        - name: arn:aws:eks:eu-west-1:111122223333:cluster/acme-dev
          user:
            exec:
              apiVersion: client.authentication.k8s.io/v1beta1
              args:
              - --region
              - eu-west-1
              - eks
              - get-token
              - --cluster-name
              - acme-dev
              command: aws
              env:
              - name: AWS_PROFILE
                value: acme-dev
              interactiveMode: IfAvailable
              provideClusterInfo: false
        - name: arn:aws:eks:eu-west-1:111122223333:cluster/acme-prod
          user:
            exec:
              apiVersion: client.authentication.k8s.io/v1beta1
              args: [--region, eu-west-1, eks, get-token, --cluster-name, acme-prod]
              command: aws
              env: null
        - name: oidc-dev
          user:
            exec:
              apiVersion: client.authentication.k8s.io/v1beta1
              args:
              - oidc-login
              - get-token
              - --oidc-issuer-url=https://issuer.example
              - --oidc-client-id=k8s
              command: kubectl
              interactiveMode: Never
        - name: oidc-prod
          user:
            exec:
              apiVersion: client.authentication.k8s.io/v1
              args: [oidc-login, get-token, --oidc-issuer-url=https://issuer.example]
              command: kubectl
              installHint: brew install kubelogin
        - name: kubernetes-admin
          user:
            client-certificate-data: Q0VSVElGSUNBVEU=
            client-key-data: U0VDUkVUS0VZU0VDUkVUS0VZ
        """

    // MARK: Reading

    func testThisMacsKubeconfigReads() throws {
        let config = try XCTUnwrap(Kubeconfig.parse(Self.thisMac))
        XCTAssertEqual(config.currentContext, "arn:aws:eks:eu-west-1:111122223333:cluster/acme-prod")
        XCTAssertEqual(config.contexts.count, 5)
        let list = KubeContextList.resolve([config], settings: [:])
        let globex = try XCTUnwrap(list.context(named: "globex-eu-west-1-dev"))
        XCTAssertEqual(globex.namespace, "globex")
        XCTAssertEqual(globex.server, "https://GHI.eks.amazonaws.com")
        XCTAssertEqual(globex.auth?.description, "exec: kubectl oidc-login")
        guard case .exec(let oidc) = globex.auth else { return XCTFail("exec") }
        XCTAssertTrue(oidc.isOIDCLogin)
        XCTAssertEqual(oidc.interactiveMode, "Never")

        let dev = try XCTUnwrap(list.context(named: "arn:aws:eks:eu-west-1:111122223333:cluster/acme-dev"))
        XCTAssertNil(dev.namespace)
        guard case .exec(let aws) = dev.auth else { return XCTFail("exec") }
        XCTAssertEqual(aws.name, "aws")
        XCTAssertEqual(aws.arguments, ["--region", "eu-west-1", "eks", "get-token", "--cluster-name", "acme-dev"])
        XCTAssertEqual(aws.environmentNames, ["AWS_PROFILE"], "the names, not the values")
        XCTAssertEqual(aws.apiVersion, "client.authentication.k8s.io/v1beta1")
        XCTAssertFalse(aws.isOIDCLogin)

        guard case .exec(let prodAWS) = list.context(named: "arn:aws:eks:eu-west-1:111122223333:cluster/acme-prod")?.auth else {
            return XCTFail("flow-style args")
        }
        XCTAssertEqual(prodAWS.arguments.last, "acme-prod")
        XCTAssertEqual(prodAWS.environmentNames, [], "env: null")
        guard case .exec(let prodOIDC) = list.context(named: "globex-eu-west-1-prod")?.auth else { return XCTFail("exec") }
        XCTAssertEqual(prodOIDC.installHint, "brew install kubelogin")

        let admin = try XCTUnwrap(list.context(named: "kubernetes-admin@k8s-cluster"))
        XCTAssertEqual(admin.auth, .clientCertificate)
        XCTAssertEqual(admin.server, "https://10.0.0.10:6443")
    }

    /// No credential is in a value Overterm holds, and an exec plugin's
    /// arguments never reach a string that could be logged.
    func testCredentialsAreNeverKept() throws {
        let text =
            Self.thisMac + """

                - name: bearer
                  user:
                    token: "eyJhbGciOiJSUzI1NiIsInNlY3JldCI6dHJ1ZX0"
                - name: basic
                  user:
                    username: admin
                    password: hunter2hunter2
                - name: legacy
                  user:
                    auth-provider:
                      name: oidc
                      config:
                        client-secret: shhhhhhh
                        id-token: eyJpZC10b2tlbi1zZWNyZXQ
                        'refresh-token': rrrrrrrrrr
                """
        let redacted = Kubeconfig.redacted(text)
        for secret in ["U0VDUkVUS0VZU0VDUkVUS0VZ", "eyJhbGciOiJSUzI1NiIsInNlY3JldCI6dHJ1ZX0", "hunter2hunter2", "shhhhhhh", "eyJpZC10b2tlbi1zZWNyZXQ", "rrrrrrrrrr"] {
            XCTAssertFalse(redacted.contains(secret), secret)
        }
        XCTAssertTrue(redacted.contains("Q0VSVElGSUNBVEU="), "a certificate isn't a secret, and is left")
        XCTAssertTrue(redacted.contains("command: aws"))

        let config = try XCTUnwrap(Kubeconfig.parse(text))
        let users = Dictionary(uniqueKeysWithValues: config.users.map { ($0.name, $0.auth) })
        XCTAssertEqual(users["bearer"], .token, "the kind still reads")
        XCTAssertEqual(users["basic"], .basic)
        XCTAssertEqual(users["legacy"], .authProvider("oidc"))
        XCTAssertEqual(users["kubernetes-admin"], .clientCertificate)
        let everything = String(reflecting: config) + "\(config)"
        for secret in ["U0VDUkVUS0VZ", "eyJhbGci", "hunter2", "shhhh", "rrrrrrrrrr"] {
            XCTAssertFalse(everything.contains(secret), secret)
        }
        XCTAssertFalse(everything.contains("--cluster-name"), "exec arguments are shown on purpose, never in a description")
        XCTAssertEqual("\(users["oidc-dev"]!)", "exec: kubectl oidc-login")
    }

    func testJSONAndEmptyFilesRead() throws {
        let json =
            #"{"apiVersion":"v1","kind":"Config","current-context":"a","clusters":[{"name":"c","cluster":{"server":"http://127.0.0.1:1"}}],"contexts":[{"name":"a","context":{"cluster":"c","user":"u","namespace":"ns"}}],"users":[{"name":"u","user":{"token":"secret-token"}}]}"#
        let config = try XCTUnwrap(Kubeconfig.parse(json))
        XCTAssertEqual(config.contexts.first?.namespace, "ns")
        XCTAssertEqual(config.users.first?.auth, .token)
        XCTAssertEqual(Kubeconfig.parse(""), Kubeconfig())
        XCTAssertNil(Kubeconfig.parse("- just\n- a list\n"))
    }

    // MARK: Merging

    /// kubectl's rule: the first file to name a context, cluster or user
    /// wins, and the first file's current context is the current one.
    func testMergeOrderIsKubectls() throws {
        let first = try XCTUnwrap(
            Kubeconfig.parse(
                """
                clusters:
                - name: shared
                  cluster: {server: https://first}
                contexts:
                - name: shared
                  context: {cluster: shared, user: shared, namespace: one}
                users:
                - name: shared
                  user: {token: x}
                """))
        let second = try XCTUnwrap(
            Kubeconfig.parse(
                """
                current-context: only-second
                clusters:
                - name: shared
                  cluster: {server: https://second}
                - name: other
                  cluster: {server: https://other}
                contexts:
                - name: shared
                  context: {cluster: shared, user: shared, namespace: two}
                - name: only-second
                  context: {cluster: other, user: shared}
                users:
                - name: shared
                  user: {client-certificate-data: abc}
                """))
        let third = try XCTUnwrap(Kubeconfig.parse("current-context: third\ncontexts: []\n"))
        let list = KubeContextList.resolve([first, second, third], settings: [:])
        XCTAssertEqual(list.contexts.map(\.name), ["shared", "only-second"])
        XCTAssertEqual(list.context(named: "shared")?.namespace, "one", "the first file's context")
        XCTAssertEqual(list.context(named: "shared")?.server, "https://first", "and its cluster")
        XCTAssertEqual(list.context(named: "only-second")?.server, "https://other")
        XCTAssertEqual(list.context(named: "only-second")?.auth, .token, "a user the first file named, wherever it is used")
        XCTAssertEqual(list.current, "only-second", "the first file that sets one — the first set none")
        XCTAssertEqual(KubeContextList.resolve([third, second], settings: [:]).current, "third")
    }

    /// The files: KUBECONFIG's list in order (repeats and empty entries
    /// passed over), else ~/.kube/config, then the setting's extras.
    func testWhichFilesAreRead() throws {
        let extra = try write("{}", to: "extra/one.yaml")
        try write("{}", to: "folder/b.yaml")
        try write("{}", to: "folder/a.yaml")
        try write("{}", to: "folder/.hidden")
        let folder = dir.appendingPathComponent("folder")
        func paths(_ variable: String?, _ extras: [String] = []) -> [String] {
            KubeconfigSources.paths(overterm: nil, guarded: false, kubeconfig: variable, extra: extras, home: home).map(\.path)
        }
        XCTAssertEqual(paths(nil), [home.appendingPathComponent(".kube/config").path])
        XCTAssertEqual(paths(""), [home.appendingPathComponent(".kube/config").path], "an empty KUBECONFIG is unset")
        XCTAssertEqual(paths("/a:/b::/a:~/c"), ["/a", "/b", home.appendingPathComponent("c").path])
        XCTAssertEqual(
            paths("/a", [extra.path, folder.path, "relative/x", "/a"]),
            ["/a", extra.path, folder.appendingPathComponent("a.yaml").path, folder.appendingPathComponent("b.yaml").path],
            "a folder gives its files, sorted; a relative path or a repeat is passed over")
        XCTAssertEqual(paths(nil, ["~/.kube/other"]), [home.appendingPathComponent(".kube/config").path, home.appendingPathComponent(".kube/other").path])
    }

    func testLoadingReadsFilesInOrderAndReportsBadOnes() throws {
        let a = try write("current-context: a\ncontexts:\n- name: a\n  context: {cluster: c, user: u}\n", to: "a.yaml")
        let b = try write("contexts:\n- name: a\n  context: {cluster: other, user: u}\n- name: b\n  context: {cluster: c, user: u}\n", to: "b.yaml")
        let bad = try write("contexts: [unclosed\n", to: "bad.yaml")
        let missing = dir.appendingPathComponent("missing.yaml")
        let list = KubeContextList.load(files: [a, missing, bad, b], settings: [:], guarded: false, home: home)
        XCTAssertEqual(list.contexts.map(\.name), ["a", "b"])
        XCTAssertEqual(list.context(named: "a")?.cluster, "c")
        XCTAssertEqual(list.files, [a, b], "a missing file is passed over, as kubectl does")
        XCTAssertEqual(list.problems.count, 1, list.problems.joined())
        XCTAssertTrue(list.problems[0].contains("bad.yaml"))
    }

    // MARK: The isolated-run guard

    /// A unit test is guarded: AppEnvironment gives no kubeconfig at all —
    /// not ~/.kube/config, not the setting's extras — and never asks the
    /// shell (an inherited KUBECONFIG can't come through).
    func testThisTestNeverSeesTheUsersKubeconfig() {
        // A broken guard must stop the test here: the calls below would
        // otherwise ask the shell and read the real ~/.kube/config.
        guard AppEnvironment.isUnitTest, AppEnvironment.guardsKubeconfig else {
            return XCTFail("the kubeconfig guard is off in a unit test — not reading on")
        }
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        let files = AppEnvironment.kubeconfigs(extra: ["~/.kube/config", realHome.appendingPathComponent(".kube").path, "/tmp/x"])
        if let own = ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"], !own.isEmpty {
            XCTAssertFalse(files.contains { KubeconfigSources.isUsersOwn($0, home: realHome) }, "\(files)")
        } else {
            XCTAssertEqual(files, [], "no kubeconfig without OVERTERM_KUBECONFIG")
        }
        let list = KubeContextList.fromEnvironment(extra: ["~/.kube/config"], settings: [:])
        XCTAssertFalse(list.files.contains { KubeconfigSources.isUsersOwn($0, home: realHome) })
        if ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"] == nil { XCTAssertEqual(list.contexts, []) }
    }

    /// Guarded, only OVERTERM_KUBECONFIG's files are read — and even then
    /// never one under ~/.kube, symlinked or not; without it, nothing.
    func testTheGuardReadsOnlyTheScenariosFile() throws {
        let fake = try write("contexts:\n- name: fake-prod\n  context: {cluster: c, user: u}\n", to: "fake/kubeconfig")
        let own = try write(Self.thisMac, to: "home/.kube/config")
        let link = dir.appendingPathComponent("innocent.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: own)

        func guarded(_ overterm: String?) -> [URL] {
            KubeconfigSources.paths(overterm: overterm, guarded: true, kubeconfig: own.path, extra: [own.path, "~/.kube/config"], home: home)
        }
        XCTAssertEqual(guarded(nil), [], "no OVERTERM_KUBECONFIG: no contexts, so no proxy can start")
        XCTAssertEqual(guarded(""), [])
        XCTAssertEqual(guarded(fake.path), [fake], "KUBECONFIG and the extras are never read")
        XCTAssertEqual(guarded("\(fake.path):\(own.path):~/.kube/config:\(link.path)"), [fake], "~/.kube refused, through a link too")
        XCTAssertEqual(
            KubeconfigSources.paths(overterm: nil, guarded: false, kubeconfig: nil, extra: [], home: home), [own],
            "not guarded, ~/.kube/config is kubectl's default")

        // The loader refuses it a second time, whoever built the list.
        let list = KubeContextList.load(files: [own, link, fake], settings: [:], guarded: true, home: home)
        XCTAssertEqual(list.contexts.map(\.name), ["fake-prod"])
        XCTAssertEqual(list.files, [fake])
        XCTAssertEqual(list.problems.count, 2)
        XCTAssertEqual(KubeContextList.load(files: [own], settings: [:], guarded: false, home: home).contexts.count, 5)
    }

    // MARK: Classes

    /// This Mac's five names: the two -prod are production, the rest remote
    /// — read-only too.
    func testThisMacsContextsClassify() throws {
        let list = KubeContextList.resolve([try XCTUnwrap(Kubeconfig.parse(Self.thisMac))], settings: [:])
        let classes = Dictionary(uniqueKeysWithValues: list.contexts.map { ($0.name, $0.contextClass) })
        XCTAssertEqual(
            classes,
            [
                "arn:aws:eks:eu-west-1:111122223333:cluster/acme-dev": .remote,
                "arn:aws:eks:eu-west-1:111122223333:cluster/acme-prod": .production,
                "globex-eu-west-1-dev": .remote,
                "globex-eu-west-1-prod": .production,
                "kubernetes-admin@k8s-cluster": .remote,
            ])
        XCTAssertTrue(list.contexts.allSatisfy { !$0.isWritable }, "nothing on this Mac is writable by default")
        XCTAssertTrue(list.context(named: list.current ?? "")?.isProduction == true, "the current context is production")
    }

    func testTheProductionPattern() {
        for name in [
            "prod", "acme-prod", "globex-eu-west-1-prod", "arn:aws:eks:eu-west-1:1:cluster/acme-prod", "prd-eu", "my_production",
            "shop.live", "PROD-1", "gke_project_europe-west1_live", "eu:prd:x", "kubernetes-admin@prod", "oidc@live-eu",
        ] {
            XCTAssertTrue(KubeClassifier.isProduction(name: name), name)
        }
        for name in [
            "acme-dev", "globex-eu-west-1-dev", "kubernetes-admin@k8s-cluster", "product-api", "products", "preprod", "delivery",
            "olive", "liveness", "kind-fake", "fake-dev", "staging", "reproduce",
        ] {
            XCTAssertFalse(KubeClassifier.isProduction(name: name), name)
        }
    }

    /// Decision 31: by hand, then production by name, then local by name,
    /// then remote — and a loopback server never makes a context local.
    func testClassPrecedence() throws {
        let config = try XCTUnwrap(
            Kubeconfig.parse(
                """
                clusters:
                - name: loop
                  cluster: {server: "http://127.0.0.1:6443"}
                - name: loop6
                  cluster: {server: "https://[::1]:6443"}
                - name: prod-cluster
                  cluster: {server: "https://k.example"}
                contexts:
                - {name: fake-prod, context: {cluster: loop, user: u}}
                - {name: fake-dev, context: {cluster: loop, user: u}}
                - {name: kind-fake, context: {cluster: loop, user: u}}
                - {name: kind-prod-copy, context: {cluster: loop, user: u}}
                - {name: tunnel, context: {cluster: loop6, user: u}}
                - {name: innocent, context: {cluster: prod-cluster, user: u}}
                - {name: docker-desktop, context: {cluster: loop, user: u}}
                - {name: k3d-dev, context: {cluster: loop, user: u}}
                - {name: hand-set, context: {cluster: loop, user: u}}
                - {name: hand-local-prod, context: {cluster: loop, user: u}}
                - {name: minikube-like, context: {cluster: loop, user: u}}
                - {name: kubernetes-admin@prod, context: {cluster: loop, user: u}}
                """))
        let settings: [String: KubeContextSettings] = [
            "hand-set": KubeContextSettings(contextClass: .production),
            "hand-local-prod": KubeContextSettings(contextClass: .local),
            "fake-dev": KubeContextSettings(writable: false),
            "kubernetes-admin@prod": KubeContextSettings(writable: true),
        ]
        let list = KubeContextList.resolve([config], settings: settings)
        func kind(_ name: String) -> KubeContextClass? { list.context(named: name)?.contextClass }
        XCTAssertEqual(kind("fake-prod"), .production)
        XCTAssertEqual(kind("fake-dev"), .remote, "127.0.0.1 is not local")
        XCTAssertEqual(kind("tunnel"), .remote, "nor ::1")
        XCTAssertEqual(kind("kind-fake"), .local)
        XCTAssertEqual(kind("kind-prod-copy"), .production, "production by name beats a local name")
        XCTAssertEqual(kind("innocent"), .production, "the cluster's name counts too")
        XCTAssertEqual(kind("docker-desktop"), .local)
        XCTAssertEqual(kind("k3d-dev"), .local)
        XCTAssertEqual(kind("minikube-like"), .remote, "local names are exact, or kind-/k3d-")
        XCTAssertEqual(kind("kubernetes-admin@prod"), .production, "kubeadm's user@cluster, its cluster's name innocent")
        XCTAssertEqual(kind("hand-set"), .production, "by hand first")
        XCTAssertEqual(kind("hand-local-prod"), .local, "by hand, even less strict — only ever by an explicit setting")

        XCTAssertFalse(list.context(named: "fake-prod")!.isWritable)
        XCTAssertFalse(list.context(named: "fake-dev")!.isWritable)
        XCTAssertTrue(list.context(named: "kind-fake")!.isWritable)
        XCTAssertFalse(list.context(named: "kind-prod-copy")!.isWritable)
        XCTAssertFalse(list.context(named: "kubernetes-admin@prod")!.isWritable, "writable: true never opens production")
    }

    /// A remote context is writable only by its flag; production never by
    /// a flag, only for a session; a local one unless its flag says no.
    func testWritable() {
        XCTAssertFalse(KubeClassifier.isWritable(.production, flag: true), "a setting never makes production writable")
        XCTAssertTrue(KubeClassifier.isWritable(.production, flag: nil, productionSession: true))
        XCTAssertFalse(KubeClassifier.isWritable(.remote, flag: nil))
        XCTAssertTrue(KubeClassifier.isWritable(.remote, flag: true))
        XCTAssertTrue(KubeClassifier.isWritable(.local, flag: nil))
        XCTAssertFalse(KubeClassifier.isWritable(.local, flag: false))
    }
}
