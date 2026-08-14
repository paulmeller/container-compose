//
//  VolumeNamespacingTests.swift
//  container-compose
//
//  A service's `volumes:` list holds compose-file keys, while a declared
//  volume is namespaced per project (`data` -> `proj_data`). Passing the raw
//  key through meant the runtime created ONE global `data` shared by every
//  project that happened to use that name — and since generic names like
//  `db-data` are near-universal, two unrelated projects would collide. The
//  second project does not merely share the data: it fails to start at all,
//  with an opaque virtualization error naming neither volumes nor the other
//  project.
//
//  The delicate part is what must NOT be rewritten: bind mounts are host
//  paths, not names, and an external volume is one the user named exactly.
//

import Testing
import Foundation
import ComposeCore
import ComposeTestSupport
@testable import ComposeEngine

@Suite("Volume namespacing")
struct VolumeNamespacingTests {

    private func plan(_ document: String, projectName: String = "proj") throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: projectName)
        )
    }

    @Test("A declared volume is referenced by its namespaced name, not its compose key")
    func declaredVolumeIsNamespaced() throws {
        let result = try plan("""
            volumes:
              data: {}
            services:
              web:
                image: nginx
                volumes:
                  - data:/var/lib/data
            """)
        let web = try #require(result.service(named: "web"))
        #expect(web.volumes == ["proj_data:/var/lib/data"])

        // What the service asks for must be what the project declares.
        let declared = try #require(result.volumes.first)
        #expect(declared.resolvedName == "proj_data")
    }

    @Test("Two projects declaring the same volume name resolve to different volumes")
    func sameNameDifferentProjectsDoNotCollide() throws {
        let document = """
            volumes:
              db-data: {}
            services:
              db:
                image: postgres
                volumes:
                  - db-data:/var/lib/postgresql/data
            """
        let one = try plan(document, projectName: "appone")
        let two = try plan(document, projectName: "apptwo")

        let dbOne = try #require(one.service(named: "db"))
        let dbTwo = try #require(two.service(named: "db"))
        #expect(dbOne.volumes == ["appone_db-data:/var/lib/postgresql/data"])
        #expect(dbTwo.volumes == ["apptwo_db-data:/var/lib/postgresql/data"])
        #expect(dbOne.volumes != dbTwo.volumes)
    }

    @Test("An external volume keeps the exact name the user gave it")
    func externalVolumeIsNotNamespaced() throws {
        let result = try plan("""
            volumes:
              shared:
                external: true
              renamed:
                external: true
                name: my-actual-volume
            services:
              web:
                image: nginx
                volumes:
                  - shared:/a
                  - renamed:/b
            """)
        let web = try #require(result.service(named: "web"))
        #expect(web.volumes == ["shared:/a", "my-actual-volume:/b"])
    }

    @Test("Bind mounts are host paths and are never rewritten")
    func bindMountsAreUntouched() throws {
        let result = try plan("""
            volumes:
              data: {}
            services:
              web:
                image: nginx
                volumes:
                  - ./site:/usr/share/nginx/html
                  - /etc/localtime:/etc/localtime:ro
                  - ../shared:/shared
                  - data:/var/lib/data
            """)
        let web = try #require(result.service(named: "web"))
        #expect(web.volumes == [
            "./site:/usr/share/nginx/html",
            "/etc/localtime:/etc/localtime:ro",
            "../shared:/shared",
            "proj_data:/var/lib/data",
        ])
    }

    @Test("A named volume never declared at the top level is left alone")
    func undeclaredNamedVolumeIsUntouched() throws {
        // Compose allows an undeclared name; namespacing it would invent a
        // volume the user never asked for, under a name they cannot predict.
        let result = try plan("""
            services:
              web:
                image: nginx
                volumes:
                  - loose:/data
            """)
        let web = try #require(result.service(named: "web"))
        #expect(web.volumes == ["loose:/data"])
    }

    @Test("Mount options after the container path survive namespacing")
    func mountOptionsArePreserved() throws {
        let result = try plan("""
            volumes:
              data: {}
            services:
              web:
                image: nginx
                volumes:
                  - data:/var/lib/data:ro
            """)
        let web = try #require(result.service(named: "web"))
        #expect(web.volumes == ["proj_data:/var/lib/data:ro"])
    }
}
