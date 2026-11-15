import XCTest

@testable import Overterm

/// The one command-line splitter Kubernetes' pane header, a tab's kind and
/// Terraform's read a pane's command through.
final class ShellCommandLineTests: XCTestCase {
    func testWordsAreTheShellsWithTheirQuotesOff() {
        XCTAssertEqual(ShellCommandLine.words("  terraform   plan "), ["terraform", "plan"])
        XCTAssertEqual(ShellCommandLine.words("terraform -chdir='envs/acme prod' plan"), ["terraform", "-chdir=envs/acme prod", "plan"])
        XCTAssertEqual(ShellCommandLine.words(#"-p 'it'\''s' "a \"b\"" c\ d ''"#), ["-p", "it's", #"a "b""#, "c d", ""])
        XCTAssertEqual(ShellCommandLine.words("sh -c 'unclosed here"), ["sh", "-c", "unclosed here"])
        // Operators are words when the line isn't split into commands.
        XCTAssertEqual(ShellCommandLine.words("a | b && c"), ["a", "|", "b", "&&", "c"])
        XCTAssertEqual(ShellCommandLine.words("a\nb"), ["a", "b"])
    }

    func testSegmentsSplitAtOperatorsOutsideQuotes() {
        XCTAssertEqual(
            ShellCommandLine.segments(of: "cd envs/prod && terraform plan | tee out; echo 'a|b' & (ls)"),
            [["cd", "envs/prod"], ["terraform", "plan"], ["tee", "out"], ["echo", "a|b"], ["ls"]])
        XCTAssertEqual(ShellCommandLine.segments(of: "a\nb"), [["a"], ["b"]])
        XCTAssertEqual(ShellCommandLine.segments(of: " ; && "), [])
    }

    func testTheCommandIsFoundBehindAssignmentsAndWrappers() throws {
        let command = try XCTUnwrap(ShellCommandLine.command(in: ShellCommandLine.words("env TF_WORKSPACE=prod terraform -chdir=envs/prod apply")))
        XCTAssertEqual(command.tool, "terraform")
        XCTAssertEqual(command.wrappers, ["env"])
        XCTAssertEqual(command.assigned("TF_WORKSPACE"), "prod")
        XCTAssertEqual(command.arguments, ["-chdir=envs/prod", "apply"])

        let sudo = try XCTUnwrap(ShellCommandLine.commands(in: "AWS_PROFILE=acme-prod-admin sudo -u root -E /opt/homebrew/bin/terraform apply").first)
        XCTAssertEqual(sudo.executable, "/opt/homebrew/bin/terraform")
        XCTAssertEqual(sudo.tool, "terraform")
        XCTAssertEqual(sudo.wrappers, ["sudo"])
        XCTAssertEqual(sudo.assignments, [.init(name: "AWS_PROFILE", value: "acme-prod-admin")])

        let watched = try XCTUnwrap(ShellCommandLine.commands(in: "watch -n 2 -d terragrunt run --all apply").first)
        XCTAssertEqual(watched.tool, "terragrunt")
        XCTAssertEqual(watched.arguments, ["run", "--all", "apply"])

        let unset = try XCTUnwrap(ShellCommandLine.commands(in: "env -u TF_DATA_DIR TF_DATA_DIR= time tofu plan").first)
        XCTAssertEqual(unset.wrappers, ["env", "time"])
        XCTAssertEqual(unset.assigned("TF_DATA_DIR"), "")
        XCTAssertEqual(unset.tool, "tofu")
    }

    func testTheLastAssignmentIsTheOneTheCommandSees() {
        let command = ShellCommandLine.commands(in: "TF_WORKSPACE=a env TF_WORKSPACE=b terraform plan").first
        XCTAssertEqual(command?.assigned("TF_WORKSPACE"), "b")
        XCTAssertNil(command?.assigned("AWS_PROFILE"))
    }

    func testEveryCommandOfALineInOrder() {
        XCTAssertEqual(
            ShellCommandLine.commands(in: "cd envs/prod && terraform init && terraform apply plan.out | tee log").map(\.tool),
            ["cd", "terraform", "terraform", "tee"])
    }

    func testNoCommandWhereThereIsNone() {
        XCTAssertNil(ShellCommandLine.command(in: []))
        XCTAssertNil(ShellCommandLine.command(in: ["FOO=1", "BAR=2"]))
        XCTAssertNil(ShellCommandLine.command(in: ["sudo", "-u", "root"]))
        // An option-looking word without a wrapper before it is the command.
        XCTAssertEqual(ShellCommandLine.command(in: ["-x"])?.tool, "-x")
        // `=` first, or a name with a dash, is no assignment.
        XCTAssertNil(ShellCommandLine.assignment("=x"))
        XCTAssertNil(ShellCommandLine.assignment("A-B=x"))
        XCTAssertEqual(ShellCommandLine.assignment("TF_VAR_acme=a=b"), .init(name: "TF_VAR_acme", value: "a=b"))
    }

    /// Reserved words and grouping aren't commands: what follows them is.
    func testReservedWordsAreSkipped() {
        let tools = { (line: String) in ShellCommandLine.commands(in: line).map(\.tool) }
        XCTAssertEqual(tools("if terraform plan; then terraform apply; fi"), ["terraform", "terraform"])
        XCTAssertEqual(ShellCommandLine.commands(in: "if terraform plan; then terraform apply; fi").last?.arguments, ["apply"])
        XCTAssertEqual(tools("{ terraform apply; }"), ["terraform"])
        XCTAssertEqual(tools("! terraform apply"), ["terraform"])
        XCTAssertEqual(tools("for d in envs/*; do terraform -chdir=$d apply; done"), ["terraform"])
        XCTAssertEqual(tools("while true; do terraform apply; done"), ["true", "terraform"])
        XCTAssertEqual(tools("if ! terraform plan; then echo no; else terraform apply; fi"), ["terraform", "echo", "terraform"])
        XCTAssertEqual(tools("case $ENV in prod) terraform apply;; esac"), ["terraform"])
        XCTAssertEqual(tools("[[ -f plan.out ]] && terraform apply plan.out"), ["terraform"])
        // Only at the command's place: an argument named `if` is an argument.
        XCTAssertEqual(ShellCommandLine.commands(in: "echo if then").first?.arguments, ["if", "then"])
    }

    /// Credential and exec wrappers, their `--` and the options that take a value.
    func testCredentialAndExecWrappersAreFollowed() throws {
        let vault = try XCTUnwrap(ShellCommandLine.commands(in: "aws-vault exec acme-prod -- terraform apply").first)
        XCTAssertEqual(vault.tool, "terraform")
        XCTAssertEqual(vault.wrappers, ["aws-vault"])
        XCTAssertEqual(vault.arguments, ["apply"])
        let cases: [(String, [String])] = [
            ("aws-vault exec acme-prod terraform apply", ["apply"]),
            ("aws-vault exec --duration 1h acme-prod -- terraform apply", ["apply"]),
            ("aws-vault --backend=file exec acme-prod -- terraform destroy", ["destroy"]),
            ("op run --env-file .env -- terraform apply", ["apply"]),
            ("op run -- terraform apply", ["apply"]),
            ("doppler run -p acme -c prd -- terraform apply", ["apply"]),
            ("mise exec -- terraform apply", ["apply"]),
            ("mise x terraform@1.9 -- terraform apply", ["apply"]),
            ("direnv exec . terraform apply", ["apply"]),
            ("timeout 600 terraform apply", ["apply"]),
            ("timeout -s KILL 10m terraform apply", ["apply"]),
            ("nice -n 10 terraform apply", ["apply"]),
            ("doas -u root terraform apply", ["apply"]),
            ("xargs -n 1 terraform apply", ["apply"]),
            ("asdf exec terraform apply", ["apply"]),
            ("sudo aws-vault exec acme-prod -- env TF_WORKSPACE=prod terraform apply", ["apply"]),
        ]
        for (line, arguments) in cases {
            let command = ShellCommandLine.commands(in: line).first
            XCTAssertEqual(command?.tool, "terraform", line)
            XCTAssertEqual(command?.arguments, arguments, line)
        }
        XCTAssertEqual(
            ShellCommandLine.commands(in: "sudo aws-vault exec acme-prod -- env TF_WORKSPACE=prod terraform apply").first?.wrappers,
            ["sudo", "aws-vault", "env"])
        // Another subcommand: the wrapper's word is the command.
        XCTAssertEqual(ShellCommandLine.commands(in: "op read op://acme/terraform").first?.tool, "op")
        XCTAssertEqual(ShellCommandLine.commands(in: "aws-vault list").first?.tool, "aws-vault")
        XCTAssertEqual(ShellCommandLine.commands(in: "mise install terraform").first?.tool, "mise")
        XCTAssertNil(ShellCommandLine.command(in: ["aws-vault", "exec", "acme-prod"]))
    }

    /// A command inside a string a shell runs is read as a line of its own.
    func testCommandsInsideStringsAreRead() throws {
        let tools = { (line: String) in ShellCommandLine.commands(in: line).map(\.tool) }
        let bash = try XCTUnwrap(ShellCommandLine.commands(in: "AWS_PROFILE=acme-prod bash -c 'terraform apply -auto-approve'").first)
        XCTAssertEqual(bash.tool, "terraform")
        XCTAssertEqual(bash.arguments, ["apply", "-auto-approve"])
        XCTAssertEqual(bash.wrappers, ["bash"])
        XCTAssertEqual(bash.assigned("AWS_PROFILE"), "acme-prod")
        XCTAssertEqual(tools("sh -c 'cd envs/prod && terraform apply'"), ["cd", "terraform"])
        XCTAssertEqual(tools("zsh -lc \"terraform apply\""), ["terraform"])
        XCTAssertEqual(tools("bash -o pipefail -c 'terraform plan | tee log'"), ["terraform", "tee"])
        XCTAssertEqual(tools("bash deploy.sh"), ["bash"])
        XCTAssertEqual(tools("bash"), ["bash"])

        let split = try XCTUnwrap(ShellCommandLine.commands(in: "env -S 'TF_WORKSPACE=prod terraform apply'").first)
        XCTAssertEqual(split.tool, "terraform")
        XCTAssertEqual(split.arguments, ["apply"])
        XCTAssertEqual(split.assigned("TF_WORKSPACE"), "prod")
        XCTAssertEqual(tools("env --split-string='terraform apply' -auto-approve"), ["terraform"])
        XCTAssertEqual(ShellCommandLine.commands(in: "env -S'terraform apply' -auto-approve").first?.arguments, ["apply", "-auto-approve"])

        XCTAssertEqual(tools("doppler run --command 'terraform apply'"), ["terraform"])
        XCTAssertEqual(tools("mise exec -c 'terraform apply'"), ["terraform"])
        XCTAssertEqual(tools("watch 'terraform plan'"), ["terraform"])
        XCTAssertEqual(tools("aws-vault exec acme-prod -- bash -c \"env -S 'terraform apply'\""), ["terraform"])
        XCTAssertEqual(
            ShellCommandLine.commands(in: "sudo aws-vault exec acme-prod -- bash -c 'terraform apply'").first?.wrappers,
            ["sudo", "aws-vault", "bash"])
        // Bounded: strings inside strings are read only so deep.
        var line = "terraform apply"
        for _ in 0..<10 { line = "bash -c \(KubectlLine.quoted(line))" }
        XCTAssertEqual(tools(line), [])
    }

    /// Kubernetes reads through it unchanged.
    func testKubectlIsReadThroughIt() {
        XCTAssertEqual(KubeCommandLine.parse("cd x && KUBECONFIG=/tmp/a sudo -E kubectl --context fake-prod get pods")?.context, "fake-prod")
        XCTAssertEqual(KubeCommandLine.parse("cd x && KUBECONFIG=/tmp/a sudo -E kubectl get pods")?.kubeconfig, "/tmp/a")
        XCTAssertNil(KubeCommandLine.parse("terraform apply"))
    }
}
