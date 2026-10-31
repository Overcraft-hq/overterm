import Foundation
import XCTest

@testable import Overterm

/// What an agent is told about a container that failed, or lines of its
/// log: what is wrong with it, what its exit code means, how it ended —
/// and that no secret is in any of it. Pure.
final class DockerAgentTextTests: XCTestCase {
    private func summary(
        _ name: String = "shop-worker-1", state: String, status: String, health: String? = nil, project: String? = "shop",
        service: String? = "worker", image: String = "node:22"
    ) -> ContainerSummary {
        var labels: [String: String] = [:]
        if let project {
            labels["com.docker.compose.project"] = project
            labels["com.docker.compose.service"] = service ?? name
            labels["com.docker.compose.project.config_files"] = "/w/\(project)/compose.yaml"
            labels["com.docker.compose.project.working_dir"] = "/w/\(project)"
        }
        return ContainerSummary(
            Id: name + "-0123456789", Names: ["/" + name], Image: image, Created: 1, Ports: [], Labels: labels, State: state, Status: status,
            Health: health.map { .init(Status: $0, FailingStreak: 0) })
    }

    private func detail(
        of container: ContainerSummary, oom: Bool = false, exit: Int? = nil, error: String? = nil, env: [String] = [], restarts: Int = 0,
        policy: String = "no", memory: Int = 0, health: ContainerDetail.Health? = nil, check: [String]? = nil, cmd: [String] = ["node", "server.js"],
        bindings: [String: [ContainerDetail.HostConfigDetail.PortBinding]?]? = nil
    ) -> ContainerDetail {
        ContainerDetail(
            Id: container.Id, Name: "/" + container.name, RestartCount: restarts,
            State: .init(Status: container.State, OOMKilled: oom, ExitCode: exit, Error: error, FinishedAt: "2026-10-29T10:00:00Z", Health: health),
            Config: .init(
                Image: container.Image, Env: env, Cmd: cmd, WorkingDir: "/app", ExposedPorts: ["3000/tcp": EmptyObject(), "9229/tcp": EmptyObject()],
                Healthcheck: check.map { .init(Test: $0, Interval: 30_000_000_000, Timeout: 5_000_000_000, Retries: 3) }),
            HostConfig: .init(
                RestartPolicy: .init(Name: policy, MaximumRetryCount: policy == "on-failure" ? 5 : 0), Memory: memory, PortBindings: bindings),
            Mounts: [DockerMountPoint(Type: "bind", Source: "/w/shop", Destination: "/app", RW: false)],
            NetworkSettings: .init(Networks: ["shop_default": .init(IPAddress: "172.18.0.3")]))
    }

    func testTroubleIsWhatTheListPaintsRed() {
        typealias T = DockerAttention
        XCTAssertEqual(T.trouble(of: summary(state: "exited", status: "Exited (1) 3 seconds ago")), .exited(1))
        XCTAssertNil(T.trouble(of: summary(state: "exited", status: "Exited (0) 3 seconds ago")), "a container done with its work")
        XCTAssertEqual(T.trouble(of: summary(state: "running", status: "Up 2 minutes (unhealthy)")), .unhealthy)
        XCTAssertNil(T.trouble(of: summary(state: "running", status: "Up 2 minutes (healthy)")))
        XCTAssertEqual(T.trouble(of: summary(state: "restarting", status: "Restarting (1) 5 seconds ago")), .restarting(exit: 1))
        XCTAssertEqual(T.trouble(of: summary(state: "dead", status: "Dead")), .dead)
        let created = summary(state: "created", status: "Created")
        XCTAssertEqual(
            T.trouble(of: created, detail: detail(of: created, error: "Bind for 0.0.0.0:3000 failed: port is already allocated")),
            .didNotStart("Bind for 0.0.0.0:3000 failed: port is already allocated"))
        XCTAssertNil(T.trouble(of: created), "created and nothing said is a container not started yet")
        let killed = summary(state: "exited", status: "Exited (137) 3 seconds ago")
        XCTAssertEqual(T.trouble(of: killed, detail: detail(of: killed, oom: true, exit: 137)), .outOfMemory, "only inspect says it")
        XCTAssertEqual(T.trouble(of: killed, detail: detail(of: killed, exit: 137)), .exited(137))
        XCTAssertEqual(
            T.trouble(of: killed, detail: detail(of: summary("other", state: "exited", status: ""), oom: true)), .exited(137),
            "another container's inspect says nothing of this one")
        let stale = summary(state: "exited", status: "Exited (1) 3 seconds ago", health: "unhealthy")
        XCTAssertEqual(T.trouble(of: stale), .exited(1), "an exit's health is the one before it")
    }

