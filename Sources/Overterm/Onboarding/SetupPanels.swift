import Foundation

/// What the panels that are on lean on (7.7, "Tools the panels use"), as
/// each feature's own finder found it — read only when the section is
/// opened, only for the panels that are on. A panel that is off is nil.
package struct SetupPanelFacts: Equatable, Sendable {
    package struct Docker: Equatable, Sendable {
        /// `docker`, where `DockerCLI.locate` finds it.
        package var cli: URL?
        /// The engine the CLI would reach: its runtime's name, and why that one.
        package var runtime: String
        package var source: String
        /// Its unix socket, when it has one on this Mac.
        package var socket: String?
        package var socketExists: Bool
        /// A remote engine's host: not reached from here.
        package var remoteHost: String?
        /// `docker compose`, `buildx`, `scout`: whether each plugin is there.
        package var plugins: [String: Bool]

        package init(
            cli: URL?, runtime: String, source: String, socket: String?, socketExists: Bool, remoteHost: String? = nil, plugins: [String: Bool] = [:]
        ) {
            self.cli = cli
            self.runtime = runtime
            self.source = source
            self.socket = socket
            self.socketExists = socketExists
            self.remoteHost = remoteHost
            self.plugins = plugins
        }
    }

    package struct Kubernetes: Equatable, Sendable {
        /// The first of `KubectlLocator.candidates`.
        package var kubectl: URL?
        /// The contexts as the Kubernetes page read them this launch; nil
        /// when it hasn't — then only the files' existence is known.
        package var contexts: Int?
        package var production: Int
        /// The kubeconfig files that exist, of those kubectl would read.
        package var kubeconfigFiles: Int
        /// Credential plugins the read contexts name that aren't on the
        /// login shell's PATH, by name — never run. nil: no context read.
        package var missingPlugins: [String]?
        /// The first of `KubeHelmLocator.candidates`.
        package var helm: URL?

        package init(
            kubectl: URL?, contexts: Int? = nil, production: Int = 0, kubeconfigFiles: Int = 0, missingPlugins: [String]? = nil, helm: URL? = nil
        ) {
            self.kubectl = kubectl
            self.contexts = contexts
            self.production = production
            self.kubeconfigFiles = kubeconfigFiles
            self.missingPlugins = missingPlugins
            self.helm = helm
        }
    }

    package struct Terraform: Equatable, Sendable {
        /// `terraform.path` when it names an executable, else `TerraformCLI.binary()`.
        package var binary: URL?
        /// The binary is `terraform.path`'s.
        package var fromSetting: Bool

        package init(binary: URL?, fromSetting: Bool) {
            self.binary = binary
            self.fromSetting = fromSetting
        }
    }

    /// One language server spec, and where `ServerDiscovery` found it.
    package struct LanguageServer: Equatable, Sendable {
        package var id: String
        package var found: URL?

        package init(id: String, found: URL?) {
            self.id = id
            self.found = found
        }
    }

    /// gcloud, for the Database's BigQuery and Cloud Storage sign-in and
    /// a GKE context's credential plugin.
    package struct GCloud: Equatable, Sendable {
        /// `gcloud`, where the BigQuery sign-in finds it (`BigQueryDriver.gcloudCandidates`).
        package var cli: URL?
        /// `gke-gcloud-auth-plugin` on the login shell's PATH, as a GKE
        /// context's proxy looks for it (`KubeProxyPlanner.isInstalled`).
        package var gkePlugin: URL?
        /// The plugin was looked for: Kubernetes on, and the shell answered.
        package var gkePluginLooked: Bool
        /// Which panels that are on lean on it.
        package var database: Bool
        package var kubernetes: Bool

        package init(cli: URL?, gkePlugin: URL? = nil, gkePluginLooked: Bool = false, database: Bool, kubernetes: Bool) {
            self.cli = cli
            self.gkePlugin = gkePlugin
            self.gkePluginLooked = gkePluginLooked
            self.database = database
            self.kubernetes = kubernetes
        }
    }

    package struct Simulator: Equatable, Sendable {
        package var xcode: Bool
        package var coreSimulator: Bool

        package init(xcode: Bool, coreSimulator: Bool) {
            self.xcode = xcode
            self.coreSimulator = coreSimulator
        }
    }

    package var docker: Docker?
    package var kubernetes: Kubernetes?
    package var terraform: Terraform?
    package var languageServers: [LanguageServer]?
    package var simulator: Simulator?
    /// Shown while Kubernetes or Database is on.
    package var gcloud: GCloud?
    /// `protoc`, where the API client's gRPC finds it (`GRPCProtoc.locate`);
    /// the outer nil: the API client is off, so it isn't looked for.
    package var protoc: URL??
    /// `~/.config/ghostty/config` exists (`AppEnvironment.ghosttyConfigFile`).
    package var ghosttyConfig: Bool
    /// The panels a fresh install hid, their tool not found, that are still
    /// off (`FreshInstall`): said here as the Start card says them.
    package var hiddenAtInstall: [SidebarPanel]

    package init(
        docker: Docker? = nil, kubernetes: Kubernetes? = nil, terraform: Terraform? = nil, languageServers: [LanguageServer]? = nil,
        simulator: Simulator? = nil, gcloud: GCloud? = nil, protoc: URL?? = nil, ghosttyConfig: Bool = false, hiddenAtInstall: [SidebarPanel] = []
    ) {
        self.docker = docker
        self.kubernetes = kubernetes
        self.terraform = terraform
        self.languageServers = languageServers
        self.simulator = simulator
        self.gcloud = gcloud
        self.protoc = protoc
        self.ghosttyConfig = ghosttyConfig
        self.hiddenAtInstall = hiddenAtInstall
    }
}

