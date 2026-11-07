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
