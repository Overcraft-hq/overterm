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
    /// `~/.config/ghostty/config` exists (`AppEnvironment.ghosttyConfigFile`).
    package var ghosttyConfig: Bool

    package init(
        docker: Docker? = nil, kubernetes: Kubernetes? = nil, terraform: Terraform? = nil, languageServers: [LanguageServer]? = nil,
        simulator: Simulator? = nil, ghosttyConfig: Bool = false
    ) {
        self.docker = docker
        self.kubernetes = kubernetes
        self.terraform = terraform
        self.languageServers = languageServers
        self.simulator = simulator
        self.ghosttyConfig = ghosttyConfig
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
    ]

    /// The panels' rows, for the panels that are on; each in its feature's own words.
    package static func panelRows(_ facts: SetupPanelFacts, home: String = NSHomeDirectory()) -> [SetupRow] {
        var rows: [SetupRow] = []
        if let docker = facts.docker { rows += dockerRows(docker, home: home) }
        if let kubernetes = facts.kubernetes { rows += kubernetesRows(kubernetes, home: home) }
        if let terraform = facts.terraform { rows += terraformRows(terraform, home: home) }
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
