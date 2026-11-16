import Foundation

/// The right-hand slot's database pages: a connection's Server page or its
/// Users page — read only while the slot shows them. docs/architecture.md,
/// Database: Server page, Users and roles.
@MainActor
final class DatabaseSlotModel: ObservableObject {
    enum Page: Equatable { case none, server, users }

    @Published private(set) var page = Page.none
    let server = DatabaseServerModel()
    let users = DatabaseUsersModel()

    /// Whether the slot is on screen showing this.
    var visible = false {
        didSet { apply() }
    }

    func show(_ page: Page) {
        self.page = page
        apply()
    }

    private func apply() {
        server.visible = visible && page == .server
        users.visible = visible && page == .users
    }
}

/// A connection's Server page: what is running, the slow statements, who
/// waits on whom, the sizes, the headline numbers. The tab shown is read
/// again every few seconds while the page shows (Pause stops it); Slow
/// Queries and Sizes, heavier, are read when their tab opens and on Refresh.
@MainActor
final class DatabaseServerModel: ObservableObject {
    @Published private(set) var session: DatabaseSession?
    @Published var part = MonitorPart.overview {
        didSet { if part != oldValue { Task { await refresh() } } }
    }
    @Published var paused = false {
        didSet { if !paused, paused != oldValue { Task { await refresh() } } }
    }
    @Published private(set) var overview: ServerOverview?
    @Published private(set) var activity: Monitored<[DatabaseActivity]>?
    @Published private(set) var slowQueries: Monitored<[SlowQuery]>?
    @Published private(set) var locks: Monitored<[LockWait]>?
    @Published private(set) var sizes: Monitored<DatabaseSizes>?
    @Published private(set) var integrity: String?
    @Published private(set) var error: String?
    @Published private(set) var updated: Date?
    @Published private(set) var reading = false
    /// Idle sessions left out of Activity.
    @Published var hideIdle = true
    @Published var slowOrder = SlowOrder.total

    enum SlowOrder: String, CaseIterable { case total = "By total time", mean = "By mean time" }

    /// How often the shown tab is read again.
    static let interval: Duration = .seconds(5)
    private var refresher: Task<Void, Never>?

    var visible = false {
        didSet {
            guard visible != oldValue else { return }
            if visible { start() } else { stop() }
        }
    }

    var name: String { session?.connection.name ?? "" }
    /// The tabs the connection's engine has.
    var parts: [MonitorPart] {
        guard let kind = session?.connection.kind, let type = DatabaseDrivers.driverType(of: kind) as? any DatabaseMonitoring.Type else { return [] }
        return type.monitorParts(for: kind)
    }
    /// Sessions are cancelled only where the connection writes.
    var canCancel: Bool { session?.connection.readOnly == false }

    /// How a session is stopped here: the kind's own ways (none: not
    /// offered), else the SQL engines' two.
    func stops(for activity: DatabaseActivity) -> [SessionStop] {
        guard let kind = session?.connection.kind else { return [] }
        if let type = DatabaseDrivers.driverType(of: kind) as? any DatabaseMonitoring.Type, let own = type.sessionStops(for: activity, kind: kind) {
            return own
        }
        return SessionStop.sql(for: activity, kind: kind)
    }

    func show(_ session: DatabaseSession) {
        if self.session?.id != session.id {
            overview = nil
            activity = nil
            slowQueries = nil
            locks = nil
            sizes = nil
            integrity = nil
            error = nil
            updated = nil
            part = .overview
        }
        self.session = session
        if visible { start() }
    }

