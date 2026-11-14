import Foundation
import XCTest

@testable import Overterm

/// Which names look secret (`Secrets.isSecret`): the words anywhere in the
/// name, and PASS, PWD, PASSPHRASE, PIN as one of its words — a name
/// RabbitMQ's image, MySQL's client or GPG reads was passed over, and its
/// value went to agents, the YAML tab, the `y` copy and Run Locally's line.
final class SecretsTests: XCTestCase {
    func testAWholeWordPassOrPwdIsSecret() {
        for name in [
            "RABBITMQ_DEFAULT_PASS", "MYSQL_PWD", "REDIS_PASS", "GPG_PASSPHRASE", "DB_PASS", "SMTP_PASS", "rootPwd", "dbPass", "smtp.pass", "CERT_PIN",
            "DB_PASSWORD", "API_TOKEN", "AWS_SECRET_ACCESS_KEY",
        ] {
            XCTAssertTrue(Secrets.isSecret(name), name)
        }
        for name in ["PWD", "OLDPWD", "BYPASS_CACHE", "COMPASS_URL", "PASSENGER_COUNT", "SPINNER", "LOG_LEVEL", "PORT", "KEYBOARD"] {
            XCTAssertFalse(Secrets.isSecret(name), name)
        }
        XCTAssertEqual(Secrets.tokens("rootPwd_v2.x-y"), ["ROOT", "PWD", "V2", "X", "Y"])
    }

    /// Ask Why's template part (`KubeAgentText.templateYAML`) and the YAML
    /// tab's masking: the values never in the text.
    func testATemplatesPassAndPwdValuesAreMasked() {
        let template: [String: Any] = [
            "spec": [
                "containers": [
                    [
                        "name": "mq", "image": "rabbitmq:3",
                        "env": [
                            ["name": "RABBITMQ_DEFAULT_PASS", "value": "s3cret-bunny!"], ["name": "MYSQL_PWD", "value": "hunter2-mysql"],
                            ["name": "LOG_LEVEL", "value": "debug"],
                        ],
                    ]
                ]
            ]
        ]
        let brief = KubeAgentText.templateYAML(template)
        let yaml = KubeYAML.text(KubeObjectStrip.maskingEnv(template))
        for text in [brief, yaml] {
            XCTAssertFalse(text.contains("s3cret-bunny!"), text)
            XCTAssertFalse(text.contains("hunter2-mysql"), text)
            XCTAssertTrue(text.contains("debug"), text)
        }
    }

    /// Run Locally asks for them in the tab, never copies them onto the line.
    func testRunLocallyAsksForThem() throws {
        let pod: [String: Any] = [
            "metadata": ["name": "mq-0", "namespace": "shop"],
            "spec": [
                "containers": [
                    [
                        "name": "mq", "image": "rabbitmq:3",
                        "env": [["name": "RABBITMQ_DEFAULT_PASS", "value": "s3cret-bunny!"], ["name": "MYSQL_PWD", "value": "hunter2-mysql"]],
                    ]
                ]
            ],
        ]
        let run = try XCTUnwrap(KubeRunLocally.plan(pod, container: "mq", context: "kind-fake", namespace: "shop", object: "pod shop/mq-0"))
        XCTAssertEqual(Set(run.asked.map(\.key)), ["RABBITMQ_DEFAULT_PASS", "MYSQL_PWD"])
        XCTAssertFalse(run.line().contains("s3cret-bunny!"))
        XCTAssertFalse(run.line().contains("hunter2-mysql"))
    }

