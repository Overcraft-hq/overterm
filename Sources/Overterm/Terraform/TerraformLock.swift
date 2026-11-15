import Foundation

/// Who holds a state's lock, read only from Terraform's own diagnostic —
/// "Error acquiring the state lock", its `detail`'s "Lock Info:" lines
/// (analysis 4.10): `ID`, `Path`, `Operation`, `Who`, `Version`, `Created`
/// (Go's `2026-11-08 11:42:46.353924 +0000 UTC`), `Info`; the http
/// backend's `HTTP remote state already locked: ID=…`. A `.lock.info` file
/// is never read: on the local backend the lock is an OS lock that went
/// with its process, and a leftover file is not a lock. `cloud {}` and
/// `remote` roots say "workspace … is locked by run …": an HCP lock,
/// never parsed here. Pure.
struct TerraformLockInfo: Equatable, Sendable {
    var id: String
    var path: String?
    /// `OperationTypeApply`, `OperationTypePlan`…
    var operation: String?
    /// `user@host`.
    var who: String?
    var version: String?
    var created: Date?
    var info: String?
    /// The http backend's variant (GitLab's managed state too): its
    /// force-unlock removes whatever lock is there (2e).
    var http = false

    static let summary = "Error acquiring the state lock"

    /// The lock a diagnostic names, or nil when it names none.
    static func parse(summary: String, detail: String) -> TerraformLockInfo? {
        guard summary.hasPrefix(Self.summary) else { return nil }
        var fields: [String: String] = [:]
        var inInfo = false
        for raw in detail.split(separator: "\n", omittingEmptySubsequences: false).prefix(80) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces) == "Lock Info:" {
                inInfo = true
                continue
            }
            guard inInfo else { continue }
            guard line.hasPrefix("  "), let colon = line.firstIndex(of: ":") else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty, !fields.isEmpty { inInfo = false }
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard ["ID", "Path", "Operation", "Who", "Version", "Created", "Info"].contains(key) else { continue }
            fields[key] = String(value.prefix(300))
        }
        let http = detail.contains("HTTP remote state already locked")
        if fields["ID"] == nil, let range = detail.range(of: #"already locked: ID=([^\s,]+)"#, options: .regularExpression) {
            fields["ID"] = String(detail[range].split(separator: "=").last ?? "")
        }
        guard let id = fields["ID"], !id.isEmpty else { return nil }
        func nonEmpty(_ key: String) -> String? { fields[key].flatMap { $0.isEmpty ? nil : $0 } }
        return TerraformLockInfo(
            id: id, path: nonEmpty("Path"), operation: nonEmpty("Operation"), who: nonEmpty("Who"), version: nonEmpty("Version"),
            created: nonEmpty("Created").flatMap(Self.date), info: nonEmpty("Info"), http: http)
    }

    /// Go's `time.Time` as the lock info prints it (`2026-11-08 11:42:46.353924 +0000 UTC`),
    /// or as JSON writes it (RFC 3339, `2026-11-08T11:42:46.353924Z`).
    static func date(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: " UTC", with: "").trimmingCharacters(in: .whitespaces)
        // The fraction dropped: a second is all a person reads.
        let plain = trimmed.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: plain) { return date }
        }
        return nil
    }

    /// "an apply", "a plan", or the operation's own word.
    var operationWords: String? {
        guard let operation else { return nil }
        switch operation {
        case "OperationTypeApply": return "an apply"
        case "OperationTypePlan": return "a plan"
        case "OperationTypeRefresh": return "a refresh"
        case "OperationTypeInvalid": return nil
        default: return operation.hasPrefix("OperationType") ? String(operation.dropFirst("OperationType".count)).lowercased() : operation
        }
    }

    /// "Locked by ci@globex-runner-7 since 09:00 (an apply, Terraform 1.17.1)".
    func said(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var text = "Locked by " + (who ?? "someone")
        if let created {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = Calendar.current.isDate(created, inSameDayAs: now) ? "HH:mm" : "yyyy-MM-dd HH:mm"
            text += " since " + formatter.string(from: created)
        }
        let about = [operationWords, version.map { "Terraform " + $0 }].compactMap { $0 }
        if !about.isEmpty { text += " (" + about.joined(separator: ", ") + ")" }
        return text
    }

    /// The lock's age, said: "3 h", "12 min".
    func age(now: Date = Date()) -> String? {
        guard let created else { return nil }
        let seconds = max(0, now.timeIntervalSince(created))
        if seconds < 120 { return "\(Int(seconds)) s" }
        if seconds < 7_200 { return "\(Int(seconds / 60)) min" }
        if seconds < 172_800 { return "\(Int(seconds / 3_600)) h" }
        return "\(Int(seconds / 86_400)) days"
    }

    /// Whether `who` is this Mac's own `user@host`: then Overterm looks for
    /// a live terraform in the root (4.10).
    func isThisMac(user: String = NSUserName(), host: String = ProcessInfo.processInfo.hostName) -> Bool {
        guard let who, let at = who.lastIndex(of: "@") else { return false }
        let name = String(who[..<at])
        let machine = String(who[who.index(after: at)...]).lowercased()
        let short = host.lowercased().split(separator: ".").first.map(String.init) ?? host.lowercased()
        return name == user && (machine == host.lowercased() || machine.split(separator: ".").first.map(String.init) == short)
    }
}
