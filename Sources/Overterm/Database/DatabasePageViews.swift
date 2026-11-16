import AppKit
import SwiftUI

/// What the database pages ask the window to do.
struct DatabaseSlotActions {
    /// Asked with the window's write confirmation; `then` runs on its
    /// button, with what was typed (when a name was asked, the caller checks it).
    var confirm: (_ confirmation: WriteConfirmation, _ then: @escaping (_ typed: String) -> Void) -> Void
    var close: () -> Void
}

/// The right-hand slot's database page: a connection's Server or Users page.
struct DatabaseSlotView: View {
    @ObservedObject var model: DatabaseSlotModel
    @ObservedObject var theme: ChromeTheme
    let actions: DatabaseSlotActions

    var body: some View {
        Group {
            switch model.page {
            case .server: DatabaseServerView(model: model.server, theme: theme, actions: actions)
            case .users: DatabaseUsersView(model: model.users, theme: theme, actions: actions)
            case .none:
                RedisChrome(theme: theme).note("A connection's Server or Users page — from its menu in the Database panel (⌥⌘B), or ⌘K.")
            }
        }
        .background(theme.panelGround)
    }
}

/// The pieces the database pages share.
@MainActor
struct OpsChrome {
    let theme: ChromeTheme

    /// Why a part is empty, and the line that turns it on.
    func gap(_ gap: MonitorGap) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: gap.reason).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2)
            .textSelection(.enabled)
            if let fix = gap.fix {
                HStack(alignment: .top, spacing: 6) {
                    Text(verbatim: fix).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        RedisChrome(theme: theme).copy(fix)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: ChromeMetrics.text(10.5)))
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.text2).help("Copy")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.7)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .accessibilityIdentifier("opsGap")
    }

    func stat(_ fact: ServerFact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: fact.title).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.dimText)
            Text(verbatim: fact.value).font(.system(size: ChromeMetrics.text(15), weight: .semibold, design: .rounded)).foregroundStyle(theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(verbatim: fact.detail ?? " ").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.dimText).lineLimit(1)
                .help(fact.detail ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.rowHover.opacity(0.6)))
    }

    func statement(_ text: String?, lines: Int = 2) -> some View {
        Text(verbatim: OpsText.statement(text, limit: 600)).font(.system(size: ChromeMetrics.text(11), design: .monospaced))
            .foregroundStyle(text == nil ? theme.dimText : theme.text).lineLimit(lines).textSelection(.enabled)
    }

    func caption(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.dimText)
    }

    func section(_ title: String) -> some View {
        Text(verbatim: title).font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.dimText)
    }
}

// MARK: The Server page

struct DatabaseServerView: View {
    @ObservedObject var model: DatabaseServerModel
    @ObservedObject var theme: ChromeTheme
    let actions: DatabaseSlotActions

