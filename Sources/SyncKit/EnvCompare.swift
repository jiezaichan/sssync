import Foundation

/// 把缺的东西在某台上补齐的办法；只会在那台自己身上执行
public enum Fix: Sendable, Hashable {
    /// 在登录 shell 里跑的命令
    case run(String)
    /// 打开的链接（如 App Store）
    case open(String)
    /// 把 App 移到废纸篓（不是 brew 装的 App 用这个卸载，能从废纸篓找回）
    case trash(path: String, bundleID: String)

    public var text: String {
        switch self {
        case .run(let command): return command
        case .open(let url): return url
        case .trash(let path, _): return "移到废纸篓：\(path)"
        }
    }
}

public struct EnvRow: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// 机器 → 显示的值；没有这个键表示那台没有
    public let values: [String: String]
    public let same: Bool
    public let note: String?
    /// 机器 → 在那台上补齐的办法
    public let fixes: [String: Fix]
    /// 机器 → 在那台上卸载的办法；只给「这台有、另一台没有」的
    public var removals: [String: Fix] = [:]
    /// 在某一台的 `local.zsh` 里声明过：故意不同，不算待处理
    public var localOnly: Bool = false

    /// 确认差异用的 id 和签名；值里带版本号，升级后会重新出现
    public var ackID: String { "report:" + id }
    public var signature: String { SharedConfig.signature(values) }
}

public struct EnvSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let rows: [EnvRow]
    public let footer: String?

    public init(id: String, title: String, systemImage: String, rows: [EnvRow], footer: String?) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.rows = rows
        self.footer = footer
    }

    public var differing: Int { rows.filter { !$0.same && !$0.localOnly }.count }
}

