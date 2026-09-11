//
//  PortEntry.swift
//  PortBar
//

import Foundation

/// One TCP port something is listening on, plus what we know about the process
/// holding it.
///
/// There is exactly one entry per port: `lsof` reports the same port several
/// times (one socket per file descriptor, one per address family), and the
/// scanner collapses those before the UI ever sees them.
struct PortEntry: Identifiable, Equatable, Sendable {
    let port: Int
    let pid: Int32
    /// Executable name as `lsof` reports it — "node", "Code Helper (Plugin)".
    let command: String
    /// Full argv from `ps`, falling back to `command` when `ps` didn't have it.
    let commandLine: String
    /// The process's working directory. `nil` when it's `/` or unreadable —
    /// which carries no information, so it's treated as absent.
    let cwd: String?
    /// Bound to `*` rather than only to loopback, so it's reachable from the LAN.
    let bindsAllInterfaces: Bool
    /// Where this process's stdout goes, and therefore what "view logs" can
    /// actually mean for it.
    let logSource: LogSource
    /// What to call this service. Derived by `ProjectName` from the working
    /// directory's manifests, or replaced with a Docker container name by
    /// `PortMonitor`. **Stored, not computed** — working it out reads files, and
    /// views must not do that.
    let projectName: String?

    var id: Int { port }

    var localURL: URL { URL(string: "http://localhost:\(port)")! }

    /// What the row calls this service, in full. `PortMenu` abbreviates it to
    /// fit — by measured width, not by counting characters, which is why the
    /// shortening lives there and not here.
    var label: String { projectName ?? command }

    /// `3000 · ` — the row's fixed prefix.
    var menuTitlePrefix: String { "\(port) · " }

    /// The submenu's trailing detail, as labelled facts. `PortMenu` draws them
    /// in two columns and prepends the full label above them when the row had
    /// to abbreviate it — which is what lets rows carry no tooltip at all:
    /// nothing the list shortens is hidden behind a hover, it's one keystroke
    /// down the submenu.
    ///
    /// **Every fact is named.** They used to be bare values on their own lines —
    /// `northwind-mobile-app`, `node`, `pid 1621` — and the user couldn't
    /// tell which was the project and which was the process, because only the
    /// pid announced what it was. A run of unlabelled grey words is a list of
    /// answers with the questions missing.
    ///
    /// Each fact is one line: joined, `com.docker.backend · pid 36878 · 0.0.0.0`
    /// is the widest thing in the submenu and forced a mid-word wrap.
    var detailFacts: [(label: String, value: String)] {
        var facts = [(label: "Process", value: command), (label: "PID", value: "\(pid)")]
        if bindsAllInterfaces { facts.append((label: "Binding", value: "0.0.0.0")) }
        return facts
    }


    /// A port published by Docker, whose row label comes from the container
    /// rather than from any directory.
    var isDockerProxy: Bool { logSource == .dockerPort }

    /// A copy relabelled — used to swap in a Docker container name once the
    /// daemon has been asked.
    func withProjectName(_ name: String) -> PortEntry {
        PortEntry(port: port, pid: pid, command: command, commandLine: commandLine,
                  cwd: cwd, bindsAllInterfaces: bindsAllInterfaces,
                  logSource: logSource, projectName: name)
    }
}

// MARK: - Logs

