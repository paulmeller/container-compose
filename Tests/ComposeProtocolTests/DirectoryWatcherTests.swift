//
//  DirectoryWatcherTests.swift
//  container-compose
//
//  Real temp directories, real kqueue events — no container daemon involved,
//  since this is pure host-filesystem watching. Timing-based like the rest
//  of this project's live-ish tests (e.g. EngineLifecycleTests' `wait`
//  timeout): sleeps past the 0.2s debounce with margin rather than
//  synchronizing exactly, which is the accepted tradeoff for asserting on
//  real OS event delivery.
//

import Testing
import Foundation
@testable import ComposeProtocol

// .serialized: these assert on real kqueue event delivery within a fixed
// margin past the 0.2s debounce. Running concurrently with the rest of the
// (normally sub-millisecond) fast suite introduces enough CPU contention to
// occasionally blow that margin — not a bug in DirectoryWatcher itself, just
// scheduling noise this suite is more exposed to than plain in-memory tests.
@Suite("DirectoryWatcher", .serialized)
struct DirectoryWatcherTests {

    private func withTempDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cc-dirwatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    @Test("fires after a new file is added to the watched directory")
    func firesOnNewFile() async throws {
        try await withTempDirectory { directory in
            let counter = ChangeCounter()
            let watcher = DirectoryWatcher(root: directory.path) { counter.increment() }
            defer { watcher.stop() }

            try "hello".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 1_500_000_000)

            #expect(counter.count > 0)
        }
    }

    @Test("fires on an atomic-save style rename over an existing file — the pattern most editors actually use")
    func firesOnAtomicSave() async throws {
        try await withTempDirectory { directory in
            let target = directory.appendingPathComponent("config.txt")
            try "v1".write(to: target, atomically: true, encoding: .utf8)

            let counter = ChangeCounter()
            let watcher = DirectoryWatcher(root: directory.path) { counter.increment() }
            defer { watcher.stop() }

            let temp = directory.appendingPathComponent("config.txt.tmp")
            try "v2".write(to: temp, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)

            try await Task.sleep(nanoseconds: 1_500_000_000)
            #expect(counter.count > 0)
        }
    }

    @Test("fires for a change inside a subdirectory that did not exist when watching started")
    func firesOnDynamicallyCreatedSubdirectory() async throws {
        try await withTempDirectory { directory in
            let counter = ChangeCounter()
            let watcher = DirectoryWatcher(root: directory.path) { counter.increment() }
            defer { watcher.stop() }

            let nested = directory.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            // Give the watcher time to notice `nested` (via the root's own
            // .write event) and register a source for it before writing
            // inside it.
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let countAfterMkdir = counter.count

            try "hello".write(to: nested.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 1_500_000_000)

            #expect(counter.count > countAfterMkdir, "a file added inside a subdirectory created after watching started must still be seen")
        }
    }

    @Test("multiple rapid changes are debounced into fewer callbacks than changes")
    func debouncesRapidChanges() async throws {
        try await withTempDirectory { directory in
            let counter = ChangeCounter()
            let watcher = DirectoryWatcher(root: directory.path) { counter.increment() }
            defer { watcher.stop() }

            for index in 0..<10 {
                try "content-\(index)".write(to: directory.appendingPathComponent("file-\(index).txt"), atomically: true, encoding: .utf8)
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)

            #expect(counter.count > 0)
            #expect(counter.count < 10, "ten changes within the debounce window must not produce ten separate callbacks")
        }
    }

    @Test("stop() prevents further callbacks")
    func stopPreventsFurtherCallbacks() async throws {
        try await withTempDirectory { directory in
            let counter = ChangeCounter()
            let watcher = DirectoryWatcher(root: directory.path) { counter.increment() }
            watcher.stop()

            try "hello".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 1_500_000_000)

            #expect(counter.count == 0)
        }
    }
}

/// Lock-guarded because `onChange` fires from `DirectoryWatcher`'s internal
/// dispatch queue, not the calling context — the same reasoning as every
/// other cross-thread collector in this project's test suite.
private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _count += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
}