    private func start() {
        refresher?.cancel()
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused || self.updated == nil { await self.refresh(timer: true) }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func stop() {
        refresher?.cancel()
        refresher = nil
    }

    /// The tab shown, read now. The timer leaves the heavy tabs alone once read.
    func refresh(timer: Bool = false) async {
        guard visible, let session else { return }
        if timer, part == .slowQueries, slowQueries != nil { return }
        if timer, part == .sizes, sizes != nil { return }
        if !session.isOpen { await session.open() }
        guard let driver = session.monitoring else {
            if case .failed(let message) = session.state { error = message } else { error = "Not connected." }
            return
        }
        reading = true
        defer { reading = false }
        do {
            switch part {
            case .overview: overview = try await driver.overview()
            case .activity: activity = try await driver.activity()
            case .slowQueries: slowQueries = try await driver.slowQueries()
            case .locks: locks = try await driver.locks()
            case .sizes: sizes = try await driver.sizes()
            }
            error = nil
            updated = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Activity as shown: idle sessions out unless asked for.
    var shownActivity: [DatabaseActivity] {
        let all = activity?.value ?? []
        return hideIdle ? all.filter { $0.isActive || $0.isOwn } : all
    }

    var shownSlowQueries: [SlowQuery] {
        let all = slowQueries?.value ?? []
        return slowOrder == .total ? all.sorted { $0.total > $1.total } : all.sorted { $0.mean > $1.mean }
    }

    /// Asked first (the window's confirmation), never offered on the page's own session.
    func cancel(_ activity: DatabaseActivity, terminate: Bool) async {
        guard let driver = session?.monitoring, canCancel, !activity.isOwn else { return }
        do {
            try await driver.cancel(session: activity.id, terminate: terminate)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    func checkIntegrity() async {
        guard let driver = session?.monitoring else { return }
        integrity = "Checking…"
        do {
            integrity = try await driver.integrityCheck() ?? "This engine has no check."
        } catch {
            integrity = error.localizedDescription
        }
    }
}

/// A connection's Users page: its users and roles, a picked one's grants,
/// and the statements that change them — each previewed, asked, sent once.
@MainActor
final class DatabaseUsersModel: ObservableObject {
    @Published private(set) var session: DatabaseSession?
    @Published private(set) var users: Monitored<[DatabaseUser]>?
    @Published var selected: DatabaseUser.ID? {
        didSet { if selected != oldValue { Task { await loadGrants() } } }
    }
    @Published private(set) var grants: Monitored<[DatabaseGrant]>?
    @Published private(set) var error: String?
    @Published private(set) var reading = false
    @Published private(set) var dialect: UserDialect?
    /// How the kind's statements are made, and what the sheets ask.
    @Published private(set) var maker: (any UserStatementMaking)?

    var visible = false {
        didSet { if visible, !oldValue, users == nil { Task { await reload() } } }
    }

    var name: String { session?.connection.name ?? "" }
    var canWrite: Bool { session?.connection.readOnly == false }
    var selectedUser: DatabaseUser? { users?.value?.first { $0.id == selected } }

    func show(_ session: DatabaseSession) {
        if self.session?.id != session.id {
            users = nil
            grants = nil
            selected = nil
            error = nil
        }
        self.session = session
        if visible { Task { await reload() } }
    }

    func reload() async {
        guard visible, let session else { return }
        if !session.isOpen { await session.open() }
        guard let driver = session.userManagement else {
            if case .failed(let message) = session.state { error = message } else { error = "Not connected." }
            return
        }
        reading = true
        defer { reading = false }
        let maker = await driver.userStatements()
        self.maker = maker
        dialect = (maker as? SQLUserStatements)?.dialect
        do {
            users = try await driver.users()
            error = nil
            if let selected, users?.value?.contains(where: { $0.id == selected }) != true { self.selected = nil }
            await loadGrants()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadGrants() async {
        guard let user = selectedUser, let driver = session?.userManagement else {
            grants = nil
            return
        }
        do {
            let read = try await driver.grants(of: user)
            if selected == user.id { grants = read }
        } catch {
            grants = .unavailable(MonitorGap(reason: error.localizedDescription))
        }
    }

    /// Said on the page: a write refused before anything was sent.
    func refuse(_ message: String) { error = message }

    /// Sent once, in order; then everything read again. The error, if any,
    /// as `UserStatement.scrub` leaves it.
    func run(_ statements: [UserStatement]) async -> String? {
        guard let driver = session?.userManagement, canWrite else { return "This connection is read-only." }
        do {
            try await driver.run(statements)
            await reload()
            return nil
        } catch {
            let message = error.localizedDescription
            self.error = message
            await reload()
            self.error = message
            return message
        }
    }
}