/// What kind of log access a port's process allows. Determined entirely by where
/// its stdout (fd 1) points, which `lsof` reports for free during the scan.
///
/// The cases are not equally good and the UI must not pretend otherwise: two of
/// them stream real output, one can only take you to the window where the output
/// already is, and one is genuinely nothing.
///
/// All of it lives in the row's menu, named in words. Nothing about logs is a
/// glyph or a hover button any more: a glyph that sometimes streamed logs and
/// sometimes raised your editor meant reading its shape to predict a click, and
/// the second case was the one action that could cost you something — raising
/// your dev server's *own* terminal makes it look like a window PortBar opened,
/// and closing that really does kill the server.
enum LogSource: Equatable, Sendable {
    /// stdout is redirected to a regular file. Tailable, no tricks.
    case file(path: String)
    /// A port published by Docker. The listening process is the shared
    /// `com.docker.backend` proxy, so *which* container is resolved on demand
    /// (`docker ps`) rather than in the poll loop — it's a round trip to the
    /// daemon, an order of magnitude slower than the rest of the scan.
    case dockerPort
    /// stdout is a PTY. **The stream is unreachable** — the process writes to the
    /// slave and the terminal emulator reads the master; opening the slave puts
    /// us on the input side, stealing keystrokes rather than capturing output.
    /// Reaching the master needs `task_for_pid` (root + entitlements).
    ///
    /// This used to offer "Reveal in Terminal", raising the window already
    /// showing the output. It was removed for being unreliable in a way the
    /// user couldn't see: it worked only for Terminal.app and iTerm2, which
    /// expose a tty per tab. Everything else fell back to activating the owning
    /// app — so for a server in VS Code's integrated terminal it brought VS Code
    /// forward *without* selecting the tab, and if VS Code was already frontmost
    /// it looked like the button did nothing at all. A silent partial failure is
    /// worse than no button.
    case terminal(tty: String)
    /// `/dev/null`, or a pipe into a process we can't follow. Nothing exists to
    /// show, and no amount of privilege would change that.
    case unavailable

    /// Always the same words. The unavailable cases used to say why — *Logs in
    /// Another Terminal*, *No Logs Available* — and a disabled noun phrase in a
    /// menu is ambiguous: it reads equally as a section header for the item
    /// below it, a dead action, or a status. One verb phrase, greyed out when it
    /// can't be picked, is the standard macOS idiom (a greyed *Paste*) and can't
    /// be misread. The distinction between the cases is real but belongs in this
    /// file's documentation, not in the menu.
    var actionTitle: String { "View Logs" }

    /// Whether the item does anything when picked.
    var canShow: Bool {
        switch self {
        case .file, .dockerPort: true
        case .terminal, .unavailable: false
        }
    }
}

// MARK: - Which glyph?

extension PortEntry {
    /// Asset-catalog name of a monochrome brand glyph for this process, or
    /// `nil` for "we don't have one" (the row then shows a generic terminal
    /// symbol). Glyphs are Simple Icons (CC0), stored as template SVGs so they
    /// tint like everything else in the list.
    ///
    /// Docker rows get the whale regardless of what's inside the container —
    /// the process is the shared proxy, and the container *name* already says
    /// what it is. Mapping the image to a glyph is a possible refinement.
    var iconName: String? {
        if isDockerProxy { return "docker" }
        // Frameworks first: `lsof` reports the *interpreter* — a Next, Vite,
        // Astro, Django or Rails server is all just "node"/"python3"/"ruby" to
        // it — so the only place the framework survives is the argv.
        if Self.interpreters.contains(commandKey), let framework = frameworkIcon {
            return framework
        }
        return Self.icons[commandKey]
    }

    /// Runtimes that run someone else's code, and so say nothing on their own.
    private static let interpreters: Set<String> = [
        "node", "bun", "deno", "python", "python2", "python3", "ruby", "java",
    ]

    /// Matches the argv against distinctive path fragments. Ordered, because
    /// the specific has to beat the general: a Next project's argv mentions
    /// webpack, and half of them mention react.
    private var frameworkIcon: String? {
        let argv = commandLine.lowercased()
        for (marker, icon) in Self.frameworkMarkers where argv.contains(marker) {
            return icon
        }
        return nil
    }

    private static let frameworkMarkers: [(String, String)] = [
        // JavaScript — matched on package paths, which are stable across
        // npm/pnpm/yarn layouts, rather than on bare words that appear in any
        // long path.
        ("next-server", "nextdotjs"), ("/next/dist", "nextdotjs"), ("/.bin/next", "nextdotjs"),
        ("/nuxt", "nuxt"), ("nuxt@", "nuxt"),
        ("/astro", "astro"), ("astro@", "astro"),
        ("/.bin/expo", "expo"), ("/expo/", "expo"), ("expo-cli", "expo"),
        ("/remix", "remix"), ("remix@", "remix"),
        ("@sveltejs", "svelte"), ("sveltekit", "svelte"), ("/svelte", "svelte"),
        ("@angular", "angular"), ("/.bin/ng", "angular"),
        ("react-scripts", "react"),
        ("/vitest", "vitest"), ("vitest@", "vitest"),
        ("/vite", "vite"), ("vite@", "vite"),
        ("storybook", "storybook"),
        ("/strapi", "strapi"), ("/n8n", "n8n"),
        ("/webpack", "webpack"),
        ("/nx/", "nx"), ("/pm2", "pm2"),
        ("/metro", "nodedotjs"),
        // Python
        ("manage.py", "django"), ("django", "django"),
        ("streamlit", "streamlit"), ("jupyter", "jupyter"),
        ("uvicorn", "fastapi"), ("fastapi", "fastapi"),
        ("gunicorn", "gunicorn"), ("flask", "flask"),
        // Ruby
        ("rails", "rubyonrails"), ("puma", "rubyonrails"),
        // Java
        ("gradle", "gradle"), ("maven", "apachemaven"), ("spring", "spring"),
    ]

