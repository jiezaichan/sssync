import Foundation

/// 三方合并要的内容：基线（没有基线时为 nil）和两边现状
public struct MergeSource: Sendable {
    public let base: String?
    /// 机器 → 文本
    public let texts: [String: String]
}

/// 把扫描、中转站、对账、执行串起来。每台只改自己：本机要改的当场应用，对面要改的写成待办。
public actor Engine {
    public let config: Config
    public let me: String
    public let peer: String
    public private(set) var shared: SharedConfig

    private let blobs = BlobStore(dir: Paths.blobs)
    private let relay: Relay
    private var relayReady = false
    private var lastLocal: [String: ItemState] = [:]
    private var lastPeer: StateDoc?
    private var lastBase: [String: String] = [:]
    private var lastReport: MachineReport?

    public init(config: Config) throws {
        self.config = config
        (me, peer) = try config.identify()
        relay = Relay(host: config.relayHost, path: config.relayPath)
        shared = SharedConfig.loadCached()
    }

    private var files: FileProvider { FileProvider(config: shared, blobs: blobs) }
    private var handlers: HandlerProvider { HandlerProvider(config: shared, blobs: blobs) }
    private var agents: AgentProvider { AgentProvider(config: shared, blobs: blobs, machine: me) }

    // MARK: 刷新

    /// 同步清单 → 执行发给本机的待办 → 扫描并发布本机状态和环境报告 → 与对面对账
    public func refresh() async throws -> Snapshot {
        if !relayReady {
            try relay.setup(machines: Array(config.machines.keys))
            relayReady = true
        }
        var messages: [String] = []
        var meta = try relay.fetchMeta(me: me, peer: peer)
        try adoptShared(meta.shared)
        // 对面让本机卸载的先做，下面采集的报告才是卸完的样子
        let uninstalls = meta.mine.filter { $0.item.hasPrefix(Self.uninstallPrefix) }
        if !uninstalls.isEmpty {
            messages += await applyUninstalls(uninstalls, peerReport: meta.peer?.report)
        }
        // 环境报告要跑登录 shell，几秒钟，和文件扫描并行
        let reportTask = Task.detached { [shared] in ReportCollector.collect(shared: shared) }
        let syncDecisions = meta.mine.filter { !$0.item.hasPrefix(Self.uninstallPrefix) }
        if !syncDecisions.isEmpty {
            messages += await applyIncoming(syncDecisions)
        }
        if !meta.mine.isEmpty {
            meta = try relay.fetchMeta(me: me, peer: peer)
        }
        if !meta.notices.isEmpty {
            let from = config.label(peer)
            messages += meta.notices.map { "\(from)：\($0.message)" }
            try? relay.remove(meta.notices.map { "notices/\(me)/\($0.decision).json" })
        }

        var refs = Set<String>()
        let local = try scanAll(refs: &refs)
        try relay.uploadBlobs(refs, from: blobs)
        let report = await reportTask.value
        let now = Date()
        let scope = Scope(shared)
        try relay.put([("machines/\(me)/state.json", try JSON.encode(StateDoc(machine: me, publishedAt: now, items: local,
                                                                              report: report,
                                                                              scope: scope)))])
        lastLocal = local
        lastPeer = meta.peer
        lastBase = meta.base
        lastReport = report

        var rows: [Row] = []
        if let peerDoc = meta.peer {
            // 两边都按现在的清单过滤：对面的状态可能是按旧清单扫的，清单外的条目不能当成「对面删了」
            let inScope = { (id: String) in !self.shared.isIgnored(id) && scope.rule(for: id) != nil }
            var peerItems = peerDoc.items.filter { inScope($0.key) }
            var local = local.filter { inScope($0.key) }
            // 规则和对面扫描时不一样的条目：对面的值不可信（可能只是还没扫），等它按新清单刷新
            let peerScope = peerDoc.scope ?? scope
            let outdated = Set(local.keys).union(peerItems.keys).filter { scope.rule(for: $0) != peerScope.rule(for: $0) }
            var outdatedStates: [String: (ItemState?, ItemState?)] = [:]
            for id in outdated {
                outdatedStates[id] = (local.removeValue(forKey: id), peerItems.removeValue(forKey: id))
            }
            let result = Reconciler.reconcile(local: local, peer: peerItems, base: meta.base,
                                              pending: Set(meta.theirs.map(\.item)))
            try writeBase(result.converged)
            rows = result.diffs.map { id, status in
                makeRow(id: id, status: status, local: local[id], peer: peerItems[id])
            }
            // 默认打开方式要看全量：两台一致的也列出来，方便直接在本机改
            rows += local.keys.filter { id in
                ItemKind(id: id) == .handler
                    && result.diffs[id] == nil
                    && peerItems[id] != nil
                    && local[id]?.fpOrAbsent == peerItems[id]?.fpOrAbsent
            }.map { id in
                makeRow(id: id, status: nil, local: local[id], peer: peerItems[id], same: true)
            }
            // 文件、目录、启动项也全量：两台一致的照样列出来，方便核对
            rows += local.keys.filter { id in
                let kind = ItemKind(id: id)
                return (kind == .file || kind == .dir || kind == .agent)
                    && result.diffs[id] == nil
                    && peerItems[id] != nil
                    && local[id]?.fpOrAbsent == peerItems[id]?.fpOrAbsent
            }.map { id in
                makeRow(id: id, status: nil, local: local[id], peer: peerItems[id], same: true)
            }
            rows += outdatedStates.compactMap { id, states in
                states.0?.fpOrAbsent == states.1?.fpOrAbsent ? nil
                    : makeRow(id: id, status: nil, local: states.0, peer: states.1)
            }
            rows.sort { ($0.group, $0.name) < ($1.group, $1.name) }
        }

        var publishedAt = [me: now]
        publishedAt[peer] = meta.peer?.publishedAt
        var reports = [me: report]
        reports[peer] = meta.peer?.report
        var snapshot = Snapshot(me: me, peer: peer,
                                machines: config.machines,
                                rows: rows, publishedAt: publishedAt, messages: messages,
                                peerMissing: meta.peer == nil,
                                reports: reports, shared: shared)
        snapshot.pendingRemovals = Set(meta.theirs.compactMap { d in
            d.item.hasPrefix(Self.uninstallPrefix) ? String(d.item.dropFirst(Self.uninstallPrefix.count)) : nil
        })
        return snapshot
    }

    // MARK: 让对面卸载

    static let uninstallPrefix = "uninstall:"

    /// 对面多出来的东西，写成待办让对面自己卸；`seen` 是拍板时看到的对面的值
    public func requestUninstall(rowID: String, name: String, seen: String) throws {
        let decision = Decision(id: UUID().uuidString, item: Self.uninstallPrefix + rowID,
                                expect: seen, value: name, mode: nil, decidedOn: me, decidedAt: Date())
        try relay.put([("decisions/\(peer)/\(decision.id).json", try JSON.line(decision))])
    }

    /// 执行对面发来的卸载：按本机现在的报告重新算一遍，值和对面拍板时看到的一样、而且本机确实是多出来的那台才卸
    private func applyUninstalls(_ decisions: [Decision], peerReport: MachineReport?) async -> [String] {
        let report = await Task.detached { [shared] in ReportCollector.collect(shared: shared) }.value
        var rows: [String: EnvRow] = [:]
        if let peerReport {
            let reports = [me: report, peer: peerReport]
            let machines = [me, peer]
            for row in (EnvCompare.environment(reports, machines: machines) + EnvCompare.apps(reports, machines: machines)).flatMap(\.rows) {
                rows[row.id] = row
            }
        }
        var messages: [String] = []
        var receipts: [(String, Data)] = []
        var done: [String] = []
        for decision in decisions.sorted(by: { $0.decidedAt < $1.decidedAt }) {
            let rowID = String(decision.item.dropFirst(Self.uninstallPrefix.count))
            let name = decision.value
            let from = config.label(decision.decidedOn)
            var result = "applied"
            var message: String
            if let row = rows[rowID], row.values[me] == decision.expect, let removal = row.removals[me] {
                do {
                    switch removal {
                    case .run(let command):
                        let (status, output) = await CommandRunner.collect(command)
                        if status != 0 {
                            let tail = output.split(separator: "\n").suffix(3).joined(separator: " ")
                            throw SyncError("退出码 \(status)：\(tail)")
                        }
                    case .trash(let path, let bundleID):
                        try await CommandRunner.trash(path: path, bundleID: bundleID)
                    case .open:
                        throw SyncError("这一项不能自动卸载")
                    }
                    message = "已按\(from)的决定卸载 \(name)"
                } catch {
                    result = "failed"
                    message = "\(name) 没能卸载（\(from)让卸的）：\(error.localizedDescription)。到这台上点「在本机卸载」试试"
                }
            } else {
                result = "stale"
                message = "\(name)：\(from)让卸载，但这台现在的情况和当时不一样了，没有动"
            }
            messages.append(message)
            let receipt = Receipt(decision: decision.id, item: decision.item, result: result,
                                  message: message, machine: me, at: Date())
            if let data = try? JSON.line(receipt) {
                receipts.append(("receipts/\(decision.id).json", data))
                // 发起那台下次刷新时看到结果
                receipts.append(("notices/\(decision.decidedOn)/\(decision.id).json", data))
            }
            done.append("decisions/\(me)/\(decision.id).json")
        }
        do {
            try relay.put(receipts)
            try relay.remove(done)
        } catch {
            messages.append("回执没写到中转站：\(error.localizedDescription)")
        }
        return messages
    }

    /// 中转站上的清单为准；中转站上还没有，就把本机的传上去
    private func adoptShared(_ remote: SharedConfig?) throws {
        if let remote {
            if remote != shared {
                shared = remote
                try shared.saveCache()
            }
        } else {
            try relay.put([("shared.json", try JSON.line(shared))])
            try shared.saveCache()
        }
    }

    /// 改同步清单：两台共用，传到中转站。在中转站上最新的那份上改，本机缓存可能是旧的，整份写回会盖掉对面刚改的
    public func updateShared(_ change: @Sendable (inout SharedConfig) -> Void) throws {
        var new = try relay.fetchShared() ?? shared
        change(&new)
        try relay.put([("shared.json", try JSON.line(new))])
        shared = new
        try shared.saveCache()
    }

    // MARK: 拍板

    /// 以 `machine` 那台为准。是本机 → 给对面写待办；是对面 → 当场改本机。
    public func use(_ id: String, machine: String) async throws {
        var refs = Set<String>()
        let current = try await scan(id, refs: &refs)
        guard current.fpOrAbsent == (lastLocal[id]?.fpOrAbsent ?? absentFP) else {
            throw SyncError("本机这一项刚刚又变了，请先刷新")
        }
        let peerState = lastPeer?.items[id]
        if machine == me {
            try relay.uploadBlobs(refs, from: blobs)
            try sendDecision(id, value: current.fpOrAbsent, mode: current.mode)
        } else {
            let target = peerState?.fpOrAbsent ?? absentFP
            try await applyChecked(id, value: target, mode: peerState?.mode, backup: Backup(session: Backup.newSession()))
            try writeBase([id: target])
        }
    }

    /// 只改本机：把某个扩展名的默认打开方式直接设成指定的 App，不写待办
    @MainActor
    public func setLocalHandler(ext: String, bundleID: String) async throws {
        try await handlers.apply(ext: ext, bundleID: bundleID)
    }

    /// 合并结果：本机当场写入，同时作为待办发给对面；两边都应用后基线更新
    public func useMerged(_ id: String, text: String) async throws {
        guard ItemKind(id: id) == .file else { throw SyncError("只有文本文件能合并") }
        var refs = Set<String>()
        let current = try await scan(id, refs: &refs)
        guard current.fpOrAbsent == (lastLocal[id]?.fpOrAbsent ?? absentFP) else {
            throw SyncError("本机这一项刚刚又变了，请先刷新")
        }
        let value = try blobs.put(Data(text.utf8))
        let mode = current.mode ?? lastPeer?.items[id]?.mode
        try await applyChecked(id, value: value, mode: mode, backup: Backup(session: Backup.newSession()))
        try relay.uploadBlobs([value], from: blobs)
        try sendDecision(id, value: value, mode: mode)
    }

    private func sendDecision(_ id: String, value: String, mode: Int?) throws {
        let decision = Decision(id: UUID().uuidString, item: id,
                                expect: lastPeer?.items[id]?.fpOrAbsent ?? absentFP,
                                value: value, mode: mode,
                                decidedOn: me, decidedAt: Date())
        try relay.put([("decisions/\(peer)/\(decision.id).json", try JSON.line(decision))])
    }

    // MARK: 对比

    /// 对比视图要的两边内容
    public func diffSource(_ id: String) throws -> DiffSource {
        guard let kind = ItemKind(id: id), kind != .handler else { throw SyncError("这一项没有可对比的内容") }
        let values = [me: lastLocal[id]?.fpOrAbsent ?? absentFP, peer: lastPeer?.items[id]?.fpOrAbsent ?? absentFP]
        guard kind == .dir else { return try contentSource(values, path: kind == .file ? itemKey(id) : nil) }
        try relay.downloadBlobs(Array(values.values), into: blobs)
        var members: [String: [String: String]] = [:]
        for (machine, fp) in values {
            members[machine] = fp == absentFP ? [:] : try files.manifest(fp).mapValues(\.fp)
        }
        return .directory(members)
    }

    /// 两边各一个内容指纹 → 文本或二进制；`path` 是含密钥的文件时值打码
    public func contentSource(_ values: [String: String], path: String? = nil) throws -> DiffSource {
        try relay.downloadBlobs(Array(values.values), into: blobs)
        let secret = path.map(shared.isSecret) ?? false
        var texts: [String: String?] = [:]
        var sizes: [String: Int?] = [:]
        var binary = false
        for (machine, fp) in values {
            guard fp != absentFP else {
                texts[machine] = .some(nil)
                sizes[machine] = .some(nil)
                continue
            }
            let data = try blobs.get(fp)
            sizes[machine] = data.count
            if let text = String(data: data, encoding: .utf8) { texts[machine] = secret ? Secrets.mask(text) : text } else { binary = true }
        }
        return binary ? .binary(sizes) : .text(texts)
    }

    public func mergeSource(_ id: String) throws -> MergeSource {
        let values = [me: lastLocal[id]?.fp, peer: lastPeer?.items[id]?.fp]
        let base = lastBase[id].flatMap { $0 == absentFP ? nil : $0 }
        try relay.downloadBlobs(values.values.compactMap { $0 } + [base].compactMap { $0 }, into: blobs)
        func text(_ fp: String?) throws -> String? {
            guard let fp else { return nil }
            guard let s = String(data: try blobs.get(fp), encoding: .utf8) else { throw SyncError("不是文本，不能合并") }
            return s
        }
        var texts: [String: String] = [:]
        for (machine, fp) in values {
            guard let t = try text(fp) else { throw SyncError("有一边没有这个文件，不需要合并") }
            texts[machine] = t
        }
        return MergeSource(base: try text(base), texts: texts)
    }

    // MARK: 内部

    private func scanAll(refs: inout Set<String>) throws -> [String: ItemState] {
        var out = try files.scanAll(refs: &refs)
        out.merge(try handlers.scanAll(refs: &refs)) { a, _ in a }
        out.merge(try agents.scanAll(refs: &refs)) { a, _ in a }
        return out.filter { !shared.isIgnored($0.key) }
    }

    private func scan(_ id: String, refs: inout Set<String>) async throws -> ItemState {
        switch ItemKind(id: id) {
        case .handler: return try handlers.scan(ext: itemKey(id), refs: &refs)
        case .agent: return try agents.scan(label: itemKey(id), refs: &refs)
        default: return try files.scan(id, refs: &refs)
        }
    }

    /// 下载所需内容 → 写入（带备份）→ 重新读本机校验
    private func applyChecked(_ id: String, value: String, mode: Int?, backup: Backup) async throws {
        try download(value, for: id)
        switch ItemKind(id: id) {
        case .handler: try await handlers.apply(ext: itemKey(id), value: value)
        case .agent: try agents.apply(label: itemKey(id), value: value, backup: backup)
        default: try files.apply(id, value: value, mode: mode, backup: backup)
        }
        var refs = Set<String>()
        let after = try await scan(id, refs: &refs)
        guard after.fpOrAbsent == value else { throw SyncError("写入后校验不一致：\(title(of: id))") }
    }

    private func download(_ value: String, for id: String) throws {
        guard value != absentFP else { return }
        try relay.downloadBlobs([value], into: blobs)
        if ItemKind(id: id) == .dir {
            try relay.downloadBlobs(try files.members(ofManifest: value), into: blobs)
        }
    }

    /// 执行发给本机的待办；前置条件不满足的作废，回到待同步
    private func applyIncoming(_ decisions: [Decision]) async -> [String] {
        var messages: [String] = []
        var receipts: [(String, Data)] = []
        var done: [String] = []
        let backup = Backup(session: Backup.newSession())
        for decision in decisions.sorted(by: { $0.decidedAt < $1.decidedAt }) {
            let from = config.label(decision.decidedOn)
            let name = title(of: decision.item)
            var result = "applied"
            var message = ""
            do {
                var refs = Set<String>()
                let current = try await scan(decision.item, refs: &refs)
                if current.fpOrAbsent != decision.expect {
                    result = "stale"
                    message = "\(name)：拍板后本机又改过，没有覆盖，回到待同步"
                } else {
                    try await applyChecked(decision.item, value: decision.value, mode: decision.mode, backup: backup)
                    try writeBase([decision.item: decision.value])
                    message = "已按\(from)的决定更新 \(name)"
                }
            } catch {
                result = "failed"
                message = "\(name) 没能更新：\(error.localizedDescription)"
            }
            messages.append(message)
            let receipt = Receipt(decision: decision.id, item: decision.item, result: result,
                                  message: message, machine: me, at: Date())
            if let data = try? JSON.line(receipt) { receipts.append(("receipts/\(decision.id).json", data)) }
            done.append("decisions/\(me)/\(decision.id).json")
        }
        do {
            try relay.put(receipts)
            try relay.remove(done)
        } catch {
            messages.append("回执没写到中转站：\(error.localizedDescription)")
        }
        return messages
    }

    private func writeBase(_ entries: [String: String]) throws {
        let files = try entries.map { item, fp in
            ("base/\(Hash.hex(Data(item.utf8))).json", try JSON.line(BaseEntry(item: item, fp: fp)))
        }
        try relay.put(files)
        for (item, fp) in entries { lastBase[item] = fp }
    }

    /// `status` 为 nil：对面还没按现在的清单扫过这一项；`same` 为 true：两台一致，只用来展示
    private func makeRow(id: String, status: DiffStatus?, local: ItemState?, peer peerState: ItemState?, same: Bool = false) -> Row {
        let rowStatus: RowStatus
        let suggested: String?
        if same {
            rowStatus = .same; suggested = nil
        } else {
            switch status {
            case nil: rowStatus = .peerOutdated; suggested = nil
            case .onlyLocal: rowStatus = .onlyChanged(me); suggested = me
            case .onlyPeer: rowStatus = .onlyChanged(peer); suggested = peer
            case .conflict: rowStatus = .conflict; suggested = nil
            case .firstTime: rowStatus = .firstTime; suggested = nil
            case .waitingPeer: rowStatus = .waiting; suggested = nil
            }
        }
        var states: [String: ItemState] = [:]
        states[me] = local ?? .absent
        states[peer] = peerState ?? .absent
        let kind = ItemKind(id: id) ?? .file
        let (group, name) = placement(of: id)
        let secret = kind == .file && shared.isSecret(itemKey(id))
        let mergeable = kind == .file && !secret && local?.fp != nil && peerState?.fp != nil
            && local?.summary.hasSuffix(" 行") == true && peerState?.summary.hasSuffix(" 行") == true
        return Row(id: id, kind: kind, group: group, name: name, title: title(of: id),
                   status: rowStatus, states: states, suggested: suggested, secret: secret, mergeable: mergeable)
    }

    /// 分组与组内名字：受管目录下的归到该目录，其余文件按所在目录分组
    private func placement(of id: String) -> (String, String) {
        let key = itemKey(id)
        switch ItemKind(id: id) {
        case .handler: return ("默认打开方式", "." + key)
        case .agent: return ("启动项（~/Library/LaunchAgents）", key)
        default: break
        }
        if let spec = shared.dirs.first(where: { key.hasPrefix($0.path + "/") }) {
            return (spec.path, String(key.dropFirst(spec.path.count + 1)))
        }
        guard let slash = key.lastIndex(of: "/") else { return ("文件", key) }
        return (String(key[..<slash]), String(key[key.index(after: slash)...]))
    }

    private func title(of id: String) -> String {
        switch ItemKind(id: id) {
        case .handler: return "." + itemKey(id)
        default: return itemKey(id)
        }
    }
}
