import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell

/// What Activity shows of a command line, a title, and what an agent reads
/// (docs/design/activity/analysis.md, 9.3, 8.4): masked once, everywhere.
final class ActivityTextTests: XCTestCase {
    private func command(_ line: String) -> String { ActivityText.command(line.split(separator: " ").map(String.init)) }

    func testSecretFlagsAndValuesAreMasked() {
        let cases: [(String, String)] = [
            ("python3 server.py --password=hunter2-acme", "python3 server.py --password=••••••"),
            ("python3 server.py --token hunter2-acme --port 8000", "python3 server.py --token •••••• --port 8000"),
            ("mysql -uroot -phunter2-acme shop", "mysql -uroot -p•••••• shop"),
            ("env API_KEY=hunter2-acme LOG_LEVEL=debug node app.js", "env API_KEY=•••••• LOG_LEVEL=debug node app.js"),
            ("psql postgres://acme:hunter2-acme@db.acme.test:5432/shop", "psql postgres://acme:••••••@db.acme.test:5432/shop"),
            ("curl -H Authorization:Bearer eyJhbGciOi.acme", "curl -H Authorization:Bearer ••••••"),
            ("gh api -H X-Acme:ghp_abcdefghijklmnop12345", "gh api -H X-Acme:ghp_••••••"),
            ("redis-cli -a hunter2-acme ping", "redis-cli -a •••••• ping"),
        ]
        for (line, masked) in cases { XCTAssertEqual(command(line), masked, line) }
        let pem = ActivityText.command(["deploy", "--cert", "-----BEGIN PRIVATE KEY-----\nMIIEacme\n-----END PRIVATE KEY-----"])
        XCTAssertFalse(pem.contains("MIIEacme"), pem)
    }

    /// The gaps 9.3 names, closed in `Secrets` first: each password where no
    /// flag's name says so.
    func testTheGapsOfTheAnalysisAreClosed() {
        let cases: [(String, String)] = [
            ("docker login -u acme -p hunter2-docker", "docker login -u acme -p ••••••"),
            ("podman login -p hunter2-podman quay.io", "podman login -p •••••• quay.io"),
            ("nerdctl login -p hunter2-nerdctl", "nerdctl login -p ••••••"),
            ("helm registry login ghcr.io -p hunter2-helm", "helm registry login ghcr.io -p ••••••"),
            ("sshpass -p hunter2-ssh ssh -p 2222 acme@globex.test", "sshpass -p •••••• ssh -p 2222 acme@globex.test"),
            ("ldapsearch -x -w hunter2-ldap -b dc=acme", "ldapsearch -x -w •••••• -b dc=acme"),
            ("ldapmodify -w hunter2-ldap -f change.ldif", "ldapmodify -w •••••• -f change.ldif"),
            ("smbclient -U acme%hunter2-smb //files.acme.test/share", "smbclient -U acme%•••••• //files.acme.test/share"),
            ("htpasswd -b .htpasswd acme hunter2-htpasswd", "htpasswd -b .htpasswd acme ••••••"),
        ]
        for (line, masked) in cases {
            XCTAssertEqual(command(line), masked, line)
            XCTAssertFalse(command(line).contains("hunter2"), line)
        }
    }

    /// A tab title is a command too: its words are masked as a command's,
    /// where no `:` or `=` says a password follows, then as text — for the
    /// screen and for an agent.
    func testATitleIsMaskedAsACommand() {
        let cases: [(String, String)] = [
            ("psql postgres://acme:hunter2-acme@db/shop — export TOKEN=abc", "psql postgres://acme:••••••@db/shop — export TOKEN=••••••"),
            ("psql --password hunter2-acme -h db.acme.test", "psql --password •••••• -h db.acme.test"),
            ("mysql -uroot -phunter2-acme shop", "mysql -uroot -p•••••• shop"),
            ("docker login -u acme -p hunter2-acme", "docker login -u acme -p ••••••"),
            ("sshpass -p hunter2-acme ssh  globex.test", "sshpass -p •••••• ssh  globex.test"),
            ("redis-cli -a hunter2-acme ping", "redis-cli -a •••••• ping"),
            ("vim README.md", "vim README.md"),
        ]
        for (title, masked) in cases {
            XCTAssertEqual(ActivityText.title(title), masked, title)
            XCTAssertEqual(ActivityText.forAgents(title, home: "/Users/acme"), masked, title)
            XCTAssertFalse(ActivityText.forAgents(title, home: "/Users/acme").contains("hunter2"), title)
        }
        XCTAssertEqual(ActivityText.display("vim README.md"), "vim README.md")
    }

