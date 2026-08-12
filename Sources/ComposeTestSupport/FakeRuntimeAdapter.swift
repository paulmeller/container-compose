//
//  FakeRuntimeAdapter.swift
//  container-compose
//
//  An in-memory RuntimeAdapter, public so every test target in this package
//  (Engine's, and Protocol's) can drive real orchestration code against it
//  without a daemon. Its existence is the payoff of the adapter boundary:
//  Engine's actual orchestration, event ordering and error handling run
//  unmodified here, with the real (shell-out) adapter exercising the
//  identical code against a live daemon separately.
//
//  Lives in its own target (not inside a test target) specifically so it can
//  be shared: a type defined in one test target is not importable from
//  another.

import ComposeCore
import ComposeEngine
import Foundation

public actor FakeRuntimeAdapter: RuntimeAdapter {
    public struct FakeContainer: Sendable {
        public var service: String
        public var running: Bool
        public var configHash: String?
    }

    public enum Failure: Error, Equatable, Sendable {
        case imagePullFailed(String)
        case createFailed(String)
        case startFailed(String)
        case healthcheckFailed(String)
    }

    public private(set) var containers: [String: FakeContainer] = [:]
    private var nextID = 0

    public init() {}

    /// Seeds a container as if it already existed before this Engine run,
    /// bypassing create/start — this is how tests set up "already running"
    /// or "stopped with a stale config" scenarios.
    public func seed(id: String, service: String, running: Bool, configHash: String?) {
        containers[id] = FakeContainer(service: service, running: running, configHash: configHash)
    }

    /// Calls to fail on, by matching image or service name — lets a test
    /// inject a specific failure without a real registry or runtime.
    private var imagesToFail: Set<String> = []
    private var servicesToFailCreate: Set<String> = []

    public func failImage(_ image: String) { imagesToFail.insert(image) }
    public func failCreate(forService service: String) { servicesToFailCreate.insert(service) }

    public func observe(projectName: String) async throws -> [ObservedContainer] {
        containers.map { id, container in
            ObservedContainer(service: container.service, containerID: id, running: container.running, configHash: container.configHash)
        }
    }

    public func ensureImage(_ image: String) async throws {
        if imagesToFail.contains(image) { throw Failure.imagePullFailed(image) }
    }

    public func createContainer(for service: PlannedService, projectName: String) async throws -> String {
        if servicesToFailCreate.contains(service.name) { throw Failure.createFailed(service.name) }
        nextID += 1
        let id = "\(projectName)-\(service.name)-\(nextID)"
        containers[id] = FakeContainer(service: service.name, running: false, configHash: service.configHash)
        return id
    }

    public func startContainer(id: String) async throws {
        containers[id]?.running = true
    }

    public func stopContainer(id: String) async throws {
        containers[id]?.running = false
    }

    public func deleteContainer(id: String, force: Bool) async throws {
        containers.removeValue(forKey: id)
    }

    public func waitForHealthy(containerID: String, healthcheck: PlannedHealthcheck?) async throws {
        // Instant in the fake — healthcheck TIMING is a real-adapter concern,
        // not something Engine's orchestration logic needs to wait on.
    }
}
