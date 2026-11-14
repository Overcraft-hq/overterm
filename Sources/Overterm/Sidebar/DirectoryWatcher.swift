import CoreServices
import Foundation

/// Recursive change notifications for directory trees, via FSEvents.
/// Reports the directories whose contents changed — as paths, which is all
/// anyone needs (a URL each cost more than the check that used it) —
/// coalesced over `latency`, on the main queue.
///
/// With `fileEvents:` it reports each file instead, with what happened to it
/// (`kFSEventStreamCreateFlagFileEvents`): a language server's watched files
/// need the file and whether it came, changed or went.
@MainActor
final class DirectoryWatcher {
    /// One file-level event: FSEvents' path (the real one, `/private/var/…`)
    /// and its flags as FSEvents gave them.
    struct Event: Sendable, Hashable {
        var path: String
        var flags: Flags
    }

    /// FSEvents' item flags, passed through. They are coalesced over the
    /// latency, and FSEvents keeps some of them for a while (a file created
    /// a moment ago may say created again when modified): whether the file
    /// is there now is the one thing to trust.
    struct Flags: OptionSet, Sendable, Hashable {
        let rawValue: UInt32
        init(rawValue: UInt32) { self.rawValue = rawValue }

        static let created = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemCreated))
        static let removed = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemRemoved))
        static let modified = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemModified))
        static let renamed = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemRenamed))
        static let inodeMetadata = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemInodeMetaMod))
        static let isFile = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemIsFile))
        static let isDirectory = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemIsDir))
        static let isSymlink = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemIsSymlink))
        /// Events were dropped below this folder: rescan it.
        static let mustScanSubdirectories = Flags(rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
    }

    /// nonisolated(unsafe) so deinit can reach it: the stream holds an
    /// unretained pointer to self and must be torn down before self is freed.
    /// Only ever touched on the main queue (init, stop, deinit of a
    /// main-actor object).
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let onEvents: ([Event]) -> Void

    convenience init?(root: URL, latency: TimeInterval = 0.3, onChange: @escaping ([String]) -> Void) {
        self.init(roots: [root], latency: latency, onChange: onChange)
    }

    /// One stream over several trees.
    convenience init?(roots: [URL], latency: TimeInterval = 0.3, onChange: @escaping ([String]) -> Void) {
        self.init(roots: roots, latency: latency, files: false) { events in onChange(events.map(\.path)) }
    }

    /// Every file under the trees, one event each, with its flags.
    convenience init?(roots: [URL], latency: TimeInterval = 0.3, fileEvents: @escaping ([Event]) -> Void) {
        self.init(roots: roots, latency: latency, files: true, onEvents: fileEvents)
    }

    private init?(roots: [URL], latency: TimeInterval, files: Bool, onEvents: @escaping ([Event]) -> Void) {
        self.onEvents = onEvents
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            // kFSEventStreamCreateFlagUseCFTypes: paths is a CFArray of CFString.
            let array = unsafeBitCast(paths, to: NSArray.self)
            // A watched home folder reports thousands a second.
            var events: [Event] = []
            events.reserveCapacity(count)
            for index in 0..<count {
                guard let path = array[index] as? String else { continue }
                events.append(Event(path: path, flags: Flags(rawValue: flags[index])))
            }
            nonisolated(unsafe) let pointer = info
            MainActor.assumeIsolated {
                Unmanaged<DirectoryWatcher>.fromOpaque(pointer).takeUnretainedValue().onEvents(events)
            }
        }
        var options = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        if files { options |= kFSEventStreamCreateFlagFileEvents }
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, roots.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(options))
        else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Stops delivery. Also done on deinit — dropping a watcher without it
    /// once let a queued event call into freed memory.
    func stop() {
        tearDown()
    }

    deinit {
        tearDown()
    }

    private nonisolated func tearDown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        // After invalidation no further callbacks run, queued ones included.
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
