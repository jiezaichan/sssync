import AppKit
import ServiceManagement
import SwiftUI
import SyncKit
import UserNotifications

enum SidebarItem: Hashable {
    case pending, waiting, acknowledged, env, apps, files, agents, handlers
}

struct RowGroup: Identifiable {
    let title: String
    let rows: [Row]
    var id: String { title }
}

/// 一条要在本机跑的补齐命令
struct CommandJob: Identifiable {
    let id = UUID()
    let title: String
    let command: String
}

/// 主窗口上弹出的面板
enum ActiveSheet: Identifiable {
    case diff(Row)
    case merge(Row)
    case template(Row)
    case command(CommandJob)

    var id: String {
        switch self {
        case .diff(let row): return "diff-" + row.id
        case .merge(let row): return "merge-" + row.id
        case .template(let row): return "template-" + row.id
        case .command(let job): return "command-" + job.id.uuidString
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var config: Config?
    var snapshot: Snapshot? {
        didSet { rebuildReports() }
    }
    var busy = false
    var errorText: String?
    /// 还没指定本机是哪台，需要先去设置
    var needsSetup = false
    var selection: SidebarItem? = .pending
    var sheet: ActiveSheet?
    private(set) var envSections: [EnvSection] = []
    private(set) var appSections: [EnvSection] = []
    private var engine: Engine?
    private var timer: Task<Void, Never>?
    private var started = false

    init() {
        Task { await start() }
    }

    private func start() async {
        guard !started else { return }
        started = true
        observeWake()
        // 系统弹窗等用户点，不能挡住刷新
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        do {
            let config = try Config.load()
            self.config = config
            try makeEngine(config)
        } catch {
            errorText = error.localizedDescription
            return
        }
        await refresh()
        restartTimer()
    }

    private func makeEngine(_ config: Config) throws {
        do {
            engine = try Engine(config: config)
            needsSetup = false
        } catch {
            engine = nil
            needsSetup = true
            throw error
        }
    }

    func saveConfig(_ draft: Config) async {
        do {
            try draft.save()
            config = draft
            snapshot = nil
            errorText = nil
            try makeEngine(draft)
        } catch {
            errorText = error.localizedDescription
            return
        }
        restartTimer()
        await refresh()
    }

    func refresh() async {
        guard let engine, !busy else { return }
        busy = true
        errorText = nil
        do {
            let new = try await engine.refresh()
            snapshot = new
            notify(new)
        } catch {
            errorText = error.localizedDescription
        }
        busy = false
    }

    func use(_ row: Row, machine: String) async {
        await perform { try await $0.use(row.id, machine: machine) }
    }

    /// 本机已装的 App，给「在本机设置」菜单用
    var localApps: [AppInfo] {
        guard let snapshot, let report = snapshot.reports[snapshot.me] else { return [] }
        return report.apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 只改本机：把这一行的扩展名直接设成某个 App
    func setHandler(_ row: Row, bundleID: String) async {
        let ext = row.name.hasPrefix(".") ? String(row.name.dropFirst()) : row.name
        await perform { try await $0.setLocalHandler(ext: ext, bundleID: bundleID) }
    }

    func useMerged(_ row: Row, text: String) async {
        await perform { try await $0.useMerged(row.id, text: text) }
    }

    /// 改两台共用的同步清单
    func updateShared(_ change: @escaping @Sendable (inout SharedConfig) -> Void) async {
        await perform { try await $0.updateShared(change) }
    }

    func ignore(_ row: Row) async {
        await updateShared { if !$0.ignored.contains(row.id) { $0.ignored.append(row.id) } }
    }

    // MARK: 确认差异

    func isAcked(_ row: Row) -> Bool { shared?.isAcknowledged(row.id, signature: row.signature) == true }
    func isAcked(_ row: EnvRow) -> Bool { shared?.isAcknowledged(row.ackID, signature: row.signature) == true }

    /// 两边就这样，翻篇；任一边再变会重新出现
    func acknowledge(_ rows: [Row]) async {
        await updateShared { s in for row in rows { s.acknowledged[row.id] = row.signature } }
    }

    func acknowledge(_ rows: [EnvRow]) async {
        await updateShared { s in for row in rows { s.acknowledged[row.ackID] = row.signature } }
    }

    func unacknowledge(_ ids: [String]) async {
        await updateShared { s in for id in ids { s.acknowledged[id] = nil } }
    }

    private func perform(_ work: (Engine) async throws -> Void) async {
        guard let engine, !busy else { return }
        busy = true
        do {
            try await work(engine)
        } catch {
            errorText = error.localizedDescription
        }
        busy = false
        await refresh()
    }

    func diffSource(_ row: Row) async throws -> DiffSource {
        guard let engine else { throw SyncError("还没准备好") }
        return try await engine.diffSource(row.id)
    }

    /// 目录对比里的单个文件：两边各一个内容指纹
    func memberSource(_ values: [String: String], path: String) async throws -> DiffSource {
        guard let engine else { throw SyncError("还没准备好") }
        return try await engine.contentSource(values, path: path)
    }

    func mergeSource(_ row: Row) async throws -> MergeSource {
        guard let engine else { throw SyncError("还没准备好") }
        return try await engine.mergeSource(row.id)
    }

    /// 补齐：链接直接打开，命令弹出面板边跑边看
    func run(_ fix: Fix, title: String) {
        switch fix {
        case .open(let url):
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        case .run(let command):
            sheet = .command(CommandJob(title: title, command: command))
        case .trash(let path, let bundleID):
            Task { await trash(path, bundleID: bundleID) }
        }
    }

    /// 对面多出来的，写成待办让对面自己卸
    func requestUninstall(_ row: EnvRow, on machine: String) async {
        guard let seen = row.values[machine] else { return }
        await perform { try await $0.requestUninstall(rowID: row.id, name: row.name, seen: seen) }
    }

    /// 卸载不是 brew 装的 App：移到废纸篓，能找回。App Store 装的归 root，系统挡住就交给访达（会要密码）
    private func trash(_ path: String, bundleID: String) async {
        let name = URL(filePath: path).deletingPathExtension().lastPathComponent
        do {
            try await CommandRunner.trash(path: path, bundleID: bundleID)
        } catch let error as SyncError {
            errorText = error.localizedDescription
            return
        } catch {
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var failure: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to delete (POSIX file \"\(escaped)\" as alias)")?.executeAndReturnError(&failure)
            if let failure {
                errorText = "\(name) 没能移到废纸篓：\(failure[NSAppleScript.errorMessage] ?? error.localizedDescription)"
                return
            }
        }
        await refresh()
    }

    // MARK: 常驻

    private func restartTimer() {
        timer?.cancel()
        let minutes = max(config?.refreshMinutes ?? 15, 1)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    /// 开盖唤醒后网络要一会儿才通，稍等再刷新
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                await self?.refresh()
            }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorText = "登录时启动设置失败：\(error.localizedDescription)"
            }
        }
    }

