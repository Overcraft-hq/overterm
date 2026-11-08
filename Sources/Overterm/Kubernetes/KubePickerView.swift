import SwiftUI

/// `n` and `c` over the Kubernetes page: a field to type into and the
/// namespaces or contexts it lets through (`KubePicker`). ↑↓ move, ↩ picks,
/// Esc or a click outside goes back to the list. The namespaces have their
/// boxes: ⌥↩ or a click on one ticks it, shown at once, the picker open. The field is the palette's
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

    private static func symbol(_ kind: KubePicker.Kind) -> String {
        switch kind {
        case .namespace: "square.dashed"
        case .context: "steeringwheel"
        case .compare: "arrow.left.arrow.right.square"
        }
    }

    private static func placeholder(_ kind: KubePicker.Kind) -> String {
        switch kind {
        case .namespace: "Namespaces — find one, type its name, or a,b"
        case .context: "Context"
        case .compare(let context, let namespace):
            namespace == nil ? "Compare with a context" : "Compare with a context — or a namespace of \(context), or namespace@context"
        }
    }

    private static func key(_ kind: KubePicker.Kind) -> String {
        switch kind {
        case .namespace: "n"
        case .context: "c"
        case .compare: ""
        }
    }

    private static func nothing(_ kind: KubePicker.Kind) -> String {
        switch kind {
        case .namespace: "Not a namespace's name."
        case .context: "No context matches."
        case .compare(_, let namespace): namespace == nil ? "No other context." : "Nothing matches: type a namespace, or namespace@context."
        }
    }

    private func card(_ picker: KubePicker) -> some View {
        let results = picker.results
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(picker.kind)).font(.system(size: 13)).foregroundStyle(theme.text3)
                PaletteField(
                    text: Binding(get: { page.picker?.query ?? "" }, set: { page.picker?.query = $0 }),
                    onMove: { page.picker?.move($0) },
                    // ⌥↩ ticks a namespace; ↩ shows the one highlighted alone.
                    onSubmit: { run in
                        if !run, picker.kind == .namespace { page.togglePicked() } else { page.choosePicked() }
                    },
                    onCancel: { page.closePicker() },
                    placeholder: Self.placeholder(picker.kind),
                    textColor: NSColor(theme.text), focusesOnAppear: true, fontSize: 14)
                Text(verbatim: Self.key(picker.kind)).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
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
                            row(item, highlighted: offset == picker.index, checkbox: checkbox(picker, item, at: offset)).id(item.id)
                                .onTapGesture {
                                    page.picker?.index = offset
                                    page.choosePicked()
                                }
                        }
                        if results.isEmpty {
                            Text(verbatim: Self.nothing(picker.kind)).font(.system(size: 12))
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
            if picker.kind == .namespace {
                Divider().opacity(0.4)
                Text(verbatim: "↩ this one alone · ⌥↩ or its box ticks it · Esc done")
                    .font(.system(size: 10.5)).foregroundStyle(theme.text3).padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.menuEdge))
        .accessibilityIdentifier("kubernetes.picker")
    }

    /// A namespace's box (and All's), ticked or not; a click on it ticks it.
    private func checkbox(_ picker: KubePicker, _ item: KubePicker.Item, at offset: Int) -> AnyView? {
        guard picker.kind == .namespace, case .scope(let scope) = item.choice, scope.names?.count ?? 1 == 1 else { return nil }
        let checked = picker.isChecked(item)
        return AnyView(
            Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: 12))
                .foregroundStyle(checked ? theme.text : theme.text3)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
                .onTapGesture {
                    page.picker?.index = offset
                    page.togglePicked()
                }
                .accessibilityIdentifier("kubernetes.picker.check.\(item.id)"))
    }

    private func row(_ item: KubePicker.Item, highlighted: Bool, checkbox: AnyView? = nil) -> some View {
        HStack(spacing: 8) {
            if let checkbox { checkbox }
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