    private var chrome: OpsChrome { OpsChrome(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RedisChrome(theme: theme).header(model.name, close: actions.close) {
                Image(systemName: "server.rack").foregroundStyle(theme.dimText)
            }
            HStack(spacing: 8) {
                Picker("", selection: $model.part) {
                    ForEach(model.parts, id: \.self) { part in Text(part.rawValue).tag(part) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .accessibilityIdentifier("serverParts")
                RedisChrome(theme: theme).iconButton(model.paused ? "play.fill" : "pause.fill", model.paused ? "Resume reading every 5 s" : "Pause: stop reading") {
                    model.paused.toggle()
                }
                RedisChrome(theme: theme).iconButton("arrow.clockwise", "Read again now") { Task { await model.refresh() } }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider().opacity(0.3)
            if let error = model.error {
                RedisChrome(theme: theme).error(error).padding(.horizontal, 12).padding(.top, 8)
            }
            switch model.part {
            case .overview: overview
            case .activity: activity
            case .slowQueries: slow
            case .locks: locks
            case .sizes: sizes
            }
            footer
        }
    }

    private var footer: some View {
        HStack {
            if let updated = model.updated {
                Text("Read \(updated, format: .dateTime.hour().minute().second())").font(.system(size: ChromeMetrics.text(10.5)))
                    .foregroundStyle(theme.dimText)
                Text(verbatim: model.paused ? "— paused" : (model.part == .slowQueries || model.part == .sizes ? "— Refresh reads again" : "— again every 5 s while this shows"))
                    .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.dimText)
            } else if model.reading {
                Text("Reading…").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.dimText)
            }
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: ChromeMetrics.row(24))
    }

    // MARK: Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let overview = model.overview {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                        ForEach(Array(overview.facts.enumerated()), id: \.offset) { _, fact in chrome.stat(fact) }
                    }
                    .accessibilityIdentifier("serverFacts")
                    ForEach(overview.notes, id: \.self) { chrome.caption($0) }
                }
                if model.session?.connection.kind == .sqlite {
                    HStack {
                        Button("Check Integrity") { Task { await model.checkIntegrity() } }.controlSize(.small)
                            .help("PRAGMA integrity_check — reads every page; on a large file it takes a while")
                        Spacer()
                    }
                    if let integrity = model.integrity {
                        Text(verbatim: integrity).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text)
                            .textSelection(.enabled).accessibilityIdentifier("integrity")
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: Activity

    private var activity: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("Idle sessions too", isOn: Binding(get: { !model.hideIdle }, set: { model.hideIdle = !$0 }))
                    .toggleStyle(.checkbox).font(.system(size: ChromeMetrics.text(11)))
                Spacer()
                if let all = model.activity?.value {
                    chrome.caption("\(model.shownActivity.count) of \(all.count) sessions")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if let gap = model.activity?.gap {
                chrome.gap(gap)
            } else if model.activity != nil, model.shownActivity.isEmpty {
                chrome.caption("Nothing running now — every session is idle.").padding(12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.shownActivity) { session in activityRow(session) }
                }
            }
            if let kind = model.session?.connection.kind, kind == .mysql || kind == .mariadb {
                chrome.caption("Other users' sessions are listed to a user with the PROCESS privilege.").padding(.horizontal, 12)
            } else if model.activity?.value?.contains(where: { $0.statement == "<insufficient privilege>" }) == true {
                chrome.caption("Other users' statements are shown to a member of pg_read_all_stats.").padding(.horizontal, 12)
            }
        }
    }

    private func activityRow(_ session: DatabaseActivity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: session.id).foregroundStyle(theme.dimText)
                Text(verbatim: [session.user, session.database].compactMap { $0 }.joined(separator: " @ ")).foregroundStyle(theme.text)
                if session.isOwn { Text("this page's connection").foregroundStyle(theme.accentText) }
                Spacer(minLength: 4)
                Text(verbatim: session.state ?? "").foregroundStyle(session.isActive ? theme.orangeText : theme.dimText)
                if let seconds = session.seconds { Text(verbatim: OpsText.duration(seconds)).foregroundStyle(theme.text) }
            }
            .font(.system(size: ChromeMetrics.text(11), design: .monospaced)).lineLimit(1)
            if session.statement != nil { chrome.statement(session.statement) }
            let detail = [session.client, session.application, session.waiting.map { "waits on \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
            if !detail.isEmpty { chrome.caption(detail.joined(separator: " · ")).lineLimit(1) }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            if let statement = session.statement { Button("Copy Statement") { RedisChrome(theme: theme).copy(OpsText.maskSecrets(statement)) } }
            Button("Copy Session ID") { RedisChrome(theme: theme).copy(session.id) }
            if model.canCancel, !session.isOwn {
                Divider()
                Button("Cancel Statement…") { askCancel(session, terminate: false) }
                Button("Terminate Session…") { askCancel(session, terminate: true) }
            }
        }
        .accessibilityIdentifier("session-\(session.id)")
    }

    private func askCancel(_ session: DatabaseActivity, terminate: Bool) {
        let kind = model.session?.connection.kind
        let mysql = kind == .mysql || kind == .mariadb
        let verb = terminate ? (mysql ? "KILL \(session.id)" : "pg_terminate_backend(\(session.id))") : (mysql ? "KILL QUERY \(session.id)" : "pg_cancel_backend(\(session.id))")
        let who = [session.user, session.database, session.client].compactMap { $0 }.joined(separator: " · ")
        let confirmation = WriteConfirmation(
            title: terminate ? "End session \(session.id)?" : "Cancel session \(session.id)'s statement?", scope: model.name,
            detail: "\(who)\n\(OpsText.statement(session.statement, limit: 400))\n\n\(verb) — "
                + (terminate ? "its connection is closed; what it hadn't committed is rolled back." : "the statement stops; the session stays."),
            button: terminate ? "Terminate" : "Cancel Statement", cancel: "Don't")
        actions.confirm(confirmation) { _ in Task { await model.cancel(session, terminate: terminate) } }
    }

    // MARK: Slow queries

    private var slow: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let gap = model.slowQueries?.gap {
                chrome.gap(gap)
            } else {
                HStack {
                    Picker("", selection: $model.slowOrder) {
                        ForEach(DatabaseServerModel.SlowOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
                    Spacer()
                    if let all = model.slowQueries?.value { chrome.caption("\(all.count) statements") }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.shownSlowQueries) { query in
                            VStack(alignment: .leading, spacing: 3) {
                                chrome.statement(query.statement, lines: 3)
                                HStack(spacing: 10) {
                                    Text(verbatim: "\(query.calls) calls")
                                    Text(verbatim: "total \(OpsText.duration(query.total))").foregroundStyle(model.slowOrder == .total ? theme.orangeText : theme.dimText)
                                    Text(verbatim: "mean \(OpsText.duration(query.mean))").foregroundStyle(model.slowOrder == .mean ? theme.orangeText : theme.dimText)
                                    if let rows = query.rows { Text(verbatim: "\(rows) rows") }
                                    if let database = query.database { Text(verbatim: database) }
                                }
                                .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.dimText)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .contextMenu { Button("Copy Statement") { RedisChrome(theme: theme).copy(OpsText.maskSecrets(query.statement)) } }
                        }
                    }
                }
            }
        }
    }

    // MARK: Locks

    private var locks: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let gap = model.locks?.gap {
                chrome.gap(gap)
            } else if let waits = model.locks?.value {
                if waits.isEmpty { chrome.caption("Nobody is waiting on a lock.").padding(12) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(waits) { wait in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(verbatim: "\(wait.waiting)\(wait.waitingUser.map { " (\($0))" } ?? "")").foregroundStyle(theme.orangeText)
                                    Text("waits on").foregroundStyle(theme.dimText)
                                    Text(verbatim: "\(wait.blocking)\(wait.blockingUser.map { " (\($0))" } ?? "")").foregroundStyle(DiffColors.removed)
                                    Spacer()
                                    if let seconds = wait.seconds { Text(verbatim: OpsText.duration(seconds)).foregroundStyle(theme.text) }
                                }
                                .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                                if let lock = wait.lock { chrome.caption(lock) }
                                chrome.statement(wait.waitingStatement, lines: 1)
                                HStack(spacing: 4) {
                                    chrome.caption("blocker:")
                                    chrome.statement(wait.blockingStatement ?? "(idle in a transaction)", lines: 1)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .contextMenu {
                                if model.canCancel,
                                    let blocker = model.activity?.value?.first(where: { $0.id == wait.blocking })
                                        ?? .some(DatabaseActivity(id: wait.blocking, user: wait.blockingUser, statement: wait.blockingStatement)),
                                    !blocker.isOwn
                                {
                                    Button("Cancel the Blocker's Statement…") { askCancel(blocker, terminate: false) }
                                    Button("Terminate the Blocker…") { askCancel(blocker, terminate: true) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Sizes

    private var sizes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let gap = model.sizes?.gap { chrome.gap(gap) }
                if let sizes = model.sizes?.value {
                    sizeList("Databases", sizes.databases)
                    sizeList("Biggest tables", sizes.tables)
                    sizeList("Biggest indexes", sizes.indexes)
                    ForEach(sizes.notes, id: \.self) { chrome.caption($0) }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder private func sizeList(_ title: String, _ entries: [SizeEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                chrome.section(title)
                let largest = max(entries.map(\.bytes).max() ?? 1, 1)
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Text(verbatim: entry.schema.map { "\($0).\(entry.name)" } ?? entry.name).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let detail = entry.detail { Text(verbatim: detail).foregroundStyle(theme.dimText).lineLimit(1) }
                        Text(verbatim: OpsText.bytes(entry.bytes)).foregroundStyle(theme.text).frame(width: 80, alignment: .trailing)
                    }
                    .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                    .background(alignment: .leading) {
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 3).fill(theme.accentText.opacity(0.12))
                                .frame(width: proxy.size.width * CGFloat(Double(entry.bytes) / Double(largest)))
                        }
                    }
                }
            }
        }
    }
}

// MARK: The Users page

struct DatabaseUsersView: View {
    @ObservedObject var model: DatabaseUsersModel
    @ObservedObject var theme: ChromeTheme
    let actions: DatabaseSlotActions
    @State private var sheet: UsersSheet?

    private var chrome: OpsChrome { OpsChrome(theme: theme) }

    enum UsersSheet: Identifiable {
        case create, password(DatabaseUser), grant(DatabaseUser), grantRole(DatabaseUser)
        var id: String {
            switch self {
            case .create: "create"
            case .password(let user): "password \(user.id)"
            case .grant(let user): "grant \(user.id)"
            case .grantRole(let user): "role \(user.id)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RedisChrome(theme: theme).header(model.name, close: actions.close) {
                Image(systemName: "person.2").foregroundStyle(theme.dimText)
                Text("Users & Roles").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.dimText)
            }
            HStack(spacing: 8) {
                if let users = model.users?.value { chrome.caption("\(users.filter { !$0.isRole }.count) users, \(users.filter(\.isRole).count) roles") }
                Spacer()
                if model.reading { ProgressView().controlSize(.mini) }
                RedisChrome(theme: theme).iconButton("arrow.clockwise", "Read again") { Task { await model.reload() } }
                if model.canWrite, model.users?.value != nil {
                    Button("New User…") { sheet = .create }.controlSize(.small).accessibilityIdentifier("newUser")
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider().opacity(0.3)
            if let error = model.error { RedisChrome(theme: theme).error(error).padding(.horizontal, 12).padding(.top, 8) }
            if let gap = model.users?.gap { chrome.gap(gap) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.users?.value ?? []) { user in userRow(user) }
                    if let user = model.selectedUser {
                        Divider().opacity(0.3).padding(.vertical, 6)
                        detail(user)
                    }
                }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .create: CreateUserSheet(model: model, actions: actions, close: { sheet = nil })
            case .password(let user): PasswordSheet(user: user, model: model, actions: actions, close: { sheet = nil })
            case .grant(let user): GrantSheet(user: user, model: model, actions: actions, close: { sheet = nil })
            case .grantRole(let user): GrantRoleSheet(user: user, model: model, actions: actions, close: { sheet = nil })
            }
        }
    }

    private func userRow(_ user: DatabaseUser) -> some View {
        let picked = model.selected == user.id
        return HStack(spacing: 8) {
            Image(systemName: user.isRole ? "person.3" : "person").font(.system(size: ChromeMetrics.text(11))).frame(width: 18)
                .foregroundStyle(theme.dimText)
            Text(verbatim: user.display).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).lineLimit(1)
            if user.superuser { badge("superuser", DiffColors.removed) }
            if user.isRole { badge("role", theme.dimText) } else if !user.canLogin { badge("can't log in", theme.orangeText) }
            ForEach(user.attributes.prefix(3), id: \.self) { badge($0, theme.dimText) }
            Spacer(minLength: 0)
            if !user.memberOf.isEmpty { chrome.caption("in " + user.memberOf.joined(separator: ", ")).lineLimit(1).truncationMode(.tail) }
        }
        .padding(.horizontal, 12).frame(height: ChromeMetrics.row(26))
        .background(RoundedRectangle(cornerRadius: 5).fill(picked ? theme.selected : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onTapGesture { model.selected = picked ? nil : user.id }
        .accessibilityIdentifier("user-\(user.display)")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(9.5), weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().strokeBorder(color.opacity(0.5)))
    }

    private func detail(_ user: DatabaseUser) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: user.display).font(.system(size: ChromeMetrics.text(13), weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
            }
            let facts =
                [
                    user.superuser ? "Superuser: bypasses every privilege check." : nil,
                    user.isRole ? "A role: granted to users, it gives them its privileges." : (user.canLogin ? "Logs in." : "Can't log in."),
                    user.validUntil.map { "Password valid until \($0)." },
                    user.connectionLimit.map { "At most \($0) connections." },
                    user.memberOf.isEmpty ? nil : "Member of \(user.memberOf.joined(separator: ", ")).",
                    user.attributes.isEmpty ? nil : user.attributes.joined(separator: " · "),
                ].compactMap { $0 }
            ForEach(facts, id: \.self) { Text(verbatim: $0).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2) }
            if model.canWrite {
                HStack(spacing: 6) {
                    if !user.isRole || model.dialect?.isMySQL == false {
                        Button("Change Password…") { sheet = .password(user) }.controlSize(.small)
                    }
                    Button("Grant…") { sheet = .grant(user) }.controlSize(.small)
                    Button("Grant Role…") { sheet = .grantRole(user) }.controlSize(.small)
                    Spacer()
                    Button("Drop…") { askDrop(user) }.controlSize(.small).foregroundStyle(DiffColors.removed)
                }
            }
            chrome.section("Grants")
            switch model.grants {
            case nil: chrome.caption("Reading…")
            case .unavailable(let gap)?: chrome.gap(gap)
            case .value(let grants)?:
                if grants.isEmpty { chrome.caption("None of its own — it may still have what PUBLIC is granted, or its roles'.") }
                ForEach(grants) { grant in grantRow(grant, user: user) }
                if model.dialect == .postgres { chrome.caption("Tables and schemas of this database; databases of the server.") }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func grantRow(_ grant: DatabaseGrant, user: DatabaseUser) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: grant.kind).foregroundStyle(theme.dimText).frame(width: 60, alignment: .leading)
            Text(verbatim: grant.object).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(verbatim: grant.privileges.joined(separator: ", ") + (grant.grantable ? " +grant" : "")).foregroundStyle(theme.text2)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
        .contextMenu {
            if model.canWrite, let statement = revoke(grant, from: user) {
                Button("Revoke…") { ask("Revoke from \(user.display)?", [statement], button: "Revoke") }
            }
        }
    }

    /// The statement that takes a listed grant back, when it is one Overterm can name.
    private func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement? {
        guard let dialect = model.dialect else { return nil }
        if grant.kind == "role" {
            let parts = grant.object.split(separator: "@", maxSplits: 1).map(String.init)
            let role = DatabaseUser(
                name: parts.first ?? grant.object, host: dialect == .mysql && parts.count > 1 ? parts[1] : nil, isRole: true)
            return try? UserStatements.revokeRole(role, from: user, dialect: dialect)
        }
        guard let target = GrantTargets.target(of: grant, dialect: dialect) else { return nil }
        let allowed = UserStatements.privileges(on: target, dialect: dialect)
        let privileges = grant.privileges.filter(allowed.contains)
        guard !privileges.isEmpty else { return nil }
        return try? UserStatements.revoke(privileges, on: target, from: user, dialect: dialect)
    }

    private func askDrop(_ user: DatabaseUser) {
        guard let dialect = model.dialect, let statement = try? UserStatements.drop(user, dialect: dialect) else { return }
        var confirmation = WriteConfirmation(
            title: "Drop \(user.display)?", scope: model.name,
            detail: statement.shown + ";\n\nType its name to drop it. What it owns must be dropped or reassigned first; the server says so if not.",
            button: "Drop", typedName: user.name, critical: true)
        confirmation.cancel = "Cancel"
        actions.confirm(confirmation) { typed in
            // The name typed, or nothing is dropped.
            guard typed == user.name else { return model.refuse("“\(typed)” isn't \(user.name) — nothing was dropped.") }
            Task { _ = await model.run([statement]) }
        }
    }

    private func ask(_ title: String, _ statements: [UserStatement], button: String) {
        UsersConfirm.ask(title, statements, button: button, model: model, actions: actions)
    }
}