    private static let icons: [String: String] = {
        var map: [String: String] = [:]
        func set(_ icon: String, _ keys: String...) { for k in keys { map[k] = icon } }
        set("nodedotjs", "node", "npm", "pnpm", "yarn", "tsx", "ts-node", "esbuild",
            "webpack", "next-server", "nuxt", "turbo", "metro", "ng")
        set("bun", "bun")
        set("deno", "deno")
        set("python", "python", "python2", "python3", "uvicorn", "gunicorn", "hypercorn",
            "flask", "django", "streamlit", "jupyter", "jupyter-lab", "uv", "poetry")
        set("ruby", "ruby", "rails", "puma", "unicorn", "bundle")
        set("php", "php", "php-fpm")
        set("openjdk", "java", "gradle", "mvn")
        set("go", "go", "air")
        set("rust", "cargo", "rustc")
        set("elixir", "elixir", "beam.smp")
        set("flutter", "flutter")
        set("swift", "swift", "swift-frontend")
        set("dotnet", "dotnet")
        set("android", "adb")
        set("docker", "docker", "com.docker.backend", "containerd", "colima")
        set("podman", "podman")
        set("postgresql", "postgres")
        set("mysql", "mysqld")
        set("mariadb", "mariadbd")
        set("redis", "redis-server", "valkey-server")
        set("mongodb", "mongod")
        set("sqlite", "sqlite", "sqlite3")
        set("elasticsearch", "elasticsearch")
        set("rabbitmq", "rabbitmq", "rabbitmq-server")
        set("apachekafka", "kafka")
        set("minio", "minio")
        set("meilisearch", "meilisearch")
        set("grafana", "grafana", "grafana-server")
        set("prometheus", "prometheus")
        set("keycloak", "keycloak")
        set("temporal", "temporal")
        set("supabase", "supabase")
        set("firebase", "firebase")
        set("tailscale", "tailscaled", "tailscale")
        set("qemu", "qemu", "qemu-system-aarch64", "qemu-system-x86_64")
        set("erlang", "erl")
        set("dart", "dart")
        set("laravel", "artisan")
        set("ollama", "ollama")
        set("cloudflare", "cloudflared")
        set("nginx", "nginx")
        set("caddy", "caddy")
        set("ngrok", "ngrok")
        return map
    }()
}

// MARK: - Is this a web thing?

extension PortEntry {
    /// Whether `http://localhost:<port>` is a sensible thing to open. A browser
    /// pointed at Postgres, Redis or `adb` produces nothing but a confused
    /// error page, so those rows offer "Copy Address" instead and don't react
    /// to a click.
    ///
    /// This is a known-list heuristic, not detection: a real answer needs an
    /// HTTP probe, which is deliberately not in the poll loop. Unknown means web,
    /// because a dev server running something unrecognised is the common case
    /// and a wrong "not web" is the more annoying mistake.
    var isLikelyWeb: Bool {
        !Self.nonWebCommands.contains(commandKey) && !Self.nonWebPorts.contains(port)
    }

    /// `localhost:5432` for a database client, `http://localhost:3000` for a
    /// browser — whichever the row actually is.
    var address: String {
        isLikelyWeb ? localURL.absoluteString : "localhost:\(port)"
    }

    private static let nonWebCommands: Set<String> = [
        "postgres", "mysqld", "mariadbd", "redis-server", "valkey-server",
        "mongod", "memcached", "adb", "sshd", "rabbitmq", "beam.smp", "kafka",
        "clickhouse", "zookeeper", "nats-server",
    ]

