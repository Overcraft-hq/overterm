import SwiftUI

/// `n` and `c` over the Kubernetes page: a field to type into and the
/// namespaces or contexts it lets through (`KubePicker`). ↑↓ move, ↩ picks,
/// Esc or a click outside goes back to the list. The field is the palette's
/// (`PaletteField`): arrows and Esc need the field editor's commands.
struct KubePickerView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if let picker = page.picker {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).onTapGesture { page.closePicker() }
                card(picker)
            }
        }
    }

    private func card(_ picker: KubePicker) -> some View {
        let results = picker.results
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: picker.kind == .namespace ? "square.dashed" : "steeringwheel").font(.system(size: 13)).foregroundStyle(theme.text3)
                PaletteField(
                    text: Binding(get: { page.picker?.query ?? "" }, set: { page.picker?.query = $0 }),
                    onMove: { page.picker?.move($0) },
                    onSubmit: { _ in page.choosePicked() },
                    onCancel: { page.closePicker() },
                    placeholder: picker.kind == .namespace ? "Namespace — find one, or type its name" : "Context",
                    textColor: NSColor(theme.text), focusesOnAppear: true, fontSize: 14)
                Text(verbatim: picker.kind == .namespace ? "n" : "c").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            Divider().opacity(0.4)
            if let note = picker.note {
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(theme.text2).padding(.horizontal, 14).padding(.vertical, 6)
                    .accessibilityIdentifier("kubernetes.picker.note")
            }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { offset, item in
                            row(item, highlighted: offset == picker.index).id(item.id)
                                .onTapGesture {
                                    page.picker?.index = offset
                                    page.choosePicked()
                                }
                        }
                        if results.isEmpty {
                            Text(picker.kind == .namespace ? "Not a namespace's name." : "No context matches.").font(.system(size: 12))
                                .foregroundStyle(theme.text3).padding(.horizontal, 10).padding(.vertical, 6)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: picker.index) { _ in
                    if let id = page.picker?.selected?.id { scroll.scrollTo(id) }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.menuEdge))
        .accessibilityIdentifier("kubernetes.picker")
    }

    private func row(_ item: KubePicker.Item, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            if item.production {
                DockerStatusDot(color: KubernetesPageView.production)
            } else if item.typed {
                Image(systemName: "keyboard").font(.system(size: 10)).foregroundStyle(theme.text3)
            }
            Text(verbatim: item.title).font(.system(size: 12.5)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let detail = item.detail {
                Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(item.production ? KubernetesPageView.production : theme.text3)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? theme.selected : .clear))
        .contentShape(Rectangle())
    }
}
