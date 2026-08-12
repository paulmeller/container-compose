//
//  FakeRuntimeAdapter.swift
//  container-compose
//
//  An in-memory RuntimeAdapter. Its existence is the payoff of the adapter
//  boundary: Engine's orchestration, event ordering and error handling are
//  tested here in milliseconds, with the real (shell-out) adapter exercising
//  the identical Engine code against a live daemon separately.
//

import ComposeCore
@testable import ComposeEngine
import Foundation

actor FakeRuntimeAdapter: RuntimeAdapter {
    struct FakeContainer {
        var service: String
        var running: Bool
        var configHash: String?
    }

    enum Failure: Error, Equatable {
        case imagePullFailed(String)
        case createFailed(String)
        case startFailed(String)
        case healthcheckFailed(String)
    }

    private(set) var containers: [String: FakeContainer] = [:]
    private var nextID = 0

    /// Seeds a container as if it already existed before this Engine run,
    /// bypassing create/start — this is how tests set up "already running"
    /// or "stopped with a stale config" scenarios.
    func seed(id: String, service: String, running: Bool, configHash: String?) {
        containers[id] = FakeContainer(service: service, running: running, configHash: configHash)
    }

    /// Calls to fail on, by matching image or service name — lets a test
    /// inject a specific failure without a real registry or runtime.
    private var imagesToFail: Set<String> = []
    private var servicesToFailCreate: Set<String> = []

    func failImage(_ image: String) { imagesToFail.insert(image) }
    func failCreate(forService service: String) { servicesToFailCreate.insert(service) }

    func observe(projectName: String) async throws -> [ObservedContainer] {
        containers.map { id, container in
            ObservedContainer(service: container.service, containerID: id, running: container.running, configHash: container.configHash)
        }
    }

    func ensureImage(_ image: String) async throws {
        if imagesToFail.contains(image) { throw Failure.imagePullFailed(image) }
    }

    func createContainer(for service: PlannedService, projectName: String) async throws -> String {
        if servicesToFailCreate.contains(service.name) { throw Failure.createFailed(service.name) }
        nextID += 1
        let id = "\(projectName)-\(service.name)-\(nextID)"
        containers[id] = FakeContainer(service: service.name, running: false, configHash: service.configHash)
        return id
    }

    func startContainer(id: String) async throws {
        containers[id]?.running = true
    }

    func stopContainer(id: String) async throws {
        containers[id]?.running = false
    }

    func deleteContainer(id: String, force: Bool) async throws {
        containers.removeValue(forKey: id)
    }

    func waitForHealthy(containerID: String, healthcheck: PlannedHealthcheck?) async throws {
        // Instant in the fake — healthcheck TIMING is a real-adapter concern,
        // not something Engine's orchestration logic needs to wait on.
    }
}
