import SwiftUI

/// A container's Settings… (`,`): its memory limit, CPUs and restart policy
/// as inspect says them, edited and applied through the engine at once,
/// running or stopped — the `docker update` written out as it is typed.
/// What the engine would refuse is said here first
/// (`DockerContainerSettings.problem`); what it says when it refuses
/// anyway stays in the sheet too.
struct DockerSettingsSheet: View {
    @State var settings: DockerContainerSettings
    @ObservedObject var page: DockerPageModel
    @ObservedObject var docker: DockerModel
    let actions: DockerActions
    /// What the engine said to Apply.
    @State private var failed: String?
    @State private var applying = false

    private var line: String { settings.line(prefix: DockerCommands.prefix(for: docker.endpoint)) }

    /// `512m, 2g — it uses 48 MB now; the engine has 8 GB`.
    private var memoryCaption: String {
        "512m, 2g" + (settings.inUse.map { " — it uses \(DockerBytes.string($0, memory: true)) now" } ?? "")
            + (settings.engineMemory.map { "; the engine has \(DockerBytes.string($0, memory: true))" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Settings of “\(settings.name)”").font(.system(size: 17, weight: .semibold))
            if let project = settings.project {
                Text(
                    verbatim: "\(project)'s compose file says how \(settings.service ?? "it") is made: the next up that makes it again puts back "
                        + "what the file says. For settings that last, write them there — mem_limit, cpus, restart."
                )
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("docker.settings.compose")
            }
            Form {
                TextField("Memory", text: $settings.memory, prompt: Text(verbatim: settings.current.memory == 0 ? "no limit" : ""))
                Text(verbatim: memoryCaption).font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("CPUs", text: $settings.cpus, prompt: Text(verbatim: settings.engineCPUs.map { "all \($0)" } ?? "all"))
                Picker("Restart", selection: $settings.restart) {
                    Text("No").tag("no")
                    Text("Always").tag("always")
                    Text("Unless stopped").tag("unless-stopped")
                    Text("On failure").tag("on-failure")
                }
                .disabled(settings.current.autoRemove)
                .help(settings.current.autoRemove ? "Run with --rm: Docker gives it no restart policy" : "")
                if settings.restart == "on-failure" {
                    Stepper(value: $settings.retries, in: 0...100) {
                        Text(verbatim: settings.retries == 0 ? "Tries again with no limit" : "Tries again \(settings.retries) times at most")
                    }
                }
            }
            if let problem = failed ?? settings.problem {
                Text(verbatim: problem).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.failed).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("docker.settings.problem")
            } else if let caution = settings.caution {
                Text(verbatim: caution).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.waiting).fixedSize(horizontal: false, vertical: true)
            }
            // `docker update` with no flag is refused: nothing to copy yet.
            Text(verbatim: settings.changed ? line : "The docker update it makes shows here as you change it.")
                .font(.system(size: 11, design: settings.changed ? .monospaced : .default)).textSelection(.enabled).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("docker.settings.command")
            HStack {
                Button("Copy") { actions.copy(line) }.disabled(!settings.changed)
                Spacer()
                Button("Cancel") { page.containerSettings = nil }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    applying = true
                    Task {
                        failed = await page.applySettings(settings)
                        applying = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(settings.update == nil || applying)
            }
        }
        .padding(20)
        .frame(width: 480)
        .accessibilityIdentifier("docker.settings")
        // Edited again: what the engine said was about the last try.
        .onChange(of: settings) { _ in failed = nil }
    }
}
