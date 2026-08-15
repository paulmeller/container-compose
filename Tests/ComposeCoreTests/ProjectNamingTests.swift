//
//  ProjectNamingTests.swift
//  container-compose
//
//  These pin the answers to "do I lowercase this", because the answer
//  differs per resource and both wrong answers are silent.
//
//  Lowercasing a network is required — the runtime rejects an uppercase
//  one. Lowercasing a volume would be wrong — it would point at a volume
//  nobody has written to, losing the data in the one that exists. And a
//  name the user wrote explicitly must survive untouched either way.
//

import Testing
@testable import ComposeCore

@Suite("Derived project names")
struct ProjectNamingTests {
    @Test("A derived network name is lowercased, because the runtime rejects uppercase")
    func networksAreLowercased() {
        // A project named from a directory called `MyApp`, or given by
        // `--project MyApp`, previously failed at create time with
        // "invalid network name" and nothing pointing at the cause.
        #expect(ProjectNaming.defaultNetworkName(project: "MyApp") == "myapp_default")
        #expect(ProjectNaming.networkName(project: "MyApp", declared: "Backend") == "myapp_backend")
    }

    @Test("A derived volume name keeps its case, because renaming one loses the data")
    func volumesKeepCase() {
        // The asymmetry with networks is deliberate, and is why these
        // cannot share one implementation: lowercasing here would point a
        // project at a volume that does not exist, silently starting it
        // with an empty disk instead of the one holding its data.
        #expect(ProjectNaming.volumeName(project: "MyApp", declared: "DbData") == "MyApp_DbData")
    }

    @Test("An explicit name is never rewritten, for either resource")
    func explicitNamesSurvive() {
        // The user named a specific network or volume. Renaming it would
        // silently attach the project to something other than what they
        // asked for.
        #expect(ProjectNaming.networkName(project: "MyApp", declared: "net", explicit: "Shared-Net") == "Shared-Net")
        #expect(ProjectNaming.volumeName(project: "MyApp", declared: "vol", explicit: "Shared-Vol") == "Shared-Vol")
    }

    @Test("An external resource keeps the name it was declared with")
    func externalNamesSurvive() {
        // External means "someone else made this"; scoping it to the
        // project would look for one that was never created.
        #expect(ProjectNaming.networkName(project: "MyApp", declared: "Shared", external: true) == "Shared")
        #expect(ProjectNaming.volumeName(project: "MyApp", declared: "Shared", external: true) == "Shared")
    }

    @Test("A container name keeps its case, because it is looked up by it")
    func containerNamesKeepCase() {
        // This is also the name the runtime registers in DNS, and the
        // reconciler finds containers by it — it has to match what
        // `create` was given, exactly.
        #expect(ProjectNaming.containerName(project: "MyApp", service: "Web") == "MyApp-Web")
    }

    @Test("A build tag is lowercased, because an image reference may not contain uppercase")
    func buildTagsAreLowercased() {
        #expect(ProjectNaming.buildTag(project: "MyApp", service: "Web") == "myapp/web:latest")
    }

    @Test("The default network name is what a project's teardown must delete")
    func teardownMatchesCreation() {
        // The live suite reimplemented this string without the
        // lowercasing and leaked a network per test — deleting a name
        // that had never existed, silently, because the failure was
        // swallowed. Anything deriving this name must call this function.
        let project = "cc-live-32C9967A"
        #expect(ProjectNaming.defaultNetworkName(project: project) == "cc-live-32c9967a_default")
    }
}
