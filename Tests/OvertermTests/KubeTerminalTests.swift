import Darwin
import XCTest

@testable import Overterm

/// Terminal in this context (docs/design/kubernetes/analysis.md, 3.11): the
/// pin's file — what it holds and doesn't, its permissions — the shell's
/// `KUBECONFIG` (the pin first, then exactly Overterm's files), the guard
/// in an isolated run or a unit test, where the tab opens, what it is and
/// how it is saved. Fictional clusters only; nothing reads ~/.kube.
final class KubeTerminalTests: XCTestCase {
    private var dir: URL!
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ot-kube-terminal-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let arn = "arn:aws:eks:eu-west-1:111122223333:cluster/acme-prod"

    private func pin(_ context: String = "fake-dev", namespace: String? = "shop", production: Bool = false) -> KubeTerminalPin {
        KubeTerminalPin(
            context: context, cluster: context + "-cluster", user: context + "-user", namespace: namespace, displayName: context,
            isProduction: production)
    }

    // MARK: The file

    func testTheFileSetsTheContextAndNamesTheUsersClusterAndUser() {
        let text = KubeTerminalConfig.text(for: pin(Self.arn, namespace: "billing", production: true))
        XCTAssertTrue(text.contains("current-context: \"\(Self.arn)\"\n"), text)
        XCTAssertTrue(text.contains("- name: \"\(Self.arn)\"\n  context:\n    cluster: \"\(Self.arn)-cluster\"\n    user: \"\(Self.arn)-user\"\n"), text)
        XCTAssertTrue(text.contains("    namespace: \"billing\"\n"), text)
        for secret in ["token", "client-key", "client-certificate", "password", "server:", "clusters:", "users:", "exec:", "auth-provider"] {
            XCTAssertFalse(text.contains(secret), "no credential, no server: \(secret)")
        }
        // Without a namespace, the entry has none (kubectl's default).
        XCTAssertFalse(KubeTerminalConfig.text(for: pin(namespace: nil)).contains("namespace"))
        // A context the kubeconfig names without its cluster or user: the
        // entry all the same, copied as it is — else the namespace is lost
        // and a set-context in the tab writes the user's file.
        let bare = KubeTerminalPin(context: "kind-fake", cluster: "", user: "", namespace: "shop", displayName: "kind-fake", isProduction: false)
        let text2 = KubeTerminalConfig.text(for: bare)
        XCTAssertTrue(text2.contains("current-context: \"kind-fake\""))
        XCTAssertTrue(text2.contains("- name: \"kind-fake\"\n  context:\n    cluster: \"\"\n    user: \"\"\n    namespace: \"shop\"\n"), text2)
    }