    func testQuestionsAndDetails() {
        let cases: [(DockerAttention.Trouble, String, String)] = [
            (.outOfMemory, "Why did w run out of memory?", "ran out of memory"),
            (.restarting(exit: 1), "Why does w keep restarting?", "keeps restarting"),
            (.dead, "Why is w dead?", "is dead"),
            (.exited(137), "Why did w exit with code 137?", "exited (137)"),
            (.unhealthy, "Why is w unhealthy?", "is unhealthy"),
            (.didNotStart("port taken"), "Why didn't w start?", "didn't start"),
        ]
        for (trouble, question, detail) in cases {
            XCTAssertEqual(trouble.question("w"), question)
            XCTAssertEqual(trouble.detail, detail)
        }
    }

    func testExitMeanings() {
        let killed = DockerAgentText.exitMeaning(137)
        XCTAssertTrue(killed?.contains("SIGKILL") == true, killed ?? "nil")
        XCTAssertTrue(killed?.contains("not by the kernel") == true, "137 without OOMKilled is someone's kill")
        XCTAssertEqual(DockerAgentText.exitMeaning(137, outOfMemory: true), "killed by signal 9 (SIGKILL)")
        XCTAssertTrue(DockerAgentText.exitMeaning(143)?.contains("SIGTERM") == true)
        XCTAssertTrue(DockerAgentText.exitMeaning(139)?.contains("SIGSEGV") == true)
        XCTAssertTrue(DockerAgentText.exitMeaning(127)?.contains("wasn't found") == true)
        XCTAssertTrue(DockerAgentText.exitMeaning(126)?.contains("not executable") == true)
        XCTAssertNil(DockerAgentText.exitMeaning(1))
        XCTAssertNil(DockerAgentText.exitMeaning(0))
    }

    func testAboutSaysHowItEnded() {
        let worker = summary(state: "exited", status: "Exited (137) 3 seconds ago")
        let db = summary("shop-db-1", state: "running", status: "Up 2 minutes (healthy)", service: "db")
        let project = ComposeProject(
            name: "shop", workingDir: "/w/shop", configFiles: ["/w/shop/compose.yaml"],
            services: [
                ComposeService(project: "shop", name: "db", containers: [db], dependsOn: []),
                ComposeService(project: "shop", name: "worker", containers: [worker], dependsOn: ["db"]),
            ])
        let probe = ContainerDetail.Health.Probe(ExitCode: 1, Output: "curl: token s3cr3t-value refused\n")
        let inspect = detail(
            of: worker, oom: true, exit: 137, env: ["API_TOKEN=s3cr3t-value", "DATABASE_URL=postgres://app:hunter2@db/app", "PORT=80"], restarts: 3,
            policy: "on-failure", memory: 256 << 20, health: .init(Status: "unhealthy", FailingStreak: 3, Log: [probe]),
            check: ["CMD-SHELL", "curl -f http://localhost:3000/"])
        let text = DockerAgentText.about(
            worker, inspect, trouble: .outOfMemory, ports: [PublishedPort(hostPort: 3000, containerPort: 3000, proto: "tcp")], project: project,
            engine: "Docker Desktop", memoryTotal: 8 << 30)
        for said in [
            "Container shop-worker-1 — compose project shop, service worker", "Image: node:22", "State: exited (137) at 2026-10-29T10:00:00Z",
            "Exit 137: killed by signal 9 (SIGKILL).", "Out of memory", "Memory limit 256 MB", "Restarts: 3 (restart policy on-failure, at most 5)",
            "Health: 3 failed checks in a row before it stopped", "Health check: CMD-SHELL curl -f http://localhost:3000/ (every 30s, timeout 5s, 3 retries)",
            "Last check (exit 1): curl: token •••••• refused", "Command: node server.js", "Ports: localhost:3000→3000",
            "Exposed, not published: 9229/tcp", "Mounts: /w/shop → /app (read-only)", "Networks: shop_default (172.18.0.3)", "Waits for: db",
            "Other services: db Up 2 minutes (healthy)", "Compose files: /w/shop/compose.yaml — run in /w/shop", "Engine: Docker Desktop",
            "API_TOKEN=••••••", "postgres://app:••••••@db/app", "PORT=80",
        ] {
            XCTAssertTrue(text.contains(said), "\(said)\n\(text)")
        }
        XCTAssertFalse(text.contains("s3cr3t-value"), text)
        XCTAssertFalse(text.contains("hunter2"), text)
        XCTAssertFalse(text.contains("not by the kernel"), "the kernel did kill it")

        let unlimited = DockerAgentText.about(
            worker, detail(of: worker, oom: true, exit: 137), trouble: .outOfMemory, ports: [], project: nil, engine: "OrbStack", memoryTotal: 8 << 30,
            logs: 0)
        XCTAssertTrue(unlimited.contains("No memory limit of its own; the engine has 8 GB."), unlimited)
        XCTAssertTrue(unlimited.contains("Compose files: /w/shop/compose.yaml"), "from its labels without the project: \(unlimited)")
        XCTAssertTrue(unlimited.contains("It wrote no log lines."), unlimited)
    }

