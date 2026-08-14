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
///
/// Split by what actually needs it: `Engine` only calls the orchestration
/// group (observe/build/image/lifecycle/health) — the observation and
/// interactive groups exist on this same protocol because they are still
/// "talk to the runtime" operations, but `ProtocolRunner` calls them directly
/// for commands that don't need Engine's reconcile-and-wave machinery at all
/// (`ps`, `logs`, `exec`, ...). Keeping them on one protocol, not scattered
/// across several, means there is exactly one thing a second runtime would
/// need to implement.
public protocol RuntimeAdapter: Sendable {

    // MARK: Observation

    /// Every container belonging to `projectName`, as observed right now.
    /// An empty result means no containers exist for this project, not an
    /// error — a fresh project reconciles against nothing.
    func observe(projectName: String) async throws -> [ObservedContainer]

    /// Every container across every compose project this tool manages —
    /// identified purely by the compose labels, no compose file needed.
    /// Backs `ls`, which is not scoped to one project.
    func observeAllProjects() async throws -> [ObservedContainer]

    // MARK: Images

    /// Ensures `image` is present locally, pulling it if not. A no-op when
    /// already present — the adapter decides what "present" means for its
    /// runtime.
    func ensureImage(_ image: String) async throws

    /// Builds `service`'s image from its `build` configuration and returns
    /// the reference it was tagged with. The adapter decides the tag, the
    /// same way it decides container names — keeping that decision in one
    /// place rather than letting the caller guess a runtime-specific format.
    func buildImage(for service: PlannedService, projectName: String) async throws -> String

    /// Pushes `image` to its registry.
    func pushImage(_ image: String) async throws

    // MARK: Networks

    /// Ensures `network` is usable before any container that references it is
    /// created. A no-op when it already exists, the same contract as
    /// `ensureImage` — the adapter decides what "exists" means for its runtime.
    ///
    /// The `external` flag is the whole distinction: an external network is
    /// declared by the user as something this project does not own, so it must
    /// be *required*, never created, and its absence is an error worth stating
    /// plainly. A non-external network is this project's to create, and is
    /// labelled with `projectName` so teardown can identify what it made.
    ///
    /// Returns whether this call created the network, so the engine can report
    /// "created" and "already there" as different things rather than making a
    /// consumer guess.
    func ensureNetwork(_ network: PlannedNetwork, projectName: String) async throws -> Bool

    // MARK: Lifecycle

    /// Creates (but does not start) a container for `service`, running
    /// `image` — which the caller has already resolved, whether from
    /// `service.image` directly or from a prior `buildImage` call. Returns
    /// the runtime's identifier for it.
    ///
    /// The adapter — not the engine — decides the container's name, since
    /// that is runtime-specific (Apple's container has more than one naming
    /// convention, chosen by DNS availability). `service.configHash` MUST be
    /// recorded on the container in a way `observe` can read back, since that
    /// is the entire mechanism reconciliation depends on.
    func createContainer(for service: PlannedService, image: String, projectName: String) async throws -> String

    func startContainer(id: String) async throws
    func stopContainer(id: String) async throws
    func killContainer(id: String, signal: String) async throws
    func deleteContainer(id: String, force: Bool) async throws

    /// Polls until `service`'s healthcheck passes, or throws on timeout/failure.
    /// A service with no healthcheck should return immediately.
    func waitForHealthy(containerID: String, healthcheck: PlannedHealthcheck?) async throws

    // MARK: Introspection

    /// The processes running inside `containerID`, as runtime-formatted text.
    /// Not structured: the runtime has no native `top`, so this is whatever a
    /// `ps`-style command inside the container reports, passed through as-is.
    func topProcesses(containerID: String) async throws -> String

    /// Resource usage for the given containers, as runtime-formatted text —
    /// same reasoning as `topProcesses`: passed through, not parsed, since
    /// there is no structured form to parse it into.
    func containerStats(containerIDs: [String]) async throws -> String

    // MARK: Files

    /// Copies between the host and a container, or container-to-container.
    /// `source`/`destination` are already-resolved runtime paths (any
    /// `SERVICE:` prefix has been rewritten to a container ID by the caller);
    /// the adapter's only job here is the copy itself.
    func copyFile(source: String, destination: String) async throws

    /// Writes `containerID`'s filesystem as a tar archive to `outputPath`.
    /// Always a file path, never stdout: a tar archive is binary, and this
    /// protocol's only other output channel is a line-oriented event stream
    /// that cannot carry it.
    func exportContainer(containerID: String, to outputPath: String) async throws

    // MARK: Logs

    /// Streams log lines for one container. `onLine` fires once per line, as
    /// it arrives — not batched — which is what lets `logs --follow` show
    /// real progress rather than a delayed dump. Returns once the underlying
    /// process exits: immediately for `follow: false`, or when the container
    /// stops (or the caller cancels the enclosing task) for `follow: true`.
    func streamLogs(containerID: String, follow: Bool, tail: Int?, onLine: @escaping @Sendable (String) -> Void) async throws

    // MARK: Interactive passthrough

    /// Runs `command` inside an already-running container with the calling
    /// process's own stdio — a live terminal session when attached to one, or
    /// plain piped I/O otherwise. Returns the child's exit code.
    ///
    /// Deliberately NOT part of the `EngineEvent`/`ProtocolMessage` stream: a
    /// live terminal session — arbitrary control codes, real-time keystrokes —
    /// cannot be expressed as discrete JSON events without either breaking the
    /// terminal experience or inventing a second, incompatible transport
    /// mid-stream. A consumer that wants this inherits the child process's
    /// stdio directly, which is a normal thing for a process-spawning API in
    /// any language to do; it just means no NDJSON is emitted for that one
    /// invocation, which is stated as a documented exception, not an oversight.
    func execPassthrough(containerID: String, command: [String], tty: Bool) async throws -> Int32

    /// Runs `command` in a fresh, uniquely-named container built from `image`,
    /// with the same stdio-inheritance behavior as `execPassthrough`. Used for
    /// `run` — a one-off invocation, not part of the managed, reconciled set of
    /// containers `up`/`down` own.
    func runPassthrough(
        image: String,
        command: [String],
        environment: [String: String],
        workingDirectory: String?,
        labels: [String: String],
        remove: Bool,
        tty: Bool
    ) async throws -> Int32
}
