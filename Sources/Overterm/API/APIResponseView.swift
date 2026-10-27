import AppKit
import SwiftUI

/// The lower half of a request: what came back — status, time, size —
/// and the body, the headers, the timeline (what went out, where the time
/// went) and the tests.
struct APIResponseView: View {
    @ObservedObject var model: APIRequestModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.border).frame(height: 1)
            if let result = model.result {
                summary(result)
                APITabBar(
                    tabs: APIRequestModel.ResponseTab.allCases.map { tab in
                        (tab.id, tab.title, tab == .tests ? result.tests.count : tab == .headers ? result.response?.headers.count ?? 0 : 0)
                    },
                    selection: Binding(
                        get: { model.responseTab.id }, set: { model.responseTab = APIRequestModel.ResponseTab(rawValue: $0) ?? .body }),
                    theme: theme)
                content(result)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            if model.isSending {
                ProgressView().controlSize(.small)
                Text("Sending…").font(.system(size: 12)).foregroundStyle(theme.text3)
            } else {
                Text("⌘↩ sends the request").font(.system(size: 12)).foregroundStyle(theme.text3)
                // The environment ⌘↩ will use: this request's collection's pick.
                if let workspace = model.workspace, let collection = workspace.collection(containing: model.url),
                    let name = workspace.pickedEnvironment(for: collection)
                {
                    Text(verbatim: "Environment: \(name)").font(.system(size: 11)).foregroundStyle(theme.text3)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The line under the divider

    private func summary(_ result: APIExecution.Result) -> some View {
        HStack(spacing: 10) {
            if let response = result.response {
                Text(verbatim: "\(response.status) \(response.statusText)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .fixedSize()
                    .foregroundStyle(Self.statusColor(response.status))
                    .accessibilityIdentifier("apiStatus")
                Text(verbatim: APIResponse.formatDuration(response.duration)).font(.system(size: 11.5)).foregroundStyle(theme.text2)
                    .fixedSize()
                Text(verbatim: APIResponse.formatSize(response.size)).font(.system(size: 11.5)).foregroundStyle(theme.text2).fixedSize()
            } else if let error = result.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.96, green: 0.45, blue: 0.40))
                    .lineLimit(2)
                    .accessibilityIdentifier("apiError")
            }
            if !result.tests.isEmpty {
                Text(verbatim: "\(result.passed)/\(result.tests.count) passed")
                    .font(.system(size: 11.5, weight: .medium))
                    .fixedSize()
                    .foregroundStyle(result.failed == 0 ? Self.statusColor(200) : Self.statusColor(500))
                    .onTapGesture { model.responseTab = .tests }
                    .accessibilityIdentifier("apiTestsSummary")
            }
            if model.isSending { ProgressView().controlSize(.small).scaleEffect(0.7) }
            Spacer()
            if model.workspace?.askAgent != nil {
                Button {
                    model.askAgent()
                } label: {
                    Image(systemName: "sparkle").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.text2)
                .help("Ask an agent about this request and its response")
                .accessibilityIdentifier("apiAskAgent")
            }
            if let response = result.response {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.rawBody ? response.text : response.prettyText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.text2)
                .help("Copy the body")
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .frame(height: 32)
        // Leading, and cut on the right in a narrow pane: the status first.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    static func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: Color(red: 0.35, green: 0.78, blue: 0.45)
        case 300..<400: Color(red: 0.36, green: 0.62, blue: 0.98)
        case 400..<500: Color(red: 0.96, green: 0.70, blue: 0.25)
        default: Color(red: 0.96, green: 0.40, blue: 0.40)
        }
    }

    // MARK: Tabs

    @ViewBuilder private func content(_ result: APIExecution.Result) -> some View {
        switch model.responseTab {
        case .body:
            if let response = result.response {
                VStack(spacing: 0) {
                    APICodeView(
                        text: .constant(model.rawBody ? response.rawDisplay : response.display), language: response.isJSON ? "json" : language(response),
                        editable: false, wraps: model.rawBody, accessibilityIdentifier: "apiResponseBody")
                    HStack {
                        Toggle("Raw", isOn: $model.rawBody).toggleStyle(.checkbox).font(.system(size: 11))
                        Spacer()
                        Text(verbatim: response.contentType).font(.system(size: 11)).foregroundStyle(theme.text3)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                }
            } else {
                Text(result.error ?? "").font(.system(size: 12)).foregroundStyle(theme.text2).padding(12)
            }
        case .headers:
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.response?.headers ?? [], id: \.self) { header in
                        HStack(alignment: .top, spacing: 10) {
                            Text(verbatim: header.name).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(theme.text)
                                .frame(width: 200, alignment: .leading)
                            Text(verbatim: header.value).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text2)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
            }
        case .timeline:
            timeline(result)
        case .tests:
            tests(result)
        }
    }

    private func language(_ response: APIResponse) -> String? {
        let type = response.contentType
        if type.contains("html") || type.contains("xml") { return "html" }
        if type.contains("yaml") { return "yaml" }
        if type.contains("javascript") { return "javascript" }
        return nil
    }

    private func timeline(_ result: APIExecution.Result) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let plan = result.plan {
                    Text(verbatim: "\(plan.method) \(plan.url.absoluteString)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.text)
                        .textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(plan.headers.enumerated()), id: \.offset) { _, header in
                            Text(verbatim: "\(header.name): \(header.value)")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.text2)
                                .textSelection(.enabled)
                        }
                    }
                    if let body = plan.body, !body.isEmpty {
                        Text(verbatim: String(data: body.prefix(4096), encoding: .utf8) ?? "<\(body.count) bytes>")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.text2)
                            .textSelection(.enabled)
                    }
                    if !plan.unresolved.isEmpty {
                        Label("Not defined: " + plan.unresolved.map { "{{\($0)}}" }.joined(separator: ", "), systemImage: "questionmark.circle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Self.statusColor(400))
                    }
                }
                if let timeline = result.response?.timeline {
                    Divider()
                    phase("DNS", timeline.dns)
                    phase("Connect", timeline.connect)
                    phase("TLS", timeline.tls)
                    phase("Waiting (TTFB)", timeline.firstByte)
                    phase("Download", timeline.download)
                    if timeline.redirects > 0 { row("Redirects", "\(timeline.redirects)") }
                    if let name = timeline.protocolName { row("Protocol", name) }
                    if let address = timeline.remoteAddress { row("Remote", address) }
                }
                if !result.logs.isEmpty {
                    Divider()
                    ForEach(Array(result.logs.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(line.level == .error ? Self.statusColor(500) : line.level == .warn ? Self.statusColor(400) : theme.text2)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func phase(_ name: String, _ milliseconds: Double?) -> some View {
        row(name, milliseconds.map(APIResponse.formatDuration) ?? "—")
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.system(size: 11.5)).foregroundStyle(theme.text2).frame(width: 120, alignment: .leading)
            Text(verbatim: value).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text)
        }
    }

    private func tests(_ result: APIExecution.Result) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if result.tests.isEmpty {
                    Text("No tests or assertions ran. Add some in the Tests and Assert tabs.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text3)
                }
                // By position: two scripts' tests may share a name.
                ForEach(Array(result.tests.enumerated()), id: \.offset) { _, test in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: test.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(test.passed ? Self.statusColor(200) : Self.statusColor(500))
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: test.name).font(.system(size: 12, design: test.isAssertion ? .monospaced : .default))
                                .foregroundStyle(theme.text)
                            if let error = test.error {
                                Text(verbatim: error).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .accessibilityIdentifier("apiTestResults")
    }
}