/// 两台报告逐项对齐。补齐的命令只给缺的那台，卸载只给多出来的那台，都只在那台自己身上执行
public enum EnvCompare {
    public static func environment(_ reports: [String: MachineReport], machines: [String]) -> [EnvSection] {
        guard machines.allSatisfy({ reports[$0] != nil }) else { return [] }
        var sections: [EnvSection] = []

        // Node
        var nodeRows: [EnvRow] = []
        let nodes = machines.reduce(into: [String: NodeReport]()) { $0[$1] = reports[$1]?.node }
        nodeRows.append(row("nvm", "nvm", machines) { nodes[$0]?.nvm })
        nodeRows.append(row("node-default", "默认 node", machines, fix: { m in
            otherValue(m, machines) { nodes[$0]?.defaultVersion }.map { .run("nvm install \($0) && nvm alias default \($0)") }
        }) { nodes[$0]?.defaultVersion })
        let versions = Set(machines.flatMap { nodes[$0]?.versions ?? [] }).sorted(by: versionLess)
        for v in versions {
            // 默认版本不能卸
            nodeRows.append(row("node-\(v)", "node \(v)", machines, fix: { _ in .run("nvm install \(v)") },
                                remove: { nodes[$0]?.defaultVersion == v ? nil : .run("nvm uninstall \(v)") }) {
                nodes[$0]?.versions.contains(v) == true ? "已装" : nil
            })
        }
        sections.append(EnvSection(id: "node", title: "Node（nvm）", systemImage: "hexagon", rows: nodeRows,
                                   footer: "默认版本不能在这里卸载，先换默认版本"))

        // 全局 npm 包：按包对账，不按装在哪个 node 版本下
        var packageRows: [EnvRow] = []
        let packages = Set(machines.flatMap { nodes[$0]?.globals.keys.map { $0 } ?? [] }).sorted()
        for name in packages {
            var values: [String: String] = [:]
            var bare: [String: Set<String>] = [:]
            var locations: [String: Set<String>] = [:]
            for m in machines {
                guard let byNode = nodes[m]?.globals[name], !byNode.isEmpty else { continue }
                bare[m] = Set(byNode.values)
                locations[m] = Set(byNode.keys)
                values[m] = byNode.sorted { versionLess($0.key, $1.key) }.map { "\($0.value)（node \($0.key)）" }.joined(separator: "、")
            }
            let same = machines.allSatisfy { bare[$0] != nil } && Set(machines.map { bare[$0]! }).count == 1
            let note = same && Set(machines.map { locations[$0]! }).count > 1 ? "版本一样，但装在不同的 node 版本下" : nil
            let newest = machines.compactMap { bare[$0] }.flatMap { $0 }.max(by: versionLess) ?? ""
            var packageRow = EnvRow(id: "npm-\(name)", name: name, values: values, same: same, note: note,
                                    fixes: fixes(machines) { m in
                                        bare[m]?.contains(newest) == true ? nil
                                            : .run("nvm use default >/dev/null && npm install -g \(name)@\(newest)")
                                    })
            // 装在几个 node 版本下就从几个下面卸
            packageRow.removals = removals(machines, values) { m in
                .run((locations[m] ?? []).sorted(by: versionLess)
                    .map { "nvm use \($0) >/dev/null && npm uninstall -g \(name)" }.joined(separator: " && "))
            }
            packageRows.append(packageRow)
        }
        sections.append(EnvSection(id: "npm", title: "全局 npm 包", systemImage: "shippingbox", rows: packageRows,
                                   footer: "补齐时装到那台的默认 node 下"))

        // Python
        var pyRows: [EnvRow] = []
        let pythons = Set(machines.flatMap { reports[$0]?.pythons ?? [] }).sorted(by: versionLess)
        for v in pythons {
            pyRows.append(row("py-\(v)", "Python \(v)", machines, fix: { _ in .run("uv python install \(v)") },
                              remove: { _ in .run("uv python uninstall \(v)") }) {
                reports[$0]?.pythons.contains(v) == true ? "已装" : nil
            })
        }
        let uvTools = Set(machines.flatMap { reports[$0]?.uvTools.keys.map { $0 } ?? [] }).sorted()
        for name in uvTools {
            pyRows.append(row("uvtool-\(name)", "uv tool · \(name)", machines, fix: { _ in .run("uv tool install \(name)") },
                              remove: { _ in .run("uv tool uninstall \(name)") }) {
                reports[$0]?.uvTools[name]
            })
        }
        sections.append(EnvSection(id: "python", title: "Python（uv）", systemImage: "chevron.left.forwardslash.chevron.right",
                                   rows: pyRows, footer: nil))

        // brew 命令行工具
        let formulae = Set(machines.flatMap { reports[$0]?.formulae.keys.map { $0 } ?? [] }).sorted()
        sections.append(EnvSection(id: "brew", title: "Homebrew 命令行工具", systemImage: "mug", rows: formulae.map { name in
            versioned("brew-\(name)", name, machines, values: { reports[$0]?.formulae[name] },
                      install: "brew install \(name)", upgrade: "brew upgrade \(name)", uninstall: "brew uninstall \(name)")
        }, footer: "只列主动装的（brew leaves），依赖不算"))

        // 命令版本
        let tools = ReportCollector.tools.map(\.0).filter { t in machines.contains { reports[$0]?.tools[t] != nil } }
        sections.append(EnvSection(id: "tools", title: "命令版本", systemImage: "terminal", rows: tools.map { t in
            row("tool-\(t)", t, machines) { reports[$0]?.tools[t] }
        } + [row("macos", "macOS", machines) { reports[$0]?.macOS }], footer: nil))

        // 环境变量；local.zsh 里声明过的自动标成本机专属
        let names = Set(machines.flatMap { reports[$0]?.env.keys.map { $0 } ?? [] }).sorted()
        let localEnv = Set(machines.flatMap { reports[$0]?.localEnv ?? [] })
        sections.append(EnvSection(id: "env", title: "环境变量", systemImage: "dollarsign", rows: names.map { n in
            var row = row("env-\(n)", n, machines) { reports[$0]?.env[n] }
            row.localOnly = localEnv.contains(n)
            return row
        }, footer: "登录 shell（zsh -lic）生效后的值，密钥已打码。要改去改 ~/.config/zsh 里的文件；只属于一台的放 local.zsh，会自动标成本机专属"))

        // PATH：按第一台的顺序，再补另一台独有的
        var pathOrder: [String] = []
        for m in machines { for p in reports[m]?.path ?? [] where !pathOrder.contains(p) { pathOrder.append(p) } }
        sections.append(EnvSection(id: "path", title: "PATH", systemImage: "point.topleft.down.to.point.bottomright.curvepath", rows: pathOrder.map { p in
            row("path-\(p)", p, machines) { m in reports[m]?.path.firstIndex(of: p).map { "第 \($0 + 1) 项" } }
        }, footer: nil))

        let errors = machines.flatMap { m in (reports[m]?.errors ?? []).map { "\(m)：\($0)" } }
        if !errors.isEmpty {
            sections.insert(EnvSection(id: "errors", title: "采集时的问题", systemImage: "exclamationmark.triangle", rows: errors.enumerated().map {
                EnvRow(id: "err-\($0.offset)", name: $0.element, values: [:], same: false, note: nil, fixes: [:])
            }, footer: nil), at: 0)
        }
        return sections
    }

