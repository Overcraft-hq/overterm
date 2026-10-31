import Foundation
import XCTest

@testable import Overterm

/// Sizes as `docker run --memory` reads them, and as the sheet writes them
/// back.
final class DockerSizeTests: XCTestCase {
    func testSizesAsDockerTakesThem() {
        XCTAssertEqual(DockerSize.parse("512m"), 536_870_912)
        XCTAssertEqual(DockerSize.parse("1.5g"), 1_610_612_736)
        XCTAssertEqual(DockerSize.parse("2GiB"), 2 << 30)
        XCTAssertEqual(DockerSize.parse("512 MB"), 512 << 20)
        XCTAssertEqual(DockerSize.parse("1,5g"), 1_610_612_736, "a comma, as a Turkish Mac types the point")
        XCTAssertEqual(DockerSize.parse("1024"), 1024, "plain bytes")
        XCTAssertEqual(DockerSize.parse(" 64M "), 64 << 20)
        for unreadable in ["", "lots", "-1m", "0", "1.5x", "m"] { XCTAssertNil(DockerSize.parse(unreadable), unreadable) }
    }

    func testSizesWrittenBack() {
        let cases: [(Int, String)] = [(512 << 20, "512m"), (1 << 30, "1g"), (1_610_612_736, "1.5g"), (1600 << 20, "1600m"), (6_291_456, "6m"), (1000, "1000")]
        for (bytes, text) in cases {
            XCTAssertEqual(DockerSize.format(bytes), text)
            XCTAssertEqual(DockerSize.parse(DockerSize.format(bytes)), bytes, "read back as written")
        }
    }
}

/// The Settings sheet's draft: read from inspect, checked as the engine
/// checks it, sent as only what changed.
final class DockerContainerSettingsTests: XCTestCase {
    private func summary(_ name: String = "ot-tune", labels: [String: String] = [:]) -> ContainerSummary {
        ContainerSummary(Id: name + "-0123456789", Names: ["/" + name], Image: "redis:7", Created: 1, Labels: labels, State: "running", Status: "Up 2 minutes")
    }

    private func settings(
        _ host: ContainerDetail.HostConfigDetail = .init(), name: String = "ot-tune", labels: [String: String] = [:], cpus: Int? = 4,
        memory: Int? = 8 << 30
    ) -> DockerContainerSettings {
        let container = summary(name, labels: labels)
        let detail = ContainerDetail(
            Id: container.Id, Name: "/" + name, State: .init(Status: "running"), Config: .init(Image: "redis:7"), HostConfig: host)
        return DockerContainerSettings(container, detail, engine: EngineInfo(NCPU: cpus, MemTotal: memory))
    }

