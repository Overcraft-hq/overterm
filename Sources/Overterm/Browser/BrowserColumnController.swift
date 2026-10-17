import AppKit

/// The column beside the terminal holds two things, one at a time: the
/// tab's browser and the simulator. One card, and a button each way —
/// rather than a sixth column, which would cost every window the width and
/// the saved divider positions (`OvertermColumns`).
@MainActor
final class BrowserColumnController: NSViewController {
    enum Mode: String {
        case web, simulator
    }

    let browser: BrowserViewController
    let simulator: SimulatorViewController
    private(set) var mode: Mode = .web
    /// Whether the column itself is on screen; the simulator is mirrored
    /// only while it is (a stream costs, shut it costs nothing).
    private(set) var isColumnOpen = false

    init(browser: BrowserViewController, simulator: SimulatorViewController) {
        self.browser = browser
        self.simulator = simulator
        super.init(nibName: nil, bundle: nil)
        addChild(browser)
        addChild(simulator)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        for child in [browser.view, simulator.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: root.topAnchor),
                child.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                child.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        apply()
    }

    /// Switches what the column shows; the one going away stops working.
    func show(_ mode: Mode) {
        self.mode = mode
        apply()
    }

    /// The column was opened or collapsed.
    func setColumnOpen(_ open: Bool) {
        isColumnOpen = open
        apply()
    }

    private func apply() {
        guard isViewLoaded else { return }
        browser.view.isHidden = mode != .web
        simulator.view.isHidden = mode != .simulator
        if mode == .simulator && isColumnOpen {
            simulator.activate()
        } else {
            simulator.deactivate()
        }
    }
}