    /// Mostly for Docker rows, where the process is the shared proxy and tells
    /// us nothing — the port number is the only hint left.
    private static let nonWebPorts: Set<Int> = [
        22, 25, 465, 587, 1025,            // ssh, smtp (1025 is MailHog's smtp)
        1433, 1521, 3306, 5432, 5433, 6432, 26257,  // sql databases and pgbouncer
        6379, 11211, 27017, 9042,          // redis, memcached, mongo, cassandra
        5672, 9092, 2181, 4222,            // amqp, kafka, zookeeper, nats
        2049, 3389, 5900,                  // nfs, rdp, vnc
    ]
}

// MARK: - Is this something I started?

extension PortEntry {
    /// Whether this looks like a service the user (or an agent acting for them)
    /// started, as opposed to one of the dozen macOS daemons that also sit on
    /// TCP ports — rapportd, ControlCenter, sharingd.
    ///
    /// Two positive signals: a recognised runtime, or a working directory
    /// somewhere under `$HOME`. Anything launched from a repo has the second
    /// one, which is what makes this work for tools we've never heard of.
    var isDev: Bool {
        let key = commandKey
        if Self.neverDev.contains(key) || key.contains("helper") { return false }
        if Self.devCommands.contains(key) { return true }
        if let cwd, cwd != Self.home, cwd.hasPrefix(Self.home + "/") { return true }
        return false
    }

    /// Sort key for "group by what this thing is" (`SortOrder.technology`).
    ///
    /// Rows that share a glyph sort together, which is the whole point — all
    /// your Node servers in one run, all your containers in another. Anything
    /// we have no glyph for groups by its own command name and sorts *after*
    /// everything recognised: pooling every unknown process under one heading
    /// would put a Postgres and a Java daemon side by side for no reason, and
    /// the unrecognised ones are the least interesting rows anyway.
    var technologyKey: (Int, String) {
        if let iconName { return (0, iconName) }
        return (1, commandKey)
    }

    /// Lowercased first word of the command — `lsof` sometimes appends
    /// parenthesised detail ("Code Helper (Plugin)").
    fileprivate var commandKey: String {
        (command.split(separator: " ").first.map(String.init) ?? command).lowercased()
    }

    private static let home = NSHomeDirectory()

    /// Runtimes and dev-facing daemons. Being on this list is enough on its own,
    /// because plenty of them legitimately run with no useful cwd (Docker, a
    /// globally installed database).
    private static let devCommands: Set<String> = [
        "node", "bun", "deno", "npm", "pnpm", "yarn", "tsx", "ts-node", "esbuild",
        "vite", "webpack", "next-server", "nuxt", "turbo", "metro", "expo", "ng",
        "python", "python2", "python3", "uvicorn", "gunicorn", "hypercorn",
        "flask", "django", "streamlit", "jupyter", "jupyter-lab", "uv", "poetry",
        "ruby", "rails", "puma", "unicorn", "bundle", "php", "php-fpm",
        "java", "gradle", "mvn", "dotnet", "go", "air", "cargo", "rustc",
        "elixir", "beam.smp", "erl", "dart", "flutter", "swift", "swift-frontend",
        "nginx", "httpd", "caddy", "traefik", "ngrok", "cloudflared", "tailscaled",
        "docker", "com.docker.backend", "containerd", "colima", "podman", "qemu",
        "postgres", "mysqld", "mariadbd", "redis-server", "valkey-server", "mongod",
        "memcached", "elasticsearch", "clickhouse", "minio", "rabbitmq", "kafka",
        "ollama", "llama-server", "lm-studio", "vllm",
        "anvil", "hardhat", "wrangler", "supabase", "firebase", "mailhog",
        "localstack", "http-server", "serve", "live-server", "browser-sync",
    ]

    /// Beats the working-directory signal. Editor and browser helper processes
    /// inherit the project's cwd, but the ports they hold are internal plumbing
    /// you would never open or stop.
    private static let neverDev: Set<String> = [
        "code", "cursor", "electron", "chrome", "google", "safari", "firefox",
        "slack", "spotify", "zoom.us", "figma", "figma_agent", "rapportd",
        "controlce", "controlcenter", "sharingd", "identityservicesd", "launchd",
    ]
}