    func testWhatItHasIsReadFromInspect() {
        let set = settings(
            .init(
                RestartPolicy: .init(Name: "on-failure", MaximumRetryCount: 3), Memory: 512 << 20, NanoCpus: 1_500_000_000, MemorySwap: 1 << 30))
        XCTAssertEqual(set.memory, "512m")
        XCTAssertEqual(set.cpus, "1.5")
        XCTAssertEqual(set.restart, "on-failure")
        XCTAssertEqual(set.retries, 3)
        XCTAssertNil(set.update, "nothing edited: nothing to send")
        XCTAssertEqual(settings(.init(RestartPolicy: .init(Name: "", MaximumRetryCount: 0))).restart, "no", "an empty policy is no policy")
        let none = settings()
        XCTAssertEqual(none.memory, "")
        XCTAssertEqual(none.cpus, "")
        XCTAssertNil(none.project, "no project: no compose warning")
        XCTAssertEqual(settings(labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "web"]).service, "web")
    }

    func testOnlyWhatChangedIsSent() {
        var set = settings(.init(RestartPolicy: .init(Name: "no", MaximumRetryCount: 0)))
        XCTAssertNil(set.update)
        XCTAssertFalse(set.changed, "nothing for docker update to say")
        set.restart = "always"
        XCTAssertTrue(set.changed)
        XCTAssertEqual(set.update, DockerEngine.ContainerUpdate(RestartPolicy: .init(Name: "always", MaximumRetryCount: 0)), "no memory, no CPUs")
        var failing = settings(.init(RestartPolicy: .init(Name: "on-failure", MaximumRetryCount: 3)))
        failing.restart = "no"
        XCTAssertEqual(failing.update?.RestartPolicy, .init(Name: "no", MaximumRetryCount: 0), "no takes no retries")
        failing.restart = "on-failure"
        failing.retries = 5
        XCTAssertEqual(failing.update?.RestartPolicy, .init(Name: "on-failure", MaximumRetryCount: 5), "only the count changed")
        var same = settings(.init(Memory: 512 << 20, MemorySwap: 1 << 30))
        same.memory = "0.5g"
        XCTAssertNil(same.update, "the same limit written another way")
    }

    func testSwapFollowsTheLimit() {
        func swap(memory: Int, swap: Int, to new: Int) -> Int? {
            var set = settings(.init(Memory: memory, MemorySwap: swap))
            set.memory = DockerSize.format(new)
            return set.update?.MemorySwap
        }
        XCTAssertEqual(swap(memory: 0, swap: 0, to: 1 << 30), 2 << 30, "no limit before: twice, as docker run -m makes it")
        XCTAssertEqual(swap(memory: 512 << 20, swap: 1 << 30, to: 1 << 30), 2 << 30, "twice it was: twice it stays")
        XCTAssertEqual(swap(memory: 512 << 20, swap: 512 << 20, to: 1 << 30), 1 << 30, "no swap stays none")
        XCTAssertEqual(swap(memory: 512 << 20, swap: -1, to: 1 << 30), -1, "unlimited stays unlimited")
        XCTAssertEqual(swap(memory: 512 << 20, swap: 768 << 20, to: 1 << 30), 1280 << 20, "the same swap on top")
        for (memory, old) in [(0, 0), (512 << 20, 1 << 30), (512 << 20, 512 << 20), (512 << 20, 768 << 20)] {
            for new in [6 << 20, 256 << 20, 4 << 30] {
                XCTAssertGreaterThanOrEqual(swap(memory: memory, swap: old, to: new) ?? 0, new, "never below the limit")
            }
        }
        var set = settings(.init(Memory: 512 << 20, MemorySwap: -1))
        set.memory = "1g"
        XCTAssertTrue(set.line().contains("--memory 1g --memory-swap -1"), set.line())
    }

    func testCPUsByQuotaWhenItWasMadeSo() {
        var set = settings(.init(CpuQuota: 50_000, CpuPeriod: 100_000))
        XCTAssertEqual(set.cpus, "0.5")
        set.cpus = "1"
        XCTAssertEqual(set.update?.CpuQuota, 100_000)
        XCTAssertNil(set.update?.NanoCpus, "the engine puts no NanoCpus over a quota")
        XCTAssertEqual(set.line(), "docker update --cpu-quota 100000 ot-tune")
        var bare = settings(.init(CpuQuota: 50_000))
        XCTAssertEqual(bare.cpus, "0.5", "a quota without a period: the kernel's 100000")
        bare.cpus = "2"
        XCTAssertEqual(bare.update?.CpuQuota, 200_000)
        var nanos = settings(.init(NanoCpus: 1_500_000_000))
        nanos.cpus = "2"
        XCTAssertEqual(nanos.update, DockerEngine.ContainerUpdate(NanoCpus: 2_000_000_000))
    }

    func testWhatTheEngineWouldRefuseIsSaidFirst() {
        func problem(_ host: ContainerDetail.HostConfigDetail = .init(), _ edit: (inout DockerContainerSettings) -> Void) -> String? {
            var set = settings(host)
            edit(&set)
            if set.problem != nil { XCTAssertNil(set.update, "nothing is sent while something is wrong") }
            return set.problem
        }
        XCTAssertTrue(problem(.init(Memory: 512 << 20, MemorySwap: 1 << 30)) { $0.memory = "" }?.contains("not take one away") == true)
        XCTAssertTrue(problem(.init(Memory: 512 << 20, MemorySwap: 1 << 30)) { $0.memory = "" }?.contains(DockerBytes.string(8 << 30, memory: true)) == true)
        XCTAssertTrue(problem { $0.memory = "4m" }?.contains("6m") == true)
        XCTAssertTrue(problem { $0.memory = "lots" }?.contains("isn't a size") == true)
        XCTAssertTrue(problem { $0.cpus = "9" }?.contains("4 CPUs") == true)
        XCTAssertTrue(problem { $0.cpus = "0.001" }?.contains("0.01") == true)
        XCTAssertTrue(problem { $0.cpus = "many" }?.contains("isn't a number") == true)
        XCTAssertTrue(problem(.init(NanoCpus: 1_000_000_000)) { $0.cpus = "" }?.contains("not take one away") == true)
        XCTAssertTrue(problem { $0.restart = "sometimes" }?.contains("isn't a restart policy") == true)
        XCTAssertTrue(problem(.init(AutoRemove: true)) { $0.restart = "always" }?.contains("--rm") == true)
        XCTAssertNil(problem(.init(AutoRemove: true)) { $0.memory = "1g" }, "a --rm container's limits change")
        XCTAssertNil(problem { $0.cpus = "0,5" }, "a comma for the point")
    }

    /// A byte count pasted into CPUs is said back, never converted: as
    /// nano-CPUs it is past what an Int holds, and the conversion traps.
    func testANumberTooLargeForCPUsIsRefusedNotConverted() {
        var known = settings()
        known.cpus = "17179869184"
        XCTAssertTrue(known.changed, "read without trapping")
        XCTAssertTrue(known.problem?.contains("4 CPUs") == true, known.problem ?? "")
        XCTAssertNil(known.update)
        var unknown = settings(cpus: nil)
        unknown.cpus = "1e10"
        XCTAssertTrue(unknown.problem?.contains("more CPUs than a machine has") == true, unknown.problem ?? "")
        XCTAssertNil(unknown.update)
        XCTAssertFalse(unknown.line().isEmpty)
        unknown.cpus = "1e400"
        XCTAssertTrue(unknown.problem?.contains("isn't a number") == true, unknown.problem ?? "")
        unknown.cpus = "512"
        XCTAssertNil(unknown.problem, "a big machine's, when the engine hasn't said")
        var byQuota = settings(.init(CpuQuota: 50_000, CpuPeriod: 100_000))
        byQuota.cpus = "-1e300"
        XCTAssertTrue(byQuota.changed)
        XCTAssertNotNil(byQuota.problem)
        XCTAssertGreaterThan(DockerContainerSettings.nanos(1e30), Int.max / 4, "held inside an Int, not trapped")
        XCTAssertLessThan(DockerContainerSettings.nanos(-1e30), -(Int.max / 4))
        XCTAssertEqual(DockerContainerSettings.nanos(.infinity), 0)
        XCTAssertEqual(DockerContainerSettings.quota(1.5, period: 100_000), 150_000)
    }

    func testACautionWhenItUsesMore() {
        var set = settings()
        set.inUse = 300 << 20
        set.memory = "256m"
        XCTAssertTrue(set.caution?.contains("killed for memory") == true, set.caution ?? "")
        XCTAssertNil(set.problem, "a caution, not a problem")
        XCTAssertNotNil(set.update)
        set.memory = "512m"
        XCTAssertNil(set.caution)
    }

    func testTheCommandAndTheSummary() {
        var set = settings()
        set.memory = "1g"
        set.cpus = "1.5"
        set.restart = "unless-stopped"
        XCTAssertEqual(
            set.line(prefix: "DOCKER_HOST=unix:///x "),
            "DOCKER_HOST=unix:///x docker update --memory 1g --memory-swap 2g --cpus 1.5 --restart unless-stopped ot-tune")
        XCTAssertEqual(set.summary, "memory \(DockerBytes.string(1 << 30, memory: true)), 1.5 CPUs, restarts unless stopped")
        set.cpus = "1"
        XCTAssertTrue(set.summary.contains("1 CPU,"), set.summary)
        set.restart = "on-failure"
        set.retries = 3
        XCTAssertTrue(set.line().contains("--restart on-failure:3"), set.line())
        XCTAssertTrue(set.summary.hasSuffix("restarts on failure, 3 times at most"), set.summary)
        var spaced = settings(name: "my app")
        spaced.restart = "always"
        XCTAssertEqual(spaced.line(), "docker update --restart always 'my app'")
    }

    func testNamesDockerRefuses() {
        XCTAssertNil(DockerContainerName.problem("web-1"))
        XCTAssertNil(DockerContainerName.problem("a.b_c"))
        for refused in ["x", "-web", "my app", "ü1", ""] { XCTAssertNotNil(DockerContainerName.problem(refused), refused) }
    }
}