    func testNamesAreQuotedWhole() {
        XCTAssertEqual(KubeTerminalConfig.quoted("a:b/c d"), #""a:b/c d""#)
        XCTAssertEqual(KubeTerminalConfig.quoted("say \"hi\"\\"), #""say \"hi\"\\""#)
        XCTAssertEqual(KubeTerminalConfig.quoted("line\nbreak\u{1}"), #""line\nbreak\u0001""#)
        XCTAssertEqual(KubeTerminalConfig.quoted("ünsal"), "\"ünsal\"")
    }

    func testTheFileIsNamedByAHashNeverTheContext() {
        let id = UUID()
        let name = KubeTerminalConfig.fileName(for: Self.arn, id: id)
        XCTAssertFalse(name.contains("acme"))
        XCTAssertTrue(name.range(of: #"^[0-9a-f]{12}-[0-9a-f]{8}-[0-9]+\.yaml$"#, options: .regularExpression) != nil, name)
        XCTAssertEqual(name, KubeTerminalConfig.fileName(for: Self.arn, id: id))
        XCTAssertNotEqual(name, KubeTerminalConfig.fileName(for: Self.arn, id: UUID()), "a tab's own")
        // The Overterm that wrote it, in the name.
        XCTAssertEqual(KubeTerminalConfig.owner(ofFile: name), getpid())
        XCTAssertEqual(KubeTerminalConfig.owner(ofFile: KubeTerminalConfig.fileName(for: "fake-dev", id: id, pid: 4242)), 4242)
        for other in ["000000000000-deadbeef.yaml", "notes.yaml", "000000000000-deadbeef-x.yaml", "000000000000-deadbeef-12.yml"] {
            XCTAssertNil(KubeTerminalConfig.owner(ofFile: other), other)
        }
    }

    func testTheSweepLeavesALiveOvertermsFiles() throws {
        let files = KubeTerminalFiles(folder: dir.appendingPathComponent("Contexts"))
        try FileManager.default.createDirectory(at: files.folder, withIntermediateDirectories: true)
        let id = UUID()
        let gone = KubeTerminalConfig.fileName(for: "fake-dev", id: id, pid: 999_991)
        let other = KubeTerminalConfig.fileName(for: "fake-dev", id: id, pid: 4242)
        let mine = KubeTerminalConfig.fileName(for: "fake-prod", id: id)
        for name in [gone, other, mine, "000000000000-deadbeef.yaml"] {
            try Data("current-context: \"fake-dev\"\n".utf8).write(to: files.folder.appendingPathComponent(name))
        }
        try files.prepare(isAlive: { $0 == 4242 })
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: files.folder.path))
        XCTAssertEqual(left, [other, mine, "000000000000-deadbeef.yaml"], "only a gone Overterm's file is swept")
        XCTAssertTrue(KubeTerminalFiles.isAlive(getpid()))
        XCTAssertTrue(KubeTerminalFiles.isAlive(1), "launchd: another user's, alive")
    }

    func testTheFileIsPrivateAndTheFolderToo() throws {
        let files = KubeTerminalFiles(folder: dir.appendingPathComponent("Kubernetes/Contexts"))
        // What a run before (gone) left goes before the first write.
        try FileManager.default.createDirectory(at: files.folder, withIntermediateDirectories: true)
        let stale = files.folder.appendingPathComponent(KubeTerminalConfig.fileName(for: "fake-prod", id: UUID(), pid: 999_993))
        try Data("current-context: \"fake-prod\"\n".utf8).write(to: stale)
        let file = try files.write(pin())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "swept")
        XCTAssertEqual(file.deletingLastPathComponent().path, files.folder.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), KubeTerminalConfig.text(for: pin()))
        XCTAssertEqual(mode(file.path), 0o600)
        XCTAssertEqual(mode(files.folder.path), 0o700)
        let second = try files.write(pin("fake-prod", production: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "only once a run: the first tab's file stays")
        XCTAssertNotEqual(file, second)
        XCTAssertEqual(mode(second.path), 0o600)
        // Never through a link someone put there.
        let target = dir.appendingPathComponent("elsewhere")
        try Data().write(to: target)
        let id = UUID()
        let link = files.folder.appendingPathComponent(KubeTerminalConfig.fileName(for: "fake-dev", id: id))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try files.write(pin(), id: id))
        XCTAssertEqual(try Data(contentsOf: target), Data())
    }

    func testTheDefaultFolderIsNeverTheRealSupportFolderInAUnitTest() {
        // A unit test's supportDirectory is the user's real one, where the
        // running app's pins live: the default moves to a temporary folder.
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        XCTAssertTrue(AppEnvironment.isUnitTest)
        let folder = KubeTerminalFiles().folder.standardizedFileURL.path
        XCTAssertFalse(folder.hasPrefix(real), folder)
        XCTAssertFalse(folder.hasPrefix(AppEnvironment.supportDirectory.standardizedFileURL.path), folder)
        XCTAssertTrue(folder.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path), folder)
        XCTAssertTrue(folder.hasSuffix("/Kubernetes/Contexts"), folder)
        XCTAssertEqual(KubeTerminalFiles.defaultFolder, KubeTerminalFiles().folder)
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return info.st_mode & 0o777
    }

    // MARK: The environment

    func testKubeconfigIsThePinThenExactlyOverTermsFiles() {
        let pinFile = URL(fileURLWithPath: "/support/Kubernetes/Contexts/abc.yaml")
        let a = URL(fileURLWithPath: "/work/a.yaml")
        let b = URL(fileURLWithPath: "/work/b.yaml")
        let environment = KubeTerminalEnvironment.make(pinFile: pinFile, kubeconfigs: [a, b, a], guarded: false, home: home)
        XCTAssertEqual(environment, ["KUBECONFIG": "/support/Kubernetes/Contexts/abc.yaml:/work/a.yaml:/work/b.yaml"], "nothing else")
        XCTAssertEqual(KubeTerminalEnvironment.firstFile(of: environment?["KUBECONFIG"]), pinFile.path)
        // The app's own run hands the user's own files on: it is their kubectl.
        let users = home.appendingPathComponent(".kube/config")
        XCTAssertEqual(
            KubeTerminalEnvironment.make(pinFile: pinFile, kubeconfigs: [users], guarded: false, home: home)?["KUBECONFIG"],
            pinFile.path + ":" + users.path)
        // Guarded: never one under ~/.kube; none, nothing.
        XCTAssertNil(KubeTerminalEnvironment.make(pinFile: pinFile, kubeconfigs: [a, users], guarded: true, home: home))
        XCTAssertNil(KubeTerminalEnvironment.make(pinFile: pinFile, kubeconfigs: [], guarded: true, home: home))
        XCTAssertNil(KubeTerminalEnvironment.make(pinFile: pinFile, kubeconfigs: [], guarded: false, home: home))
    }

