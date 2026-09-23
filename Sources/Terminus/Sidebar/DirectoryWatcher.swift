import CoreServices
import Foundation

/// Recursive change notifications for one directory tree, via FSEvents.
/// Reports the directories whose contents changed, coalesced over `latency`,
/// on the main queue.
@MainActor
final class DirectoryWatcher {
    /// nonisolated(unsafe) so deinit can reach it: the stream holds an
    /// unretained pointer to self and must be torn down before self is freed.
    /// Only ever touched on the main queue (init, stop, deinit of a
    /// main-actor object).
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let onChange: ([URL]) -> Void

    init?(root: URL, latency: TimeInterval = 0.3, onChange: @escaping ([URL]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            // kFSEventStreamCreateFlagUseCFTypes: paths is a CFArray of CFString.
            let array = unsafeBitCast(paths, to: NSArray.self)
            let urls = (0..<count).compactMap { (array[$0] as? String).map { URL(fileURLWithPath: $0) } }
            nonisolated(unsafe) let pointer = info
            MainActor.assumeIsolated {
                Unmanaged<DirectoryWatcher>.fromOpaque(pointer).takeUnretainedValue().onChange(urls)
            }
        }
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
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
