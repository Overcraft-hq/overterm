import AppKit

/// Over a file with edits of yours that something else (an agent, most
/// likely) rewrote on disk: Reload takes theirs, Keep Mine leaves yours —
/// saving them still asks before writing over theirs (EDIT-G3).
@MainActor
package final class EditorDiskBar: NSView {
    package static let height: CGFloat = 30

    package var onReload: (() -> Void)?
    package var onKeep: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let reload = NSButton(title: "Reload", target: nil, action: nil)
    private let keep = NSButton(title: "Keep Mine", target: nil, action: nil)
    private var background: NSColor

    package init(theme: EditorTheme) {
        background = EditorPicker.blend(theme.background, theme.warning, 0.18)
        super.init(frame: .zero)
        setAccessibilityIdentifier("editor.diskBar")
        if #available(macOS 14, *) { clipsToBounds = true }
        label.font = .systemFont(ofSize: 12)
        label.textColor = theme.text
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [reload, keep] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11.5)
            button.target = self
        }
        reload.action = #selector(reloadPressed)
        keep.action = #selector(keepPressed)
        let stack = NSStackView(views: [label, reload, keep])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    package required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The sentence the bar says, for `name`.
    package static func message(_ name: String) -> String {
        "“\(name)” changed on disk while you had edits here."
    }

    package func show(name: String) {
        label.stringValue = Self.message(name)
    }

    package var message: String { label.stringValue }

    package override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    @objc private func reloadPressed() { onReload?() }
    @objc private func keepPressed() { onKeep?() }
}
