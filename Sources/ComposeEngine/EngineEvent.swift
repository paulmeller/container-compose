//
//  EngineEvent.swift
//  container-compose
//

import ComposeCore
import Foundation

/// A stage a service is passing through, emitted as it happens rather than
/// batched at the end. This is what a consumer renders as progress.
public enum ServiceState: String, Codable, Sendable {
    case pulling
    case building
    case pushing
    case creating
    case starting
    case waitingForDependency
    case waitingForHealthy
    case recreating
    case stopping
    case removing
    /// `watch` syncing a changed host path into an already-running container.
    case syncing
}

/// Why a service was not attempted at all.
public enum SkipReason: String, Codable, Sendable {
    /// A dependency's wave failed, so this service — which depended on it —
    /// was never reached.
    case dependencyFailed

    /// A network the project declares could not be made available, so no
    /// container was attempted. Distinct from `dependencyFailed`: nothing in
    /// the project ran, and retrying a single service cannot help until the
    /// network itself is fixed.
    case networkUnavailable

    /// As `networkUnavailable`, for a declared volume.
    case volumeUnavailable
}

/// What a `resourceRemoved` event removed.
public enum ResourceKind: String, Codable, Sendable {
    case network
    case volume
}

/// What `imageReady` reports having happened to the image. Distinguishing
/// these — rather than reusing `serviceReady` for all three, as build/pull/
/// push originally did — is what lets a consumer reading one message in
/// isolation say "built" or "pushed" without having tracked which top-level
/// command produced it.
public enum ImageAction: String, Codable, Sendable {
    case built
    case pulled
    case pushed
}

/// One event in the stream an `up`/`down` operation produces.
///
/// This is the machine contract: a GUI renders these directly, a CLI prints a
/// line per event, and both see the same information. Nothing is available to
/// one consumer that is not available to the other — the enforced rule from
/// the design thesis is that the CLI has no privileged access.
public enum EngineEvent: Sendable, Equatable {
    /// Emitted once, before anything executes: the full plan, so a consumer
    /// can render "here is what's about to happen" up front.
    case planned(services: [String], waves: [[String]])

    /// A service entered a new stage.
    case serviceState(service: String, state: ServiceState, detail: String?)

    /// A service reached a running, correct state. `reused` distinguishes "was
    /// already running and untouched" from "just started" — the case a
    /// delete-and-recreate implementation cannot report, because for it every
    /// ready service was just recreated.
    case serviceReady(service: String, containerID: String, reused: Bool)

    /// A service's container was stopped, but still exists — `down` without
    /// `--remove`, `stop`, and `kill`. Kept distinct from `serviceReady`:
    /// "ready" is not an honest description of a container that was just
    /// told to stop.
    case serviceStopped(service: String, containerID: String)

    /// A service's container no longer exists — `down --remove`, and `rm`.
    case serviceRemoved(service: String, containerID: String)

    /// A service's image was produced or relocated — `build`, `pull`, `push`.
    /// `action` says which, so this reads correctly even outside the context
    /// of knowing which top-level command emitted it.
    case imageReady(service: String, image: String, action: ImageAction)

    /// A network the project declares is available. `created` distinguishes
    /// "this run made it" from "it was already there" — the same reuse-vs-new
    /// distinction `serviceReady` draws, and for the same reason: a consumer
    /// showing progress needs to say which happened.
    case networkReady(network: String, created: Bool)

    /// A declared network could not be made available. Carries the reason as
    /// text because the actionable part is runtime-specific (an external
    /// network that does not exist needs a different fix from a create that
    /// was refused), and no enum of causes would survive contact with a second
    /// runtime.
    case networkFailed(network: String, reason: String)

    /// A declared volume is available. `created` carries the same
    /// new-vs-already-there distinction `networkReady` does.
    case volumeReady(volume: String, created: Bool)

    /// A declared volume could not be made available.
    case volumeFailed(volume: String, reason: String)

    /// A network or volume this project created was deleted during teardown.
    /// `kind` distinguishes them rather than two near-identical cases, since
    /// consumers render both the same way — as a line saying what went.
    case resourceRemoved(kind: ResourceKind, name: String)

    /// A service failed. `service.state` is not set to failed separately —
    /// this event is the terminal state.
    case serviceFailed(service: String, reason: String)

    /// A service was never attempted because a dependency's wave failed.
    /// Distinguishing this from `serviceFailed` is the specific gap named in
    /// the design thesis: today, "attempted and failed" and "never attempted"
    /// are indistinguishable from the outside.
    case serviceSkipped(service: String, reason: SkipReason)

    /// The operation finished. Emitted exactly once, always — including when
    /// `success` is false, so a consumer always has a final per-service
    /// accounting rather than only on the happy path.
    case done(success: Bool, ready: [String], failed: [String], skipped: [String])
}

extension ReconcileAction {
    /// The human-facing reason a `.recreate` action is happening, when there
    /// is one. `nil` for actions that do not carry one.
    var recreateReason: String? {
        if case .recreate(_, _, let reason) = self { return reason }
        return nil
    }
}
