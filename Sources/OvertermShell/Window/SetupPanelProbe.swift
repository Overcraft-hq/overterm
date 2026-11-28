import Foundation

/// "Tools the panels use" on the Setup page (onboarding 7.7, 3.1–3.2):
/// each panel's tools found by its feature's own finder — they look in
/// seven different ways, and one search for all would contradict what each
/// feature does — only for the panels that are on, only once the section
/// is opened. Here, above the features, because the finders are theirs.
///
/// Nothing under Desktop, Documents, Downloads or iCloud Drive is looked
/// at (`SetupProbe.isProtected`): a PATH folder there is passed over, as
/// macOS would ask the person before an app looks inside — but a path the
/// person set themselves (`kubernetes.kubectlPath`, `kubernetes.helmPath`,
/// `terraform.path`) is looked at wherever it is: they asked for it.
///
/// It looks; it never runs. No `docker info` or ping (it wakes Docker
/// Desktop's VM), no kube proxy or credential plugin, no `terraform
/// version`, no `mise which`, no `xcrun`, no `simctl`, no `dlopen`. Docker's
/// config and the kubeconfigs are read only by their features' own readers
/// (`DockerEndpoint.current()`; the Kubernetes page's contexts, when it read
/// them this launch — `reloadContexts()` is never called here); nothing of
/// either is kept but a name or a count.
package enum SetupPanelProbe {
    /// What the main thread hands over: which panels are on, their settings,
    /// and what the Kubernetes page has already read.
    package struct Inputs: Sendable {
        package var home: URL
        /// The PATH Overterm was started with (Docker's CLI looks there first).
        package var appPath: String?
        package var docker: Bool
        package var kubernetes: Bool
        package var terraform: Bool
        package var simulator: Bool
        package var languageServers: Bool
        /// The Database (BigQuery's gcloud) and the API client (gRPC's protoc).
        package var database: Bool
        package var api: Bool
        package var kubectlPath: String
        package var helmPath: String
        package var terraformPath: String
        /// An isolated run or a unit test: kubectl and helm only where their settings say.
        package var guardsKubeconfig: Bool
        /// The contexts as the Kubernetes page read them; nil when it hasn't this launch.
        package var contexts: [KubeContext]?
        package var ghosttyConfig: Bool
        /// The panels a fresh install hid (`FreshInstall.panelsHiddenKey`).
        package var hiddenAtInstall: [SidebarPanel]

        package init(
            home: URL, appPath: String?, docker: Bool, kubernetes: Bool, terraform: Bool, simulator: Bool, languageServers: Bool,
            database: Bool = false, api: Bool = false, kubectlPath: String = "", helmPath: String = "", terraformPath: String = "",
            guardsKubeconfig: Bool = false, contexts: [KubeContext]? = nil, ghosttyConfig: Bool = false, hiddenAtInstall: [SidebarPanel] = []
        ) {
            self.home = home
            self.appPath = appPath
            self.docker = docker
            self.kubernetes = kubernetes
            self.terraform = terraform
            self.simulator = simulator
            self.languageServers = languageServers
            self.database = database
            self.api = api
            self.hiddenAtInstall = hiddenAtInstall
            self.kubectlPath = kubectlPath
            self.helmPath = helmPath
            self.terraformPath = terraformPath
            self.guardsKubeconfig = guardsKubeconfig
            self.contexts = contexts
            self.ghosttyConfig = ghosttyConfig
        }
    }

    /// Where Xcode and the framework the simulator loads are: only their existence.
    package static let xcodePath = "/Applications/Xcode.app"
    package static let coreSimulatorPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"

    /// The paths the person set themselves, standardized: looked at even
    /// in a protected folder. Pure.
    package nonisolated static func chosenPaths(_ inputs: Inputs) -> Set<String> {
        var chosen: [String] = [inputs.kubectlPath, inputs.helmPath].compactMap { setting in
            KubeconfigSources.expand(setting.trimmingCharacters(in: .whitespaces), home: inputs.home)?.path
        }
        let terraform = (inputs.terraformPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if terraform.hasPrefix("/") { chosen.append(terraform) }
        return Set(chosen.map { path in (path as NSString).standardizingPath })
    }

    /// The facts, from the finders. Pure but for the closures and the
    /// language servers' `discovery`, which only look at files (fixed
    /// folders, none protected). `login`: the login shell's environment, as
    /// the features hand their tools. Every finder is handed an
    /// `isExecutable` that passes over protected folders but for the
    /// person's own settings (`chosenPaths`); `terraformBinary` too.
    package nonisolated static func facts(
        _ inputs: Inputs, login: [String: String]?, exists: (String) -> Bool, isExecutable: (String) -> Bool,
        dockerEndpoint: () -> DockerEndpoint, kubeconfigs: () -> [URL], terraformBinary: (_ isExecutable: (String) -> Bool) -> URL?,
        discovery: ServerDiscovery
    ) -> SetupPanelFacts {
        var facts = SetupPanelFacts(ghosttyConfig: inputs.ghosttyConfig)
        let home = inputs.home
        let chosen = chosenPaths(inputs)
        func looksExecutable(_ path: String) -> Bool {
            if SetupProbe.isProtected(path, home: home.path), !chosen.contains((path as NSString).standardizingPath) { return false }
            return isExecutable(path)
        }
        // Only those still off: one turned back on is a panel like any other.
        let on: [SidebarPanel: Bool] = [.docker: inputs.docker, .kubernetes: inputs.kubernetes, .terraform: inputs.terraform]
        facts.hiddenAtInstall = inputs.hiddenAtInstall.filter { panel in on[panel] == false }
        if inputs.docker {
            let endpoint = dockerEndpoint()
            var socket: String?
            if case .unix(let path) = endpoint.address { socket = path }
            var plugins: [String: Bool] = [:]
            for plugin in SetupCheck.dockerPlugins {
                plugins[plugin] = DockerCLI.hasPlugin(plugin, home: home, isExecutable: looksExecutable)
            }
            facts.docker = SetupPanelFacts.Docker(
                cli: DockerCLI.locate("docker", home: home, path: inputs.appPath, isExecutable: looksExecutable), runtime: DockerRuntime.of(endpoint).name,
                source: endpoint.source, socket: endpoint.remoteHost == nil ? socket : nil, socketExists: socket.map(exists) ?? false,
                remoteHost: endpoint.remoteHost, plugins: plugins)
        }
        if inputs.kubernetes {
            let loginPath = login?["PATH"]
            let kubectl = KubectlLocator.candidates(
                configured: inputs.kubectlPath, guarded: inputs.guardsKubeconfig, loginPath: loginPath, home: home, isExecutable: looksExecutable
            ).first
            let helm = KubeHelmLocator.candidates(
                configured: inputs.helmPath, guarded: inputs.guardsKubeconfig, loginPath: loginPath, home: home, isExecutable: looksExecutable
            ).first
            var kube = SetupPanelFacts.Kubernetes(kubectl: kubectl, helm: helm)
            if let contexts = inputs.contexts {
                kube.contexts = contexts.count
                kube.production = contexts.count { context in context.isProduction }
                // Each plugin as the proxy would look for it, by name; never run.
                var missing: [String] = []
                for context in contexts {
                    guard case .exec(let exec)? = context.auth, !missing.contains(exec.name),
                        !KubeProxyPlanner.isInstalled(exec, in: login ?? [:], isExecutable: looksExecutable)
                    else { continue }
                    missing.append(exec.name)
                }
                kube.missingPlugins = login == nil ? nil : missing
            } else {
                kube.kubeconfigFiles = kubeconfigs().count { url in exists(url.path) }
            }
            facts.kubernetes = kube
        }
        if inputs.terraform {
            // `terraform.path` as `binary(forRoot:)` takes it, without
            // that function's `mise which`.
            let setting = (inputs.terraformPath as NSString).expandingTildeInPath
            if setting.hasPrefix("/"), looksExecutable(setting) {
                facts.terraform = SetupPanelFacts.Terraform(binary: URL(fileURLWithPath: setting), fromSetting: true)
            } else {
                facts.terraform = SetupPanelFacts.Terraform(binary: terraformBinary(looksExecutable), fromSetting: false)
            }
        }
        if inputs.kubernetes || inputs.database {
            // gcloud where BigQuery's sign-in looks; its GKE plugin where a context's proxy looks.
            facts.gcloud = SetupPanelFacts.GCloud(
                cli: BigQueryDriver.gcloudCandidates(home: home).first(where: looksExecutable).map(URL.init(fileURLWithPath:)),
                gkePlugin: inputs.kubernetes ? login.flatMap { login in ShellEnvironment.executable("gke-gcloud-auth-plugin", in: login, isExecutable: looksExecutable) } : nil,
                gkePluginLooked: inputs.kubernetes && login != nil, database: inputs.database, kubernetes: inputs.kubernetes)
        }
        if inputs.api {
            // As gRPC looks: the login shell's environment, else the one Overterm was started with.
            facts.protoc = .some(GRPCProtoc.locate(environment: login ?? ["PATH": inputs.appPath ?? ""], isExecutable: looksExecutable))
        }
        if inputs.languageServers {
            facts.languageServers = LanguageServers.specs.map { spec in
                SetupPanelFacts.LanguageServer(id: spec.id, found: discovery.command(for: spec)?.executable)
            }
        }
        if inputs.simulator {
            facts.simulator = SetupPanelFacts.Simulator(xcode: exists(xcodePath), coreSimulator: exists(coreSimulatorPath))
        }
        return facts
    }

    /// The facts now, for the panels that are on: the settings and the
    /// Kubernetes page's contexts read here, the rest off the main thread
    /// (the login shell, the files). Nil in an isolated run, which looks at
    /// none of the user's tools (a scenario sets `SetupProbe.panelsOverride`).
    @MainActor package static func read() async -> SetupPanelFacts? {
        guard !AppEnvironment.isIsolated else { return nil }
        let settings = Settings.shared
        let kubernetes = KubernetesModel.shared
        let inputs = Inputs(
            home: FileManager.default.homeDirectoryForCurrentUser, appPath: ProcessInfo.processInfo.environment["PATH"], docker: settings.dockerEnabled,
            kubernetes: settings.kubernetesEnabled, terraform: settings.terraformEnabled, simulator: settings.simulatorEnabled,
            languageServers: settings.editorLanguageServers, database: settings.databaseEnabled, api: settings.apiEnabled, kubectlPath: settings.kubernetesKubectlPath,
            helmPath: settings.kubernetesHelmPath,
            terraformPath: settings.terraformPath, guardsKubeconfig: AppEnvironment.guardsKubeconfig,
            contexts: kubernetes.contextsRead ? kubernetes.contexts.contexts : nil, ghosttyConfig: AppEnvironment.ghosttyConfigFile != nil,
            hiddenAtInstall: FreshInstall.hidden(stored: AppEnvironment.defaults.stringArray(forKey: FreshInstall.panelsHiddenKey)))
        let extra = settings.kubernetesKubeconfigs
        return await withCheckedContinuation { (continuation: CheckedContinuation<SetupPanelFacts?, Never>) in
            // Spelled `@Sendable`: a block for a queue written here would
            // otherwise be typed main-actor and trap off it.
            let work: @Sendable () -> Void = {
                let files = FileManager.default
                let facts = Self.facts(
                    inputs, login: ShellEnvironment.login(), exists: { path in files.fileExists(atPath: path) },
                    isExecutable: { path in files.isExecutableFile(atPath: path) }, dockerEndpoint: { DockerEndpoint.current() },
                    kubeconfigs: { AppEnvironment.kubeconfigs(extra: extra) },
                    terraformBinary: { looksExecutable in TerraformCLI.binary(isExecutable: looksExecutable) },
                    discovery: ServerDiscovery(home: inputs.home, runsXcrun: false))
                continuation.resume(returning: facts)
            }
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    }
}
