import AppKit

/// The one confirmation every write is asked with (Kubernetes' rule 3,
/// first DockerMCP's `allow`): a sheet on the window, its title, the
/// context and namespace it changes — in production's red on production —
/// what it does with every character visible, where asked a field for the
/// object's name, then the button and Cancel. Nothing is sent until the
/// button; what was typed goes back for the caller to check.
@MainActor
struct WriteConfirmation {
    var title: String
    /// The context and namespace (or another scope) the write changes;
    /// nil when there is none to say.
    var scope: String?
    var production = false
    var detail: String
    var button: String
    var cancel = "Cancel"
    /// The name to type, shown as the field's placeholder; nil, no field.
    var typedName: String?
    /// An image, in a field of its own above the name's: prefilled, and
    /// what it says when the button is pressed goes back with the name.
    var image: String? = nil
    /// The critical style: production, or a name asked.
    var critical = false

    /// Production's colour, as the Kubernetes page draws it.
    static let productionRed = NSColor(srgbRed: 0.86, green: 0.17, blue: 0.17, alpha: 1)
    /// The typed-name field's identifier, for the scenario.
    static let typedNameField = "write.typedName"
    /// The image field's identifier, for the scenario.
    static let imageField = "write.image"
    /// A detail longer than this goes in a scroll view, all of it.
    static let shortDetail = 600

    /// A detail whose first line is a production scope ("PRODUCTION ·
    /// fake-prod · namespace shop"): that line as the scope, drawn red.
    static func splittingProduction(title: String, detail: String, button: String) -> WriteConfirmation {
        let lines = detail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.hasPrefix(KubeWriteConfirmation.productionMark) else {
            return WriteConfirmation(title: title, detail: detail, button: button)
        }
        return WriteConfirmation(
            title: title, scope: first, production: true, detail: lines.count > 1 ? lines[1] : "", button: button, critical: true)
    }

    /// The alert, and its typed-name field when one is asked.
    func alert() -> (NSAlert, NSTextField?) {
        let (alert, field, _) = alertWithImage()
        return (alert, field)
    }

    /// The alert, its typed-name field and its image field, each when asked.
    func alertWithImage() -> (NSAlert, NSTextField?, NSTextField?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = critical || production ? .critical : .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: cancel)
        let width: CGFloat = 320
        var views: [NSView] = []
        if let scope {
            let label = NSTextField(wrappingLabelWithString: scope)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = production ? Self.productionRed : .secondaryLabelColor
            label.setAccessibilityIdentifier("write.scope")
            views.append(label)
        }
        // All of it, never cut: the first 2,000 characters were shown and
        // all of it ran — `ls` and two thousand spaces hid what came after.
        if detail.count > Self.shortDetail {
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 220)
            if let text = scroll.documentView as? NSTextView {
                text.string = detail
                text.isEditable = false
                text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            }
            alert.informativeText = "\(detail.count) characters — all of it below."
            views.append(scroll)
        } else if scope != nil, !detail.isEmpty {
            // Under the scope, so the context is read first.
            let label = NSTextField(wrappingLabelWithString: detail)
            label.font = .systemFont(ofSize: 11.5)
            views.append(label)
        } else {
            alert.informativeText = detail
        }
        var imageField: NSTextField?
        if let image {
            let label = NSTextField(labelWithString: "Image")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            views.append(label)
            let typed = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
            typed.stringValue = image
            typed.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            typed.identifier = NSUserInterfaceItemIdentifier(Self.imageField)
            typed.setAccessibilityIdentifier(Self.imageField)
            views.append(typed)
            imageField = typed
        }
        var field: NSTextField?
        if let typedName {
            let typed = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
            typed.placeholderString = typedName
            typed.identifier = NSUserInterfaceItemIdentifier(Self.typedNameField)
            typed.setAccessibilityIdentifier(Self.typedNameField)
            views.append(typed)
            field = typed
        }
        if !views.isEmpty {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            let stackWidth = max(width, views.map { $0 is NSScrollView ? $0.frame.width : 0 }.max() ?? 0)
            for view in views {
                if let label = view as? NSTextField, label !== field, label !== imageField { label.preferredMaxLayoutWidth = stackWidth }
                view.translatesAutoresizingMaskIntoConstraints = false
                view.widthAnchor.constraint(equalToConstant: view is NSScrollView ? view.frame.width : stackWidth).isActive = true
                if view is NSScrollView { view.heightAnchor.constraint(equalToConstant: view.frame.height).isActive = true }
            }
            stack.frame = NSRect(origin: .zero, size: NSSize(width: stackWidth, height: stack.fittingSize.height))
            alert.accessoryView = stack
            if let first = field ?? imageField { alert.window.initialFirstResponder = first }
        }
        return (alert, field, imageField)
    }

    /// Asked on `window` as a sheet: `then` gets what was typed ("" when no
    /// name was asked) once the button is pressed; Cancel calls nothing.
    func present(on window: NSWindow, then: @escaping (String) -> Void) {
        presentAnswer(on: window) { then($0.typed) }
    }

    /// The same, with the image field's text too (nil when it had none).
    func presentAnswer(on window: NSWindow, then: @escaping (KubeWriteAnswer) -> Void) {
        let (alert, field, imageField) = alertWithImage()
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { then(KubeWriteAnswer(typed: field?.stringValue ?? "", image: imageField?.stringValue)) }
        }
    }

    /// Asked on `window` (else on its own): what was typed, nil when cancelled.
    func ask(on window: NSWindow?) async -> String? {
        let (alert, field) = alert()
        guard let window else { return alert.runModal() == .alertFirstButtonReturn ? field?.stringValue ?? "" : nil }
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .alertFirstButtonReturn ? field?.stringValue ?? "" : nil
    }
}
