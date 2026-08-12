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
}

struct WireStatus: Decodable {
    let state: String
}

struct WireImageEntry: Decodable {
    let reference: String
}