    /// Overterm's own command in a pinned tab carries the pin's KUBECONFIG
    /// on its line: a startup file's `export KUBECONFIG=…` ran after the
    /// tab's environment, and `--context C` then meant another file's C.
    func testATypedLineCarriesExactlyThePinnedKubeconfig() throws {
        let files = KubeTerminalFiles(folder: dir.appendingPathComponent("Contexts"))
        let own = [dir.appendingPathComponent("acme config.yaml"), dir.appendingPathComponent("extra.yaml")]
        let ready = try KubeTerminalLaunch.prepare(pin(), kubeconfigs: own, files: files, guarded: true, home: home)
        let pinned = try XCTUnwrap(ready.environment["KUBECONFIG"])
        let command = "kubectl drain node-1 --context fake-dev"
        let line = try XCTUnwrap(KubeTerminalLaunch.pinnedLine(command, environment: ready.environment))
        XCTAssertEqual(line, "export KUBECONFIG=" + KubectlLine.quoted(pinned) + "; " + command)
        XCTAssertNil(KubeTerminalLaunch.pinnedLine(command, environment: [:]))
        // The shell's rc exported another: the line puts the pin's back.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "export KUBECONFIG=/elsewhere/config; " + line.replacingOccurrences(of: command, with: "print -rn -- $KUBECONFIG")]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), pinned)
    }

