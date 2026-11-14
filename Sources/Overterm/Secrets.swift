import Foundation

/// What looks secret, hidden where a person or an agent reads it — Docker's
/// Inspect and its MCP tools, a Kubernetes object's YAML, a brief or a log's
/// lines handed to an agent. Shared by Docker and Kubernetes (Docker calls
/// it `DockerSecrets`); pure.
///
/// - **Env values** whose names look secret are masked (`masked`), and
///   taken out of other text (`scrub`: the env's values, every URL's
///   password) — Docker's rules, unchanged.
/// - **Credentials in text** (`scrubCredentials`), for what has no env to
///   say which values are secret — a pod's log, an event's message, a
///   brief: PEM blocks' bodies, bearer tokens, JWTs, AWS keys, a
///   kubeconfig's credential fields (`token`, `client-key-data`,
///   `client-certificate-data`, `password`, an auth provider's
///   `id-token`, `refresh-token`, `client-secret`…), `password=`-style
///   pairs, and base64-looking blobs (`maskBase64Blobs`).
enum Secrets {
    static let words = ["PASSWORD", "PASSWD", "SECRET", "TOKEN", "KEY", "CREDENTIAL", "PRIVATE", "AUTH", "SESSION", "SALT", "DSN"]
    /// Words that are secret only as a whole word of the name — `_`, `-`,
    /// `.` or a camelCase hump around them: `RABBITMQ_DEFAULT_PASS`,
    /// `MYSQL_PWD`, `GPG_PASSPHRASE`, Helm's `rootPwd`, a `CERT_PIN` — never
    /// `BYPASS_CACHE`, `COMPASS_URL` or `PASSENGER_COUNT`.
    static let tokenWords: Set<String> = ["PASS", "PWD", "PASSPHRASE", "PIN"]
    /// Keys that carry those words and aren't secrets: the shell's working
    /// directory is `PWD`.
    static let harmless: Set<String> = ["KEYBOARD", "PUBLIC_KEY_PATH", "AUTH_ENABLED", "MONKEY", "PWD", "OLDPWD"]
    /// Secret names none of the words find: `sshpass -e` reads the password
    /// from `SSHPASS`.
    static let secretNames: Set<String> = ["SSHPASS"]

    static func isSecret(_ key: String) -> Bool {
        let upper = key.uppercased()
        guard !harmless.contains(upper) else { return false }
        return secretNames.contains(upper) || words.contains { upper.contains($0) } || !tokenWords.isDisjoint(with: tokens(key))
    }

    /// A name's words: split on anything not a letter or digit, and where a
    /// lowercase letter or digit meets an uppercase one; uppercased.
    static func tokens(_ key: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var afterLower = false
        func flush() {
            if !current.isEmpty { tokens.append(current.uppercased()) }
            current = ""
        }
        for character in key {
            guard character.isLetter || character.isNumber else {
                flush()
                afterLower = false
                continue
            }
            if character.isUppercase, afterLower { flush() }
            current.append(character)
            afterLower = character.isLowercase || character.isNumber
        }
        flush()
        return tokens
    }

    static func mask(_ value: String) -> String { value.isEmpty ? "" : "••••••" }

