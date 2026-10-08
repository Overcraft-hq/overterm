import Foundation

/// One command a pane ran: what it was, which rows of the scrollback it
/// occupies, and how it went.
struct CommandBlock: Identifiable, Equatable {
    let id: Int
    let command: String
    /// The first row of its output, counted from the oldest row libghostty
    /// still holds. Rows shift when the scrollback is trimmed; the ledger
    /// shifts them with it.
    var startRow: UInt64
    /// Its last row, while it is running the newest row there is.
    var endRow: UInt64
    /// Nil while it runs.
    var exit: Int?
    var seconds: Double?

    var isRunning: Bool { exit == nil && seconds == nil }
    var failed: Bool { (exit ?? 0) != 0 }
    var rows: UInt64 { endRow > startRow ? endRow - startRow + 1 : 0 }

    /// Whether its rows are real — whether anything it printed scrolled.
    ///
    /// The scrollbar's `total` counts the scrollback plus the screen, and
    /// the screen is a fixed height — so it does not move at all until
    /// output starts falling off the top. A command whose output fits on
    /// screen therefore has no row of its own that anyone can name, and
    /// the only honest thing to do is say so: nothing that draws at a row
    /// draws for one of these, and reading its output takes the cheaper
    /// path (the visible screen rather than the whole scrollback).
    ///
    /// One row off at the boundary — a command that scrolled exactly one
    /// line reads as unlocated — which is a row nobody could see on a map
    /// anyway.
    var isLocated: Bool { endRow > startRow }

    /// "exit 2 · 8.1 s", "4.2 s", "running" — what the block's row says
    /// about it after the command itself.
    var detail: String {
        guard let seconds else { return "running" }
        let time = seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds.rounded())) s"
        guard let exit, exit != 0 else { return time }
        return "exit \(exit) · \(time)"
    }
}

/// What a pane has run, and where it is in the scrollback.
///
/// libghostty exposes none of OSC 133 over its C API — no prompt marks, no
/// command boundaries — so this is assembled from the three things it does
/// push: the title the shell integration sets to the running command,
/// `COMMAND_FINISHED` with the exit code and duration, and the scrollbar.
/// The scrollbar's `total` is the clock: a command starts at the row that
/// does not exist yet and ends at the last one that does.
///
/// That means the ledger is exactly as good as shell integration. Without
/// it there are no titles and no finish events, and the ledger stays empty
/// — which is the right failure: nothing is drawn rather than drawn wrong.
///
/// Pure, and the reason it is: every interesting case here (a command
/// inside a command, a trimmed scrollback, a screen cleared) is a row
/// arithmetic bug waiting to be written, and none of them need a terminal
/// to reproduce.
struct CommandLedger: Equatable {
    /// Beyond this the oldest blocks go. Ten screens of history is more
    /// than the scroll map can distinguish anyway.
    static let limit = 200

    private(set) var blocks: [CommandBlock] = []
    /// Rows libghostty holds, the viewport's top row, and its height.
    private(set) var total: UInt64 = 0
    private(set) var offset: UInt64 = 0
    private(set) var rows: UInt64 = 0
    private var nextID = 0
    /// Closed because the prompt came back before its exit arrived; the
    /// exit still belongs to it.
    private var closedByPrompt: Int?

    var running: CommandBlock? { blocks.last.flatMap { $0.isRunning ? $0 : nil } }
    /// The newest finished block — what "copy the last output" means.
    var lastFinished: CommandBlock? { blocks.last { !$0.isRunning } }
    var failures: [CommandBlock] { blocks.filter(\.failed) }
    /// The failures anything row-based can actually point at.
    var locatedFailures: [CommandBlock] { blocks.filter { $0.failed && $0.isLocated } }

    /// Where the viewport is. Also how the ledger learns that rows were
    /// dropped: `total` only ever grows until libghostty trims the
    /// scrollback, and everything recorded then slides down with it.
    mutating func scrolled(total: UInt64, offset: UInt64, rows: UInt64) {
        if total < self.total { shift(by: self.total - total) }
        self.total = total
        self.offset = offset
        self.rows = rows
        // The newest block owns every row down to the end, running or
        // not: the scroll a command's last lines caused can arrive long
        // after its exit (the renderer recomputes the scrollbar on its own
        // cadence, and under load that is several frames). Freezing it at
        // the exit cut blocks off before their own output. It is frozen
        // instead by the next command starting.
        if let last = blocks.indices.last, total > 0 {
            blocks[last].endRow = max(total - 1, blocks[last].endRow)
        }
    }

