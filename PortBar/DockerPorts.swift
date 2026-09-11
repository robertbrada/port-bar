//
//  DockerPorts.swift
//  PortBar
//

import Foundation

/// Maps a published host port to the container behind it, so a row can say
/// `northwind-customer-dashboard-db` instead of `com.docker.backend`.
///
/// Every container's published port is held by the same shared proxy process, so
/// the port *is* the only thing that identifies which container it belongs to —
/// `lsof` and `ps` can't help here at all.
///
/// An actor because the cache is shared mutable state and scans can overlap: the
/// poll loop and a stop-triggered refresh both call in.
actor DockerPorts {
    static let shared = DockerPorts()

    /// A GUI app inherits none of the shell's `PATH`, so the CLI has to be found
    /// by hand. Also used by `LogViewer`.
    nonisolated static let cliPath: String? = {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
         NSHomeDirectory() + "/.docker/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private var names: [Int: String] = [:]
    private var lastFetch = Date.distantPast

    /// `docker ps` costs about as much as the whole port scan (~46ms measured),
    /// and the scan runs every 2s — so this is cached, not because it's slow but
    /// because container names barely ever change.
    private static let ttl: TimeInterval = 30
    /// A floor for the "a port I don't recognise appeared" refetch. Without it,
    /// a published port the daemon doesn't know about would re-run `docker ps`
    /// on *every* scan, forever.
    private static let refetchFloor: TimeInterval = 3

    func names(forPorts ports: Set<Int>) -> [Int: String] {
        guard Self.cliPath != nil else { return [:] }
        let age = Date().timeIntervalSince(lastFetch)
        let hasUnknown = !ports.isSubset(of: Set(names.keys))
        if age > Self.ttl || (hasUnknown && age > Self.refetchFloor) { fetch() }
        return names
    }

    private func fetch() {
        guard let cli = Self.cliPath else { return }
        lastFetch = Date()
        let output = Shell.run(cli, ["ps", "--format", "{{.Names}}\t{{.Ports}}"])

        var found: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            // "0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp" — the host port is
            // the one before the arrow, and a container usually lists the same
            // one twice (IPv4 and IPv6).
            for mapping in fields[1].split(separator: ",") {
                guard let arrow = mapping.range(of: "->") else { continue }
                let host = mapping[..<arrow.lowerBound]
                guard let colon = host.lastIndex(of: ":"),
                      let port = Int(host[host.index(after: colon)...])
                else { continue }
                found[port] = String(fields[0])
            }
        }
        names = found
    }
}
