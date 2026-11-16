import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and reports changes (debounced by FSEvents' latency) on the main
/// queue. `rootGone` is true when the folder itself was deleted, renamed or moved.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let box: Box

    private final class Box {
        let onChange: (Bool) -> Void
        init(_ onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
    }

    init(url: URL, latency: TimeInterval = 0.4, onChange: @escaping (_ rootGone: Bool) -> Void) {
        box = Box(onChange)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let rootChanged = (0..<count).contains { flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 }
            MainActor.assumeIsolated { box.onChange(rootChanged) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
