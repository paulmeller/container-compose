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
    case creating
    case starting
    case waitingForDependency
    case waitingForHealthy
    case recreating
    case stopping
    case removing
}

/// Why a service was not attempted at all.
public enum SkipReason: String, Codable, Sendable {
    /// A dependency's wave failed, so this service — which depended on it —
    /// was never reached.
    case dependencyFailed
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
