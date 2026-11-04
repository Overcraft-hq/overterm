import Foundation

/// A Secret's values in its detail, only once the user asks (rule 9): the
/// list and the detail never read them — its Table row has the type and
/// how many keys — and Show makes the one GET, which returns every value
/// at once. On a production context the first Show of the session asks
/// first, naming the context. Then the keys are listed with every value
/// masked (its length shown), one value revealed at a time — revealing
/// another hides the first — and Copy copies one, when asked. Everything
/// it read is released — the views back to Show — when
/// the detail moves on or closes, the page hides, the context changes,
/// or `timeout` passes without the user touching a value. A TLS
/// Secret's certificate is read from `tls.crt`; `tls.key` is never
/// decoded, revealed or copied. Nothing here logs, writes or keeps a value
/// anywhere else, and nothing printable of it carries one.
@MainActor
final class KubeSecretSession: ObservableObject {
    enum State: Equatable {
        /// Nothing read: Show.
        case hidden
        /// Production: Show asked first.
        case confirming
        case loading
        case shown
        case failed(String)
    }

    /// Why what was read went.
    enum Drop: Equatable {
        /// The detail moved on, or closed.
        case navigation
        /// The page hid (another page, the terminal, the window off screen).
        case pageHidden
        case contextChanged
        case timeout
        /// Hide, pressed.
        case asked

        func said(timeout: Duration) -> String? {
            switch self {
            case .navigation, .asked: nil
            case .pageHidden: "Hidden again when the page was hidden."
            case .contextChanged: "Hidden again: another context."
            case .timeout: "Hidden again after \(KubeSecretSession.said(timeout)) without a look."
            }
        }
    }

    nonisolated static let defaultTimeout: Duration = .seconds(120)

    let ref: KubeObjectRef
    let isProduction: Bool
    /// What the list's row said, before Show: its Type and Data (how many keys).
    let listedType: String?
    let listedKeys: Int?
    @Published private(set) var state: State = .hidden
    /// The Secret's type, once read.
    @Published private(set) var type: String?
    @Published private(set) var entries: [KubeSecretEntry] = []
    /// The key whose value shows; one at most.
    @Published private(set) var revealed: String?
    /// `tls.crt`'s, leaf first, on a TLS Secret.
    @Published private(set) var certificates: [KubeCertificate] = []
    /// Why the values went, while nothing shows.
    @Published private(set) var dropped: Drop?
    /// How long the values stay after Show, a reveal or a copy.
    var timeout: Duration = KubeSecretSession.defaultTimeout

    /// The object as read, without its values: the detail's Overview and YAML.
    var onRead: ((Data) -> Void)?
    /// Everything read is gone: the detail forgets the object too.
    var onDrop: (() -> Void)?

    private let client: KubeClient?
    private let consent: KubeSecretConsent
    private var values: [String: Data] = [:]
    private var fetching: Task<Void, Never>?
    private var expiry: Task<Void, Never>?

    init(ref: KubeObjectRef, client: KubeClient?, consent: KubeSecretConsent, isProduction: Bool, listedType: String? = nil, listedKeys: Int? = nil) {
        self.ref = ref
        self.client = client
        self.consent = consent
        self.isProduction = isProduction
        self.listedType = listedType
        self.listedKeys = listedKeys
    }

    // MARK: Show

    /// Show: the one GET — on production, asked first the session's first time.
    func show() {
        switch state {
        case .hidden, .failed: break
        default: return
        }
        if consent.needsAsking(ref.context, production: isProduction) {
            state = .confirming
            return
        }
        fetch()
    }

    /// The production question answered yes: not asked again this session.
    func confirm() {
        guard state == .confirming else { return }
        consent.grant(ref.context)
        fetch()
    }

    func cancelConfirmation() {
        guard state == .confirming else { return }
        state = .hidden
    }

    private func fetch() {
        guard let client else { return state = .failed("Kubernetes is off, or the context is gone.") }
        state = .loading
        dropped = nil
        let ref = self.ref
        fetching = Task { [weak self] in
            do {
                let read = try await client.secret(ref.kind, namespace: ref.namespace, name: ref.name)
                guard let self, !Task.isCancelled, self.state == .loading else { return }
                self.take(read)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.state == .loading else { return }
                self.state = .failed(KubernetesModel.said(error))
            }
        }
    }

    private func take(_ read: KubeSecretRead) {
        fetching = nil
        values = read.values
        type = read.type
        entries = read.entries
        revealed = nil
        if read.type == KubeSecret.tlsType, let pem = values["tls.crt"] {
            certificates = KubeCertificate.certificates(inPEM: String(decoding: pem, as: UTF8.self))
        }
        state = .shown
        onRead?(read.stripped)
        restartExpiry()
    }

    // MARK: One value

    /// `key`'s value shows, and only it: another revealed hides. A private
    /// key never shows.
    @discardableResult
    func reveal(_ key: String) -> Bool {
        guard state == .shown, let entry = entries.first(where: { $0.key == key }), !entry.isPrivateKey, values[key] != nil else { return false }
        revealed = key
        restartExpiry()
        return true
    }

    /// The revealed value masked again.
    func conceal() { revealed = nil }

    /// The revealed value as it shows: text as it is, anything else as
    /// base64. Asked for while drawing, never kept.
    var revealedText: String? {
        guard let revealed, let entry = entries.first(where: { $0.key == revealed }) else { return nil }
        return text(of: entry)
    }

    /// One value, for Copy: asked for by the user, for this key alone.
    func copyValue(_ key: String) -> String? {
        guard state == .shown, let entry = entries.first(where: { $0.key == key }), !entry.isPrivateKey else { return nil }
        restartExpiry()
        return text(of: entry)
    }

    private func text(of entry: KubeSecretEntry) -> String? {
        guard !entry.isPrivateKey, let value = values[entry.key] else { return nil }
        return entry.isBinary ? value.base64EncodedString() : String(decoding: value, as: UTF8.self)
    }

    // MARK: Gone

    /// Everything read goes: the values released, the keys, the
    /// certificate, the request in flight; the view back to Show. The
    /// decoded copies are cleared first, but that is not a promise the
    /// memory held no value: the response, Foundation's strings and the
    /// text drawn were copies of their own, only released.
    func drop(_ reason: Drop) {
        fetching?.cancel()
        fetching = nil
        expiry?.cancel()
        expiry = nil
        let had = state == .shown || state == .loading
        for key in Array(values.keys) {
            let count = values[key]?.count ?? 0
            values[key]?.resetBytes(in: 0..<count)
        }
        values = [:]
        entries = []
        revealed = nil
        certificates = []
        type = nil
        if state != .hidden { state = .hidden }
        if had {
            dropped = reason
            onDrop?()
        }
    }

    /// What the view says about the last drop, if anything.
    var droppedNote: String? { dropped?.said(timeout: timeout) }

    /// Whether any value is held.
    var holdsValues: Bool { !values.isEmpty }

    private func restartExpiry() {
        expiry?.cancel()
        let timeout = self.timeout
        expiry = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.drop(.timeout)
        }
    }

    /// `2 minutes`, `90 seconds`.
    nonisolated static func said(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds >= 60, seconds % 60 == 0 { return "\(seconds / 60) minute\(seconds == 60 ? "" : "s")" }
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }
}
