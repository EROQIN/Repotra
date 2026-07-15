import CoreServices
import Foundation

final class DirectoryWatcher: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let callback: @Sendable () -> Void
        init(callback: @escaping @Sendable () -> Void) {
            self.callback = callback
        }
    }

    private var stream: FSEventStreamRef?
    private var box: CallbackBox?

    func start(url: URL, callback: @escaping @Sendable () -> Void) {
        stop()
        let box = CallbackBox(callback: callback)
        self.box = box
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().callback()
            },
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
        guard let stream else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        box = nil
    }

    deinit { stop() }
}