    func testLogsAreBoundedAndScrubbed() throws {
        let lines = (0..<200).map { DockerLogLine.parse("line \($0) " + String(repeating: "x", count: 100), stream: .stdout, timestamps: false) }
        let logs = try XCTUnwrap(DockerAgentText.logs(lines, env: []))
        XCTAssertTrue(logs.text.hasPrefix("Its last \(logs.count) log lines (newest last, secrets taken out):\n… earlier lines left out\n"), String(logs.text.prefix(120)))
        XCTAssertLessThan(logs.count, 200)
        XCTAssertLessThanOrEqual(logs.text.utf8.count, DockerAgentText.maxLogBytes + 200)
        XCTAssertTrue(logs.text.hasSuffix("line 199 " + String(repeating: "x", count: 100)), "the newest last")
        XCTAssertFalse(logs.text.contains("line 0 "))

        let secret = [DockerLogLine.parse("auth s3cr3t-value against postgres://app:hunter2@db/app", stream: .stderr, timestamps: false)]
        let scrubbed = try XCTUnwrap(DockerAgentText.logs(secret, env: [(key: "API_TOKEN", value: "s3cr3t-value")]))
        XCTAssertEqual(scrubbed.text, "Its last 1 log line (newest last, secrets taken out):\nauth •••••• against postgres://app:••••••@db/app")
        XCTAssertNil(DockerAgentText.logs([], env: []))
    }

    /// The newest line alone over the budget — a stack trace in one JSON
    /// line — is the crash: cut, not dropped.
    func testTheNewestLineIsCutNotDropped() throws {
        let huge = #"{"level":"fatal","msg":"boom","stack":""# + String(repeating: "at Foo.bar(Foo.java:42) ", count: 900) + #""}"#
        XCTAssertGreaterThan(huge.utf8.count, 20_000)
        let alone = try XCTUnwrap(DockerAgentText.logs([DockerLogLine.parse(huge, stream: .stderr, timestamps: false)], env: []))
        XCTAssertEqual(alone.count, 1)
        XCTAssertTrue(alone.text.contains("boom") && alone.text.contains("at Foo.bar(Foo.java:42)"), String(alone.text.prefix(200)))
        XCTAssertTrue(alone.text.hasSuffix(" … (line cut)"), String(alone.text.suffix(80)))
        XCTAssertLessThanOrEqual(alone.text.utf8.count, DockerAgentText.maxLogBytes + 200)

        let after = try XCTUnwrap(
            DockerAgentText.logs(["starting", huge].map { DockerLogLine.parse($0, stream: .stdout, timestamps: false) }, env: []))
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(after.text.contains("… earlier lines left out\n"), String(after.text.prefix(200)))
        XCTAssertFalse(after.text.contains("starting"))
        XCTAssertEqual(DockerAgentText.cut("héllo", bytes: 2), "h", "cut between characters")
    }