    /// `postgres://user:pass@host/db` keeps everything but the password.
    /// A URL's userinfo holds no `/`, `?` or `#` (RFC 3986), so a port
    /// and a later `@` (`http://api:8080/users/jane@example.com`) are no
    /// password.
    static func maskURL(_ value: String) -> String {
        // No user is Redis's way: `redis://:pass@host`.
        guard let range = value.range(of: #"://[^:/?#@\s]*:([^/?#@\s]+)@"#, options: .regularExpression) else { return value }
        let segment = value[range]
        guard let colon = segment.dropFirst(3).firstIndex(of: ":"), let at = segment.lastIndex(of: "@") else { return value }
        return value.replacingCharacters(in: segment.index(after: colon)..<at, with: "••••••")
    }

    static func masked(_ key: String, _ value: String) -> String {
        isSecret(key) ? mask(value) : maskURL(value)
    }

    /// Every secret value in a set of env entries, to take out of other
    /// text (a log line an agent is shown). Besides `names` the text says
    /// anyway: a dev stack's password is often its image's name
    /// (`POSTGRES_PASSWORD=postgres`), and taking that out blanks the
    /// container's own name, its paths and its log, not a secret.
    static func values(in env: [(key: String, value: String)], besides names: Set<String> = []) -> [String] {
        env.filter { isSecret($0.key) && $0.value.count >= 4 && !names.contains($0.value) }.map(\.value)
    }

    static func redact(_ text: String, values: [String]) -> String {
        values.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: "••••••") }
    }

    /// Every URL's password in `text` masked, not just the first: a log
    /// line can name two databases. No `/`, `?` or `#` in a password, as
    /// in `maskURL`: a request's path with an email in it stays.
    static func maskURLs(in text: String) -> String {
        guard hasBytes(text, Array("://".utf8)) else { return text }
        return text.replacingOccurrences(of: #"(://[^:/?#@\s]*:)([^/?#@\s]+)(@)"#, with: "$1••••••$3", options: .regularExpression)
    }

    /// What an agent may read of `text`: the env's secret values (but
    /// `names`, see `values`) and every URL's password taken out — it
    /// lands in the agent's transcript.
    static func scrub(_ text: String, env: [(key: String, value: String)], keeping names: Set<String> = []) -> String {
        maskURLs(in: redact(text, values: values(in: env, besides: names)))
    }

    /// `${VAR}` or `$VAR`, nothing else: a default (`${VAR:-pw}`) may be
    /// the secret itself.
    static func isReference(_ text: String) -> Bool {
        text.range(of: #"^\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)$"#, options: .regularExpression) != nil
    }

    /// A command's words, what its secret-looking flags give masked: the
    /// word after `--requirepass`, `--password`, `--token`, `--api-key`,
    /// redis-cli's `-a`, mongosh's `-p`; `--flag=value` and `KEY=value` by
    /// their name; mysql's `-pvalue`; curl's `-u user:password` past the
    /// colon; the passwords programs take in flags and places of their own
    /// (`maskProgramPasswords`); `//user:password@server`, whatever the
    /// program (`maskNetworkPath`). A shell script's words (`sh -c '…'`,
    /// `CMD-SHELL`) the same. Compose has put `.env`'s values into a
    /// command already, so the container's env can't name them all. A
    /// `${VAR}` stays as written.
    static func maskArguments(_ words: [String]) -> [String] {
        let words = maskProgramPasswords(words)
        enum Pending { case secret, userinfo }
        let programs = Set(words.map { ($0 as NSString).lastPathComponent })
        let redis = programs.contains("redis-cli")
        let curl = programs.contains("curl")
        let mongo = !programs.isDisjoint(with: ["mongosh", "mongo"])
        let mysql = !programs.isDisjoint(with: ["mysql", "mysqladmin", "mysqldump", "mysqlshow", "mysqlcheck", "mariadb", "mariadb-admin", "mariadb-dump"])
        var pending: Pending?
        let masked = words.map { word -> String in
            // A flag after a flag: the first one took no value.
            if let wanted = pending, !word.hasPrefix("--") {
                pending = nil
                return wanted == .userinfo ? maskUserinfo(word) : maskValue(word)
            }
            pending = nil
            if word.contains(where: \.isWhitespace) { return maskScript(word) }
            if word.hasPrefix("-"), word.count > 1 {
                let flag = String(word.drop { $0 == "-" })
                let dashes = String(word.prefix(word.count - flag.count))
                if let equals = flag.firstIndex(of: "=") {
                    let name = String(flag[..<equals])
                    let value = String(flag[flag.index(after: equals)...])
                    if curl && name == "user" { return dashes + name + "=" + maskUserinfo(value) }
                    return isSecretFlag(name) ? dashes + name + "=" + maskValue(value) : word
                }
                let long = dashes.count > 1
                if isSecretFlag(flag) || (redis && word == "-a") || (mongo && word == "-p") {
                    pending = .secret
                } else if curl && (word == "-u" || word == "--user") {
                    pending = .userinfo
                } else if curl && !long && flag.hasPrefix("u") {
                    return "-u" + maskUserinfo(String(flag.dropFirst()))
                } else if mysql && !long && flag.hasPrefix("p") && flag.count > 1 {
                    return "-p" + maskValue(String(flag.dropFirst()))
                }
                return word
            }
            if let equals = word.firstIndex(of: "=") {
                let name = String(word[..<equals])
                if name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil, isSecret(name) {
                    let value = String(word[word.index(after: equals)...])
                    // `SSHPASS` holds a password and nothing else: a `/` starts one, no path.
                    return name + "=" + (secretNames.contains(name.uppercased()) ? maskPassword(value) : maskValue(value))
                }
            }
            return word
        }
        return masked.map(maskNetworkPath)
    }

    /// A flag's name that says a secret follows: the env's words, and a
    /// pass (`--requirepass`, `--pass`, `--db-pass`).
    static func isSecretFlag(_ name: String) -> Bool {
        let lower = name.lowercased()
        return isSecret(name.replacingOccurrences(of: "-", with: "_")) || lower.hasSuffix("pass") || lower.contains("passphrase")
    }

    /// A shell script's words masked in place, its spacing kept.
    private static func maskScript(_ script: String) -> String {
        let string = script as NSString
        guard let words = try? NSRegularExpression(pattern: #"\S+"#) else { return script }
        let matches = words.matches(in: script, range: NSRange(location: 0, length: string.length))
        let masked = maskArguments(matches.map { string.substring(with: $0.range) })
        var out = script as NSString
        for (match, word) in zip(matches, masked).reversed() { out = out.replacingCharacters(in: match.range, with: word) as NSString }
        return out as String
    }

    /// A flag's value: a `${VAR}` kept as written, a path too (`--key
    /// /certs/key.pem` names a file, not the key).
    private static func maskValue(_ value: String) -> String {
        let bare = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return isReference(bare) || bare.hasPrefix("/") ? value : mask(value)
    }

    /// A value in a place that only ever holds a password — a registry
    /// login's `-p`, sshpass's, the LDAP tools' `-w`, Samba's `%…`,
    /// htpasswd's, openssl's `pass:`, `SSHPASS` —: only a `${VAR}` kept as
    /// written. No path: one generated password in 64 starts with `/`, and
    /// `maskValue` would have shown it whole.
    private static func maskPassword(_ value: String) -> String {
        isReference(value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) ? value : mask(value)
    }

    /// `user:password`: the user kept.
    private static func maskUserinfo(_ value: String) -> String {
        guard let colon = value.firstIndex(of: ":") else { return value }
        return String(value[...colon]) + maskValue(String(value[value.index(after: colon)...]))
    }
}

// MARK: Programs' own password flags

extension Secrets {
    /// Registry clients whose `login` takes the password as `-p`, Docker's
    /// flags; `helm registry login` and `crane auth login` take it the same.
    static let registryClients: Set<String> = ["docker", "podman", "nerdctl", "finch", "buildah", "skopeo", "oras", "cosign"]
    /// The global flags that take a value — the registry clients', helm's,
    /// crane's —: before a subcommand, such a flag's value written apart
    /// (`docker --context login …`) is no subcommand. A flag missing here
    /// is read as a switch.
    static let globalValuedFlags: Set<String> = [
        // docker
        "-c", "--context", "-H", "--host", "--config", "-l", "--log-level", "--tlscacert", "--tlscert", "--tlskey",
        // podman
        "--cdi-spec-dir", "--cgroup-manager", "--conmon", "--connection", "--events-backend", "--hooks-dir", "--identity", "--imagestore",
        "--module", "--network-cmd-path", "--network-config-dir", "--out", "--root", "--runroot", "--runtime", "--runtime-flag", "--ssh",
        "--storage-driver", "--storage-opt", "--tmpdir", "--url", "--volumepath",
        // nerdctl, finch
        "-a", "--address", "-n", "--namespace", "--snapshotter", "--cni-path", "--cni-netconfpath", "--data-root", "--host-gateway-ip",
        "--hosts-dir", "--bridge-ip", "--cdi-spec-dirs", "--global-dns", "--global-dns-opts", "--global-dns-search", "--userns-remap",
        // buildah
        "--cpu-profile", "--memory-profile", "--default-mounts-file", "--registries-conf", "--registries-conf-dir", "--short-name-alias-conf",
        "--userns-uid-map", "--userns-gid-map", "--cdi-config-dir",
        // skopeo
        "--command-timeout", "--override-arch", "--override-os", "--override-variant", "--policy", "--registries.d",
        // cosign
        "--output-file", "-t", "--timeout",
        // helm
        "--burst-limit", "--kube-apiserver", "--kube-as-group", "--kube-as-user", "--kube-ca-file", "--kube-context", "--kube-tls-server-name",
        "--kube-token", "--kubeconfig", "--qps", "--registry-config", "--repository-cache", "--repository-config", "--content-cache",
        // crane
        "--platform",
    ]
    /// `--creds user:password` — podman's, buildah's, skopeo's — and
    /// skopeo's `--src-creds`, `--dest-creds`: in any subcommand, a pull's,
    /// a push's, a copy's.
    static let credentialFlags: Set<String> = ["--creds", "--src-creds", "--dest-creds"]
    /// The OpenLDAP tools: `-w` is the bind password (ldappasswd's `-a` and
    /// `-s` the old and the new one).
    static let ldapTools: Set<String> = [
        "ldapsearch", "ldapmodify", "ldapadd", "ldapdelete", "ldapmodrdn", "ldappasswd", "ldapwhoami", "ldapcompare", "ldapexop", "ldapvc",
    ]
    /// The LDAP tools' short options that take a value wherever they exist —
    /// a letter that is a switch in one tool (ldapmodify's `-a`) isn't
    /// here: taken for a value, the `-w` after it would be skipped.
    static let ldapValued: Set<Character> = ["d", "D", "e", "E", "f", "h", "H", "o", "O", "p", "P", "R", "U", "X", "y", "Y", "b", "l", "T", "z"]
    /// Samba's clients: `-U user%password`.
    static let sambaClients: Set<String> = ["smbclient", "rpcclient", "smbcacls", "smbcquotas", "smbget", "smbtree", "net"]

    /// What a word that ends a shell command is: what follows is another
    /// command, with its own flags (a `docker run -p 8080:80` after a
    /// `docker login -p …`).
    static let commandSeparators: Set<String> = ["&&", "||", ";", "|", "&", "|&", ";;", "(", ")", "{", "}"]

    /// The passwords programs take in flags and places that say nothing of
    /// a password — a registry login's `-p` (`docker login`, `podman`,
    /// `nerdctl`…, `helm registry login`, `crane auth login`), the registry
    /// clients' `--creds user:password` and oras's `-p` in any subcommand,
    /// `sshpass -p`, the LDAP tools' `-w`, Samba's `-U user%password`,
    /// `htpasswd -b`'s password after the user, openssl's `-passin pass:…`
    /// and `enc -k` — each only within its own command, so a port's `-p`
    /// elsewhere, or the `ssh -p 2222` sshpass runs, stays. Only a
    /// `${VAR}` stays as written there (`maskPassword`).
    static func maskProgramPasswords(_ words: [String]) -> [String] {
        let programs = words.indices.compactMap { index -> (Int, String)? in
            let program = (words[index] as NSString).lastPathComponent
            return passwordPrograms.contains(program) ? (index, program) : nil
        }
        guard !programs.isEmpty else { return words }
        let ends = commandEnds(words)
        var out = words
        for (start, program) in programs {
            let arguments = (start + 1)..<ends[start]
            if registryClients.contains(program) {
                if program == "oras" {
                    // oras's `-p` is `--password` in every subcommand: a push's, a pull's.
                    maskPasswordFlag(&out, words, arguments)
                } else {
                    maskLoginPassword(&out, words, arguments, subcommand: ["login"])
                }
                maskCredentials(&out, words, arguments)
            } else if program == "helm" {
                maskLoginPassword(&out, words, arguments, subcommand: ["registry", "login"])
            } else if program == "crane" {
                maskLoginPassword(&out, words, arguments, subcommand: ["auth", "login"])
            } else if program == "sshpass" {
                maskShortOptions(&out, words, arguments, secret: ["p"], valued: ["f", "d", "P"], operandEnds: true)
            } else if ldapTools.contains(program) {
                let secret: Set<Character> = program == "ldappasswd" ? ["w", "a", "s"] : ["w"]
                maskShortOptions(&out, words, arguments, secret: secret, valued: ldapValued.subtracting(secret), operandEnds: false)
            } else if sambaClients.contains(program) {
                maskSambaUser(&out, words, arguments)
            } else if program == "htpasswd" {
                maskHtpasswd(&out, words, arguments)
            } else if program == "openssl" {
                for index in arguments.dropLast() {
                    if ["-passin", "-passout"].contains(words[index]), words[index + 1].hasPrefix("pass:") {
                        out[index + 1] = "pass:" + maskWord(String(words[index + 1].dropFirst(5)))
                    } else if words[index] == "-k" {
                        // `openssl enc -k`: the passphrase itself (`-kfile` names a file).
                        out[index + 1] = maskWord(words[index + 1])
                    }
                }
            }
        }
        return out
    }

    /// Every program `maskProgramPasswords` knows a rule for.
    static let passwordPrograms: Set<String> =
        registryClients.union(ldapTools).union(sambaClients).union(["helm", "crane", "sshpass", "htpasswd", "openssl"])

    /// For each word, where a command it begins would end: at the next
    /// separator, or after the next word a separator is glued to (`pw;`).
    /// One pass from the end — a linker's argv has thousands of words.
    static func commandEnds(_ words: [String]) -> [Int] {
        var ends = [Int](repeating: words.count, count: words.count)
        var end = words.count
        for index in words.indices.reversed() {
            ends[index] = end
            let word = words[index]
            if commandSeparators.contains(word) {
                end = index
            } else if word.count > 1, let last = word.last, ";&|".contains(last) {
                end = index + 1
            }
        }
        return ends
    }

    /// After `subcommand` (`login`, `registry login`) — the command's first
    /// operands, global flags and their values skipped (`firstOperand`): a
    /// `login` anywhere else (`docker run --name login -p 8080:80`) is no
    /// login —, its `-p` (`maskPasswordFlag`).
    private static func maskLoginPassword(_ out: inout [String], _ words: [String], _ arguments: Range<Int>, subcommand: [String]) {
        var start = arguments.lowerBound
        for name in subcommand {
            guard let operand = firstOperand(words, start..<arguments.upperBound), words[operand] == name else { return }
            start = operand + 1
        }
        maskPasswordFlag(&out, words, start..<arguments.upperBound)
    }

    /// The first operand in `arguments` — a subcommand —: flags skipped,
    /// and after one of `globalValuedFlags` its value too; nil when there
    /// is none.
    private static func firstOperand(_ words: [String], _ arguments: Range<Int>) -> Int? {
        var index = arguments.lowerBound
        while index < arguments.upperBound {
            let word = words[index]
            if word == "--" { return index + 1 < arguments.upperBound ? index + 1 : nil }
            guard word.hasPrefix("-"), word.count > 1 else { return index }
            index += globalValuedFlags.contains(word) ? 2 : 1
        }
        return nil
    }

    /// `-p VALUE`, `-pVALUE` and `-p=VALUE` in `arguments`: Docker's flags,
    /// pflag's forms. A word after `-p` that is a long flag means `-p` took
    /// none.
    private static func maskPasswordFlag(_ out: inout [String], _ words: [String], _ arguments: Range<Int>) {
        var index = arguments.lowerBound
        while index < arguments.upperBound {
            let word = words[index]
            if word == "-p" {
                if index + 1 < arguments.upperBound, !words[index + 1].hasPrefix("--") {
                    out[index + 1] = maskWord(words[index + 1])
                    index += 1
                }
            } else if word.hasPrefix("-p"), !word.hasPrefix("--") {
                let value = word.dropFirst(2)
                let equals = value.hasPrefix("=") ? "=" : ""
                out[index] = "-p" + equals + maskWord(String(value.dropFirst(equals.count)))
            }
            index += 1
        }
    }

    /// `--creds user:password`, `--creds=user:password`, skopeo's
    /// `--src-creds` and `--dest-creds`: the user kept, a bare user too
    /// (its password asked for).
    private static func maskCredentials(_ out: inout [String], _ words: [String], _ arguments: Range<Int>) {
        func masked(_ value: Substring) -> String {
            guard let colon = value.firstIndex(of: ":") else { return String(value) }
            return String(value[...colon]) + maskWord(String(value[value.index(after: colon)...]))
        }
        for index in arguments {
            let word = words[index]
            if credentialFlags.contains(word) {
                if index + 1 < arguments.upperBound { out[index + 1] = masked(words[index + 1][...]) }
            } else if word.hasPrefix("--"), let equals = word.firstIndex(of: "="), credentialFlags.contains(String(word[..<equals])) {
                out[index] = String(word[...equals]) + masked(word[word.index(after: equals)...])
            }
        }
    }

    /// A getopt program's short options: a secret one's value masked,
    /// glued (`-wPASS`, `-xwPASS`) or the next word. `valued` options take
    /// a value of their own; any other letter is a switch, so a cluster is
    /// read on past it. `operandEnds`: the first operand ends the options —
    /// sshpass's is the command it runs, whose `-p` is its own.
    private static func maskShortOptions(
        _ out: inout [String], _ words: [String], _ arguments: Range<Int>, secret: Set<Character>, valued: Set<Character>, operandEnds: Bool
    ) {
        var index = arguments.lowerBound
        while index < arguments.upperBound {
            let word = words[index]
            if word == "--" { return }
            guard word.hasPrefix("-"), !word.hasPrefix("--"), word.count > 1 else {
                if operandEnds { return }
                index += 1
                continue
            }
            let letters = Array(word.dropFirst())
            var skipsNext = false
            for (position, letter) in letters.enumerated() {
                let glued = position + 1 < letters.count
                if secret.contains(letter) {
                    if glued {
                        out[index] = "-" + String(letters[...position]) + maskWord(String(letters[(position + 1)...]))
                    } else if index + 1 < arguments.upperBound {
                        out[index + 1] = maskWord(words[index + 1])
                        skipsNext = true
                    }
                    break
                }
                if valued.contains(letter) {
                    skipsNext = !glued
                    break
                }
            }
            index += skipsNext ? 2 : 1
        }
    }

    /// `-U user%password`, `-Uuser%password`, `--user user%password`,
    /// `--user=user%password`: the user kept.
    private static func maskSambaUser(_ out: inout [String], _ words: [String], _ arguments: Range<Int>) {
        func masked(_ value: Substring) -> String {
            guard let percent = value.firstIndex(of: "%") else { return String(value) }
            return String(value[...percent]) + maskWord(String(value[value.index(after: percent)...]))
        }
        for index in arguments {
            let word = words[index]
            if word == "-U" || word == "--user" {
                if index + 1 < arguments.upperBound { out[index + 1] = masked(words[index + 1][...]) }
            } else if word.hasPrefix("--user=") {
                out[index] = "--user=" + masked(word.dropFirst(7))
            } else if word.hasPrefix("-U") {
                out[index] = "-U" + masked(word.dropFirst(2))
            }
        }
    }

    /// `htpasswd -b [file] user password`: the password the operand after
    /// the user (`-n` has no file). Its options come first, as apr_getopt
    /// reads them: the first operand, or `--`, ends them, so a password
    /// that starts with `-` is still one. `-C` and `-r` take a value, glued
    /// or the next word.
    private static func maskHtpasswd(_ out: inout [String], _ words: [String], _ arguments: Range<Int>) {
        var batch = false
        var display = false
        var index = arguments.lowerBound
        while index < arguments.upperBound {
            let word = words[index]
            if word == "--" {
                index += 1
                break
            }
            guard word.hasPrefix("-"), word.count > 1 else { break }
            index += 1
            let letters = Array(word.dropFirst())
            for (position, letter) in letters.enumerated() {
                if letter == "b" { batch = true }
                if letter == "n" { display = true }
                if letter == "C" || letter == "r" {
                    if position == letters.count - 1 { index += 1 }
                    break
                }
            }
        }
        let password = index + (display ? 1 : 2)
        if batch, password < arguments.upperBound { out[password] = maskWord(words[password]) }
    }

    /// A password word masked (`maskPassword`), a separator glued to it
    /// kept: `pw;` is `••••••;`.
    private static func maskWord(_ word: String) -> String {
        let separator = word.reversed().prefix { ";&|".contains($0) }
        guard !separator.isEmpty, separator.count < word.count else { return maskPassword(word) }
        return maskPassword(String(word.dropLast(separator.count))) + String(separator.reversed())
    }

    /// `//user:password@server/share` — SMB's form, `mount -t smbfs`'s,
    /// mount_smbfs's, smbutil's — at a word's start or a value's
    /// (`--url=//…`), whatever the program: `mount` keeps its argv while
    /// mount_smbfs runs. No scheme, so `maskURLs` never sees it.
    static func maskNetworkPath(_ word: String) -> String {
        guard hasBytes(word, doubleSlash) else { return word }
        return word.replacingOccurrences(of: #"(^|=)(//[^/:@\s]*:)([^/@\s]+)(@)"#, with: "$1$2••••••$4", options: .regularExpression)
    }

    private static let doubleSlash = Array("//".utf8)
}

// MARK: Credentials in text

extension Secrets {
    static let credentialMask = "••••••"

    /// What a credential in free text looks like, and what it becomes.
    /// The key-value pattern covers a kubeconfig's fields as YAML or JSON
    /// writes them (`token: …`, `"client-key-data": "…"`), an auth
    /// provider's `config` (`id-token`, `refresh-token`, `access-token`,
    /// `client-secret`), and env-style names with a prefix (`DB_PASSWORD=`,
    /// `GITHUB_TOKEN:`, `db.pass=`) — the prefix ends in `_`, `-` or `.`, so
    /// `bypass=` is no password. Only spaces and tabs around the `:` or `=`:
    /// in YAML a key on its own line (`secret:` over `secretName: …`) is a
    /// block, and the next line's key no value. Tokens by their vendor's
    /// prefix (GitHub's, Slack's, GitLab's, Stripe's) keep the prefix.
    static let credentialPatterns: [(String, String)] = [
        // A PEM block's body, its armour kept.
        (#"(-----BEGIN [A-Z0-9 ]*(?:PRIVATE KEY|CERTIFICATE)-----)[\s\S]*?(-----END [A-Z0-9 ]*(?:PRIVATE KEY|CERTIFICATE)-----)"#, "$1 \(credentialMask) $2"),
        (#"(?i)(\bbearer[ \t]+)[A-Za-z0-9\-._~+/]+=*"#, "$1\(credentialMask)"),
        (#"(?i)(\bauthorization["']?[ \t]*[:=][ \t]*["']?basic[ \t]+)[A-Za-z0-9+/]+=*"#, "$1\(credentialMask)"),
        (#"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]+"#, credentialMask),
        (#"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[A-Z0-9]{16}\b"#, credentialMask),
        (#"(?<![A-Za-z0-9])(gh[pousr]_|github_pat_|xox[abeprs]-|glpat-|[rs]k_(?:live|test)_)[A-Za-z0-9_-]{8,}"#, "$1\(credentialMask)"),
        // A quoted value whole — `password: "correct horse battery"`, JSON's
        // `"password":"p@ss w0rd"` — escapes in it included: the bare form
        // below stops at the first space and left the rest.
        (#"(?i)("# + credentialKey + #"["']?[ \t]*[:=][ \t]*)"(?:[^"\\\n]|\\.)*""#, "$1\"\(credentialMask)\""),
        (#"(?i)("# + credentialKey + #"["']?[ \t]*[:=][ \t]*)'(?:[^'\\\n]|''|\\.)*'"#, "$1'\(credentialMask)'"),
        (#"(?i)("# + credentialKey + #"["']?[ \t]*[:=][ \t]*["']?)[^\s"',;&]+"#, "$1\(credentialMask)"),
    ]

    /// A credential field's name, as `credentialPatterns` finds it before its value.
    private static let credentialKey =
        #"(?<![A-Za-z0-9_.-])(?:[A-Za-z0-9_.-]*[_.-])?(?:client-key-data|client-certificate-data|certificate-authority-data|idp-certificate-authority-data|token|id-token|refresh-token|access[_-]?token|client[_-]?secret|api[_-]?key|apikey|secret|secret[_-]?key|private[_-]?key|aws_secret_access_key|aws_session_token|password|passwd|passphrase|pass|pwd)"#

    /// `text` with every credential `credentialPatterns` finds masked, then
    /// every base64-looking blob.
    static func scrubCredentials(_ text: String) -> String {
        var out = text
        // ASCII lowercased once: what the patterns' needles are looked for in.
        let lowered = text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
        for (index, (pattern, template)) in credentialPatterns.enumerated() {
            // Only where the pattern could match: running nine patterns
            // over every string was most of the time a 2,000-resource
            // Terraform plan took to read.
            guard mayMatch(index, lowered: lowered) else { continue }
            if let regex = credentialRegexes[index] {
                out = regex.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: template)
            } else {
                out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
            }
        }
        return maskBase64Blobs(in: out)
    }

    /// `credentialPatterns`, compiled, in their order.
    private static let credentialRegexes: [NSRegularExpression?] = credentialPatterns.map { try? NSRegularExpression(pattern: $0.0) }

    /// What each of `credentialPatterns` can't match without, in any case:
    /// one of these words — and, for the three of a key and its value, `:`
    /// or `=`. Lowercase ASCII.
    private static let credentialNeedles: [[[UInt8]]] = [
        ["-----begin"], ["bearer"], ["authorization"], ["eyj"], ["akia", "asia", "agpa", "aida", "aroa", "anpa"],
        ["gh", "github_pat_", "xox", "glpat-", "k_live_", "k_test_"],
        ["token", "secret", "key", "pass", "pwd", "data"], ["token", "secret", "key", "pass", "pwd", "data"], ["token", "secret", "key", "pass", "pwd", "data"],
    ].map { $0.map { Array($0.utf8) } }

    /// Whether pattern `index` could match the text whose ASCII-lowercased
    /// bytes are `lowered`. A pattern past the needles' list always runs.
    static func mayMatch(_ index: Int, lowered: [UInt8]) -> Bool {
        guard index < credentialNeedles.count else { return true }
        let found = lowered.withUnsafeBytes { hay in
            credentialNeedles[index].contains { needle in
                needle.withUnsafeBytes { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil }
            }
        }
        guard found else { return false }
        return index < 6 || lowered.contains(0x3A) || lowered.contains(0x3D)
    }

    /// The shortest run taken for a blob: 32 characters of base64 is 24
    /// bytes, a key's or a token's length; shorter runs are words.
    static let blobLength = 32

    private static let blobPattern = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/_-]{\#(blobLength),}={0,2}(?![A-Za-z0-9+/=_-])"#)

    /// Runs of base64 (standard or URL-safe: `-` and `_` too) that look
    /// like encoded bytes — a Secret's value, a key, a Fernet key, a
    /// `token_urlsafe` — masked. A run counts when it has upper- and lowercase
    /// letters and a digit: a git SHA, an image digest and a uid are
    /// lowercase hex (and a uid has dashes), a Kubernetes name is lowercase,
    /// a word has no digits. A path (`/var/lib/…`, a slash in front, or
    /// `//`) isn't one.
    static func maskBase64Blobs(in text: String) -> String {
        guard text.utf8.count >= blobLength, hasBase64Run(text), let blobPattern else { return text }
        let string = text as NSString
        let matches = blobPattern.matches(in: text, range: NSRange(location: 0, length: string.length))
        guard !matches.isEmpty else { return text }
        var out = string
        for match in matches.reversed() where looksLikeBlob(string.substring(with: match.range)) {
            out = out.replacingCharacters(in: match.range, with: credentialMask) as NSString
        }
        return out as String
    }

    /// Whether `text` has a run of `blobLength` base64 characters with an
    /// upper- and a lowercase letter and a digit in it — what the pattern
    /// and `looksLikeBlob` both need — checked byte by byte before the
    /// pattern runs.
    static func hasBase64Run(_ text: String) -> Bool {
        var run = 0
        var upper = false
        var lower = false
        var digit = false
        for byte in text.utf8 {
            switch byte {
            case 0x41...0x5A: upper = true
            case 0x61...0x7A: lower = true
            case 0x30...0x39: digit = true
            case 0x2B, 0x2F, 0x5F, 0x2D: break
            default:
                run = 0
                upper = false
                lower = false
                digit = false
                continue
            }
            run += 1
            if run >= blobLength, upper, lower, digit { return true }
        }
        return false
    }

    /// Whether `text`'s UTF-8 holds `needle`.
    static func hasBytes(_ text: String, _ needle: [UInt8]) -> Bool {
        func search(_ hay: UnsafeBufferPointer<UInt8>) -> Bool {
            needle.withUnsafeBytes { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil }
        }
        if let found = text.utf8.withContiguousStorageIfAvailable(search) { return found }
        return Array(text.utf8).withUnsafeBufferPointer(search)
    }

    static func looksLikeBlob(_ run: String) -> Bool {
        guard run.count >= blobLength, !run.hasPrefix("/"), !run.contains("//") else { return false }
        var upper = false
        var lower = false
        var digit = false
        for character in run.unicodeScalars {
            switch character.value {
            case 0x41...0x5A: upper = true
            case 0x61...0x7A: lower = true
            case 0x30...0x39: digit = true
            default: break
            }
        }
        return upper && lower && digit
    }
}
