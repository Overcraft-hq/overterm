import XCTest

@testable import Overterm

/// What a tab's icon says it is. The rule decides a glyph people read
/// without looking, so it has to be boring and predictable.
final class TabKindTests: XCTestCase {
    func testAnAgentTabIsAnAgentWhateverItsTitleSays() {
        XCTAssertEqual(TabKind.of(agent: .claude, title: "ssh prod-eu-1", hasPort: true), .agent)
    }

    func testSshIsToldFromTheCommandAndFromTheRemotePrompt() {
        XCTAssertEqual(TabKind.of(agent: nil, title: "ssh prod-eu-1", hasPort: false), .ssh)
        XCTAssertEqual(TabKind.of(agent: nil, title: "mosh box", hasPort: false), .ssh)
        XCTAssertEqual(TabKind.of(agent: nil, title: "deploy@prod-eu-1:~", hasPort: false), .ssh)
    }

    /// A path has an @ in it often enough (node_modules/@scope, an email in
    /// a cwd) that it must not read as a machine.
    func testAPathIsNotAMachine() {
        XCTAssertEqual(TabKind.of(agent: nil, title: "~/src/@scope/pkg", hasPort: false), .shell)
        XCTAssertEqual(TabKind.of(agent: nil, title: "@", hasPort: false), .shell)
        XCTAssertEqual(TabKind.of(agent: nil, title: "me@", hasPort: false), .shell)
        XCTAssertEqual(TabKind.of(agent: nil, title: "@host", hasPort: false), .shell)
    }

    /// Listening is what makes a shell a server — the title alone never says
    /// so ("pnpm dev" could be anything).
    func testAListeningTabIsAServer() {
        XCTAssertEqual(TabKind.of(agent: nil, title: "pnpm dev", hasPort: true), .server)
        XCTAssertEqual(TabKind.of(agent: nil, title: "pnpm dev", hasPort: false), .shell)
    }

    func testAShellInAContainerIsAContainer() {
        for title in [
            "docker exec -it shop-db-1 sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'",
            "DOCKER_HOST=unix:///tmp/x.sock docker exec -it api bash", "docker run --rm -it debian:bookworm-slim", "docker compose exec web sh",
            "docker compose run --rm migrate", "docker attach api", "docker debug api", "podman exec -it db psql", "docker container exec -it db sh",
            // As the Docker page types a one-off: Compose's own options first.
            "DOCKER_HOST=unix:///tmp/x.sock docker compose -p shop -f /w/shop/compose.yaml run --rm web",
            "docker compose --profile jobs -f compose.yaml run --rm migrate", "docker compose --file=compose.yaml exec web sh",
            // A path with a space, quoted as the page quotes it: one word.
            "docker compose -p shop -f '/w/my app/compose.yaml' run --rm web",
            #"DOCKER_HOST='unix:///w/my sock' docker compose -p 'my app' -f '/w/it'\''s here/compose.yaml' run --rm web"#,
            #"docker compose -f "/w/my app/compose.yaml" exec web sh"#,
        ] {
            XCTAssertEqual(TabKind.of(agent: nil, title: title, hasPort: true), .container, title)
        }
        for title in [
            "docker ps", "docker run -d nginx", "docker logs -f api", "docker compose up -d", "dockerd", "docker compose -p shop -f /w/shop/compose.yaml watch",
            "docker compose -p shop -f /w/shop/compose.yaml up -d --build web", "docker compose -p run logs -f",
            "docker compose -p shop -f '/w/my app/compose.yaml' watch", #"docker compose -f /w/a\ exec up -d"#,
        ] {
            XCTAssertNotEqual(TabKind.of(agent: nil, title: title, hasPort: false), .container, title)
        }
    }

    /// What the shell would pass: quoted words are one, their quotes off.
    func testTheTitleIsReadInTheShellsWords() {
        XCTAssertEqual(TabKind.shellWords("  docker   ps "), ["docker", "ps"])
        XCTAssertEqual(TabKind.shellWords("-f '/w/my app/compose.yaml' run"), ["-f", "/w/my app/compose.yaml", "run"])
        XCTAssertEqual(TabKind.shellWords(#"-p 'it'\''s' "a \"b\"" c\ d ''"#), ["-p", "it's", #"a "b""#, "c d", ""])
        XCTAssertEqual(TabKind.shellWords("sh -c 'unclosed here"), ["sh", "-c", "unclosed here"])
    }

    func testAPlainShellIsTheFallback() {
        XCTAssertEqual(TabKind.of(agent: nil, title: "", hasPort: false), .shell)
        XCTAssertEqual(TabKind.of(agent: nil, title: "zsh", hasPort: false), .shell)
    }
}
