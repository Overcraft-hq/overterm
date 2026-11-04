import AppKit
import SwiftUI

/// What Overterm ships of other people's work, and each one's licence as its
/// authors wrote it: `Resources/licenses/index.json`, made by
/// Scripts/fetch-licenses.sh. Settings ▸ About ▸ Acknowledgements.
struct Acknowledgement: Codable, Hashable, Identifiable {
    var group: String
    var name: String
    var version: String
    var license: String
    var url: String
    /// The licence's text, relative to the bundle's Resources.
    var file: String

    var id: String { group + "/" + name }

    /// The order the groups are listed in.
    static let groups = ["Terminal", "Editor", "Swift packages", "Notes"]

    static func load(from resources: URL? = Bundle.main.resourceURL) -> [Acknowledgement] {
        guard let resources, let data = try? Data(contentsOf: resources.appendingPathComponent("licenses/index.json")),
            let all = try? JSONDecoder().decode([Acknowledgement].self, from: data)
        else { return [] }
        return all
    }

    func text(in resources: URL? = Bundle.main.resourceURL) -> String {
        guard let resources, let text = try? String(contentsOf: resources.appendingPathComponent(file), encoding: .utf8) else {
            return "The licence isn’t in this build: \(url)"
        }
        return text
    }
}

/// Settings ▸ About ▸ Acknowledgements: a window, as the changelog is.
@MainActor
final class AcknowledgementsWindowController: NSWindowController {
    static let shared = AcknowledgementsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Acknowledgements"
        window.minSize = NSSize(width: 620, height: 400)
        // Over a full-screen Overterm, on the Space you are on.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AcknowledgementsView(all: Acknowledgement.load()))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AcknowledgementsView: View {
    let all: [Acknowledgement]
    @State private var selection: Acknowledgement.ID?
    @State private var query = ""

    private var shown: [Acknowledgement] {
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.license.localizedCaseInsensitiveContains(query) }
    }

    private var selected: Acknowledgement? { all.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Filter", text: $query).textFieldStyle(.roundedBorder).padding(8)
                List(selection: $selection) {
                    ForEach(Acknowledgement.groups, id: \.self) { group in
                        let items = shown.filter { $0.group == group }
                        if !items.isEmpty {
                            Section(group) {
                                ForEach(items) { item in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: item.name)
                                        Text(verbatim: "\(item.version) · \(item.license)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .tag(item.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                Text(verbatim: "\(all.count) components").font(.caption).foregroundStyle(.secondary).padding(6)
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            Group {
                if let item = selected {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: item.name).font(.title3.weight(.semibold))
                            Text(verbatim: "\(item.version) · \(item.license)").foregroundStyle(.secondary)
                            Spacer()
                            if let url = URL(string: item.url) { Link("Website", destination: url) }
                        }
                        ScrollView {
                            Text(verbatim: item.text())
                                .font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                } else {
                    VStack(spacing: 6) {
                        Text("Overterm is built on these.").font(.headline)
                        Text("Pick one for its licence.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selection = selection ?? all.first?.id }
    }
}
