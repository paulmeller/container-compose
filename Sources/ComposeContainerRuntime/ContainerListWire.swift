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
}

struct WireImageEntry: Decodable {
    let reference: String
}

/// `container network list --format json`. Only the name is read: existence is
/// the entire question `ensureNetwork` asks, and decoding the subnet/gateway
/// status block would couple this to fields that carry no meaning here.
struct WireNetworkEntry: Decodable {
    struct Configuration: Decodable {
        let name: String
    }
    let configuration: Configuration
}