    /// A long title or command for an agent is masked in one pass, then cut.
    func testALongTitleIsMaskedWhole() {
        let words = (0..<20_000).map { "obj\($0).o" }
        let title = "zsh -c 'ld " + words.joined(separator: " ") + " && docker login -p hunter2-acme registry.acme.test'"
        let masked = ActivityText.title(title)
        XCTAssertTrue(masked.hasSuffix("docker login -p •••••• registry.acme.test'"))
        XCTAssertEqual(masked.count, title.count - "hunter2-acme".count + "••••••".count)
        XCTAssertEqual(ActivityText.forAgents(title, home: "/Users/acme").count, ActivityText.agentFieldLimit)
    }

    func testWhatAnAgentReads() {
        let home = "/Users/acme"
        XCTAssertEqual(ActivityText.forAgents("node /Users/acme/dev/globex/server.js --token=abc123", home: home), "node ~/dev/globex/server.js --token=••••••")
        XCTAssertEqual(ActivityText.forAgents("cd /Users/acme2/x", home: home), "cd /Users/acme2/x", "another user's folder, not ~")
        XCTAssertEqual(ActivityText.forAgents("/Users/acme", home: home), "~")
        // One line, every character visible: a title can't draw a second
        // line, a direction override shows as its code.
        XCTAssertEqual(ActivityText.forAgents("line one\nline two\u{202E}", home: home), "line one line two\\u{202E}")
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(ActivityText.forAgents(long, home: home).count, ActivityText.agentFieldLimit)
        XCTAssertEqual(ActivityText.forAgents(long, home: home, limit: nil).count, 300, "Overterm's own words aren't cut")
    }

    /// An interpreter's label names what it runs (6.5).
    func testInterpreterLabels() throws {
        let cases: [(String, String?)] = [
            ("node /Users/acme/dev/globex/node_modules/vite/bin/vite.js --port 5173", "vite"),
            ("node /Users/acme/dev/globex/node_modules/.bin/eslint src", "eslint"),
            ("node /Users/acme/dev/globex/node_modules/@playwright/mcp/cli.js", "@playwright/mcp"),
            ("node --inspect --require ts-node/register server.ts", "server.ts"),
            ("/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js exec @playwright/mcp", "npm exec @playwright/mcp"),
            ("node /usr/local/bin/npm run dev", "npm run dev"),
            ("npm exec @playwright/mcp", "npm exec @playwright/mcp"),
            ("npx -y @modelcontextprotocol/server-filesystem /tmp", "npx @modelcontextprotocol/server-filesystem"),
            ("pnpm dev", "pnpm dev"),
            ("uvx mcp-server-fetch", "uvx mcp-server-fetch"),
            ("python -m http.server 8000", "python -m http.server"),
            ("python3.12 -u -m uvicorn app:main", "python3.12 -m uvicorn"),
            ("/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python manage.py runserver", "manage.py"),
            ("python3 /Users/acme/dev/globex/.venv/bin/uvicorn app:main", "uvicorn"),
            ("python3 -c import time", "python3 -c"),
            ("ruby bin/rails server", "rails"),
            ("java -Xmx2g -jar /opt/acme/globex-server.jar", "globex-server.jar"),
            ("deno run --allow-net main.ts", "main.ts"),
            ("bun run dev.ts", "dev.ts"),
            ("next-server", nil),
            ("zsh -l", nil),
        ]
        for (line, label) in cases {
            XCTAssertEqual(ActivityText.label(line.split(separator: " ").map(String.init)), label, line)
        }
        XCTAssertNil(ActivityText.label([]))
        // Masked whole, then cut: a cut inside the userinfo would have lost
        // the `@` that says a password ends there.
        let password = "acme" + String(repeating: "hunter2", count: 12)
        let url = "git+https://acme:\(password)@git.acme.test/globex/" + String(repeating: "tool", count: 20) + ".git"
        let masked = try XCTUnwrap(ActivityText.label(["npx", url]))
        XCTAssertFalse(masked.contains("hunter2"), masked)
        XCTAssertEqual(masked.count, ActivityText.labelLimit)
        XCTAssertTrue(masked.hasPrefix("npx git+https://acme:••••••@git.acme.test/globex/tool"), masked)
        XCTAssertEqual(ActivityText.interpreter("python3.12"), "python")
        XCTAssertEqual(ActivityText.interpreter("Python"), "python")
        XCTAssertNil(ActivityText.interpreter("pythonista"))
    }
}
