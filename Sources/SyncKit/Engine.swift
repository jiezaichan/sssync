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
    private var prefs: PrefProvider { PrefProvider(config: shared, blobs: blobs) }
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
        // 环境报告要跑登录 shell，几秒钟，和文件扫描并行
        let reportTask = Task.detached { [shared] in ReportCollector.collect(shared: shared) }
        if !meta.mine.isEmpty {
            messages += await applyIncoming(meta.mine)
            meta = try relay.fetchMeta(me: me, peer: peer)
        }

        var refs = Set<String>()
        let local = try scanAll(refs: &refs)
        try relay.uploadBlobs(refs, from: blobs)
        let report = await reportTask.value
        let now = Date()
        let unreadable = prefs.blockedContainers().map(\.domain)
        try relay.put([("machines/\(me)/state.json", try JSON.encode(StateDoc(machine: me, publishedAt: now, items: local,
                                                                              report: report, unreadable: unreadable)))])
        lastLocal = local
        lastPeer = meta.peer
        lastBase = meta.base
        lastReport = report

        var rows: [Row] = []
        var blockedApps: [String: [String]] = [:]
        if !unreadable.isEmpty { blockedApps[me] = unreadable.map(AppNames.name(of:)) }
        if let peerDoc = meta.peer {
            // 任一台读不到的 App：它的设置值未知，整个不参与对比，免得把「读不到」当成「没有」
            let blind = Set(unreadable + (peerDoc.unreadable ?? []))
            if let peerBlocked = peerDoc.unreadable, !peerBlocked.isEmpty { blockedApps[peer] = peerBlocked.map(AppNames.name(of:)) }
            let peerItems = peerDoc.items.filter { !shared.isIgnored($0.key) && Self.visible($0.key, blind: blind) }
            let local = local.filter { Self.visible($0.key, blind: blind) }
            let result = Reconciler.reconcile(local: local, peer: peerItems, base: meta.base,
                                              pending: Set(meta.theirs.map(\.item)))
            try writeBase(result.converged)
            rows = result.diffs.map { id, status in
                makeRow(id: id, status: status, local: local[id], peer: peerItems[id])
            }.sorted { ($0.group, $0.name) < ($1.group, $1.name) }
        }

        var publishedAt = [me: now]
        publishedAt[peer] = meta.peer?.publishedAt
        var reports = [me: report]
        reports[peer] = meta.peer?.report
        return Snapshot(me: me, peer: peer,
                        machines: config.machines,
                        rows: rows, publishedAt: publishedAt, messages: messages,
                        peerMissing: meta.peer == nil,
                        reports: reports, shared: shared, blockedApps: blockedApps)
    }

    /// 偏好条目所在的域有一台读不到时不显示
    private static func visible(_ id: String, blind: Set<String>) -> Bool {
        guard ItemKind(id: id) == .pref, let (domain, _) = PrefProvider.parse(id) else { return true }
        return !blind.contains(domain)
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

    /// 改同步清单：两台共用，传到中转站
    public func updateShared(_ new: SharedConfig) throws {
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
        out.merge(try prefs.scanAll(refs: &refs)) { a, _ in a }
        out.merge(try agents.scanAll(refs: &refs)) { a, _ in a }
        return out.filter { !shared.isIgnored($0.key) }
    }

    private func scan(_ id: String, refs: inout Set<String>) async throws -> ItemState {
        switch ItemKind(id: id) {
        case .handler: return try handlers.scan(ext: itemKey(id), refs: &refs)
        case .pref: return try prefs.scan(id, refs: &refs)
        case .agent: return try agents.scan(label: itemKey(id), refs: &refs)
        default: return try files.scan(id, refs: &refs)
        }
    }

    /// 下载所需内容 → 写入（带备份）→ 重新读本机校验
    private func applyChecked(_ id: String, value: String, mode: Int?, backup: Backup) async throws {
        try download(value, for: id)
        switch ItemKind(id: id) {
        case .handler: try await handlers.apply(ext: itemKey(id), value: value)
        case .pref: try prefs.apply(id, value: value, backup: backup)
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

    private func makeRow(id: String, status: DiffStatus, local: ItemState?, peer peerState: ItemState?) -> Row {
        let rowStatus: RowStatus
        let suggested: String?
        switch status {
        case .onlyLocal: rowStatus = .onlyChanged(me); suggested = me
        case .onlyPeer: rowStatus = .onlyChanged(peer); suggested = peer
        case .conflict: rowStatus = .conflict; suggested = nil
        case .firstTime: rowStatus = .firstTime; suggested = nil
        case .waitingPeer: rowStatus = .waiting; suggested = nil
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
        case .pref:
            guard let (domain, prefKey) = PrefProvider.parse(id) else { return ("App 设置", key) }
            return ("App 设置 · \(AppNames.name(of: domain))", prefKey)
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
        case .pref:
            guard let (domain, key) = PrefProvider.parse(id) else { return itemKey(id) }
            return "\(AppNames.name(of: domain)) · \(key)"
        default: return itemKey(id)
        }
    }
}