extension SetupCheck {
    package static let panelsTitle = "Tools the panels use"
    package static let panelsNote =
        "Docker's config and the kubeconfigs are read by their features' own readers; no credential in them is kept or shown. No proxy, ping or plugin is started."
    package static let isolatedPanels = "Not looked at in an isolated run."

    /// The commands the panels' rows offer, by row (with `installCommands`).
    package static let panelInstallCommands: [String: String] = [
        SetupRow.ID.kubectl.key: "brew install kubectl",
        SetupRow.ID.helm.key: "brew install helm",
        SetupRow.ID.terraform.key: "brew install hashicorp/tap/terraform",
        SetupRow.ID.protoc.key: "brew install protobuf",
    ]

    /// gcloud's install page: its installer is Google's, and a command for it would go stale (risk 13).
    package static let gcloudInstallPage = URL(string: "https://cloud.google.com/sdk/docs/install")

    /// A panel a fresh install hid, as the Start card says it.
    package static let hiddenAtInstallDetail = "hidden — not found on this Mac"

    /// The panels' rows, for the panels that are on; each in its feature's own words.
    package static func panelRows(_ facts: SetupPanelFacts, home: String = NSHomeDirectory()) -> [SetupRow] {
        var rows: [SetupRow] = facts.hiddenAtInstall.map(hiddenRow)
        if let docker = facts.docker { rows += dockerRows(docker, home: home) }
        if let kubernetes = facts.kubernetes { rows += kubernetesRows(kubernetes, home: home) }
        if let terraform = facts.terraform { rows += terraformRows(terraform, home: home) }
        if let gcloud = facts.gcloud { rows.append(gcloudRow(gcloud, home: home)) }
        if let protoc = facts.protoc { rows.append(protocRow(protoc, home: home)) }
        if let servers = facts.languageServers { rows.append(languageServersRow(servers, home: home)) }
        if let simulator = facts.simulator { rows.append(simulatorRow(simulator)) }
        rows.append(
            SetupRow(
                id: .ghosttyConfig, title: "Ghostty config",
                detail: facts.ghosttyConfig ? "~/.config/ghostty/config found: it applies as it is" : "none · Ghostty's defaults", found: facts.ghosttyConfig,
                looked: "Only whether the file is there; it isn't read here."))
        return rows
    }

    /// The plugins the Docker page uses, in the order they show.
    package static let dockerPlugins = ["compose", "buildx", "scout"]

    private static func dockerRows(_ docker: SetupPanelFacts.Docker, home: String) -> [SetupRow] {
        var rows: [SetupRow] = []
        rows.append(
            docker.cli.map { cli in
                SetupRow(
                    id: .docker, title: "docker", detail: tilde(cli.path, home: home), found: true,
                    looked: "Overterm's PATH and seven install folders. Never run here.")
            }
                ?? SetupRow(
                    id: .docker, title: "docker", detail: "docker isn't on this Mac, so Compose can't read the compose file.", found: false, isProblem: true,
                    looked: "Overterm's PATH and seven install folders."))
        let engineLooked = "The engine the CLI would reach (\(docker.source)): only whether its socket is there — never pinged, which would wake its VM."
        if let remote = docker.remoteHost {
            rows.append(
                SetupRow(id: .dockerEngine, title: "Docker engine", detail: "on \(remote) · not reached from here", found: true, looked: engineLooked))
        } else if let socket = docker.socket {
            rows.append(
                docker.socketExists
                    ? SetupRow(
                        id: .dockerEngine, title: "Docker engine", detail: "\(docker.runtime) · socket at \(tilde(socket, home: home))", found: true,
                        looked: engineLooked)
                    : SetupRow(
                        id: .dockerEngine, title: "Docker engine", detail: "\(docker.runtime) isn't running — no socket at \(tilde(socket, home: home)).",
                        found: false, isProblem: true, looked: engineLooked))
        } else {
            rows.append(SetupRow(id: .dockerEngine, title: "Docker engine", detail: "\(docker.runtime) · not reached from here", found: true, looked: engineLooked))
        }
        let needs = ["compose": "Compose's verbs need it", "buildx": "builds are read with it", "scout": "image scans need it"]
        for plugin in dockerPlugins {
            let found = docker.plugins[plugin] ?? false
            rows.append(
                SetupRow(
                    id: .dockerPlugin(plugin), title: "docker \(plugin)", detail: found ? "found" : "not found · \(needs[plugin] ?? "optional")", found: found,
                    looked: "Docker's plugin folders."))
        }
        return rows
    }

