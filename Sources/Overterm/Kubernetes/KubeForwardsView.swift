import SwiftUI

/// The page's Forwards section (`9`): every forward of the app, whichever
/// context — where it listens, what it goes to, the pod it is pinned to,
/// how it stands — with Open, Edit and Stop; one that stopped by itself
/// says why, with Start Again and Remove.
struct KubeForwardsSection: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var forwards: KubeForwards
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if forwards.forwards.isEmpty {
                Text(
                    verbatim:
                        "No forwards. \(KubernetesKey.portForward.key) on a pod, a Service or a Deployment forwards one of its ports — "
                        + "a Service's or a Deployment's to a ready pod of theirs, started again on the next one when it goes."
                )
                .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3).frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 34)
                .accessibilityIdentifier("kubernetes.forwards.empty")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(forwards.forwards) { forward in row(forward) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .accessibilityIdentifier("kubernetes.forwards")
    }

    private func color(_ forward: KubeForward) -> Color {
        switch forward.state {
        case .forwarding: TabStatusStyle.done
        case .stopped: TabStatusStyle.failed
        default: TabStatusStyle.waiting
        }
    }

    private func row(_ forward: KubeForward) -> some View {
        let spec = forward.spec
        let picked = page.forwardSelection == forward.id
        return HStack(spacing: 10) {
            DockerStatusDot(color: color(forward))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: spec.hostPort).font(.system(size: ChromeMetrics.text(12.5), weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.text)
                    Text(verbatim: "→ \(spec.target):\(spec.remotePort)").font(.system(size: ChromeMetrics.text(12), design: .monospaced)).foregroundStyle(theme.text2)
                    if let pod = forward.pod {
                        Text(verbatim: "pod \(pod)" + (forward.podPort.map { ":\($0)" } ?? "")).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                            .foregroundStyle(theme.text3)
                    }
                }
                Text(verbatim: details(forward)).font(.system(size: ChromeMetrics.text(11))).lineLimit(2).truncationMode(.tail)
                    .foregroundStyle(forward.state.isStopped ? TabStatusStyle.failed : forward.production ? KubernetesPageView.production : theme.text3)
                    .textSelection(.enabled)
                if let api = forwards.openAPI[forward.id] {
                    Label {
                        Text(verbatim: "Serves an OpenAPI document: \(api.title)").lineLimit(1).truncationMode(.tail)
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text2)
                    .accessibilityIdentifier("kubernetes.forward.api.\(spec.localPort)")
                }
            }
            Spacer(minLength: 8)
            if forward.state.isStopped {
                button("Start Again") { page.forwards.startAgain(forward.id) }
                button("Remove") { page.stopForward(forward.id) }
            } else {
                button("Open") { page.openForward(forward.id) }.disabled(!forward.isForwarding)
                if forwards.openAPI[forward.id] != nil {
                    button("Import API") { page.importForwardAPI(forward.id) }
                        .help("Its OpenAPI document as a Bruno collection in the checkout, in the API client")
                }
                button("Edit…") { page.editForward(forward.id) }
                button("Stop") { page.stopForward(forward.id) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(picked ? theme.selected : .clear))
        .contentShape(Rectangle())
        .onTapGesture { page.forwardSelection = forward.id }
        .help(forward.kubectl ?? spec.summary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kubernetes.forward.\(spec.localPort)")
    }

    private func details(_ forward: KubeForward) -> String {
        var parts = [forward.spec.context, forward.spec.namespace]
        if forward.spec.address != KubeForwardAddress.loopback { parts.append("on \(forward.spec.address)") }
        if forward.spec.https { parts.append("https") }
        parts.append(forward.state.text)
        if forward.restarts > 0 { parts.append(forward.restarts == 1 ? "started again once" : "started again \(forward.restarts) times") }
        return parts.joined(separator: " · ")
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).controlSize(.small)
    }
}

/// How many forwards run, beside the section's name.
struct KubeForwardsCount: View {
    @ObservedObject var forwards: KubeForwards
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        let live = forwards.forwards.filter { !$0.state.isStopped }.count
        if live > 0 {
            Text(verbatim: "\(live)").foregroundStyle(theme.text3).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
        }
    }
}

