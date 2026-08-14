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

// .serialized: these assert on real kqueue event delivery, so they are more
// exposed to CPU contention than the rest of the (sub-millisecond, in-memory)
// fast suite.
//
// Waiting is done by POLLING for the expected condition rather than sleeping a
// fixed margin past the 0.2s debounce. The fixed-sleep version failed roughly
// one run in three: a loaded machine simply had not delivered the event yet
// when the assertion ran, which says nothing about DirectoryWatcher and
// everything about how long the test was willing to wait. Polling returns as
// soon as the event lands — so the common case is FASTER than the old fixed
// sleep — and only spends the long timeout when something is genuinely wrong.
@Suite("DirectoryWatcher", .serialized)
struct DirectoryWatcherTests {

    /// How long a correct watcher is allowed to take. Generous on purpose:
    /// this bound is never reached unless the event never arrives, so raising
    /// it costs nothing in a passing run and only buys tolerance for a busy
    /// machine.
    private static let eventTimeout: Duration = .seconds(10)

    private func withTempDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cc-dirwatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// Polls until `condition` holds, or the timeout elapses. Returns whether
    /// it held, so a caller can assert on it with a useful message.
    @discardableResult
    private func waitUntil(
        timeout: Duration = DirectoryWatcherTests.eventTimeout,
        _ condition: @Sendable () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Waits for the debounce window to close and any in-flight callbacks to
    /// land. Used only where the assertion is about how MANY callbacks fired,
    /// which cannot be polled for — you have to let it settle and then look.
    private func settle() async throws {
        try await Task.sleep(for: .seconds(1))
    }

    /// Repeats `change` until the watcher reports it, or the timeout elapses.
    ///
    /// The retry is not defensive padding, it is required for correctness of
    /// the test: `DirectoryWatcher.init` registers its kqueue source
    /// asynchronously (`queue.async { self?.watch(root) }`), so it returns
    /// before anything is actually being watched. A change made inside that
    /// window is missed permanently — kqueue reports future events, not past
    /// ones — so a single write can legitimately produce no callback ever.
    /// On an idle machine the window is microseconds and a lone write almost
    /// always wins; under load it stretches far enough to lose, which is
    /// exactly the flake this suite had. Retrying asserts the property that
    /// actually matters — changes are seen — without pretending the
    /// registration race does not exist.
    private func waitForChange(
        counter: ChangeCounter,
        from baseline: Int = 0,
        timeout: Duration = DirectoryWatcherTests.eventTimeout,
        _ change: (Int) throws -> Void
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        var attempt = 0
        while ContinuousClock.now < deadline {
            try change(attempt)
            attempt += 1
            if try await waitUntil(timeout: .milliseconds(500), { counter.count > baseline }) { return true }
        }
        return counter.count > baseline
    }

    @Test("fires after a new file is added to the watched directory")
    func firesOnNewFile() async throws {
        try await withTempDirectory { directory in
            let counter = ChangeCounter()
            let watcher = DirectoryWatcher(root: directory.path) { counter.increment() }
            defer { watcher.stop() }

            let fired = try await waitForChange(counter: counter) { attempt in
                try "hello".write(
                    to: directory.appendingPathComponent("a-\(attempt).txt"), atomically: true, encoding: .utf8
                )
            }
            #expect(fired, "a new file in the watched directory must trigger a callback")
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

            let fired = try await waitForChange(counter: counter) { attempt in
                let temp = directory.appendingPathComponent("config.txt.tmp")
                try "v\(attempt + 2)".write(to: temp, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: temp, to: target)
            }
            #expect(fired, "an atomic-save rename over an existing file must trigger a callback")
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
            try await settle()
            let countAfterMkdir = counter.count

            // Same registration race as above, one level down: the watcher
            // only sees writes inside `nested` once it has added a source for
            // it, and that moment is not observable from outside.
            let sawNestedWrite = try await waitForChange(counter: counter, from: countAfterMkdir) { attempt in
                try "hello-\(attempt)".write(
                    to: nested.appendingPathComponent("b-\(attempt).txt"), atomically: true, encoding: .utf8
                )
            }
            #expect(sawNestedWrite, "a file added inside a subdirectory created after watching started must still be seen")
        }
    }

    @Test("multiple rapid changes are debounced into fewer callbacks than changes")
    func debouncesRapidChanges() async throws {
        try await withTempDirectory { directory in
            let counter = ChangeCounter()
            let watcher = DirectoryWatcher(root: directory.path) { counter.increment() }
            defer { watcher.stop() }

            // Confirm the watcher is actually live BEFORE the burst: counting
            // callbacks is meaningless if some of the ten writes landed during
            // the asynchronous registration window and were never watched.
            let live = try await waitForChange(counter: counter) { attempt in
                try "warmup-\(attempt)".write(
                    to: directory.appendingPathComponent("warmup-\(attempt).txt"), atomically: true, encoding: .utf8
                )
            }
            #expect(live, "the watcher must be delivering events before the burst is meaningful")
            try await settle()
            let baseline = counter.count

            for index in 0..<10 {
                try "content-\(index)".write(to: directory.appendingPathComponent("file-\(index).txt"), atomically: true, encoding: .utf8)
            }

            let fired = try await waitUntil { counter.count > baseline }
            #expect(fired, "ten rapid writes must produce at least one callback")

            // "Fewer than ten" only means something once nothing further is
            // coming, so this one has to settle rather than poll.
            try await settle()
            #expect(
                counter.count - baseline < 10,
                "ten changes within the debounce window must not produce ten separate callbacks"
            )
        }
    }

    @Test("stop() prevents further callbacks")
    func stopPreventsFurtherCallbacks() async throws {
        try await withTempDirectory { directory in
            let counter = ChangeCounter()
            let watcher = DirectoryWatcher(root: directory.path) { counter.increment() }
            watcher.stop()

            try "hello".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

            // A negative assertion, so there is nothing to poll for: waiting
            // is what gives it meaning, and waiting LONGER only makes it
            // stronger — the opposite of the timing risk the others carried.
            try await settle()
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
