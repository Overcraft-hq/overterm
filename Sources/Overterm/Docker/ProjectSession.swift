import Combine
import SwiftUI

/// A compose project a detail shows: its services' logs merged by time,
/// each line with its service — what `docker compose logs -f` prints, read
/// only while its Logs tab is on screen.
@MainActor
final class ProjectSession: ObservableObject {
    let name: String
    let feed = DockerLogFeed()

    private let docker: DockerModel
    private var followers: [String: DockerLogFollower] = [:]
    private var watching: AnyCancellable?
    private var wanted = false

    init(name: String, docker: DockerModel = .shared) {
        self.name = name
        self.docker = docker
        if let project = docker.projects.first(where: { $0.name == name }) {
            feed.terminalCommand = DockerCommands.compose(project, "logs -f --tail 100", endpoint: docker.endpoint)
        }
        // A service started (or scaled) is followed; one restarted again
        // from where it stopped.
        watching = docker.$projects
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sync() } }
    }

    func follow(shown: Bool) {
        wanted = shown
        sync()
    }

    private func sync() {
        // Selected before it ran: its command once it exists.
        if feed.terminalCommand == nil, let project = docker.projects.first(where: { $0.name == name }) {
            feed.terminalCommand = DockerCommands.compose(project, "logs -f --tail 100", endpoint: docker.endpoint)
        }
        guard wanted, let project = docker.projects.first(where: { $0.name == name }) else {
            followers.values.forEach { $0.stop() }
            updateFollowing()
            return
        }
        for container in project.containers where !container.isOneOff && container.state == .running {
            let follower = followers[container.Id] ?? make(container)
            if !follower.following { follower.start(tail: 200, tty: nil) }
        }
        updateFollowing()
    }

    private func make(_ container: ContainerSummary) -> DockerLogFollower {
        let follower = DockerLogFollower(id: container.Id, service: container.composeService ?? container.name, feed: feed, docker: docker, merging: true)
        follower.onChange = { [weak self] in self?.updateFollowing() }
        followers[container.Id] = follower
        return follower
    }

    private func updateFollowing() {
        let any = followers.values.contains { $0.following }
        if feed.following != any { feed.following = any }
    }

    func close() {
        wanted = false
        followers.values.forEach { $0.stop() }
        watching = nil
    }
}

/// A compose project, at the side of the list: its state, its verbs, its
/// services' merged logs and the services themselves — before it runs,
/// its services as its compose files say them.
struct ProjectDetailView: View {
    let project: ComposeProject
    @ObservedObject var session: ProjectSession
    @ObservedObject var page: DockerPageModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    /// What Compose said when it last couldn't read the files, for a
    /// project before it runs.
    var planError: String? = nil

    enum Tab: String, CaseIterable { case logs, services }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    DockerStatusDot(color: DockerStatusStyle.color(project, idle: theme.text3))
                    Text(verbatim: project.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                Text(verbatim: subtitle).font(.system(size: 11.5)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.head)
                DockerActionBar(verbs: page.verbs(for: project), theme: theme).padding(.top, 4)
                if project.planned, let planError {
                    Text(verbatim: planError).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.failed).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .help("What docker compose config said; the services are from the last time it could read the file")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if project.planned {
                Rectangle().fill(theme.border).frame(height: 1)
                plannedServices
            } else {
                tabs
            }
        }
        .accessibilityIdentifier("docker.project.detail")
    }

    private var subtitle: String {
        let folder = project.workingDir.map { ($0 as NSString).abbreviatingWithTildeInPath }
        let count = project.services.count
        let state =
            project.planned
            ? "not created: \(count) service\(count == 1 ? "" : "s")" : "\(project.running) of \(project.expected) running"
        return [folder, state].compactMap { $0 }.joined(separator: "  —  ")
    }

    /// Before it runs: its services as Compose will make them.
    private var plannedServices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(project.services) { service in
                    DockerPlannedServiceRow(service: service, theme: theme, folder: project.workingDir, indented: false)
                }
            }
            .padding(16)
        }
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        page.projectTab = tab
                    } label: {
                        Text(tab.rawValue.capitalized)
                            .font(.system(size: 12, weight: page.projectTab == tab ? .semibold : .regular))
                            .foregroundStyle(page.projectTab == tab ? theme.text : theme.text2)
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(page.projectTab == tab ? theme.selected : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Rectangle().fill(theme.border).frame(height: 1)
            switch page.projectTab {
            case .logs: DockerLogsPane(feed: session.feed, theme: theme, actions: actions)
            case .services: services
            }
        }
    }

    private var services: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(project.services) { service in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(verbatim: service.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.text)
                            if !service.dependsOn.isEmpty {
                                Text(verbatim: "after " + service.dependsOn.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(theme.text3)
                            }
                        }
                        ForEach(service.containers) { container in
                            Button {
                                page.selection = [container.Id]
                            } label: {
                                DockerContainerRow(container: container, inProject: true, busy: false, theme: theme, open: actions.open, remoteHost: page.docker.publishedHost)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text2)
        .help(help)
    }
}
