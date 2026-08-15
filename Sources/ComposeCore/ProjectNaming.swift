//
//  ProjectNaming.swift
//  container-compose
//
//  Every name this tool derives from a project and a service, in one
//  place, because the rules are not guessable and getting one wrong is
//  silent.
//
//  The rule that keeps biting is lowercasing. Apple's runtime rejects an
//  uppercase network name outright ("invalid network name"), so a derived
//  network has to be lowercased — while a volume does not, and an
//  explicit `name:` must be left exactly as the user wrote it. That is
//  three different answers to "do I lowercase this", and it was
//  previously spelled out at each call site.
//
//  It has already gone wrong twice. A project named `MyApp` failed at
//  network-create time with nothing pointing at the cause. Later, the
//  live test teardown reimplemented `"\(project)_default"` without the
//  lowercasing, so it deleted a name that had never existed and leaked a
//  network per test — silently, until the accumulated pile stopped the
//  daemon from starting.
//
//  Tests use these too. A test that derives a name by hand is not testing
//  the same string the product builds.
//

import Foundation

public enum ProjectNaming {
    /// The network a project gets when its compose file names none.
    ///
    /// Lowercased: the runtime rejects uppercase network names.
    public static func defaultNetworkName(project: String) -> String {
        "\(project)_default".lowercased()
    }

    /// A network the compose file declared, scoped to the project.
    ///
    /// Lowercased for the same reason. `external` networks and any with an
    /// explicit `name:` are the user's own and are returned untouched —
    /// silently renaming one would attach the project to a different
    /// network than the one asked for.
    public static func networkName(project: String, declared: String, explicit: String? = nil, external: Bool = false) -> String {
        if let explicit { return explicit }
        if external { return declared }
        return "\(project)_\(declared)".lowercased()
    }

    /// A volume the compose file declared, scoped to the project.
    ///
    /// NOT lowercased, unlike networks: the runtime accepts a mixed-case
    /// volume name, and lowercasing would rename volumes that already
    /// exist on disk under their original casing — losing the data by
    /// pointing at a volume nobody has written to.
    public static func volumeName(project: String, declared: String, explicit: String? = nil, external: Bool = false) -> String {
        if let explicit { return explicit }
        if external { return declared }
        return "\(project)_\(declared)"
    }

    /// A service's container. Case-preserving: this is also the name the
    /// runtime registers in DNS, and the reconciler looks containers up by
    /// it, so it must match what `create` was given exactly.
    public static func containerName(project: String, service: String) -> String {
        "\(project)-\(service)"
    }

    /// The tag `build:` produces when the service names no image.
    ///
    /// Lowercased: an image reference may not contain uppercase, so a
    /// project or service with a capital letter would produce a tag the
    /// runtime refuses.
    public static func buildTag(project: String, service: String) -> String {
        "\(project.lowercased())/\(service.lowercased()):latest"
    }
}
