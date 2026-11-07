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
        ]
        for (text, scrubbed) in cases {
            XCTAssertEqual(Secrets.scrubCredentials(text), scrubbed, text)
        }
        for leftover in ["horse", "battery", "w0rd", "quoted", "words", "y z"] {
            XCTAssertFalse(cases.map { Secrets.scrubCredentials($0.0) }.joined().contains(leftover), leftover)
        }
    }
}
