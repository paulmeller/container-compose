//
//  WireDecodingTests.swift
//  container-compose
//
//  The adapter reads the runtime's `--format json` output. When one of those
//  shapes is decoded wrongly the result is not a crash: the decode fails, the
//  failure is swallowed, and the adapter concludes the runtime has nothing —
//  no images, no networks, no volumes. That reads as "slow" or "recreated
//  again", never as "the parser is wrong".
//
//  Every payload below is real output from `container` 1.1.0, trimmed to the
//  fields the adapter reads.
//

import Testing
import Foundation
@testable import ComposeContainerRuntime

@Suite("Runtime JSON decoding")
struct WireDecodingTests {

    /// Real `container image list --format json`, abbreviated. The reference
    /// is at `configuration.name`; there is no top-level `reference` key, and
    /// decoding one produced an empty list that made every image look absent.
    private static let imageListJSON = """
        [
          {
            "configuration": {
              "creationDate": "2026-06-16T00:01:20Z",
              "descriptor": { "digest": "sha256:abc", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 374 },
              "name": "docker.io/n8nio/n8n:2.10.2"
            },
            "id": "cfa50544c4cc",
            "variants": []
          },
          {
            "configuration": {
              "creationDate": "2026-06-16T00:01:20Z",
              "descriptor": { "digest": "sha256:def", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 374 },
              "name": "docker.io/library/nginx:alpine"
            },
            "id": "584d9796f319",
            "variants": []
          }
        ]
        """

    @Test("An image list decodes, and finds the images it contains")
    func imageListDecodes() throws {
        let data = try #require(Self.imageListJSON.data(using: .utf8))
        let entries = try JSONDecoder().decode([WireImageEntry].self, from: data)

        #expect(entries.count == 2)
        #expect(entries.map(\.reference) == ["docker.io/n8nio/n8n:2.10.2", "docker.io/library/nginx:alpine"])
    }

    @Test("A registry-qualified reference matches the short form a compose file writes")
    func referenceMatching() {
        // A compose file says `n8nio/n8n:2.10.2`; the runtime stores
        // `docker.io/n8nio/n8n:2.10.2`. Failing to match means re-pulling an
        // image that is already present, on every single run.
        #expect(ContainerRuntimeAdapter.imageReference(
            entries: "docker.io/n8nio/n8n:2.10.2", matches: "n8nio/n8n:2.10.2"))
        #expect(ContainerRuntimeAdapter.imageReference(
            entries: "docker.io/library/nginx:alpine", matches: "nginx:alpine"))
        #expect(ContainerRuntimeAdapter.imageReference(
            entries: "nginx:alpine", matches: "nginx:alpine"))

        #expect(!ContainerRuntimeAdapter.imageReference(
            entries: "docker.io/library/nginx:alpine", matches: "nginx:latest"))
        #expect(!ContainerRuntimeAdapter.imageReference(
            entries: "docker.io/library/postgres:17", matches: "nginx:alpine"))
    }

    @Test("A network list decodes with its labels")
    func networkListDecodes() throws {
        // Labels carry project ownership, which is what teardown uses to tell
        // this project's networks from ones the user made themselves.
        let json = """
            [
              {
                "configuration": {
                  "creationDate": "2026-08-11T13:31:22Z",
                  "labels": { "com.docker.compose.project": "myapp" },
                  "mode": "nat",
                  "name": "myapp_backend"
                },
                "id": "myapp_backend"
              },
              {
                "configuration": { "creationDate": "2026-08-09T03:37:14Z", "labels": {}, "mode": "nat", "name": "default" },
                "id": "default"
              }
            ]
            """
        let data = try #require(json.data(using: .utf8))
        let entries = try JSONDecoder().decode([WireNetworkEntry].self, from: data)

        #expect(entries.map(\.configuration.name) == ["myapp_backend", "default"])
        #expect(entries[0].configuration.labels?["com.docker.compose.project"] == "myapp")
        #expect(entries[1].configuration.labels?.isEmpty == true)
    }

    @Test("A volume list decodes with its labels")
    func volumeListDecodes() throws {
        let json = """
            [
              {
                "configuration": {
                  "driver": "local",
                  "format": "ext4",
                  "labels": { "com.docker.compose.project": "myapp" },
                  "name": "myapp_data",
                  "options": {},
                  "sizeInBytes": 549755813888
                },
                "id": "myapp_data"
              }
            ]
            """
        let data = try #require(json.data(using: .utf8))
        let entries = try JSONDecoder().decode([WireVolumeEntry].self, from: data)

        #expect(entries.map(\.configuration.name) == ["myapp_data"])
        #expect(entries[0].configuration.labels?["com.docker.compose.project"] == "myapp")
    }

    @Test("A list with no labels key still decodes")
    func missingLabelsDecodes() throws {
        // Older payloads omit `labels` entirely rather than sending `{}`.
        // Making it non-optional would fail the whole decode, which — before
        // the fix that motivated this suite — meant silently seeing nothing.
        let json = """
            [{"configuration": {"name": "plain"}, "id": "plain"}]
            """
        let data = try #require(json.data(using: .utf8))

        let networks = try JSONDecoder().decode([WireNetworkEntry].self, from: data)
        #expect(networks[0].configuration.name == "plain")
        #expect(networks[0].configuration.labels == nil)

        let volumes = try JSONDecoder().decode([WireVolumeEntry].self, from: data)
        #expect(volumes[0].configuration.name == "plain")
    }
}