/// `f`'s sheet over the page: the target's ports (or one typed), the local
/// port — the same where it is free, else one at random — the address
/// (127.0.0.1 unless changed) and https. Forward stays greyed until
/// `kubectl auth can-i create pods/portforward` says yes.
struct KubeForwardSheetView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if let draft = page.forwardDraft {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).onTapGesture { page.closeForwardSheet() }
                card(draft)
            }
        }
    }

    private func binding(_ path: WritableKeyPath<KubeForwardDraft, String>) -> Binding<String> {
        Binding(get: { page.forwardDraft?[keyPath: path] ?? "" }, set: { page.forwardDraft?[keyPath: path] = $0 })
    }

    private func card(_ draft: KubeForwardDraft) -> some View {
        let production = page.model.contexts.context(named: draft.context)?.isProduction == true
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: draft.editing == nil ? "Port-forward \(draft.target)" : "Edit the forward to \(draft.target)")
                .font(.system(size: ChromeMetrics.text(14), weight: .semibold)).foregroundStyle(theme.text)
            Text(verbatim: (production ? "PRODUCTION · " : "") + "\(draft.context) · \(draft.namespace)")
                .font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(production ? KubernetesPageView.production : theme.text2)
            field("Remote port") {
                if draft.editing != nil {
                    Text(verbatim: draft.remote).font(.system(size: ChromeMetrics.text(12), design: .monospaced)).foregroundStyle(theme.text2)
                } else {
                    TextField("port", text: binding(\.remote)).textFieldStyle(.roundedBorder).frame(width: 90)
                        .accessibilityIdentifier("kubernetes.forward.remote")
                    if !draft.offered.isEmpty {
                        Menu {
                            ForEach(draft.offered, id: \.self) { option in
                                Button(option.label) { page.forwardDraft?.remote = "\(option.port)" }
                            }
                        } label: {
                            Text(verbatim: draft.offered.first { "\($0.port)" == draft.remote }?.label ?? "Ports…").font(.system(size: ChromeMetrics.text(11.5)))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            field("Local port") {
                TextField("port", text: binding(\.local)).textFieldStyle(.roundedBorder).frame(width: 90)
                    .accessibilityIdentifier("kubernetes.forward.local")
                Button("Random") { page.randomLocalPort() }.controlSize(.small)
            }
            field("Address") {
                TextField(KubeForwardAddress.loopback, text: binding(\.address)).textFieldStyle(.roundedBorder).frame(width: 160)
                    .accessibilityIdentifier("kubernetes.forward.address")
                if !KubeForwardAddress.isLoopback(draft.address.trimmingCharacters(in: .whitespaces)) {
                    Text("reachable from other machines").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(TabStatusStyle.waiting)
                }
            }
            field("") {
                Toggle(
                    "HTTPS — open it as https://", isOn: Binding(get: { page.forwardDraft?.https ?? false }, set: { page.forwardDraft?.https = $0 })
                )
                .toggleStyle(.checkbox).font(.system(size: ChromeMetrics.text(12)))
            }
            Text(verbatim: note(draft)).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            if let why = draft.unavailable {
                Text(verbatim: why).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(why.hasPrefix("Checking") ? theme.text2 : TabStatusStyle.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kubernetes.forward.unavailable")
            }
            if let problem = page.forwardProblem {
                Text(verbatim: problem).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(TabStatusStyle.failed).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kubernetes.forward.problem")
            }
            HStack {
                Spacer()
                Button("Cancel") { page.closeForwardSheet() }.keyboardShortcut(.cancelAction)
                Button(draft.editing == nil ? "Forward" : "Save") { page.confirmForward() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.unavailable != nil)
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(production ? KubernetesPageView.production : theme.menuEdge))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .accessibilityIdentifier("kubernetes.forwardSheet")
    }

    private func note(_ draft: KubeForwardDraft) -> String {
        switch draft.target {
        case .pod: "kubectl port-forward to this pod, with your own kubectl and credentials. It stops when the pod goes."
        case .service:
            "Overterm picks a ready endpoint's pod and forwards to it; when kubectl exits or the pod goes, it picks again and starts a new one."
        case .deployment: "Overterm picks a ready pod of the Deployment; when kubectl exits or the pod goes, it picks again and starts a new one."
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).frame(width: 84, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }
}
