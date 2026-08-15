//
//  ContainerListWire.swift
//  container-compose
//

import Foundation

/// Mirrors the subset of `container ls --all --format json`'s shape this
/// adapter reads. Deliberately narrow — only the fields reconciliation and
/// observation need — so an unrelated field the runtime adds does not break
/// decoding.
struct WireContainerEntry: Decodable {
    let configuration: WireConfiguration
    let status: WireStatus
}

struct WireConfiguration: Decodable {
    let id: String
    let labels: [String: String]?
    let image: WireImageDescriptor?
    let publishedPorts: [WirePublishedPort]?
}

struct WireImageDescriptor: Decodable {
    let reference: String
}

struct WirePublishedPort: Decodable {
    let containerPort: Int
    let hostPort: Int
    let hostAddress: String
}

struct WireStatus: Decodable {
    let state: String
    /// Per-network attachment, carrying the address the runtime assigned.
    /// Populated only once a container is running: a created-but-stopped
    /// container reports none, which is why service addresses can only be
    /// recorded after `start` rather than planned ahead of it.
    let networks: [WireStatusNetwork]?
}

struct WireStatusNetwork: Decodable {
    let ipv4Address: String?
}

/// `container image list --format json`.
///
/// The reference lives at `configuration.name`, NOT at the top level. Decoding
/// it from a top-level `reference` silently produced nothing — the decode
/// failed, the failure was swallowed by a `?? []`, and every existence check
/// answered "absent", so every `up` re-pulled every image it already had. The
/// only symptom was slowness, which reads as the network being slow rather
/// than as a bug.
struct WireImageEntry: Decodable {
    struct Configuration: Decodable {
        /// Registry-qualified, e.g. `docker.io/n8nio/n8n:2.10.2`.
        let name: String
    }
    let configuration: Configuration

    var reference: String { configuration.name }
}

/// `container network list --format json`. Name and labels only: existence is
/// what `ensureNetwork` asks, ownership is what teardown asks, and decoding
/// the subnet/gateway status block would couple this to fields carrying no
/// meaning here.
struct WireNetworkEntry: Decodable {
    struct Configuration: Decodable {
        let name: String
        let labels: [String: String]?
    }
    let configuration: Configuration
}

/// `container volume list --format json`. Same shape and same reasoning as
/// the network entry above.
struct WireVolumeEntry: Decodable {
    struct Configuration: Decodable {
        let name: String
        let labels: [String: String]?
    }
    let configuration: Configuration
}