    func testGuardedNothingOfTheUsersIsWrittenOrHandedOn() {
        let files = KubeTerminalFiles(folder: dir.appendingPathComponent("Contexts"))
        let users = home.appendingPathComponent(".kube/config")
        XCTAssertThrowsError(try KubeTerminalLaunch.prepare(pin(), kubeconfigs: [users], files: files, guarded: true, home: home)) {
            XCTAssertEqual($0 as? KubeTerminalLaunch.Problem, .usersOwn)
        }
        XCTAssertThrowsError(try KubeTerminalLaunch.prepare(pin(), kubeconfigs: [], files: files, guarded: true, home: home)) {
            XCTAssertEqual($0 as? KubeTerminalLaunch.Problem, .noKubeconfig)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.folder.path), "refused before anything is written")
        // A unit test is guarded: its files are only OVERTERM_KUBECONFIG's — none here.
        XCTAssertTrue(AppEnvironment.guardsKubeconfig)
        if ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"] == nil {
            let own = AppEnvironment.kubeconfigs(extra: ["~/.kube/config"])
            XCTAssertEqual(own, [], "the user's KUBECONFIG and ~/.kube never come through")
            XCTAssertThrowsError(try KubeTerminalLaunch.prepare(pin(), kubeconfigs: own, files: files)) {
                XCTAssertEqual($0 as? KubeTerminalLaunch.Problem, .noKubeconfig)
            }
        }
    }

    func testPreparedThePinKnowsItsFiles() throws {
        let files = KubeTerminalFiles(folder: dir.appendingPathComponent("Contexts"))
        let own = dir.appendingPathComponent("fake.yaml")
        let ready = try KubeTerminalLaunch.prepare(pin(), kubeconfigs: [own], files: files, guarded: true, home: home)
        XCTAssertEqual(ready.pin.kubeconfigs, [own.path])
        let value = try XCTUnwrap(ready.environment["KUBECONFIG"])
        let first = try XCTUnwrap(KubeTerminalEnvironment.firstFile(of: value))
        XCTAssertTrue(first.hasPrefix(files.folder.path + "/"))
        XCTAssertEqual(value, first + ":" + own.path)
        XCTAssertTrue(try String(contentsOfFile: first, encoding: .utf8).contains("current-context: \"fake-dev\""))
    }

    // MARK: The pin, the folder, the tab

    func testThePinsNamespaceIsTheOneAskedElseTheContexts() {
        let context = KubeContext(
            name: "fake-dev", cluster: "c", server: "http://127.0.0.1:1", namespace: "shop", user: "u", auth: nil, file: nil, contextClass: .remote,
            settings: KubeContextSettings())
        XCTAssertEqual(KubeTerminalPin(context, namespace: "payments").namespace, "payments")
        XCTAssertEqual(KubeTerminalPin(context).namespace, "shop")
        let picked = KubeContext(
            name: "fake-dev", cluster: "c", server: nil, namespace: "shop", user: "u", auth: nil, file: nil, contextClass: .remote,
            settings: KubeContextSettings(defaultNamespace: "web"))
        XCTAssertEqual(KubeTerminalPin(picked).namespace, "web")
        let prod = KubeContext(
            name: "fake-prod", cluster: "c", server: nil, namespace: nil, user: "u", auth: nil, file: nil, contextClass: .production,
            settings: KubeContextSettings(displayName: "Prod"))
        let pin = KubeTerminalPin(prod)
        XCTAssertNil(pin.namespace)
        XCTAssertTrue(pin.isProduction)
        XCTAssertEqual(pin.label, "⎈ Prod")
        XCTAssertEqual(KubeTerminalPin(context).label, "⎈ fake-dev · shop")
        XCTAssertTrue(pin.help.contains("PRODUCTION"))
    }

    func testTheTabOpensInTheContextsFolderElseHome() {
        let folders: Set<String> = ["/Users/someone/src/shop", "/repo"]
        let isFolder: (String) -> Bool = { folders.contains($0) }
        XCTAssertEqual(KubeTerminalDirectory.choose(setting: "~/src/shop", checkout: nil, home: home, isFolder: isFolder).path, "/Users/someone/src/shop")
        XCTAssertEqual(KubeTerminalDirectory.choose(setting: "~/gone", checkout: URL(fileURLWithPath: "/repo"), home: home, isFolder: isFolder).path, "/repo")
        XCTAssertEqual(KubeTerminalDirectory.choose(setting: "relative", checkout: nil, home: home, isFolder: isFolder), home)
        XCTAssertEqual(KubeTerminalDirectory.choose(setting: nil, checkout: nil, home: home, isFolder: isFolder), home)
    }

    func testTheSettingIsAnEntryField() {
        let settings = KubeContextSettings(fields: ["terminalDirectory": .string("~/src/shop")])
        XCTAssertEqual(settings.terminalDirectory, "~/src/shop")
        XCTAssertNil(KubeContextSettings(fields: ["terminalDirectory": .string("")]).terminalDirectory)
        XCTAssertTrue(KubeContextSettings.fields.contains { $0.name == "terminalDirectory" })
    }

    func testAPinnedTabIsAKubernetesOne() {
        XCTAssertEqual(TabKind.of(agent: nil, title: "~/src", hasPort: false, pinned: true), .kubernetes)
        XCTAssertEqual(TabKind.of(agent: nil, title: "pnpm dev", hasPort: true, pinned: true), .kubernetes)
        XCTAssertEqual(TabKind.of(agent: nil, title: "ssh box", hasPort: false, pinned: true), .ssh, "on another machine now")
        XCTAssertEqual(TabKind.of(agent: nil, title: "docker exec -it web sh", hasPort: false, pinned: true), .container)
        XCTAssertEqual(TabKind.of(agent: .claude, title: "~/src", hasPort: false, pinned: true), .agent)
        XCTAssertEqual(TabKind.of(agent: nil, title: "~/src", hasPort: false), .shell)
        XCTAssertEqual(TabKind.kubernetes.symbol, "helm")
    }

    // MARK: Restored, followed, a tab of several

    /// fake-dev and fake-prod, in a file of the test's own.
    private func kubeconfig(_ name: String = "fake.yaml", prodNamespace: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let namespace = prodNamespace.map { ", namespace: \($0)" } ?? ""
        let text = """
            apiVersion: v1
            kind: Config
            current-context: fake-prod
            clusters:
            - name: fake-dev
              cluster: {server: "http://127.0.0.1:1"}
            - name: fake-prod
              cluster: {server: "http://127.0.0.1:2"}
            users:
            - name: dev
              user: {}
            - name: prod
              user: {}
            contexts:
            - name: fake-dev
              context: {cluster: fake-dev, user: dev, namespace: shop}
            - name: fake-prod
              context: {cluster: fake-prod, user: prod\(namespace)}

            """
        try Data(text.utf8).write(to: url)
        return url
    }

    private func list(_ files: [URL], settings: [String: KubeContextSettings] = [:]) -> KubeContextList {
        KubeContextList.load(files: files, settings: settings, guarded: true, home: home)
    }

    @MainActor func testARestoredPinWhoseKubeconfigIsGoneIsLostNeverAPlainShell() throws {
        let files = KubeTerminalFiles(folder: dir.appendingPathComponent("Contexts"))
        var saved = pin("fake-dev")
        saved.kubeconfigs = [dir.appendingPathComponent("gone.yaml").path]
        // No kubeconfig at all now.
        let none = KubeTerminalRestore.pane(saved, list: KubeContextList(), kubeconfigs: [], files: files, guarded: true, home: home)
        XCTAssertNil(none.pin)
        XCTAssertEqual(none.lost?.pin, saved, "kept, to be tried again")
        XCTAssertEqual(none.environment, ["KUBECONFIG": "/dev/null"], "a KUBECONFIG reaching nothing — never the app's own, the current context")
        // The files named, but none of them there: the context is gone.
        let missing = [dir.appendingPathComponent("gone.yaml")]
        let gone = KubeTerminalRestore.pane(saved, list: list(missing), kubeconfigs: missing, files: files, guarded: true, home: home)
        XCTAssertNil(gone.pin)
        XCTAssertEqual(gone.environment["KUBECONFIG"], "/dev/null")
        XCTAssertTrue(gone.lost?.reason.contains("fake-dev") == true, "\(String(describing: gone.lost))")
        XCTAssertTrue(gone.lost?.label.contains("pin lost") == true)
        // A context no longer in the files that are there.
        let own = try kubeconfig()
        let renamed = KubeTerminalRestore.pane(pin("acme-gone"), list: list([own]), kubeconfigs: [own], files: files, guarded: true, home: home)
        XCTAssertNotNil(renamed.lost)
        XCTAssertEqual(renamed.environment, KubeTerminalLost.environment)
        // Guarded, the user's own is refused: lost, nothing written.
        let users = home.appendingPathComponent(".kube/config")
        let refused = KubeTerminalRestore.pane(
            pin("fake-dev"), list: list([own]), kubeconfigs: [own, users], files: files, guarded: true, home: home)
        XCTAssertNotNil(refused.lost)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.folder.path))
        // The tab it comes back as says so, in red, and is a Kubernetes one.
        let tab = Tab(terminal: TerminalView(environment: none.environment, kubePinLost: none.lost))
        XCTAssertEqual(tab.kubeBadge?.text, "⎈ pin lost")
        XCTAssertEqual(tab.kubeBadge?.alert, true)
        XCTAssertEqual(tab.kind, .kubernetes)
        XCTAssertEqual(TerminalWindowController.savedKubePin(tab.terminal), saved, "saved again as it was")
    }

    func testARestoredPinIsTheContextAsItIsNowNotAsSaved() throws {
        let files = KubeTerminalFiles(folder: dir.appendingPathComponent("Contexts"))
        let now = try kubeconfig("now.yaml")
        // Saved before fake-prod was production, from files Overterm reads no more.
        let saved = KubeTerminalPin(
            context: "fake-prod", cluster: "old-cluster", user: "old-user", namespace: "payments", displayName: "Old name", isProduction: false,
            kubeconfigs: ["/work/old.yaml"])
        let restored = KubeTerminalRestore.pane(
            saved, list: list([now], settings: ["fake-prod": KubeContextSettings(displayName: "Prod")]), kubeconfigs: [now], files: files,
            guarded: true, home: home)
        let pin = try XCTUnwrap(restored.pin)
        XCTAssertTrue(pin.isProduction, "its class now: the band")
        XCTAssertEqual(pin.displayName, "Prod")
        XCTAssertEqual(pin.cluster, "fake-prod")
        XCTAssertEqual(pin.user, "prod")
        XCTAssertEqual(pin.namespace, "payments", "the tab's namespace kept")
        XCTAssertEqual(pin.kubeconfigs, [now.path], "Overterm's files now")
        let value = try XCTUnwrap(restored.environment["KUBECONFIG"])
        XCTAssertTrue(value.hasSuffix(":" + now.path) && !value.contains("old.yaml"), value)
        let text = try String(contentsOfFile: try XCTUnwrap(KubeTerminalEnvironment.firstFile(of: value)), encoding: .utf8)
        XCTAssertTrue(text.contains("cluster: \"fake-prod\"") && !text.contains("old-cluster"), text)
        // And the other way: saved production, no longer.
        let dev = KubeTerminalRestore.pane(
            KubeTerminalPin(context: "fake-dev", cluster: "x", user: "y", namespace: nil, displayName: "fake-dev", isProduction: true),
            list: list([now]), kubeconfigs: [now], files: files, guarded: true, home: home)
        XCTAssertEqual(dev.pin?.isProduction, false)
        XCTAssertEqual(dev.pin?.namespace, "shop", "none saved: the context's own")
    }

    @MainActor func testThePinFollowsAUseContextTypedInTheTab() throws {
        let files = KubeTerminalFiles(folder: dir.appendingPathComponent("Contexts"))
        let own = try kubeconfig(prodNamespace: "payments")
        let ready = try KubeTerminalLaunch.prepare(pin("fake-dev", namespace: "shop"), kubeconfigs: [own], files: files, guarded: true, home: home)
        let value = try XCTUnwrap(ready.environment["KUBECONFIG"])
        let paneFiles = KubeTerminalFollow.files(of: value)
        XCTAssertEqual(paneFiles.map(\.path), value.split(separator: ":").map(String.init))
        func followed() -> KubeTerminalPin { KubeTerminalFollow.pin(from: list(paneFiles), was: ready.pin, settings: [:]) }
        XCTAssertEqual(followed().context, "fake-dev")
        XCTAssertEqual(followed().namespace, "shop")
        XCTAssertFalse(followed().isProduction)
        let pinFile = paneFiles[0]
        // `kubectl config set-context --current --namespace=web`, as kubectl writes it.
        try Data(
            "apiVersion: v1\nkind: Config\ncurrent-context: fake-dev\ncontexts:\n- context:\n    cluster: fake-dev\n    namespace: web\n    user: dev\n  name: fake-dev\n"
                .utf8
        ).write(to: pinFile)
        XCTAssertEqual(followed().namespace, "web")
        // `kubectl config use-context fake-prod`: production now, in its own namespace.
        try Data(
            "apiVersion: v1\nkind: Config\ncurrent-context: fake-prod\ncontexts:\n- context:\n    cluster: fake-dev\n    namespace: web\n    user: dev\n  name: fake-dev\n"
                .utf8
        ).write(to: pinFile)
        let prod = followed()
        XCTAssertEqual(prod.context, "fake-prod")
        XCTAssertTrue(prod.isProduction)
        XCTAssertEqual(prod.namespace, "payments")
        XCTAssertEqual(prod.label, "⎈ fake-prod · payments")
        XCTAssertEqual(prod.kubeconfigs, ready.pin.kubeconfigs)
        // `unset current-context`: the next file's — the user's own, production.
        try Data("apiVersion: v1\nkind: Config\n".utf8).write(to: pinFile)
        XCTAssertEqual(followed().context, "fake-prod")
        XCTAssertTrue(followed().isProduction)
        // A name no file has: kubectl refuses it; classed by its name.
        try Data("apiVersion: v1\nkind: Config\ncurrent-context: acme-prod\n".utf8).write(to: pinFile)
        XCTAssertEqual(followed().context, "acme-prod")
        XCTAssertTrue(followed().isProduction)
        // And a pane's label follows: the tab's strip with it.
        let pane = TerminalView(environment: ready.environment, kubePin: ready.pin)
        let tab = Tab(terminal: pane)
        XCTAssertEqual(tab.kubeBadge?.text, "⎈ fake-dev")
        pane.kubePin = prod
        XCTAssertEqual(tab.kubeBadge, KubeTabBadge(text: "⎈ fake-prod", help: prod.help, alert: true))
        XCTAssertEqual(TerminalWindowController.savedKubePin(pane), prod, "saved as it is now")
    }

    @MainActor func testAMovedPaneKeepsItsPinAndTheTabSaysMixed() {
        let dev = pin("fake-dev")
        let prod = pin("fake-prod", namespace: nil, production: true)
        typealias P = KubeTabBadge.Pane
        XCTAssertNil(KubeTabBadge.of([P(), P()]))
        XCTAssertEqual(KubeTabBadge.of([P(pin: dev), P(pin: dev)])?.text, "⎈ fake-dev")
        XCTAssertEqual(KubeTabBadge.of([P(pin: dev), P(pin: dev)])?.alert, false)
        // A fake-prod pane moved into a fake-dev tab.
        let mixed = KubeTabBadge.of([P(pin: dev), P(pin: prod)])
        XCTAssertEqual(mixed?.text, "⎈ mixed")
        XCTAssertEqual(mixed?.alert, true)
        XCTAssertTrue(mixed?.help.contains("fake-prod (PRODUCTION)") == true, mixed?.help ?? "")
        // An unpinned pane among pinned ones reaches the current context: never one pane's label.
        let plain = KubeTabBadge.of([P(pin: dev), P()])
        XCTAssertEqual(plain?.text, "⎈ mixed")
        XCTAssertEqual(plain?.alert, true)
        XCTAssertTrue(plain?.help.contains("unpinned") == true)
        XCTAssertEqual(KubeTabBadge.of([P(), P(pin: dev)])?.text, "⎈ mixed", "whichever pane has the keyboard")
        // The same context in other namespaces differs too.
        XCTAssertEqual(KubeTabBadge.of([P(pin: dev), P(pin: pin("fake-dev", namespace: "web"))])?.text, "⎈ mixed")

        // A tab of such panes: the strip says mixed, the focused pane's pin is its own.
        let devPane = TerminalView(kubePin: dev)
        let tab = Tab(terminal: devPane)
        let prodPane = TerminalView(kubePin: prod)
        tab.setSplits(tab.splits.inserting(prodPane, at: devPane, .right))
        XCTAssertEqual(tab.kubeBadge?.text, "⎈ mixed")
        tab.focus(prodPane)
        XCTAssertEqual(tab.kubePin, prod)
        XCTAssertEqual(tab.kind, .kubernetes)
    }

    func testEachPaneIsSavedWithItsOwnPin() throws {
        let dev = pin("fake-dev")
        let prod = pin("fake-prod", production: true)
        let layout = SessionState.PaneLayout.split(
            axis: "horizontal", ratio: 0.5, first: .pane(directory: "/a"),
            second: .split(axis: "vertical", ratio: 0.5, first: .pane(directory: "/b"), second: .pane(directory: "/c")))
        var tab = SessionState.TabState(workingDirectory: "/a", customTitle: nil, color: nil, isPinned: false, agent: nil, panes: layout)
        tab.paneKubeContexts = [dev, prod, nil]
        XCTAssertEqual(tab.kubeContext(ofPane: 0), dev)
        XCTAssertEqual(tab.kubeContext(ofPane: 1), prod, "a fake-prod pane moved in comes back fake-prod")
        XCTAssertNil(tab.kubeContext(ofPane: 2), "an unpinned pane comes back unpinned")
        XCTAssertNil(tab.kubeContext(ofPane: 3))
        XCTAssertTrue(tab.hasKubeContext)
        let url = dir.appendingPathComponent("session.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try SessionState(tabs: [tab], selectedIndex: 0).save(to: url)
        XCTAssertEqual(SessionState.load(from: url)?.tabs.first?.paneKubeContexts, [dev, prod, nil])
        // A file from before panes had their own: the tab's, every pane.
        var old = SessionState.TabState(workingDirectory: "/a", customTitle: nil, color: nil, isPinned: false, agent: nil, panes: layout)
        old.kubeContext = dev
        XCTAssertEqual((0..<3).map { old.kubeContext(ofPane: $0) }, [dev, dev, dev])
        let none = SessionState.TabState(workingDirectory: "/a", customTitle: nil, color: nil, isPinned: false, agent: nil)
        XCTAssertFalse(none.hasKubeContext)
        // The order is the one restore builds the panes in.
        var order: [String?] = []
        _ = layout.tree { directory, _ -> NSObject in
            order.append(directory)
            return NSObject()
        }
        XCTAssertEqual(order, ["/a", "/b", "/c"])
    }

    func testAPinnedTabIsSavedAndAnOldSessionStillLoads() throws {
        let url = dir.appendingPathComponent("session.json")
        var saved = pin()
        saved.kubeconfigs = ["/work/fake.yaml"]
        let state = SessionState(
            tabs: [.init(workingDirectory: "/repo", customTitle: nil, color: nil, isPinned: false, agent: nil, kubeContext: saved)], selectedIndex: 0)
        try state.save(to: url)
        XCTAssertEqual(SessionState.load(from: url)?.tabs.first?.kubeContext, saved)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("token"))
        try Data(#"{"selectedIndex":0,"tabs":[{"workingDirectory":"/repo","isPinned":false}]}"#.utf8).write(to: url)
        XCTAssertNotNil(SessionState.load(from: url))
        XCTAssertNil(SessionState.load(from: url)?.tabs.first?.kubeContext)
    }
}