    private static func kubernetesRows(_ kube: SetupPanelFacts.Kubernetes, home: String) -> [SetupRow] {
        var rows: [SetupRow] = []
        let kubectlLooked = "Settings ▸ Kubernetes ▸ kubectl, four install folders, then your login shell's PATH. Never run here."
        rows.append(
            kube.kubectl.map { kubectl in SetupRow(id: .kubectl, title: "kubectl", detail: tilde(kubectl.path, home: home), found: true, looked: kubectlLooked) }
                ?? SetupRow(
                    id: .kubectl, title: "kubectl", detail: "No kubectl found. Install it, or set Settings ▸ Kubernetes ▸ kubectl.", found: false,
                    isProblem: true, looked: kubectlLooked, action: panelInstallCommands[SetupRow.ID.kubectl.key].map(SetupRow.Action.command)))
        if let contexts = kube.contexts {
            let words = (contexts == 1 ? "1 context" : "\(contexts) contexts") + (kube.production > 0 ? ", \(kube.production) production" : "")
            rows.append(
                SetupRow(
                    id: .kubeconfig, title: "Kubernetes", detail: words, found: contexts > 0,
                    looked: "As the Kubernetes page read them this launch — names only, credentials blanked before reading. No proxy started."))
        } else {
            let files = kube.kubeconfigFiles
            rows.append(
                SetupRow(
                    id: .kubeconfig, title: "Kubernetes",
                    detail: files == 0 ? "No kubeconfig" : (files == 1 ? "1 kubeconfig file found" : "\(files) kubeconfig files found"), found: files > 0,
                    looked: "Only whether the files are there: the Kubernetes page reads them when it shows. No proxy started."))
        }
        if let missing = kube.missingPlugins {
            rows.append(
                SetupRow(
                    id: .kubePlugins, title: "Credential plugins",
                    detail: missing.isEmpty ? "found for every context" : missing.map { name in "\(name) isn't installed." }.joined(separator: " "),
                    found: missing.isEmpty, isProblem: !missing.isEmpty, looked: "On your login shell's PATH, for each context. Never run."))
        } else {
            // Never silent: the contexts are the Kubernetes page's to read, and
            // only its reading this launch names their plugins.
            rows.append(
                SetupRow(
                    id: .kubePlugins, title: "Credential plugins",
                    detail: kube.contexts == nil ? kubePluginsUnread : "not looked for — your login shell didn't say its PATH", found: false,
                    looked: "Only the contexts the Kubernetes page read this launch; the kubeconfigs aren't read here for them. Never run."))
        }
        rows.append(
            kube.helm.map { helm in
                SetupRow(id: .helm, title: "helm", detail: tilde(helm.path, home: home), found: true, looked: "Settings ▸ Kubernetes ▸ helm, two install folders, then your login shell's PATH.")
            }
                ?? SetupRow(
                    id: .helm, title: "helm", detail: "helm isn't installed (or set kubernetes.helmPath in Settings ▸ Kubernetes).", found: false,
                    looked: "Settings ▸ Kubernetes ▸ helm, two install folders, then your login shell's PATH.",
                    action: panelInstallCommands[SetupRow.ID.helm.key].map(SetupRow.Action.command)))
        return rows
    }

