import SwiftUI

/// The ⌘F overlay, over the terminal: a query and grouped results.
struct SpotlightView: View {
    @ObservedObject var model: SpotlightModel
    let theme: ChromeTheme
    let onChoose: (SpotlightModel.Row) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001).onTapGesture(perform: onDismiss)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.dimText)
                    PaletteField(
                        text: $model.query,
                        onMove: { model.move($0) },
                        onSubmit: { _ in model.selected.map(onChoose) },
                        onCancel: onDismiss,
                        placeholder: placeholder,
                        textColor: NSColor(theme.text))
                }
                .frame(height: 44)
                .padding(.horizontal, 14)
                if !model.rows.isEmpty {
                    Divider().opacity(0.4)
                    results
                }
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.strip))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.dimText.opacity(0.25)))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.top, 40)
        }
    }

    private var placeholder: String {
        model.root.map { "Search the terminal and \($0.lastPathComponent)…" } ?? "Search the terminal…"
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, selected: index == model.selectedIndex)
                            .id(row.id)
                            .onTapGesture { onChoose(row) }
                    }
                }
                .padding(6)
            }
            // A ScrollView takes all the height it may; size it to the rows so
            // two results don't sit in an empty 380 pt box.
            .frame(height: min(CGFloat(model.rows.count) * 46 + 12, 380))
            .onChange(of: model.selectedIndex) { index in
                if model.rows.indices.contains(index) { proxy.scrollTo(model.rows[index].id) }
            }
        }
    }

    @ViewBuilder private func rowView(_ row: SpotlightModel.Row, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch row {
            case .terminal(let total):
                icon("terminal")
                title("Find “\(model.query)” in the terminal", subtitle: total.map { $0 == 1 ? "1 match" : "\($0) matches" } ?? "searching…")
                Spacer()
                tag("Terminal")
            case .file(let path):
                icon("doc")
                title((path as NSString).lastPathComponent, subtitle: (path as NSString).deletingLastPathComponent)
                Spacer()
                tag("File")
            case .content(let match):
                icon("text.magnifyingglass")
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "\(match.path):\(match.line)").foregroundStyle(theme.text).lineLimit(1).truncationMode(.head)
                    Text(verbatim: match.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.dimText).lineLimit(1)
                }
                Spacer()
                tag("In file")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? theme.selected : .clear))
        .contentShape(Rectangle())
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).frame(width: 18).foregroundStyle(theme.dimText)
    }

    private func title(_ text: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: text).foregroundStyle(theme.text).lineLimit(1)
            if !subtitle.isEmpty {
                Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(theme.dimText).lineLimit(1).truncationMode(.head)
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(theme.dimText)
    }
}