/// The merge order 3.11 depends on, with the real tools when this Mac has
/// them — temporary kubeconfigs only, every server a closed port on
/// 127.0.0.1, a HOME of the test's own, kuberc off. `KUBECONFIG=<the pin's
/// file>:<the user's files>` makes a plain `kubectl` (and `helm`) use the
/// pin's context, its namespace, and the user's cluster and credentials;
/// the user's own `current-context` is production here, as on this Mac.
/// k9s reads it the same way (checked by hand: analysis 3.11) — a TUI, so
/// not here.
final class KubeTerminalMergeTests: XCTestCase {
    private var dir: URL!
    private var devPort = 0
    private var prodPort = 0

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ot-kube-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("home"), withIntermediateDirectories: true)
        devPort = try Self.closedPort()
        prodPort = try Self.closedPort()
        let users = """
            apiVersion: v1
            kind: Config
            current-context: fake-prod
            clusters:
            - name: fake-dev
              cluster: {server: "https://127.0.0.1:\(devPort)", insecure-skip-tls-verify: true}
            - name: fake-prod
              cluster: {server: "https://127.0.0.1:\(prodPort)", insecure-skip-tls-verify: true}
            users:
            - name: dev
              user: {token: fake-token-dev}
            - name: prod
              user: {token: fake-token-prod}
            contexts:
            - name: fake-dev
              context: {cluster: fake-dev, user: dev}
            - name: fake-prod
              context: {cluster: fake-prod, user: prod}

            """
        try Data(users.utf8).write(to: usersFile)
        try Data("apiVersion: v1\nkind: Config\ncurrent-context: fake-prod\ncontexts:\n- name: kind-fake\n  context: {cluster: fake-dev, user: dev}\n".utf8)
            .write(to: extraFile)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var usersFile: URL { dir.appendingPathComponent("users.yaml") }
    private var extraFile: URL { dir.appendingPathComponent("extra.yaml") }

    private static func tool(_ name: String) -> URL? {
        ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"].map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A port nothing listens on: bound, then let go.
    private static func closedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: 1) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw NSError(domain: "bind", code: 1) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// The tool, with only the test's own files and folders.
    private func run(_ tool: URL, _ arguments: [String], kubeconfig: String) -> String {
        let home = dir.appendingPathComponent("home").path
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": home, "KUBECONFIG": kubeconfig, "KUBERC": "off", "XDG_CONFIG_HOME": home + "/.config",
            "XDG_CACHE_HOME": home + "/.cache", "XDG_DATA_HOME": home + "/.data", "HELM_CONFIG_HOME": home + "/helm",
            "HELM_CACHE_HOME": home + "/helm-cache", "HELM_DATA_HOME": home + "/helm-data",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pinned(namespace: String?) throws -> (file: URL, kubeconfig: String) {
        let pin = KubeTerminalPin(context: "fake-dev", cluster: "fake-dev", user: "dev", namespace: namespace, displayName: "fake-dev", isProduction: false)
        let files = KubeTerminalFiles(folder: dir.appendingPathComponent("Contexts"))
        let ready = try KubeTerminalLaunch.prepare(
            pin, kubeconfigs: [usersFile, extraFile], files: files, guarded: true, home: URL(fileURLWithPath: "/Users/someone"))
        let value = try XCTUnwrap(ready.environment["KUBECONFIG"])
        return (URL(fileURLWithPath: try XCTUnwrap(KubeTerminalEnvironment.firstFile(of: value))), value)
    }

    func testAPlainKubectlGoesToThePinnedContext() throws {
        guard let kubectl = Self.tool("kubectl") else { throw XCTSkip("no kubectl") }
        let plain = usersFile.path + ":" + extraFile.path
        XCTAssertEqual(run(kubectl, ["config", "current-context"], kubeconfig: plain), "fake-prod", "the user's own: production")
        let (file, kubeconfig) = try pinned(namespace: "shop")
        XCTAssertEqual(run(kubectl, ["config", "current-context"], kubeconfig: kubeconfig), "fake-dev")
        let minify = run(
            kubectl,
            ["config", "view", "--minify", "-o", "jsonpath={.contexts[0].name} {.contexts[0].context.namespace} {.clusters[0].cluster.server} {.users[0].name}"],
            kubeconfig: kubeconfig)
        XCTAssertEqual(minify, "fake-dev shop https://127.0.0.1:\(devPort) dev", "its namespace, the user's cluster and user")
        // Changed in the tab, the pin's file changes — never the user's.
        let before = try Data(contentsOf: usersFile)
        _ = run(kubectl, ["config", "set-context", "--current", "--namespace=payments"], kubeconfig: kubeconfig)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("payments"))
        _ = run(kubectl, ["config", "use-context", "kind-fake"], kubeconfig: kubeconfig)
        XCTAssertEqual(run(kubectl, ["config", "current-context"], kubeconfig: kubeconfig), "kind-fake")
        XCTAssertEqual(try Data(contentsOf: usersFile), before, "the user's file is untouched")
        XCTAssertEqual(run(kubectl, ["config", "current-context"], kubeconfig: plain), "fake-prod", "and every other tab's context")
    }

    func testAContextWithoutAUserIsPinnedWithItsEntry() throws {
        guard let kubectl = Self.tool("kubectl") else { throw XCTSkip("no kubectl") }
        let text = try String(contentsOf: usersFile, encoding: .utf8) + "- name: fake-nouser\n  context: {cluster: fake-dev}\n"
        try Data(text.utf8).write(to: usersFile)
        let pin = KubeTerminalPin(context: "fake-nouser", cluster: "fake-dev", user: "", namespace: "shop", displayName: "fake-nouser", isProduction: false)
        let ready = try KubeTerminalLaunch.prepare(
            pin, kubeconfigs: [usersFile], files: KubeTerminalFiles(folder: dir.appendingPathComponent("Contexts")), guarded: true,
            home: URL(fileURLWithPath: "/Users/someone"))
        let kubeconfig = try XCTUnwrap(ready.environment["KUBECONFIG"])
        let file = URL(fileURLWithPath: try XCTUnwrap(KubeTerminalEnvironment.firstFile(of: kubeconfig)))
        let minify = run(
            kubectl, ["config", "view", "--minify", "-o", "jsonpath={.contexts[0].name} {.contexts[0].context.namespace} {.clusters[0].cluster.server}"],
            kubeconfig: kubeconfig)
        XCTAssertEqual(minify, "fake-nouser shop https://127.0.0.1:\(devPort)", "its namespace kept, the user's cluster")
        let before = try Data(contentsOf: usersFile)
        _ = run(kubectl, ["config", "set-context", "--current", "--namespace=payments"], kubeconfig: kubeconfig)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("payments"), "the pin's file takes it")
        XCTAssertEqual(try Data(contentsOf: usersFile), before, "never the user's")
    }

    func testHelmReadsItTheSameWay() throws {
        guard let helm = Self.tool("helm") else { throw XCTSkip("no helm") }
        let (_, kubeconfig) = try pinned(namespace: "billing")
        XCTAssertTrue(run(helm, ["env"], kubeconfig: kubeconfig).contains("HELM_NAMESPACE=\"billing\""))
        // A closed port answers at once: which server it tried says which context.
        XCTAssertTrue(run(helm, ["list"], kubeconfig: kubeconfig).contains("127.0.0.1:\(devPort)"))
        XCTAssertTrue(run(helm, ["list"], kubeconfig: usersFile.path).contains("127.0.0.1:\(prodPort)"))
    }
}
