import Foundation
import CoreServices

/// FSEvents coalesces recursive directory changes without polling file contents.
/// The callback owns no UI or repository; callers choose their execution context.
final class LibraryFileWatcher {
    private var stream: FSEventStreamRef?
    private let changed: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Teachshelf.filesystem-events", qos: .utility)

    init(root: URL, changed: @escaping @Sendable () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, context, _, _, _, _ in
            guard let context else { return }
            Unmanaged<LibraryFileWatcher>.fromOpaque(context).takeUnretainedValue().changed()
        }, &context, [root.appendingPathComponent("files").path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.35,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            // Drain callbacks before the unretained context is destroyed.
            queue.sync {}
            FSEventStreamRelease(stream)
        }
    }
}

@MainActor extension AppStore {
    func watchLibraryFiles() {
        fileSyncTask?.cancel()
        fileSyncTask = nil
        let repository = repository
        fileWatcher = LibraryFileWatcher(root: repository.root) { [weak self, weak repository] in
            Task { @MainActor [weak self, weak repository] in
                guard let self, let repository, self.repository === repository else { return }
                self.requestFileSystemSync()
            }
        }
    }

    func requestFileSystemSync() {
        fileSyncGeneration += 1
        guard fileSyncTask == nil else { return }
        fileSyncTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                if self.isBusy { continue }
                let generation = self.fileSyncGeneration, repository = self.repository
                do {
                    let changed = try await Task.detached(priority: .utility) {
                        try repository.synchronizeFileSystem()
                    }.value
                    guard self.repository === repository else { return }
                    failures = 0
                    if changed {
                        self.reload()
                        self.status = "已同步 Finder 中的更改"
                    }
                } catch {
                    guard self.repository === repository else { return }
                    self.reload()
                    self.status = "Finder 同步未完成：\(error.localizedDescription)"
                    failures += 1
                    if failures < 3 { continue }
                }
                if generation == self.fileSyncGeneration { self.fileSyncTask = nil; return }
            }
        }
    }
}