    /// 对面改了、还没提醒过的条目发一条系统通知；执行了对面的决定也说一声
    private func notify(_ snapshot: Snapshot) {
        guard config?.notify == true else { return }
        let defaults = UserDefaults.standard
        let seen = Set(defaults.stringArray(forKey: "notified") ?? [])
        var fresh: [Row] = []
        var current = Set<String>()
        for row in snapshot.rows where !snapshot.shared.isAcknowledged(row.id, signature: row.signature) {
            let peerChanged: Bool
            switch row.status {
            case .onlyChanged(let m): peerChanged = m == snapshot.peer
            case .conflict: peerChanged = true
            default: peerChanged = false
            }
            guard peerChanged else { continue }
            let key = row.id + "@" + (row.states[snapshot.peer]?.fp ?? absentFP)
            current.insert(key)
            if !seen.contains(key) { fresh.append(row) }
        }
        // 只记还在差异里的；抹平后再变会重新提醒
        defaults.set(Array(current), forKey: "notified")

        if !fresh.isEmpty {
            let names = fresh.prefix(4).map(\.title).joined(separator: "、")
            post("\(snapshot.badge(snapshot.peer))改了 \(fresh.count) 项", fresh.count > 4 ? names + " 等" : names)
        }
        if !snapshot.messages.isEmpty {
            post("sssync 执行结果", snapshot.messages.joined(separator: "\n"))
        }
    }