/// A user statement's confirmation: every statement as shown (passwords
/// masked), then sent.
@MainActor
enum UsersConfirm {
    static func ask(_ title: String, _ statements: [UserStatement], button: String, model: DatabaseUsersModel, actions: DatabaseSlotActions) {
        let confirmation = WriteConfirmation(
            title: title, scope: model.name, detail: statements.map { $0.shown + ";" }.joined(separator: "\n"), button: button)
        actions.confirm(confirmation) { _ in Task { _ = await model.run(statements) } }
    }
}

/// A grant's object, as a target a REVOKE names. Pure.
enum GrantTargets {
    static func target(of grant: DatabaseGrant, dialect: UserDialect) -> GrantTarget? {
        if let target = grant.target { return target }
        switch grant.kind {
        case "server": return dialect.isMySQL ? .server : nil
        case "database": return .database(dialect.isMySQL ? String(grant.object.dropLast(2)) : grant.object)
        case "schema": return .schema(grant.object)
        default: return nil
        }
    }
}

// MARK: Sheets

/// A sheet's frame: its title, its fields, the statements it would run
/// (passwords masked), and its buttons.
private struct UserSheetFrame<Fields: View>: View {
    let title: String
    let preview: Result<[UserStatement], Error>
    let button: String
    let close: () -> Void
    let go: ([UserStatement]) -> Void
    @ViewBuilder let fields: () -> Fields

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title).font(.headline)
            fields()
            Text("Runs").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Group {
                switch preview {
                case .success(let statements):
                    Text(verbatim: statements.map { $0.shown + ";" }.joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                case .failure(let error):
                    Text(verbatim: error.localizedDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))
            .accessibilityIdentifier("userPreview")
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(button) {
                    if case .success(let statements) = preview { go(statements) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((try? preview.get()) == nil)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

/// A new user: its name, a password typed twice (in memory until sent, never
/// kept), what it may do.
private struct CreateUserSheet: View {
    @ObservedObject var model: DatabaseUsersModel
    let actions: DatabaseSlotActions
    let close: () -> Void
    @State private var user = NewUser()
    @State private var again = ""

    private var dialect: UserDialect { model.dialect ?? .postgres }

    private var preview: Result<[UserStatement], Error> {
        if !user.password.isEmpty, user.password != again { return .failure(UserStatements.Refusal(message: "The two passwords differ.")) }
        return Result { try UserStatements.create(user, dialect: dialect) }
    }

    var body: some View {
        UserSheetFrame(title: "New User on \(model.name)", preview: preview, button: "Create…", close: close, go: go) {
            TextField("Name", text: $user.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("newUserName")
            if dialect.isMySQL {
                TextField("Host (% is any)", text: $user.host).textFieldStyle(.roundedBorder)
            }
            SecureField("Password", text: $user.password).textFieldStyle(.roundedBorder)
            SecureField("Password again", text: $again).textFieldStyle(.roundedBorder)
            if !dialect.isMySQL {
                HStack(spacing: 14) {
                    if dialect == .postgres { Toggle("Logs in", isOn: $user.login) }
                    Toggle("Superuser", isOn: $user.superuser)
                    Toggle("Creates databases", isOn: $user.createDatabases)
                    if dialect == .postgres { Toggle("Creates roles", isOn: $user.createRoles) }
                }
                .toggleStyle(.checkbox).font(.system(size: 11.5))
                TextField("Valid until (yyyy-MM-dd, empty: forever)", text: $user.validUntil).textFieldStyle(.roundedBorder)
            }
            Text(
                dialect == .postgres
                    ? "The password is sent as its SCRAM-SHA-256 verifier — never in the clear, and never kept here."
                    : dialect == .redshift ? "The password is sent as its md5 form, and never kept here." : "The password is sent once, over this connection, and never kept here."
            )
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    private func go(_ statements: [UserStatement]) {
        close()
        UsersConfirm.ask("Create \(user.name)?", statements, button: "Create", model: model, actions: actions)
    }
}

private struct PasswordSheet: View {
    let user: DatabaseUser
    @ObservedObject var model: DatabaseUsersModel
    let actions: DatabaseSlotActions
    let close: () -> Void
    @State private var password = ""
    @State private var again = ""

    private var preview: Result<[UserStatement], Error> {
        if password != again { return .failure(UserStatements.Refusal(message: "The two passwords differ.")) }
        return Result { [try UserStatements.password(of: user, to: password, dialect: model.dialect ?? .postgres)] }
    }

    var body: some View {
        UserSheetFrame(title: "New Password for \(user.display)", preview: preview, button: "Change…", close: close, go: go) {
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            SecureField("Password again", text: $again).textFieldStyle(.roundedBorder)
        }
    }

    private func go(_ statements: [UserStatement]) {
        close()
        UsersConfirm.ask("Change \(user.display)'s password?", statements, button: "Change", model: model, actions: actions)
    }
}

private struct GrantSheet: View {
    let user: DatabaseUser
    @ObservedObject var model: DatabaseUsersModel
    let actions: DatabaseSlotActions
    let close: () -> Void
    @State private var kind = ""
    @State private var database = ""
    @State private var schema = ""
    @State private var table = ""
    @State private var picked: Set<String> = []
    @State private var grantOption = false

    private var dialect: UserDialect { model.dialect ?? .postgres }

    private var target: GrantTarget {
        switch kind {
        case "Server": return .server
        case "Schema": return .schema(schema)
        case "All tables in schema": return .allTables(schema)
        case "Table": return .table(TableName(schema: dialect.isMySQL ? database : schema, name: table))
        default: return .database(database)
        }
    }

    private var preview: Result<[UserStatement], Error> {
        let privileges = UserStatements.privileges(on: target, dialect: dialect).filter(picked.contains)
        return Result { [try UserStatements.grant(privileges, on: target, to: user, dialect: dialect, grantOption: grantOption)] }
    }

    var body: some View {
        UserSheetFrame(title: "Grant to \(user.display)", preview: preview, button: "Grant…", close: close, go: go) {
            Picker("On", selection: $kind) {
                ForEach(UserStatements.targetKinds(dialect), id: \.self) { Text($0).tag($0) }
            }
            if kind == "Database" || (dialect.isMySQL && kind == "Table") {
                TextField("Database", text: $database).textFieldStyle(.roundedBorder)
            }
            if !dialect.isMySQL, kind != "Database" {
                TextField("Schema", text: $schema).textFieldStyle(.roundedBorder)
            }
            if kind == "Table" { TextField("Table", text: $table).textFieldStyle(.roundedBorder) }
            let privileges = UserStatements.privileges(on: target, dialect: dialect)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(privileges, id: \.self) { privilege in
                    Toggle(
                        privilege,
                        isOn: Binding(
                            get: { picked.contains(privilege) }, set: { on in if on { picked.insert(privilege) } else { picked.remove(privilege) } })
                    )
                    .toggleStyle(.checkbox).font(.system(size: 11))
                }
            }
            Toggle("With grant option — it may grant these to others", isOn: $grantOption).toggleStyle(.checkbox).font(.system(size: 11.5))
        }
        .onAppear {
            kind = UserStatements.targetKinds(dialect).first { $0 == "Database" } ?? "Database"
            database = model.session?.connection.database ?? ""
            schema = model.session?.schema ?? "public"
        }
    }

    private func go(_ statements: [UserStatement]) {
        close()
        UsersConfirm.ask("Grant to \(user.display)?", statements, button: "Grant", model: model, actions: actions)
    }
}

private struct GrantRoleSheet: View {
    let user: DatabaseUser
    @ObservedObject var model: DatabaseUsersModel
    let actions: DatabaseSlotActions
    let close: () -> Void
    @State private var role: DatabaseUser.ID?

    private var dialect: UserDialect { model.dialect ?? .postgres }
    /// Roles first; PostgreSQL grants any role, MySQL 8 any account.
    private var candidates: [DatabaseUser] {
        let others = (model.users?.value ?? []).filter { $0.id != user.id && !user.memberOf.contains($0.display) }
        let roles = others.filter(\.isRole)
        return dialect == .mariadb || dialect == .redshift ? roles : roles + others.filter { !$0.isRole }
    }

    private var preview: Result<[UserStatement], Error> {
        guard let picked = candidates.first(where: { $0.id == role }) else { return .failure(UserStatements.Refusal(message: "Pick a role.")) }
        return Result { [try UserStatements.grantRole(picked, to: user, dialect: dialect)] }
    }

    var body: some View {
        UserSheetFrame(title: "Grant a Role to \(user.display)", preview: preview, button: "Grant…", close: close, go: go) {
            Picker("Role", selection: $role) {
                Text("Choose…").tag(DatabaseUser.ID?.none)
                ForEach(candidates) { Text(verbatim: $0.display + ($0.isRole ? "" : " (a user)")).tag(DatabaseUser.ID?.some($0.id)) }
            }
        }
    }

    private func go(_ statements: [UserStatement]) {
        close()
        UsersConfirm.ask("Grant a role to \(user.display)?", statements, button: "Grant", model: model, actions: actions)
    }
}