    private static func terraformRows(_ terraform: SetupPanelFacts.Terraform, home: String) -> [SetupRow] {
        let looked = "Settings ▸ Terraform ▸ terraform, else your login shell's PATH, then Homebrew's folders. Neither mise nor terraform is run here."
        var rows: [SetupRow] = []
        if let binary = terraform.binary {
            let how = terraform.fromSetting ? "Settings ▸ Terraform ▸ terraform" : "a root with a version file may use mise's; not asked here"
            rows.append(SetupRow(id: .terraform, title: "terraform", detail: "\(tilde(binary.path, home: home)) · \(how)", found: true, looked: looked))
        } else {
            rows.append(
                SetupRow(
                    id: .terraform, title: "terraform", detail: "No terraform found: set Settings ▸ Terraform ▸ terraform, or install it.", found: false,
                    isProblem: true, looked: looked, action: panelInstallCommands[SetupRow.ID.terraform.key].map(SetupRow.Action.command)))
        }
        rows.append(
            SetupRow(
                id: .tofu, title: "OpenTofu", detail: "not looked for · set Settings ▸ Terraform ▸ terraform to tofu; untried until then", found: false,
                looked: "Nowhere: Overterm runs terraform, or what that setting names.", action: .settings(.terraform, key: "terraform.path")))
        return rows
    }

    /// The credential plugins' row before the Kubernetes page has read the contexts.
    package static let kubePluginsUnread = "Open Kubernetes once to check its contexts' plugins"

    private static func hiddenRow(_ panel: SidebarPanel) -> SetupRow {
        let section = panel.settingsSection
        return SetupRow(
            id: .panelHidden(panel), title: panel.title, detail: hiddenAtInstallDetail, found: false,
            looked: "Once, at the first launch: your login shell's PATH and the tool's install folders, as the panel looks. Nothing was run."
                + (section.map { section in " On again in Settings ▸ \(section.title)." } ?? ""),
            action: section.map { section in .settings(section, key: panel.toggleKey) })
    }

    private static func gcloudRow(_ gcloud: SetupPanelFacts.GCloud, home: String) -> SetupRow {
        var parts = [gcloud.cli.map { cli in tilde(cli.path, home: home) } ?? "not found"]
        if gcloud.database {
            parts.append(gcloud.cli == nil ? "BigQuery's and Cloud Storage's gcloud sign-in needs it" : "BigQuery and Cloud Storage can sign in with it")
        }
        if gcloud.kubernetes {
            if let plugin = gcloud.gkePlugin {
                parts.append("gke-gcloud-auth-plugin at \(tilde(plugin.path, home: home))")
            } else if gcloud.gkePluginLooked {
                parts.append("gke-gcloud-auth-plugin not on your PATH — a GKE context needs it")
            } else {
                parts.append("gke-gcloud-auth-plugin not looked for — your login shell didn't say its PATH")
            }
        }
        let found = gcloud.cli != nil || gcloud.gkePlugin != nil
        return SetupRow(
            id: .gcloud, title: "gcloud", detail: parts.joined(separator: " · "), found: found,
            looked:
                "gcloud: Homebrew's folders and ~/google-cloud-sdk, as the Database's BigQuery sign-in looks; gke-gcloud-auth-plugin: your login shell's PATH, as a GKE context's proxy looks. Never run.",
            action: found ? nil : gcloudInstallPage.map(SetupRow.Action.page))
    }

    private static func protocRow(_ protoc: URL?, home: String) -> SetupRow {
        let looked = "Your login shell's PATH, then Homebrew's two folders, as the API client's gRPC looks. Never run."
        guard let protoc else {
            return SetupRow(
                id: .protoc, title: "protoc", detail: "not found · a gRPC request from .proto files needs it; a server with reflection doesn't",
                found: false, looked: looked, action: panelInstallCommands[SetupRow.ID.protoc.key].map(SetupRow.Action.command))
        }
        return SetupRow(id: .protoc, title: "protoc", detail: "\(tilde(protoc.path, home: home)) · gRPC from .proto files", found: true, looked: looked)
    }

    private static func languageServersRow(_ servers: [SetupPanelFacts.LanguageServer], home: String) -> SetupRow {
        let found = servers.count { $0.found != nil }
        let more = servers.map { server in "\(server.id) — " + (server.found.map { url in tilde(url.path, home: home) } ?? "not found") }
        return SetupRow(
            id: .languageServers, title: "Language servers", detail: "\(found) of \(servers.count) found", found: found > 0,
            looked:
                "Six fixed folders, Xcode's and the Command Line Tools' toolchains and Zed's downloads — never your shell's PATH; not looked for with xcrun.",
            more: more)
    }

    private static func simulatorRow(_ simulator: SetupPanelFacts.Simulator) -> SetupRow {
        let found = simulator.xcode && simulator.coreSimulator
        return SetupRow(
            id: .simulator, title: "Simulator", detail: found ? "Xcode and CoreSimulator found" : "No simulators on this Mac. They come with Xcode.", found: found,
            looked: "Only whether /Applications/Xcode.app and CoreSimulator.framework are there; neither is loaded, simctl isn't run.")
    }
}