    public static func apps(_ reports: [String: MachineReport], machines: [String]) -> [EnvSection] {
        guard machines.allSatisfy({ reports[$0] != nil }) else { return [] }
        var byID: [String: [String: AppInfo]] = [:]
        for m in machines { for app in reports[m]?.apps ?? [] { byID[app.bundleID, default: [:]][m] = app } }
        let ids = byID.keys.sorted {
            let a = byID[$0]!.values.first!.name, b = byID[$1]!.values.first!.name
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        let rows = ids.map { id -> EnvRow in
            let apps = byID[id]!
            let any = apps.values.first!
            var values: [String: String] = [:]
            for (m, app) in apps { values[m] = app.version.isEmpty ? sourceName(app.source) : "\(app.version) · \(sourceName(app.source))" }
            let versions = machines.map { apps[$0]?.version }
            let same = versions.allSatisfy { $0 != nil } && Set(versions).count == 1
            let newest = apps.values.max { versionLess($0.version, $1.version) }!
            let fixes = fixes(machines) { m -> Fix? in
                if let mine = apps[m], !versionLess(mine.version, newest.version) { return nil }
                switch newest.source {
                case .brew: return newest.cask.map { .run(apps[m] == nil ? "brew install --cask \($0)" : "brew upgrade --cask \($0)") }
                case .appStore: return newest.storeID.map { .open("macappstore://apps.apple.com/app/id\($0)") }
                case .manual: return nil
                }
            }
            let note = apps.count < machines.count && newest.source == .manual ? "不是从 brew 或 App Store 装的，要自己下载" : nil
            var row = EnvRow(id: "app-\(id)", name: any.name, values: values, same: same, note: note, fixes: fixes)
            // brew 装的走 brew，其余移到废纸篓
            row.removals = removals(machines, values) { m in
                let app = apps[m]!
                if app.source == .brew, let cask = app.cask { return .run("brew uninstall --cask \(cask)") }
                return .trash(path: app.path, bundleID: app.bundleID)
            }
            return row
        }
        var sections = [EnvSection(id: "apps", title: "应用", systemImage: "square.grid.2x2", rows: rows,
                                   footer: "/Applications 和 ~/Applications 里的 App，系统自带的不算")]

        // 不对应 .app 的 cask（字体、命令行工具等）
        var extraCasks: [String: [String: String]] = [:]
        for m in machines {
            guard let r = reports[m] else { continue }
            let appCasks = Set(r.apps.compactMap(\.cask))
            for (cask, version) in r.casks where !appCasks.contains(cask) { extraCasks[cask, default: [:]][m] = version }
        }
        if !extraCasks.isEmpty {
            sections.append(EnvSection(id: "casks", title: "其它 brew cask", systemImage: "textformat", rows: extraCasks.keys.sorted().map { cask in
                versioned("cask-\(cask)", cask, machines, values: { extraCasks[cask]?[$0] },
                          install: "brew install --cask \(cask)", upgrade: "brew upgrade --cask \(cask)",
                          uninstall: "brew uninstall --cask \(cask)")
            }, footer: "字体之类没有 .app 的 cask"))
        }
        return sections
    }

    static func sourceName(_ source: AppInfo.Source) -> String {
        switch source {
        case .appStore: return "App Store"
        case .brew: return "brew"
        case .manual: return "手动安装"
        }
    }

    // MARK: 工具

    /// 普通一行：值相同才算一致；缺的那台给 fix
    private static func row(_ id: String, _ name: String, _ machines: [String],
                            fix: ((String) -> Fix?)? = nil, remove: ((String) -> Fix?)? = nil,
                            value: (String) -> String?) -> EnvRow {
        var values: [String: String] = [:]
        for m in machines { values[m] = value(m) }
        let same = values.count == machines.count && Set(values.values).count == 1
        let fixes = same || fix == nil ? [:] : self.fixes(machines) { m in values[m] == nil || id == "node-default" ? fix!(m) : nil }
        var row = EnvRow(id: id, name: name, values: values, same: same, note: nil, fixes: fixes)
        if let remove { row.removals = removals(machines, values, remove) }
        return row
    }

    /// 带版本的一行：没装的给安装命令，版本旧的给升级命令，只有一台有的给卸载命令
    private static func versioned(_ id: String, _ name: String, _ machines: [String],
                                  values value: (String) -> String?, install: String, upgrade: String,
                                  uninstall: String) -> EnvRow {
        var values: [String: String] = [:]
        for m in machines { values[m] = value(m) }
        let same = values.count == machines.count && Set(values.values).count == 1
        let newest = values.values.max(by: versionLess) ?? ""
        let fixes = same ? [:] : self.fixes(machines) { m -> Fix? in
            guard let mine = values[m] else { return .run(install) }
            return versionLess(mine, newest) ? .run(upgrade) : nil
        }
        var row = EnvRow(id: id, name: name, values: values, same: same, note: nil, fixes: fixes)
        row.removals = removals(machines, values) { _ in .run(uninstall) }
        return row
    }

    /// 只有一台有的时候，给有的那台卸载办法；两台都有不给（那是版本差异，不是多装了）
    private static func removals(_ machines: [String], _ values: [String: String], _ make: (String) -> Fix?) -> [String: Fix] {
        guard values.count < machines.count else { return [:] }
        return fixes(machines) { values[$0] == nil ? nil : make($0) }
    }

    private static func fixes(_ machines: [String], _ make: (String) -> Fix?) -> [String: Fix] {
        var out: [String: Fix] = [:]
        for m in machines { out[m] = make(m) }
        return out
    }

    private static func otherValue(_ machine: String, _ machines: [String], _ value: (String) -> String?) -> String? {
        machines.first { $0 != machine }.flatMap(value)
    }
}
