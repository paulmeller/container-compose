//
//  DirectoryWatcher.swift
//  container-compose
//

import Dispatch
import Foundation

/// Watches a directory tree for changes using one kqueue-backed
/// `DispatchSourceFileSystemObject` per directory, opened recursively — what
/// lets `watch` react to real filesystem activity instead of unconditionally
/// re-walking and re-`stat`ing every watched file on a fixed timer, which
/// does not scale to large trees.
///
/// Deliberately directory-level, not one source per file: a directory's
/// `.write` event fires on add/remove/rename of its direct children, which
/// is exactly what the atomic-save pattern most editors use (write a temp
/// file, then rename it over the original) actually produces — so this
/// catches the overwhelming majority of real edits without one file
/// descriptor per watched FILE. What it cannot see is a rare same-inode
/// in-place write with no rename; `ProtocolRunner.runWatch` pairs this with
/// an infrequent safety-net rescan so that gap self-heals within a few
/// seconds rather than staying permanent.
final class DirectoryWatcher: @unchecked Sendable {
    /// Above this many directories, stop opening new watches and rely on the
    /// caller's periodic safety net alone for anything beyond it — a
    /// defensive cap, not a tuned limit, so pointing `develop.watch` at an
    /// enormous tree degrades rather than exhausting file descriptors.
    private static let maxWatchedDirectories = 4000

    private let queue = DispatchQueue(label: "container-compose.directory-watcher")
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private let onChange: @Sendable () -> Void
    private var debounceWorkItem: DispatchWorkItem?
    private var stopped = false

    /// Starts watching `root` (and everything beneath it) immediately.
    /// `onChange` fires — debounced, on an internal queue — after real
    /// filesystem activity anywhere in the tree.
    init(root: String, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        queue.async { [weak self] in self?.watch(root) }
    }

    /// Cancels every open source. Idempotent; safe to call from any thread.
    /// Callers must call this explicitly — a `deinit`-based cancel would
    /// race the queue's own async setup in `init`.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for source in self.sources.values { source.cancel() }
            self.sources.removeAll()
            self.stopped = true
        }
    }

    private func watch(_ path: String) {
        guard !stopped, sources[path] == nil, sources.count < Self.maxWatchedDirectories else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) {
                self.forget(path)
            } else {
                self.handleChange(at: path)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources[path] = source

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for entry in entries {
            let childPath = path + "/" + entry
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: childPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            watch(childPath)
        }
    }

    /// The watched directory itself was deleted — its own kqueue source is
    /// now meaningless; the deletion itself is a real, worth-reacting-to
    /// change, so it still triggers `onChange`, just without re-scanning
    /// (nothing there to re-scan).
    private func forget(_ path: String) {
        sources[path]?.cancel()
        sources.removeValue(forKey: path)
        onChange()
    }

    /// A directory's own `.write` fires on add/remove/rename of its direct
    /// children — re-walk from here so a newly created subdirectory gets its
    /// own source, then debounce the actual callback: editors commonly fire
    /// several fs events for a single logical save.
    private func handleChange(at path: String) {
        guard !stopped else { return }
        watch(path)
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [onChange] in onChange() }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }
}