    /// A quoted value is masked whole: the bare form stopped at its first
    /// space and handed the rest of a passphrase to the agent.
    func testAQuotedValueIsMaskedWhole() {
        let cases: [(String, String)] = [
            (#"password: "correct horse battery""#, #"password: "••••••""#),
            (#"{"password":"p@ss w0rd","user":"jane"}"#, #"{"password":"••••••","user":"jane"}"#),
            (#"{"client_secret": "a \"quoted\" word", "n": 1}"#, #"{"client_secret": "••••••", "n": 1}"#),
            ("passphrase='two words here' next", "passphrase='••••••' next"),
            ("DB_PASS=\"x y z\"", "DB_PASS=\"••••••\""),
            ("password=hunter2 rest", "password=•••••• rest"),
            // YAML's and SQL's single quote escapes a quote by doubling it.
            ("password: 'it''s a secret' # db", "password: '••••••' # db"),
        ]
        for (text, scrubbed) in cases {
            XCTAssertEqual(Secrets.scrubCredentials(text), scrubbed, text)
        }
        for leftover in ["horse", "battery", "w0rd", "quoted", "words", "y z", "a secret"] {
            XCTAssertFalse(cases.map { Secrets.scrubCredentials($0.0) }.joined().contains(leftover), leftover)
        }
    }

    /// A fake password for the programs' cases, made at run time.
    private let pw = ["hunt", "er2"].joined()

    /// The passwords programs take where no flag's name says so (Activity's
    /// analysis, 9.3): they went through `maskArguments` into Docker's and
    /// Kubernetes' text, agents' briefs and every command a page shows.
    func testProgramsOwnPasswordPlacesAreMasked() {
        let cases: [(String, String)] = [
            ("docker login -u acme -p \(pw)-docker registry.acme.test", "docker login -u acme -p •••••• registry.acme.test"),
            ("docker login -p\(pw)-docker", "docker login -p••••••"),
            ("docker login -p=\(pw)-docker", "docker login -p=••••••"),
            ("/usr/local/bin/docker --context acme login -p \(pw)-docker", "/usr/local/bin/docker --context acme login -p ••••••"),
            ("podman login -p \(pw)-podman quay.io", "podman login -p •••••• quay.io"),
            ("nerdctl login --username acme -p \(pw)-nerdctl", "nerdctl login --username acme -p ••••••"),
            ("helm registry login ghcr.io -u acme -p \(pw)-helm", "helm registry login ghcr.io -u acme -p ••••••"),
            ("crane auth login ghcr.io -u acme -p \(pw)-crane", "crane auth login ghcr.io -u acme -p ••••••"),
            ("sshpass -p \(pw)-ssh ssh -p 2222 acme@globex.test", "sshpass -p •••••• ssh -p 2222 acme@globex.test"),
            ("sshpass -p\(pw)-ssh scp -P 2222 a b", "sshpass -p•••••• scp -P 2222 a b"),
            ("sshpass -v -p \(pw)-ssh ssh host", "sshpass -v -p •••••• ssh host"),
            (
                "ldapsearch -x -H ldap://ldap.acme.test -D cn=admin,dc=acme -w \(pw)-ldap -b dc=acme -s sub",
                "ldapsearch -x -H ldap://ldap.acme.test -D cn=admin,dc=acme -w •••••• -b dc=acme -s sub"
            ),
            ("ldapsearch -xw\(pw)-ldap -b dc=acme", "ldapsearch -xw•••••• -b dc=acme"),
            ("ldapmodify -a -w \(pw)-ldap -f add.ldif", "ldapmodify -a -w •••••• -f add.ldif"),
            ("ldapwhoami -x -w \(pw)-ldap", "ldapwhoami -x -w ••••••"),
            ("ldappasswd -x -w \(pw)-bind -a old-\(pw) -s new-\(pw) cn=acme", "ldappasswd -x -w •••••• -a •••••• -s •••••• cn=acme"),
            ("smbclient //files.acme.test/share -U alice%\(pw)-smb", "smbclient //files.acme.test/share -U alice%••••••"),
            ("smbclient -Ualice%\(pw)-smb //files/share", "smbclient -Ualice%•••••• //files/share"),
            ("rpcclient --user=alice%\(pw)-smb files", "rpcclient --user=alice%•••••• files"),
            ("smbclient -U alice //files/share", "smbclient -U alice //files/share"),
            ("htpasswd -b .htpasswd alice \(pw)-htpasswd", "htpasswd -b .htpasswd alice ••••••"),
            ("htpasswd -bcB -C 12 .htpasswd alice \(pw)-htpasswd", "htpasswd -bcB -C 12 .htpasswd alice ••••••"),
            ("htpasswd -nb alice \(pw)-htpasswd", "htpasswd -nb alice ••••••"),
            ("htpasswd -c .htpasswd alice", "htpasswd -c .htpasswd alice"),
            ("mount_smbfs //alice:\(pw)-smbfs@files.acme.test/share /Volumes/share", "mount_smbfs //alice:••••••@files.acme.test/share /Volumes/share"),
            ("openssl rsa -in key.pem -passin pass:\(pw)-openssl -passout env:NEW", "openssl rsa -in key.pem -passin pass:•••••• -passout env:NEW"),
            // `mount` keeps its argv while mount_smbfs runs: the form, whatever the program.
            ("mount -t smbfs //alice:\(pw)-smbfs@files.acme.test/share /Volumes/share", "mount -t smbfs //alice:••••••@files.acme.test/share /Volumes/share"),
            ("acme-sync --remote=//alice:\(pw)-smbfs@files.acme.test/share", "acme-sync --remote=//alice:••••••@files.acme.test/share"),
            ("openssl enc -aes-256-cbc -k \(pw)-openssl -in a -out b", "openssl enc -aes-256-cbc -k •••••• -in a -out b"),
            ("podman pull --creds acme:\(pw)-podman quay.io/acme/web", "podman pull --creds acme:•••••• quay.io/acme/web"),
            ("buildah from --creds=acme:\(pw)-buildah quay.io/acme/web", "buildah from --creds=acme:•••••• quay.io/acme/web"),
            (
                "skopeo copy --src-creds acme:\(pw)-src --dest-creds=globex:\(pw)-dest docker://a docker://b",
                "skopeo copy --src-creds acme:•••••• --dest-creds=globex:•••••• docker://a docker://b"
            ),
            ("skopeo inspect --creds acme docker://a", "skopeo inspect --creds acme docker://a"),
            ("oras push -u acme -p \(pw)-oras registry.acme.test/web:1 a.txt", "oras push -u acme -p •••••• registry.acme.test/web:1 a.txt"),
            // A login's subcommand after the global flags and their values.
            ("docker -H tcp://docker.acme.test:2376 --tlsverify login -u acme -p \(pw)-docker", "docker -H tcp://docker.acme.test:2376 --tlsverify login -u acme -p ••••••"),
            ("docker --config /tmp/acme -l debug login -p \(pw)-docker", "docker --config /tmp/acme -l debug login -p ••••••"),
            ("helm --kube-context acme registry login ghcr.io -p \(pw)-helm", "helm --kube-context acme registry login ghcr.io -p ••••••"),
        ]
        for (line, masked) in cases {
            let words = line.split(separator: " ").map(String.init)
            XCTAssertEqual(Secrets.maskArguments(words).joined(separator: " "), masked, line)
        }
        XCTAssertTrue(Secrets.isSecret("SSHPASS"), "sshpass -e reads it")
        XCTAssertEqual(Secrets.maskArguments(["SSHPASS=\(pw)-ssh", "sshpass", "-e", "ssh", "host"]), ["SSHPASS=••••••", "sshpass", "-e", "ssh", "host"])
    }

    /// Where only a password ever goes, a `/` starts a password, not a
    /// path — one generated in 64 starts so —; a `${VAR}` alone stays. And
    /// htpasswd's options end at its first operand: a password that starts
    /// with `-` is still the password.
    func testAPasswordPlaceKeepsNoPath() {
        let cases: [(String, String)] = [
            ("docker login -u acme -p /Xy9\(pw)", "docker login -u acme -p ••••••"),
            ("sshpass -p /Xy9\(pw) ssh h", "sshpass -p •••••• ssh h"),
            ("ldapsearch -x -w /Xy9\(pw) -b dc=acme", "ldapsearch -x -w •••••• -b dc=acme"),
            ("smbclient -U acme%/Xy9\(pw) //files/share", "smbclient -U acme%•••••• //files/share"),
            ("openssl rsa -in key.pem -passin pass:/Xy9\(pw)", "openssl rsa -in key.pem -passin pass:••••••"),
            ("htpasswd -b .htpasswd acme /Xy9\(pw)", "htpasswd -b .htpasswd acme ••••••"),
            ("podman pull --creds acme:/Xy9\(pw) quay.io/acme/web", "podman pull --creds acme:•••••• quay.io/acme/web"),
            ("SSHPASS=/Xy9\(pw) sshpass -e ssh h", "SSHPASS=•••••• sshpass -e ssh h"),
            ("htpasswd -b .htpasswd acme -Xy9\(pw)", "htpasswd -b .htpasswd acme ••••••"),
            ("htpasswd -nb acme -Xy9\(pw)", "htpasswd -nb acme ••••••"),
            ("htpasswd -bC12 .htpasswd acme \(pw)-htpasswd", "htpasswd -bC12 .htpasswd acme ••••••"),
            ("htpasswd -b -- .htpasswd acme \(pw)-htpasswd", "htpasswd -b -- .htpasswd acme ••••••"),
            // A flag that may name a file keeps its path, as it always did.
            ("acme-server --key /certs/acme.pem", "acme-server --key /certs/acme.pem"),
        ]
        for (line, masked) in cases {
            let words = line.split(separator: " ").map(String.init)
            XCTAssertEqual(Secrets.maskArguments(words).joined(separator: " "), masked, line)
            XCTAssertFalse(Secrets.maskArguments(words).joined().contains(pw), line)
        }
        XCTAssertEqual(Secrets.maskArguments(["sshpass", "-p", "\"${SSH_PW}\"", "ssh", "h"]), ["sshpass", "-p", "\"${SSH_PW}\"", "ssh", "h"])
    }

    /// Each rule ends with its command: a port's `-p` elsewhere is no
    /// password — a later `docker run`, the command sshpass runs, another
    /// program's `-w` or `-U`.
    func testAProgramsRuleEndsWithItsCommand() {
        let unchanged = [
            "docker run -p 8080:80 nginx",
            "docker compose up -p acme",
            "podman run -p 5432:5432 postgres",
            "helm install acme ./chart -p",
            "ssh -p 2222 acme@globex.test",
            "curl -w %{http_code} https://acme.test",
            "lsof -U",
            "grep -w login file",
            "openssl s_client -connect acme.test:443 -passin env:PW",
            // `login` as a container's name, a context's, an image's: no subcommand.
            "docker run --name login -p 8080:80 nginx",
            "podman run --name login -p 3000:3000 acme/web",
            "docker --context login run -p 8080:80 nginx",
            "docker run -d acme/login -p 8080",
            "helm install login ./chart --set registry.login=true -p",
        ]
        for line in unchanged {
            let words = line.split(separator: " ").map(String.init)
            XCTAssertEqual(Secrets.maskArguments(words), words, line)
        }
        let script = ["sh", "-c", "docker login -u acme -p \(pw)-docker && docker run -p 8080:80 nginx; sshpass -p \(pw)-ssh ssh -p 2222 h"]
        XCTAssertEqual(
            Secrets.maskArguments(script),
            ["sh", "-c", "docker login -u acme -p •••••• && docker run -p 8080:80 nginx; sshpass -p •••••• ssh -p 2222 h"])
        let glued = "docker login -p \(pw)-docker; docker run -p 8080:80 nginx".split(separator: " ").map(String.init)
        XCTAssertEqual(Secrets.maskArguments(glued).joined(separator: " "), "docker login -p ••••••; docker run -p 8080:80 nginx")
        // A ${VAR} stays as written, as for every other flag.
        XCTAssertEqual(Secrets.maskArguments(["docker", "login", "-p", "${REGISTRY_PASSWORD}"]), ["docker", "login", "-p", "${REGISTRY_PASSWORD}"])
    }

    /// A linker's argv is thousands of words: one pass, not one a word.
    func testALongCommandIsMaskedInOnePass() {
        let words = ["ld"] + (0..<20_000).map { "obj\($0).o" } + ["docker", "login", "-p", "\(pw)-docker"]
        let masked = Secrets.maskArguments(words)
        XCTAssertEqual(masked.last, "••••••")
        XCTAssertEqual(masked.count, words.count)
    }
}

/// ⌘L on a selection in a pod's or a pinned tab (rule 9): what the cluster
/// printed is scrubbed as the page's Logs tab scrubs it; another tab's is
/// handed on as selected.
final class AskSelectionTests: XCTestCase {
    func testAPodOrPinnedTabsSelectionIsScrubbed() {
        let token = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJhY21lIn0.c2lnbmF0dXJlLXZhbHVl"
        let selection = "GET /api 200 Authorization: Bearer \(token)\nDB_PASSWORD=hunter2-acme postgres://shop:pw-acme@db:5432/shop"
        for (kind, pinned) in [(TabKind.pod, false), (.kubernetes, false), (.shell, true)] {
            let text = AskSelection.text(selection, kind: kind, pinned: pinned)
            for secret in [token, "hunter2-acme", "pw-acme"] { XCTAssertFalse(text.contains(secret), "\(kind): \(text)") }
            XCTAssertTrue(text.contains("GET /api 200"), text)
        }
        XCTAssertEqual(AskSelection.text(selection, kind: .shell, pinned: false), selection, "another tab's selection as it is")
    }
    /// A pod's tab knows its pod's plain env: a value printed bare is
    /// masked, as the Logs tab masks it. The command the selection came
    /// from goes scrubbed too.
    func testAPodsEnvAndTheCommandAreScrubbed() {
        let env = [(key: "DB_PASSWORD", value: "acme-s3cret-value")]
        let text = AskSelection.text("connecting with acme-s3cret-value", kind: .pod, pinned: true, env: env)
        XCTAssertFalse(text.contains("acme-s3cret-value"), text)
        let block = CommandBlock(id: 1, command: "kubectl --token abc123-acme --context kind-fake get po", startRow: 0, endRow: 1, exit: 0, seconds: 1)
        let command = AskSelection.command(block, kind: .shell, pinned: true)
        XCTAssertFalse(command?.command.contains("abc123-acme") ?? true, command?.command ?? "")
        XCTAssertTrue(command?.command.contains("--context kind-fake get po") ?? false, command?.command ?? "")
        XCTAssertEqual(AskSelection.command(block, kind: .shell, pinned: false), block, "another tab's command as it is")
    }
}
