//
//  RuntimeAdapter.swift
//  container-compose
//

import ComposeCore
import Foundation

/// The engine's only doorway to the outside world.
///
/// Every operation that touches a real container runtime goes through this
/// protocol, and nowhere else in the engine calls out directly. That is what
/// makes `Engine` itself testable against an in-memory fake: swap the adapter,
/// and the reconciliation, event-ordering and error-handling logic runs
/// exactly as it would against a live daemon, in milliseconds.
public protocol RuntimeAdapter: Sendable {
    /// Every container belonging to `projectName`, as observed right now.
    /// An empty result means no containers exist for this project, not an
    /// error — a fresh project reconciles against nothing.
    func observe(projectName: String) async throws -> [ObservedContainer]

    /// Ensures `image` is present locally, pulling it if not. A no-op when
    /// already present — the adapter decides what "present" means for its
    /// runtime.
    func ensureImage(_ image: String) async throws

    /// Creates (but does not start) a container for `service`. Returns the
    /// runtime's identifier for it.
    ///
    /// The adapter — not the engine — decides the container's name, since that
    /// is runtime-specific (Apple's container has more than one naming
    /// convention, chosen by DNS availability). `service.configHash` MUST be
    /// recorded on the container in a way `observe` can read back, since that
    /// is the entire mechanism reconciliation depends on.
    func createContainer(for service: PlannedService, projectName: String) async throws -> String

    func startContainer(id: String) async throws
    func stopContainer(id: String) async throws
    func deleteContainer(id: String, force: Bool) async throws

    /// Polls until `service`'s healthcheck passes, or throws on timeout/failure.
    /// A service with no healthcheck should return immediately.
    func waitForHealthy(containerID: String, healthcheck: PlannedHealthcheck?) async throws
}
