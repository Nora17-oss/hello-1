import Foundation
import CoreServices

@MainActor
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    var changed: (() -> Void)?
    func start(_ url: URL) {
        stop()
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.changed?() }
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }
    func stop() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
        stream = nil
    }
}
