//
//  FakeRuntimeAdapter.swift
//  container-compose
//
//  An in-memory RuntimeAdapter, public so every test target in this package
//  can drive real orchestration code against it without a daemon. Its
//  existence is the payoff of the adapter boundary: Engine's and
//  ProtocolRunner's actual code runs unmodified here, with the real
//  (shell-out) adapter exercising the identical code against a live daemon
//  separately.
//
//  Lives in its own target (not inside a test target) specifically so it can
//  be shared: a type defined in one test target is not importable from
//  another.

import ComposeCore
import ComposeEngine
import Foundation

public actor FakeRuntimeAdapter: RuntimeAdapter {
    public struct FakeContainer: Sendable {
        public var project: String
        public var service: String
        public var running: Bool
        public var configHash: String?
        public var image: String
        public var publishedPorts: [PublishedPort] = []
    }

    public enum Failure: Error, Equatable, Sendable {
        case imagePullFailed(String)
        case imageBuildFailed(String)
        case createFailed(String)
        case startFailed(String)
        case healthcheckFailed(String)
        case notFound(String)
        case networkUnavailable(String)
        case volumeUnavailable(String)
    }

    public private(set) var containers: [String: FakeContainer] = [:]
    /// Log lines recorded per container, for `streamLogs` to replay. Tests
    /// seed this directly; the fake does not generate any output on its own.
    public private(set) var logs: [String: [String]] = [:]
    /// Files "copied" so far, as (source, destination) pairs — lets a test
    /// assert a copy happened without a real filesystem.
    public private(set) var copies: [(source: String, destination: String)] = []
    public private(set) var pushedImages: [String] = []
    /// Every `ensureImage` call, in order — separate from `presentImages` so a
    /// test can tell "was asked about" from "had to fetch".
    public private(set) var pulledImages: [String] = []
    private var presentImages: Set<String> = []
    public private(set) var exports: [(containerID: String, outputPath: String)] = []
    /// Every network Engine asked for, in call order — the assertion that
    /// networks are ensured at all, and before any container exists.
    public private(set) var ensuredNetworks: [String] = []
    /// The subset of those that did not already exist and so were created.
    /// Kept separate from `ensuredNetworks` so a test can tell "required an
    /// external network" apart from "made a new one".
    public private(set) var createdNetworks: [String] = []
    private var existingNetworks: Set<String> = []
    /// Created by this project, and so removable by it — the in-memory stand-in
    /// for the project label the real adapter writes.
    private var ownedNetworks: Set<String> = []
    /// Volumes, tracked exactly as networks are above.
    public private(set) var ensuredVolumes: [String] = []
    public private(set) var createdVolumes: [String] = []
    private var existingVolumes: Set<String> = []
    private var ownedVolumes: Set<String> = []
    /// Every seed attempt, in call order — the assertion that a newly created
    /// volume is seeded from the right image at the right path, and that an
    /// existing one is left alone.
    public private(set) var seededVolumes: [(volume: String, image: String, path: String)] = []
    private var volumesWithoutShell: Set<String> = []
    private var nextID = 0

    public init() {}

    /// Seeds a container as if it already existed before this Engine run,
    /// bypassing create/start — this is how tests set up "already running"
    /// or "stopped with a stale config" scenarios.
    public func seed(
        id: String,
        project: String,
        service: String,
        running: Bool,
        configHash: String?,
        image: String = "alpine:latest",
        publishedPorts: [PublishedPort] = []
    ) {
        containers[id] = FakeContainer(
            project: project, service: service, running: running, configHash: configHash,
            image: image, publishedPorts: publishedPorts
        )
    }

    public func seedLogs(containerID: String, lines: [String]) {
        logs[containerID] = lines
    }

    /// Seeds a network as already present, by resolved name — how a test sets
    /// up "this external network exists" or "this one was created by an
    /// earlier run".
    public func seedNetwork(_ resolvedName: String) {
        existingNetworks.insert(resolvedName)
    }

    /// Seeds a volume as already present, by resolved name — "this external
    /// volume exists", or "an earlier run created it".
    public func seedVolume(_ resolvedName: String) {
        existingVolumes.insert(resolvedName)
    }

    /// Calls to fail on, by matching image or service name — lets a test
    /// inject a specific failure without a real registry or runtime.
    private var imagesToFail: Set<String> = []
    private var servicesToFailCreate: Set<String> = []
    private var servicesToFailBuild: Set<String> = []
    private var networksToFail: Set<String> = []
    private var volumesToFail: Set<String> = []
    private var servicesToFailHealth: Set<String> = []

    public func failImage(_ image: String) { imagesToFail.insert(image) }
    public func failCreate(forService service: String) { servicesToFailCreate.insert(service) }
    public func failBuild(forService service: String) { servicesToFailBuild.insert(service) }
    public func failNetwork(_ resolvedName: String) { networksToFail.insert(resolvedName) }
    public func failVolume(_ resolvedName: String) { volumesToFail.insert(resolvedName) }
    /// Marks an image as having no shell, so seeding reports that it could not
    /// copy rather than throwing — distroless images really are like this.
    public func imageHasNoShell(_ image: String) { volumesWithoutShell.insert(image) }

    // MARK: Observation

    public func observe(projectName: String) async throws -> [ObservedContainer] {
        containers
            .filter { $0.value.project == projectName }
            .map { id, container in
                ObservedContainer(
                    project: container.project, service: container.service, containerID: id,
                    running: container.running, configHash: container.configHash,
                    image: container.image, publishedPorts: container.publishedPorts
                )
            }
    }

    public func observeAllProjects() async throws -> [ObservedContainer] {
        containers.map { id, container in
            ObservedContainer(
                project: container.project, service: container.service, containerID: id,
                running: container.running, configHash: container.configHash,
                image: container.image, publishedPorts: container.publishedPorts
            )
        }
    }

    // MARK: Images

    public func ensureImage(_ image: String) async throws -> Bool {
        if imagesToFail.contains(image) { throw Failure.imagePullFailed(image) }
        pulledImages.append(image)
        // Present after the first ask, so a second `up` in one test reports
        // the same "already there" a real runtime would.
        return presentImages.insert(image).inserted
    }

    /// Seeds an image as already local, so `ensureImage` reports no pull.
    public func seedImage(_ image: String) { presentImages.insert(image) }

    public func buildImage(for service: PlannedService, projectName: String) async throws -> String {
        if servicesToFailBuild.contains(service.name) { throw Failure.imageBuildFailed(service.name) }
        return "\(projectName)/\(service.name):built"
    }

    public func pushImage(_ image: String) async throws {
        pushedImages.append(image)
    }

    // MARK: Networks

    public func ensureNetwork(_ network: PlannedNetwork, projectName: String) async throws -> Bool {
        ensuredNetworks.append(network.resolvedName)
        if networksToFail.contains(network.resolvedName) {
            throw Failure.networkUnavailable(network.resolvedName)
        }
        if existingNetworks.contains(network.resolvedName) { return false }
        // An external network is the user's to provide: absent means the run
        // cannot proceed, not that the fake should invent one.
        if network.external { throw Failure.networkUnavailable(network.resolvedName) }
        existingNetworks.insert(network.resolvedName)
        createdNetworks.append(network.resolvedName)
        ownedNetworks.insert(network.resolvedName)
        return true
    }

    public func removeNetworks(projectName: String) async throws -> [String] {
        let removed = ownedNetworks.sorted()
        existingNetworks.subtract(ownedNetworks)
        ownedNetworks.removeAll()
        return removed
    }

    // MARK: Volumes

    public func ensureVolume(_ volume: PlannedVolume, projectName: String) async throws -> Bool {
        ensuredVolumes.append(volume.resolvedName)
        if volumesToFail.contains(volume.resolvedName) {
            throw Failure.volumeUnavailable(volume.resolvedName)
        }
        if existingVolumes.contains(volume.resolvedName) { return false }
        // Mirrors the network rule, and matters more: silently inventing a
        // missing external volume hands back an empty disk where data was.
        if volume.external { throw Failure.volumeUnavailable(volume.resolvedName) }
        existingVolumes.insert(volume.resolvedName)
        createdVolumes.append(volume.resolvedName)
        ownedVolumes.insert(volume.resolvedName)
        return true
    }

    public func seedVolume(_ volume: String, fromImage image: String, atPath path: String) async throws -> Bool {
        seededVolumes.append((volume: volume, image: image, path: path))
        return !volumesWithoutShell.contains(image)
    }

    public func removeVolumes(projectName: String) async throws -> [String] {
        let removed = ownedVolumes.sorted()
        existingVolumes.subtract(ownedVolumes)
        ownedVolumes.removeAll()
        return removed
    }

    // MARK: Lifecycle

    public func createContainer(for service: PlannedService, image: String, projectName: String) async throws -> String {
        if servicesToFailCreate.contains(service.name) { throw Failure.createFailed(service.name) }
        nextID += 1
        let id = "\(projectName)-\(service.name)-\(nextID)"
        containers[id] = FakeContainer(
            project: projectName, service: service.name, running: false,
            configHash: service.configHash, image: image
        )
        return id
    }

    public func startContainer(id: String) async throws {
        containers[id]?.running = true
    }

    public func stopContainer(id: String) async throws {
        containers[id]?.running = false
    }

    public func killContainer(id: String, signal: String) async throws {
        containers[id]?.running = false
    }

    public func deleteContainer(id: String, force: Bool) async throws {
        containers.removeValue(forKey: id)
    }

    public func waitForHealthy(containerID: String, healthcheck: PlannedHealthcheck?) async throws {
        // Instant in the fake — healthcheck TIMING is a real-adapter concern,
        // not something Engine's orchestration logic needs to wait on. What
        // Engine DOES own is whether it waits at all, so a test needs to be
        // able to make the check fail.
        if let service = containers[containerID]?.service, servicesToFailHealth.contains(service) {
            throw Failure.healthcheckFailed(service)
        }
    }

    /// Makes this service's healthcheck fail, so a test can tell "waited and
    /// the check failed" from "never waited".
    public func failHealthcheck(forService service: String) { servicesToFailHealth.insert(service) }

    // MARK: Introspection

    public func topProcesses(containerID: String) async throws -> String {
        guard containers[containerID] != nil else { throw Failure.notFound(containerID) }
        return "PID   COMMAND\n1     fake-process"
    }

    public func containerStats(containerIDs: [String]) async throws -> String {
        "CONTAINER   CPU   MEMORY\n" + containerIDs.map { "\($0)      0.0%  0B" }.joined(separator: "\n")
    }

    // MARK: Files

    public func copyFile(source: String, destination: String) async throws {
        copies.append((source, destination))
    }

    public func exportContainer(containerID: String, to outputPath: String) async throws {
        guard containers[containerID] != nil else { throw Failure.notFound(containerID) }
        exports.append((containerID, outputPath))
    }

    // MARK: Logs

    public func streamLogs(containerID: String, follow: Bool, tail: Int?, onLine: @escaping @Sendable (String) -> Void) async throws {
        let lines = logs[containerID] ?? []
        let selected = tail.map { Array(lines.suffix($0)) } ?? lines
        for line in selected { onLine(line) }
        // `follow` is a no-op in the fake: there is no live process to keep
        // reading from, and Engine/ProtocolRunner orchestration logic does not
        // depend on how long this call takes, only on it returning the lines
        // it has.
    }

    // MARK: Interactive passthrough

    public func execPassthrough(containerID: String, command: [String], tty: Bool) async throws -> Int32 {
        guard containers[containerID] != nil else { throw Failure.notFound(containerID) }
        return 0
    }

    public func runPassthrough(
        image: String,
        command: [String],
        environment: [String: String],
        workingDirectory: String?,
        labels: [String: String],
        remove: Bool,
        tty: Bool
    ) async throws -> Int32 {
        0
    }
}
