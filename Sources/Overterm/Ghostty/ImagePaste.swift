import AppKit
import GhosttyKit

/// ⌘V with a picture on the clipboard, into an agent: Claude Code, Codex,
/// pi and Gemini CLI read a clipboard image themselves, on ⌃V
/// (`Agent.takesClipboardImage`) — a terminal can't send them a
/// picture, and with no text to paste Ghostty sends nothing at all, so ⌘V
/// just did nothing. In a pane an agent has the keyboard of, the paste key
/// with only an image on the clipboard is handed over as ⌃V. Anywhere else
/// it is left alone: ⌃V in a shell is quoted-insert.
enum ImagePaste {
    /// The clipboard a paste reads — the terminal's own, which an isolated
    /// run keeps away from the user's — unless a scenario hands in another.
    nonisolated(unsafe) static var override: NSPasteboard?
    @MainActor static var pasteboard: NSPasteboard { override ?? GhosttyRuntime.pasteboard(GHOSTTY_CLIPBOARD_STANDARD) ?? .general }

    /// An image and nothing a paste would type — no text, no file.
    @MainActor static func clipboardHasOnlyImage(_ pasteboard: NSPasteboard? = nil) -> Bool {
        let pasteboard = pasteboard ?? Self.pasteboard
        let types = Set(pasteboard.types ?? [])
        guard !types.contains(.string), !types.contains(.fileURL) else { return false }
        return !types.isDisjoint(with: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")])
    }

    /// Whether an agent that reads a clipboard image itself
    /// (`Agent.takesClipboardImage`) is in the pane's foreground process
    /// group (`ghostty_surface_foreground_pid`: the group, `tcgetpgrp`, not
    /// a pid), read at the instant it matters, inside the key equivalent
    /// (docs/design/activity/analysis.md, 7.7): the group's members by
    /// `proc_listpids(PROC_PGRP_ONLY)` and their names — microseconds, no
    /// table read —, where the pane's `login` was paired by a scan of the
    /// app's children and its tree read on the main thread, 7–23 ms. Only a
    /// member running as the user alone, alive, can be an agent (the
    /// census's rule, `ProcessInspector.running`): `proc_name` answers for
    /// any user's, root's too, so `sudo claude` never turns ⌘V into ⌃V.
    /// A member whose name doesn't say but may host one (`mayHost`: Claude
    /// Code as `node`, or under its version's name) is named by its argv's
    /// first word alone, unmasked, at most `argumentReads` of them a paste
    /// — a shell's, vim's or a build's group reads none. At most `limit`
    /// members are looked at.
    nonisolated static func agentHasKeyboard(
        foreground group: pid_t?, kernel: some ActivityKernel = LiveActivityKernel(), limit: Int = 64, argumentReads: Int = 4
    ) -> Bool {
        guard let group, group > 0, let members = kernel.groupMembers(group, limit: limit) else { return false }
        var reads = argumentReads
        for pid in members where agent(pid, kernel: kernel, argumentReads: &reads)?.takesClipboardImage == true { return true }
        return false
    }

    /// The agent `pid` is: by the name it runs as, else — a name that may
    /// host one, while `argumentReads` lasts — by its argv's first word's
    /// file, or under an interpreter by the script it runs (`Agent.of`'s
    /// rule: Gemini CLI under `node`); nil for one gone, a zombie, or one not
    /// running as the user alone.
    nonisolated static func agent(_ pid: pid_t, kernel: some ActivityKernel, argumentReads: inout Int) -> Agent? {
        guard let process = kernel.process(pid), !process.isZombie, process.isWhollyOwn(by: kernel.uid),
            let name = kernel.name(of: pid)
        else { return nil }
        if let agent = Agent.of(processName: name) { return agent }
        guard mayHost(name), argumentReads > 0 else { return nil }
        argumentReads -= 1
        // One read: the agent off argv's raw words inside it (`Agent.of(arguments:)`).
        return ProcessArguments.read(pid, kernel: kernel, markers: false, codeSigning: nil)?.agent
    }

    /// Whether a process of this name may be an agent under another name:
    /// a JavaScript runtime (Claude Code's or Codex's npm install, Gemini
    /// CLI, runs as `node`), a name that starts with an agent's (a platform build of
    /// Codex), or a version's (Claude Code's native install runs its
    /// `versions/<x.y.z>` file). Pure.
    nonisolated static func mayHost(_ name: String) -> Bool {
        if Agent.interpreters.contains(name) || name.hasPrefix("node") { return true }
        if Agent.allCases.contains(where: { name.hasPrefix($0.rawValue) }) { return true }
        return name.contains(where: \.isNumber) && name.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }

    /// The foreground process group of `surface`'s terminal; nil when it
    /// has none.
    @MainActor static func foregroundGroup(of surface: ghostty_surface_t) -> pid_t? {
        let group = ghostty_surface_foreground_pid(surface)
        guard group > 0, group <= UInt64(Int32.max) else { return nil }
        return pid_t(group)
    }

    /// The ⌃V an agent reads the clipboard on, for `window`.
    static func controlV(like event: NSEvent, _ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.keyEvent(
            with: type, location: event.locationInWindow, modifierFlags: [.control], timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: "\u{16}", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9)
    }
}