    private func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: 视图用

    var title: String {
        guard let snapshot else { return "sssync" }
        let order = snapshot.machineOrder
        return "sssync — \(snapshot.badge(order[0])) ↔ \(snapshot.badge(order[1]))"
    }

    var shared: SharedConfig? { snapshot?.shared }

    private func rebuildReports() {
        guard let snapshot else {
            envSections = []
            appSections = []
            return
        }
        envSections = EnvCompare.environment(snapshot.reports, machines: snapshot.machineOrder)
        appSections = EnvCompare.apps(snapshot.reports, machines: snapshot.machineOrder)
    }

    func count(_ item: SidebarItem) -> Int {
        switch item {
        case .env: return openRows(envSections.filter { $0.id != "errors" }).count
        case .apps: return openRows(appSections).count
        case .acknowledged: return rows(for: .acknowledged).count + ackedReportSections.reduce(0) { $0 + $1.rows.count }
        // 默认打开方式列表里有一致项和已确认的差异，角标只数还要处理的
        case .handlers: return rows(for: .handlers).filter { $0.status != .same && !isAcked($0) }.count
        // 「文件」和「启动项」列出全部条目，角标只数不一致、还没确认的
        case .files, .agents: return rows(for: item).filter { $0.status != .same && !isAcked($0) }.count
        default: return rows(for: item).count
        }
    }

    /// 待处理总数：要拍板的 + 环境和应用里没确认的差异。目标是清零
    var totalOpen: Int { count(.pending) + count(.env) + count(.apps) }

    /// 环境和应用里确认过的差异，按原分组
    var ackedReportSections: [EnvSection] {
        (envSections + appSections).compactMap { s in
            let rows = s.rows.filter { !$0.same && !$0.localOnly && isAcked($0) }
            return rows.isEmpty ? nil : EnvSection(id: s.id, title: s.title, systemImage: s.systemImage, rows: rows, footer: nil)
        }
    }

    /// 不同、且还没确认的；本机专属（local.zsh）不算
    func openRows(_ sections: [EnvSection]) -> [EnvRow] {
        sections.flatMap(\.rows).filter { !$0.same && !$0.localOnly && !isAcked($0) }
    }

    var visibleGroups: [RowGroup] {
        let rows = rows(for: selection ?? .pending)
        var order: [String] = []
        var byGroup: [String: [Row]] = [:]
        for row in rows {
            if byGroup[row.group] == nil { order.append(row.group) }
            byGroup[row.group, default: []].append(row)
        }
        return order.map { RowGroup(title: $0, rows: byGroup[$0]!) }
    }

    private func rows(for item: SidebarItem) -> [Row] {
        let everything = snapshot?.rows ?? []
        switch item {
        case .acknowledged:
            return everything.filter { $0.status != .same && !$0.status.isWaiting && isAcked($0) }
        // 这三个分类列全量：两台一致的和确认过差异的都留着，随时能回看
        case .files: return everything.filter { $0.kind == .file || $0.kind == .dir }
        case .agents: return everything.filter { $0.kind == .agent }
        case .handlers: return everything.filter { $0.kind == .handler }
        default: break
        }
        let all = everything.filter { !isAcked($0) }
        switch item {
        case .pending: return all.filter { $0.status != .same && !$0.status.isWaiting }
        case .waiting: return all.filter { $0.status != .same && $0.status.isWaiting }
        default: return []
        }
    }
}

extension Snapshot {
    /// 界面上左右列的固定顺序：家里在左、公司在右
    var machineOrder: [String] {
        [me, peer].sorted { a, b in a == "home" ? true : b == "home" ? false : a < b }
    }

    func other(than machine: String) -> String { machine == me ? peer : me }

    /// 「以某台为准」按钮：左列的往右推「🏠 →」，右列的往左拉「← 🏢」
    func arrow(_ machine: String, text: String? = nil) -> String {
        let core = text.map { "\(emoji(machine)) \($0)" } ?? emoji(machine)
        return machine == machineOrder[0] ? "\(core) →" : "← \(core)"
    }
}