    /// Whether a title is the shell saying *where* it is rather than what
    /// it is running.
    ///
    /// Shell integration sets the title to the command while one runs and
    /// back to the directory at the prompt — so half of what arrives here
    /// is a path, and recording those as commands produced a block per
    /// prompt, each one stealing the rows of the command before it.
    ///
    /// `cd` survives this: the shell announces it as `cd …` first, and only
    /// afterwards shows the new directory.
    static func isPrompt(_ title: String, cwd: String?) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return true }
        if let cwd {
            let home = NSHomeDirectory()
            let short = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
            if title == cwd || title == short || title == (cwd as NSString).lastPathComponent { return true }
        }
        // A bare path with no arguments is not something anybody ran.
        if title.hasPrefix("~") && !title.contains(" ") { return true }
        return title.hasPrefix("/") && !title.contains(" ")
    }

    /// The prompt is back: whatever was running has ended, and this is not
    /// a new command.
    ///
    /// Usually `COMMAND_FINISHED` has already arrived and this is a no-op.
    /// When it has not — the two come from different places and nothing
    /// orders them — the block is closed here and `finished` still fills
    /// in its exit code afterwards.
    mutating func prompted() {
        guard let last = blocks.indices.last, blocks[last].isRunning else { return }
        blocks[last].seconds = 0
        closedByPrompt = blocks[last].id
    }

    /// The shell set its title: with shell integration that is the command
    /// it is about to run. A new one while another is still running closes
    /// the first — nested commands are not a thing the title can express.
    mutating func began(command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The same title twice is the shell re-announcing, not a new run.
        if let last = blocks.last, last.isRunning, last.command == trimmed { return }
        closedByPrompt = nil
        if let last = blocks.indices.last, blocks[last].isRunning { blocks[last].seconds = 0 }
        blocks.append(
            CommandBlock(id: nextID, command: trimmed, startRow: total, endRow: total, exit: nil, seconds: nil))
        nextID += 1
        if blocks.count > Self.limit { blocks.removeFirst(blocks.count - Self.limit) }
    }

    /// `COMMAND_FINISHED`. Without a title first there is no block to close
    /// — that happens when shell integration reports the exit of something
    /// it never announced, and inventing a block for it would put an
    /// unnamed frame on screen.
    mutating func finished(exitCode: Int?, seconds: Double) {
        guard let last = blocks.indices.last, blocks[last].isRunning || blocks[last].id == closedByPrompt else {
            return
        }
        closedByPrompt = nil
        blocks[last].exit = exitCode ?? 0
        blocks[last].seconds = seconds
        blocks[last].endRow = total > 0 ? max(total - 1, blocks[last].endRow) : blocks[last].startRow
    }

    /// The scrollback was trimmed by `dropped` rows: everything moves down,
    /// and whatever fell off the top goes.
    private mutating func shift(by dropped: UInt64) {
        blocks = blocks.compactMap { block in
            guard block.endRow >= dropped else { return nil }
            var block = block
            block.startRow = block.startRow >= dropped ? block.startRow - dropped : 0
            block.endRow -= dropped
            return block
        }
    }

    // MARK: Navigating

    /// The next failed block after the viewport, wrapping — ⌥⌘↓.
    func nextFailure(after row: UInt64) -> CommandBlock? {
        locatedFailures.first { $0.startRow > row } ?? locatedFailures.first
    }

    /// How far to scroll to put `row` at the top of the viewport. Positive
    /// is down, which is what `scroll_lines:` wants.
    func lines(toReach row: UInt64) -> Int {
        Int(clamping: Int64(bitPattern: row) - Int64(bitPattern: offset))
    }

    /// Where a block sits in the scroll map, as fractions of the whole
    /// scrollback. Nil when there is nothing to map yet.
    func position(of block: CommandBlock) -> ClosedRange<Double>? {
        guard total > 0, block.isLocated else { return nil }
        let start = Double(block.startRow) / Double(total)
        let end = Double(min(block.endRow + 1, total)) / Double(total)
        return start...Swift.max(start, end)
    }

    /// The viewport's own place in it, for the map's thumb.
    var viewport: ClosedRange<Double>? {
        guard total > 0, rows > 0 else { return nil }
        let start = Double(offset) / Double(total)
        let end = Double(min(offset + rows, total)) / Double(total)
        return start...Swift.max(start, end)
    }
}