    private let config = Data(
        #"""
        {"name":"shop","services":{
          "web":{"image":"nginx:1.27"},
          "worker":{"image":"node:22","command":["node","server.js"],
            "environment":{"DB_PASSWORD":"compose-literal-pw","STRIPE_SECRET_KEY":"${STRIPE_SECRET_KEY}","DATABASE_URL":"postgres://u:pw@db/x","NODE_ENV":"production"},
            "build":{"context":"/w/shop","args":["NPM_TOKEN=abc","NODE_VERSION=22"]},
            "depends_on":{"db":{"condition":"service_started","required":true}}}}}
        """#.utf8)

    func testTheComposeServiceIsPickedAndMasked() throws {
        let text = try XCTUnwrap(DockerAgentText.service("worker", inConfig: config, env: []))
        XCTAssertTrue(text.hasPrefix("Its service in the compose file, as Compose reads it (variables as written):\n"), text)
        XCTAssertTrue(text.contains("node:22"), text)
        XCTAssertTrue(text.contains("\"${STRIPE_SECRET_KEY}\""), "a variable it names is kept as written: \(text)")
        XCTAssertFalse(text.contains("compose-literal-pw"), text)
        XCTAssertTrue(text.contains("postgres://u:••••••@db/x"), text)
        XCTAssertTrue(text.contains("NPM_TOKEN=••••••") && text.contains("NODE_VERSION=22"), text)
        XCTAssertTrue(text.contains("\"NODE_ENV\" : \"production\""), text)
        XCTAssertTrue(text.contains("service_started"), text)
        XCTAssertFalse(text.contains("nginx:1.27"), "another service's isn't its")
        XCTAssertNil(DockerAgentText.service("cache", inConfig: config, env: []))
        XCTAssertNil(DockerAgentText.service("worker", inConfig: Data("not json".utf8), env: []))
        // A default may be the secret itself.
        XCTAssertTrue(DockerSecrets.isReference("${STRIPE_SECRET_KEY}"))
        XCTAssertTrue(DockerSecrets.isReference("$TOKEN"))
        XCTAssertFalse(DockerSecrets.isReference("${DB_PASSWORD:-hunter2}"))
    }

    /// A literal password in the compose file's command or health check
    /// is masked as the inspect's is.
    func testTheComposeServicesCommandIsMasked() throws {
        let config = Data(
            #"{"services":{"cache":{"image":"redis:7","command":["redis-server","--requirepass","literal-pw"],"healthcheck":{"test":["CMD-SHELL","redis-cli -a literal-pw ping"]}}}}"#
                .utf8)
        let text = try XCTUnwrap(DockerAgentText.service("cache", inConfig: config, env: []))
        XCTAssertFalse(text.contains("literal-pw"), text)
        XCTAssertTrue(text.contains("\"--requirepass\",\n") && text.contains("redis-cli -a •••••• ping"), text)
    }

    func testScrubTakesEveryURLPasswordOut() {
        XCTAssertEqual(
            DockerSecrets.scrub("a postgres://u:p1@h/db and redis://:p2@r:6379", env: []), "a postgres://u:••••••@h/db and redis://:••••••@r:6379")
        XCTAssertEqual(DockerSecrets.scrub("GET http://localhost:3000/health 200", env: []), "GET http://localhost:3000/health 200")
        XCTAssertEqual(DockerSecrets.scrub("key s3cr3t-value", env: [(key: "API_KEY", value: "s3cr3t-value")]), "key ••••••")
        // No `/`, `?` or `#` in a URL's password: a port, then a path or a
        // query with an `@` in it, is no password.
        for line in [
            "GET http://api:8080/v1/users/jane@example.com 500", "POST http://api:8080/invite?email=a@b.com 400", "GET http://api:8080/#to=a@b 404",
        ] {
            XCTAssertEqual(DockerSecrets.scrub(line, env: []), line)
            XCTAssertEqual(DockerSecrets.maskURL(line), line)
        }
        XCTAssertEqual(DockerSecrets.scrub("to http://u:pw@api:8080/v1/users/jane@example.com", env: []), "to http://u:••••••@api:8080/v1/users/jane@example.com")
        XCTAssertEqual(DockerSecrets.maskURL("postgres://app:hunter2@db:5432/app"), "postgres://app:••••••@db:5432/app")
    }

    /// Compose has put .env's values into the command already, and the
    /// container's env may not hold them: the flags say which words are
    /// secrets.
    func testACommandsSecretFlagsAreMasked() {
        let cases: [([String], [String])] = [
            (["docker-entrypoint.sh", "redis-server", "--requirepass", "p4ssw0rd"], ["docker-entrypoint.sh", "redis-server", "--requirepass", "••••••"]),
            (["CMD", "redis-cli", "-a", "p4ssw0rd", "ping"], ["CMD", "redis-cli", "-a", "••••••", "ping"]),
            (["CMD-SHELL", "redis-cli -a p4ssw0rd ping || exit 1"], ["CMD-SHELL", "redis-cli -a •••••• ping || exit 1"]),
            (["sh", "-c", "PGPASSWORD=hunter2 psql -h db  -U app"], ["sh", "-c", "PGPASSWORD=•••••• psql -h db  -U app"]),
            (["app", "--api-key=abc123", "--port", "80", "--token", "${TOKEN}", "--pass", "x1"], ["app", "--api-key=••••••", "--port", "80", "--token", "${TOKEN}", "--pass", "••••••"]),
            (["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-pr00t"], ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-p••••••"]),
            (["curl", "-u", "elastic:changeme", "http://es:9200"], ["curl", "-u", "elastic:••••••", "http://es:9200"]),
            (["mongosh", "-u", "root", "-p", "example"], ["mongosh", "-u", "root", "-p", "••••••"]),
            (["redis-server", "--requirepass", "--appendonly", "yes"], ["redis-server", "--requirepass", "--appendonly", "yes"]),
            (["nginx", "-g", "daemon off;"], ["nginx", "-g", "daemon off;"]),
            (["server", "--tls-key", "/certs/key.pem", "-p", "8080:80", "--auth-enabled=true"], ["server", "--tls-key", "/certs/key.pem", "-p", "8080:80", "--auth-enabled=true"]),
        ]
        for (words, masked) in cases { XCTAssertEqual(DockerSecrets.maskArguments(words), masked, "\(words)") }
    }

    /// The canonical redis service: its password from .env, not its env.
    @MainActor func testACommandsPasswordIsMaskedThoughTheEnvDoesntHoldIt() {
        let cache = summary("shop-cache-1", state: "exited", status: "Exited (1) 3 seconds ago", service: "cache", image: "redis:7")
        let inspect = detail(
            of: cache, exit: 1, env: ["REDIS_ARGS=--save 60"], check: ["CMD", "redis-cli", "-a", "p4ssw0rd", "ping"],
            cmd: ["redis-server", "--requirepass", "p4ssw0rd"])
        let text = DockerAgentText.about(cache, inspect, trouble: .exited(1), ports: [], project: nil, engine: "Docker Desktop", memoryTotal: nil)
        XCTAssertFalse(text.contains("p4ssw0rd"), text)
        XCTAssertTrue(text.contains("Command: redis-server --requirepass ••••••"), text)
        XCTAssertTrue(text.contains("Health check: CMD redis-cli -a •••••• ping"), text)
        XCTAssertEqual(
            DockerMCP.describe(cache, inspect).split(separator: "\n").first { $0.hasPrefix("Command:") }, "Command: redis-server --requirepass ••••••")
    }

    /// `POSTGRES_PASSWORD=postgres`: the brief's own words stay.
    func testAPasswordThatIsTheImagesNameLeavesTheBriefAlone() throws {
        let db = summary("shop-postgres-1", state: "exited", status: "Exited (1) 3 seconds ago", service: "postgres", image: "postgres:16")
        let inspect = detail(
            of: db, exit: 1, error: "", env: ["POSTGRES_PASSWORD=postgres", "PGDATA=/var/lib/postgresql/data", "API_TOKEN=s3cr3t-value"],
            cmd: ["postgres", "-c", "log_statement=all"])
        let text = DockerAgentText.about(db, inspect, trouble: .exited(1), ports: [], project: nil, engine: "Docker Desktop", memoryTotal: nil)
        for said in [
            "Container shop-postgres-1 — compose project shop, service postgres", "Image: postgres:16", "Command: postgres -c log_statement=all",
            "PGDATA=/var/lib/postgresql/data", "POSTGRES_PASSWORD=••••••", "API_TOKEN=••••••",
        ] {
            XCTAssertTrue(text.contains(said), "\(said)\n\(text)")
        }
        let names = DockerAgentText.names(of: db, image: inspect.Config.Image)
        XCTAssertTrue(names.isSuperset(of: ["shop", "postgres", "shop-postgres-1"]), "\(names)")
        let lines = ["postgres database system is shut down", "token s3cr3t-value"].map {
            DockerLogLine.parse($0, stream: .stdout, timestamps: false)
        }
        let logs = try XCTUnwrap(DockerAgentText.logs(lines, env: inspect.env, keeping: names))
        XCTAssertTrue(logs.text.hasSuffix("postgres database system is shut down\ntoken ••••••"), logs.text)
        XCTAssertEqual(
            DockerAgentText.names(of: summary(state: "exited", status: "", image: "registry:5000/team/api:1.2@sha256:abc")).intersection(["api", "team"]),
            ["api", "team"], "a registry's port isn't a tag")
    }

    /// Stopped, the list's ports are gone; what it publishes is its
    /// bindings, and those are no "exposed, not published" port.
    func testAStoppedContainersPortsAreItsBindings() {
        let worker = summary(state: "created", status: "Created")
        let inspect = detail(
            of: worker, error: "Bind for 0.0.0.0:3000 failed: port is already allocated",
            bindings: ["3000/tcp": [.init(HostIp: "", HostPort: "3000")], "5353/udp": [.init(HostIp: "127.0.0.1", HostPort: "")]])
        let text = DockerAgentText.about(
            worker, inspect, trouble: .didNotStart("port taken"), ports: [], project: nil, engine: "Docker Desktop", memoryTotal: nil)
        XCTAssertTrue(text.contains("Ports it publishes when it runs: 3000→3000, 127.0.0.1, a port the engine picks→5353/udp"), text)
        XCTAssertTrue(text.contains("Exposed, not published: 9229/tcp"), text)
        XCTAssertFalse(text.contains("3000/tcp"), "it is published: \(text)")
        XCTAssertFalse(text.contains("\nPorts: "), text)

        let running = summary(state: "running", status: "Up 2 minutes")
        let live = DockerAgentText.about(
            running, detail(of: running, bindings: ["3000/tcp": [.init(HostIp: "", HostPort: "3000")]]), trouble: nil,
            ports: [PublishedPort(hostPort: 3000, containerPort: 3000, proto: "tcp")], project: nil, engine: "Docker Desktop", memoryTotal: nil)
        XCTAssertTrue(live.contains("Ports: localhost:3000→3000"), live)
        XCTAssertFalse(live.contains("when it runs"), live)
    }

    /// Stopped, the engine calls any health-checked container unhealthy:
    /// only a failing streak is news, and the check itself stays.
    func testAStoppedContainersHealthIsItsStreak() {
        let crashed = summary(state: "exited", status: "Exited (1) 3 seconds ago")
        let text = DockerAgentText.about(
            crashed, detail(of: crashed, exit: 1, health: .init(Status: "unhealthy", FailingStreak: 0), check: ["CMD", "true"]), trouble: .exited(1),
            ports: [], project: nil, engine: "Docker Desktop", memoryTotal: nil)
        XCTAssertFalse(text.contains("Health:"), text)
        XCTAssertTrue(text.contains("Health check: CMD true"), text)

        let sick = summary(state: "running", status: "Up 2 minutes (unhealthy)")
        let live = DockerAgentText.about(
            sick, detail(of: sick, health: .init(Status: "unhealthy", FailingStreak: 4)), trouble: .unhealthy, ports: [], project: nil,
            engine: "Docker Desktop", memoryTotal: nil)
        XCTAssertTrue(live.contains("Health: unhealthy, 4 failed checks in a row"), live)
    }

    /// The agents of a checkout first, the closest first; a folder above
    /// it that is no repository (`~`) holds every project, so isn't its.
    func testCloseness() {
        typealias T = DockerAttention
        XCTAssertEqual(T.closeness(of: "/w/shop", to: "/w/shop", isRepository: true), 0)
        XCTAssertEqual(T.closeness(of: "/w/shop", to: "/w/shop", isRepository: false), 0)
        XCTAssertEqual(T.closeness(of: "/w/shop/web", to: "/w/shop", isRepository: false), 1)
        XCTAssertEqual(T.closeness(of: "/w/shop", to: "/w/shop/infra", isRepository: true), 2)
        XCTAssertEqual(T.closeness(of: "/w", to: "/w/shop/infra", isRepository: true), 3)
        XCTAssertNil(T.closeness(of: "/Users/me", to: "/Users/me/code/shop", isRepository: false), "a home folder holds every project")
        XCTAssertNil(T.closeness(of: "/w/other", to: "/w/shop", isRepository: true))
    }

    func testWholeLines() {
        let text = "one\ntwo two\nthree three\nfour"
        let from = (text as NSString).range(of: "o two").location
        let to = (text as NSString).range(of: "ree three").location
        XCTAssertEqual(DockerAgentText.wholeLines(of: text, NSRange(location: from, length: to - from)), "two two\nthree three")
        XCTAssertEqual(DockerAgentText.wholeLines(of: text, NSRange(location: (text as NSString).length - 2, length: 2)), "four")
    }
}

/// A brief as the window reads it, against the fake engine: what failed,
/// how, its last lines and its service — secrets out of all of it.
@MainActor
final class DockerAgentBriefingTests: XCTestCase {
    private var fake: FakeDockerEngine!
    private var model: DockerModel!
    private var web = ""
    private var worker = ""

    private let config = Data(
        #"{"name":"shop","services":{"web":{"image":"nginx:1.27"},"worker":{"image":"node:22","environment":{"DB_PASSWORD":"compose-literal-pw","STRIPE_SECRET_KEY":"${STRIPE_SECRET_KEY}"}}}}"#
            .utf8)

    override func setUp() async throws {
        let socket = "/tmp/ot-docker-\(UUID().uuidString.prefix(8)).sock"
        fake = FakeDockerEngine(socket: socket)
        try fake.start()
        let endpoint = DockerEndpoint(address: .unix(socket), context: nil, source: "test")
        model = DockerModel(endpoint: { endpoint }, retries: [.milliseconds(50)])
        web = fake.add(
            name: "shop-web-1", image: "nginx:1.27", project: "shop", workingDir: "/w/shop", service: "web",
            ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8080, Type: "tcp")], env: ["API_TOKEN=s3cr3t-value", "PORT=80"])
        worker = fake.add(
            name: "shop-worker-1", image: "node:22", project: "shop", workingDir: "/w/shop", service: "worker",
            env: ["STRIPE_SECRET_KEY=sk_test_abc123", "DATABASE_URL=postgres://shop:hunter2@db/shop"])
        model.start()
        try await until { self.model.containers.count == 2 }
    }

    override func tearDown() async throws {
        model.stop()
        fake.stop()
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "in time")
    }

    /// The worker, out of memory, its health check failing, its last
    /// lines naming its secrets.
    private func failWorker() async throws -> ContainerSummary {
        fake.log(worker, "stripe key sk_test_abc123 loaded")
        fake.log(worker, "connecting to postgres://shop:hunter2@db/shop")
        fake.log(worker, "Error: Cannot find module 'express'", stream: .stderr)
        fake.setFailure(worker, oomKilled: true, restarts: 2, probes: ["boom"])
        fake.set(worker, state: .exited, exitCode: 137, health: "unhealthy")
        try await until { self.model.container(self.worker)?.exitCode == 137 }
        return try XCTUnwrap(model.container(worker))
    }

    func testAFailureBriefHasItsStateLogsAndService() async throws {
        let failed = try await failWorker()
        var asked: (project: String, endpoint: DockerEndpoint?)?
        let config = config
        let brief = try await DockerAgentBriefing.brief(.failure(failed), docker: model) { project, endpoint in
            asked = (project.name, endpoint)
            return config
        }
        XCTAssertEqual(brief.message, "Why did shop-worker-1 run out of memory?")
        XCTAssertEqual(brief.subject, "shop-worker-1 ran out of memory")
        XCTAssertTrue(brief.text.contains("Restarts: 2"), brief.text)
        XCTAssertTrue(brief.text.contains("Last check (exit 1): boom"), brief.text)
        XCTAssertTrue(brief.text.contains("Image: node:22"), brief.text)
        XCTAssertTrue(brief.text.contains("No memory limit of its own; the engine has 8 GB."), brief.text)
        XCTAssertTrue(brief.text.contains("STRIPE_SECRET_KEY=••••••"), brief.text)
        XCTAssertEqual(brief.parts.map(\.title), ["last 3 log lines", "compose service"])
        XCTAssertTrue(brief.parts[0].text.contains("Error: Cannot find module 'express'"), brief.parts[0].text)
        XCTAssertTrue(brief.parts[0].text.contains("stripe key •••••• loaded"), brief.parts[0].text)
        XCTAssertTrue(brief.parts[0].text.contains("postgres://shop:••••••@db/shop"), brief.parts[0].text)
        XCTAssertTrue(brief.parts[1].text.contains("node:22") && brief.parts[1].text.contains("${STRIPE_SECRET_KEY}"), brief.parts[1].text)
        XCTAssertEqual(asked?.project, "shop")
        XCTAssertNotNil(asked?.endpoint, "Compose is told the engine Overterm reaches")
        for said in [brief.text] + brief.parts.map(\.text) {
            for secret in ["sk_test_abc123", "hunter2", "compose-literal-pw"] { XCTAssertFalse(said.contains(secret), "\(secret) in \(said)") }
        }
        XCTAssertEqual(brief.folder, "/w/shop")
        XCTAssertTrue(fake.requests.contains { $0.contains("/containers/\(worker)/logs") && $0.contains("tail=80") }, "\(fake.requests)")
    }

    func testNoServicePartWithoutCompose() async throws {
        let failed = try await failWorker()
        let brief = try await DockerAgentBriefing.brief(.failure(failed), docker: model) { _, _ in nil }
        XCTAssertEqual(brief.parts.map(\.title), ["last 3 log lines"])

        // Nothing written: no chip, and the text says so.
        fake.set(web, state: .exited, exitCode: 1)
        try await until { self.model.container(self.web)?.exitCode == 1 }
        let quiet = try await DockerAgentBriefing.brief(.failure(try XCTUnwrap(model.container(web))), docker: model) { _, _ in nil }
        XCTAssertEqual(quiet.message, "Why did shop-web-1 exit with code 1?")
        XCTAssertTrue(quiet.parts.isEmpty)
        XCTAssertTrue(quiet.text.contains("It wrote no log lines."), quiet.text)
        XCTAssertTrue(quiet.text.contains("Ports: localhost:8080→80"), quiet.text)
    }

    func testSelectedLinesAreScrubbedAndCarryTheirContainer() async throws {
        let container = try XCTUnwrap(model.container(web))
        let brief = try await DockerAgentBriefing.brief(.logLines("token s3cr3t-value failed", container), docker: model)
        XCTAssertEqual(brief.text, "token •••••• failed")
        XCTAssertNil(brief.subject)
        XCTAssertEqual(brief.message, "")
        XCTAssertEqual(brief.parts.map(\.title), ["shop-web-1"])
        XCTAssertTrue(brief.parts[0].text.hasPrefix("They come from this container's log:\n"), brief.parts[0].text)
        XCTAssertTrue(brief.parts[0].text.contains("Image: nginx:1.27"), brief.parts[0].text)
        XCTAssertFalse(brief.parts[0].text.contains("s3cr3t-value"))
        XCTAssertEqual(brief.folder, "/w/shop")
    }

    func testProjectLinesAreScrubbedWithEveryServicesEnv() async throws {
        try await until { self.model.projects.first?.services.count == 2 }
        let project = try XCTUnwrap(model.projects.first { $0.name == "shop" })
        let picked = "web | token s3cr3t-value\nworker | key sk_test_abc123 at postgres://shop:hunter2@db/shop"
        let brief = try await DockerAgentBriefing.brief(.projectLogLines(picked, project), docker: model)
        XCTAssertEqual(brief.text, "web | token ••••••\nworker | key •••••• at postgres://shop:••••••@db/shop")
        XCTAssertEqual(brief.parts.map(\.title), ["shop"])
        XCTAssertTrue(brief.parts[0].text.contains("compose project shop's logs"), brief.parts[0].text)
        XCTAssertTrue(brief.parts[0].text.contains("Compose files: /w/shop/compose.yaml"), brief.parts[0].text)
        XCTAssertEqual(brief.folder, "/w/shop")
    }

    func testAnEngineThatIsntThereIsAnError() async throws {
        let away = DockerModel(endpoint: { nil })
        let container = try XCTUnwrap(model.container(web))
        do {
            _ = try await DockerAgentBriefing.brief(.logLines("token s3cr3t-value", container), docker: away)
            XCTFail("unscrubbed lines would have gone")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("secrets can't be taken out"), error.localizedDescription)
        }
    }
}
