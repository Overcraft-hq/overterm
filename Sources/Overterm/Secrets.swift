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

    static func isSecret(_ key: String) -> Bool {
        let upper = key.uppercased()
        guard !harmless.contains(upper) else { return false }
        return words.contains { upper.contains($0) } || !tokenWords.isDisjoint(with: tokens(key))
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
        guard text.contains("://") else { return text }
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
    /// colon. A shell script's words (`sh -c '…'`, `CMD-SHELL`) the same.
    /// Compose has put `.env`'s values into a command already, so the
    /// container's env can't name them all. A `${VAR}` stays as written.
    static func maskArguments(_ words: [String]) -> [String] {
        enum Pending { case secret, userinfo }
        let programs = Set(words.map { ($0 as NSString).lastPathComponent })
        let redis = programs.contains("redis-cli")
        let curl = programs.contains("curl")
        let mongo = !programs.isDisjoint(with: ["mongosh", "mongo"])
        let mysql = !programs.isDisjoint(with: ["mysql", "mysqladmin", "mysqldump", "mysqlshow", "mysqlcheck", "mariadb", "mariadb-admin", "mariadb-dump"])
        var pending: Pending?
        return words.map { word -> String in
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
                    return name + "=" + maskValue(String(word[word.index(after: equals)...]))
                }
            }
            return word
        }
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

    /// `user:password`: the user kept.
    private static func maskUserinfo(_ value: String) -> String {
        guard let colon = value.firstIndex(of: ":") else { return value }
        return String(value[...colon]) + maskValue(String(value[value.index(after: colon)...]))
    }
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
        (#"(?i)("# + credentialKey + #"["']?[ \t]*[:=][ \t]*)'(?:[^'\\\n]|\\.)*'"#, "$1'\(credentialMask)'"),
        (#"(?i)("# + credentialKey + #"["']?[ \t]*[:=][ \t]*["']?)[^\s"',;&]+"#, "$1\(credentialMask)"),
    ]

    /// A credential field's name, as `credentialPatterns` finds it before its value.
    private static let credentialKey =
        #"(?<![A-Za-z0-9_.-])(?:[A-Za-z0-9_.-]*[_.-])?(?:client-key-data|client-certificate-data|certificate-authority-data|idp-certificate-authority-data|token|id-token|refresh-token|access[_-]?token|client[_-]?secret|api[_-]?key|apikey|secret|secret[_-]?key|private[_-]?key|aws_secret_access_key|aws_session_token|password|passwd|passphrase|pass|pwd)"#

    /// `text` with every credential `credentialPatterns` finds masked, then
    /// every base64-looking blob.
    static func scrubCredentials(_ text: String) -> String {
        var out = text
        for (pattern, template) in credentialPatterns {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return maskBase64Blobs(in: out)
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
        guard text.utf8.count >= blobLength, let blobPattern else { return text }
        let string = text as NSString
        let matches = blobPattern.matches(in: text, range: NSRange(location: 0, length: string.length))
        guard !matches.isEmpty else { return text }
        var out = string
        for match in matches.reversed() where looksLikeBlob(string.substring(with: match.range)) {
            out = out.replacingCharacters(in: match.range, with: credentialMask) as NSString
        }
        return out as String
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
