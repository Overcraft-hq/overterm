import AppKit

// libghostty's process-wide init has to precede every other call into it.
guard GhosttyRuntime.initialize() else {
    FileHandle.standardError.write(Data("terminus: ghostty_init failed\n".utf8))
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