/// A container saved as an image: its name, and what is left out of it.
final class DockerCommitTests: XCTestCase {
    func testANameForTheImage() {
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 10, day: 28, hour: 23, minute: 21).date!
        XCTAssertEqual(DockerCommit.suggestedName(for: "ot-shop-web-1", at: date), "ot-shop-web-1:20261028-2321")
        XCTAssertEqual(DockerCommit.suggestedName(for: "My__App.", at: date), "my-app:20261028-2321")
        XCTAssertEqual(DockerCommit.suggestedName(for: "...", at: date), "snapshot:20261028-2321")
        XCTAssertNil(DockerCommit.problem(DockerCommit.suggestedName(for: "My__App.", at: date)), "what it suggests, it takes")
    }

    func testReferencesDockerRefuses() {
        XCTAssertNil(DockerCommit.problem("ot/web:1"))
        XCTAssertNil(DockerCommit.problem("ot/web"), "latest when no tag")
        XCTAssertNil(DockerCommit.problem("Registry.io:5000/app:1"), "a registry's host in any case")
        XCTAssertEqual(DockerCommit.problem("Web:1"), "An image's name is lower-case.")
        XCTAssertEqual(DockerCommit.problem("my.App:1"), "An image's name is lower-case.", "one part is a name, not a host")
        XCTAssertEqual(DockerCommit.problem("web@sha256:abc"), "A tag, not a digest: name:tag.")
        XCTAssertEqual(DockerCommit.problem("web:bad tag"), "No spaces in an image's name.")
        XCTAssertNotNil(DockerCommit.problem("web:" + String(repeating: "a", count: 129)))
        XCTAssertNil(DockerCommit.problem("web:" + String(repeating: "a", count: 128)))
        XCTAssertNotNil(DockerCommit.problem("ot//web:1"))
    }

    func testSecretsAndBookkeepingAreLeftOut() {
        let env = ["NGINX_PORT=80", "API_TOKEN=s3cr3t", "GPG_KEY=abc", "EMPTY_TOKEN=", "DATABASE_URL=postgres://app:hunter2@db/app"]
        let labels = [
            "com.docker.compose.project": "shop", "com.docker.compose.service": "web", "org.testcontainers.sessionId": "3f2a", "app": "shop",
        ]
        let changes = DockerCommit.changes(env: env, imageEnv: ["GPG_KEY=abc"], labels: labels)
        XCTAssertEqual(
            changes,
            [
                #"ENV API_TOKEN="" DATABASE_URL="""#,
                #"LABEL com.docker.compose.project="" com.docker.compose.service="" org.testcontainers.sessionId="""#,
            ])
        for value in ["s3cr3t", "hunter2", "abc", "shop", "3f2a"] { XCTAssertFalse(changes.joined().contains(value), value) }
        XCTAssertFalse(changes.joined().contains("app="), "its own labels stay")
        XCTAssertEqual(DockerCommit.secretKeys(env: ["GPG_KEY=xyz"], imageEnv: ["GPG_KEY=abc"]), ["GPG_KEY"], "the image's key, given another value")
        XCTAssertEqual(DockerCommit.changes(env: ["PORT=80"], imageEnv: [], labels: ["app": "x"]), [], "nothing to leave out")
    }

    private func detail(
        env: [String] = [], cmd: [String]? = ["nginx", "-g", "daemon off;"], entrypoint: [String]? = nil, health: [String]? = nil,
        labels: [String: String] = [:]
    ) -> ContainerDetail {
        ContainerDetail(
            Id: "id", Name: "/web", State: .init(Status: "running"),
            Config: .init(
                Image: "nginx", Env: env, Cmd: cmd, Entrypoint: entrypoint, Labels: labels, Healthcheck: health.map { .init(Test: $0) }))
    }

    private func summary(image: String = "nginx", mounts: [DockerMountPoint] = []) -> ContainerSummary {
        ContainerSummary(Id: "id", Names: ["/web"], Image: image, Created: 1, State: "running", Status: "Up", Mounts: mounts)
    }

    func testWhatTheQuestionAndTheNoteSay() {
        let container = summary(mounts: [
            DockerMountPoint(Type: "volume", Name: "data", Destination: "/data"), DockerMountPoint(Type: "tmpfs", Destination: "/tmp"),
            DockerMountPoint(Type: "bind", Source: "/w", Destination: "/app"),
        ])
        let plan = DockerCommit.plan(
            container, detail(env: ["API_TOKEN=s3cr3t", "PORT=80"], labels: ["com.docker.compose.project": "shop"]), imageEnv: [])
        XCTAssertEqual(plan.secrets, ["API_TOKEN"])
        XCTAssertEqual(plan.labels, ["com.docker.compose.project"])
        XCTAssertEqual(plan.volumes, ["/data", "/app"])
        XCTAssertEqual(plan.keeps, [], "nothing in its command")
        let said = DockerCommit.explanation(plan)
        XCTAssertTrue(said.contains("not its volumes (/data, /app)."), said)
        XCTAssertTrue(said.contains("Its env's secrets (API_TOKEN) and Compose's labels are left out."), said)
        XCTAssertTrue(said.contains("paused"), "a running one is paused: \(said)")
        XCTAssertFalse(said.contains("A password"), said)
        XCTAssertEqual(
            DockerCommit.note(name: "web", repository: "ot/web", tag: "1", id: "sha256:0123456789abcdef", plan: plan),
            "web is the image ot/web:1 (0123456789ab) — without its volumes, its secrets left out (API_TOKEN).")
        XCTAssertEqual(DockerCommit.note(name: "web", repository: "ot/web", tag: "1", id: "abc", plan: .init()), "web is the image ot/web:1 (abc).")
        let plain = DockerCommit.explanation(.init())
        XCTAssertFalse(plain.contains("left out") || plain.contains("paused"), "nothing to leave out, nothing running: \(plain)")
        let tests = DockerCommit.explanation(.init(labels: ["org.testcontainers.sessionId"]))
        XCTAssertTrue(tests.contains("Testcontainers' labels are left out."), tests)
    }

    /// What a commit keeps as it is, said: a password in its command or
    /// its health check — Compose puts `.env`'s values there, where the
    /// env doesn't name them.
    func testAPasswordInItsCommandIsSaidToStay() {
        let redis = DockerCommit.plan(
            summary(image: "redis:7"),
            detail(cmd: ["redis-server", "--requirepass", "p4ssw0rd"], health: ["CMD", "redis-cli", "-a", "p4ssw0rd", "ping"]), imageEnv: [])
        XCTAssertEqual(redis.keeps, ["command", "health check"])
        XCTAssertEqual(redis.changes, [], "nothing a commit can blank")
        let said = DockerCommit.explanation(redis)
        XCTAssertTrue(said.contains("A password in its command and health check stays in the image"), said)
        XCTAssertFalse(said.contains("left out"), said)
        let note = DockerCommit.note(name: "redis", repository: "ot/redis", tag: "1", id: "abc", plan: redis)
        XCTAssertTrue(note.hasSuffix("The password in its command and health check is in it."), note)

        let shell = DockerCommit.plan(
            summary(image: "redis:7"), detail(cmd: ["sh", "-c", #"redis-server --requirepass "$REDIS_PASSWORD""#], health: ["CMD-SHELL", "redis-cli ping"]),
            imageEnv: [])
        XCTAssertEqual(shell.keeps, [], "expanded in the container: nothing in it")
        let token = DockerCommit.plan(
            summary(), detail(env: ["API_TOKEN=s3cr3t-value"], cmd: ["app", "--header", "Bearer s3cr3t-value"]), imageEnv: [])
        XCTAssertEqual(token.keeps, ["command"], "the env's secret, in its command too")
        let url = DockerCommit.plan(summary(), detail(cmd: ["--db", "postgres://app:hunter2@db/app"], entrypoint: ["migrate"]), imageEnv: [])
        XCTAssertEqual(url.keeps, ["command"], "a URL's password")
        let named = DockerCommit.plan(summary(image: "postgres:16"), detail(env: ["POSTGRES_PASSWORD=postgres"], cmd: ["postgres"]), imageEnv: [])
        XCTAssertEqual(named.keeps, [], "a password that is the program's name is no secret in its command")
        XCTAssertEqual(named.secrets, ["POSTGRES_PASSWORD"], "though the env's is blanked")
    }
}
