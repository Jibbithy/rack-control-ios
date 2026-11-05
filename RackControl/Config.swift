import Foundation

enum Config {
    /// Resolves for anyone; routes for nobody off the tailnet. A failure to
    /// reach it is therefore "Tailscale is off", not "the hub is down" - which
    /// is why HubError separates .unreachable from .unauthorized.
    static let baseURL = URL(string: "https://example.com")!

    /// The rack, mirroring `web/nodes.js`'s NODE_DEFS.
    ///
    /// THIS DRIFTED, AND THE DRIFT WAS INVISIBLE. It used to be a bare array of
    /// four names, and iris - deployed as the fifth node on 2026-09-02 - was
    /// never added. Nothing failed: the Rack tab simply rendered four machines
    /// and the fifth did not exist as far as the phone was concerned, which
    /// looks exactly like a rack that has four machines. There is no endpoint
    /// that lists these, so the list is hardcoded on both sides and the only
    /// defence is that this file now carries the same FIELDS as nodes.js and
    /// can be diffed against it by eye.
    ///
    /// `ru` and `role` exist so a card can say what a machine IS. The web has
    /// said that since the rack column was built; the app showed a bare
    /// hostname, which tells you nothing about the box you are about to
    /// restart something on.
    struct NodeDef: Identifiable, Hashable {
        let id: String
        let ru: String
        let role: String
        /// The node has Docker AND the rackctl forced command. atlas and talos
        /// have no Docker at all - a panel that showed an empty container list
        /// for them would read as "nothing running", which is a different
        /// claim from "this machine does not do containers".
        let docker: Bool
        /// `false` means the platform has no thermal sensor at all, which is
        /// different from a sensor reading zero. iris returns a literal `[]`
        /// from /api/4/sensors: psutil has no sensors_temperatures() on macOS.
        let temps: Bool
    }

    static let nodeDefs: [NodeDef] = [
        .init(
            id: "atlas", ru: "NODE 0 · 3U", role: "The NAS · Ubuntu 24.04 · hub",
            docker: true, temps: true),
        .init(
            id: "calypso", ru: "NODE 1 · 1U", role: "Thin client · Ubuntu 24.04",
            docker: true, temps: true),
        .init(
            id: "hermes", ru: "NODE 2 · 1U", role: "Thin client · Ubuntu 24.04 · agent host",
            docker: true, temps: true),
        .init(
            id: "talos", ru: "NODE Pi · 1U", role: "Raspberry Pi · Debian 13",
            docker: false, temps: true),
        .init(
            id: "iris", ru: "NODE Mac · 1U", role: "Mac mini M1 · macOS 26 · iOS build node",
            docker: false, temps: false),
    ]

    static let nodes = nodeDefs.map(\.id)

    static func def(_ id: String) -> NodeDef? { nodeDefs.first { $0.id == id } }

    /// atlas carries the storage pool; every other node's interesting mount is
    /// just its root filesystem.
    static func poolMount(for node: String) -> String {
        node == "atlas" ? "/srv/data" : "/"
    }

    /// The hub's files.js allows exactly two roots, /srv/data and
    /// /srv/rack-control, and refuses anything else - so "all the files on the
    /// server" means the storage pool, not /.
    static let filesRoot = "/srv/data"
    static let vaultRoot = "/srv/data/vault"
}
