import Foundation

// Reports on the main queue when the watched file is written, replaced, moved, or
// deleted. It follows the file it was given, not the path: after an editor saves by
// replacing the file, the owner must start a new watcher on the path.
final class FileWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
