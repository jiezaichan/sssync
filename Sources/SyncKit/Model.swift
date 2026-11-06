import Foundation

/// 「不存在」在指纹位置上的写法
public let absentFP = "absent"

/// 一台机器上一个条目的现状；`fp == nil` 表示不存在
public struct ItemState: Codable, Sendable, Equatable {
    public var fp: String?
    public var summary: String
    public var mode: Int?

    public init(fp: String?, summary: String, mode: Int? = nil) {
        self.fp = fp
        self.summary = summary
        self.mode = mode
    }

    public static let absent = ItemState(fp: nil, summary: "不存在")

    public var fpOrAbsent: String { fp ?? absentFP }
}

/// 条目 id：`file:~/x`、`dir:~/x`、`handler:json`、`pref:<域>#<键>`、`agent:<label>`
public enum ItemKind: String, Sendable {
    case file, dir, handler, pref, agent

    init?(id: String) {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        self.init(rawValue: String(id[..<colon]))
    }
}

func itemKey(_ id: String) -> String {
    guard let colon = id.firstIndex(of: ":") else { return id }
    return String(id[id.index(after: colon)...])
}

/// 每台发布到中转站的状态
struct StateDoc: Codable, Sendable {
    var machine: String
    var publishedAt: Date
    var items: [String: ItemState]
    /// 环境与应用的只读报告；旧版本发布的状态里没有
    var report: MachineReport?
    /// 这台读不到的偏好域（沙盒被挡）：这些域的条目不知道值，不能当成「不存在」
    var unreadable: [String]?
    /// 扫描时用的规则；旧版本发布的状态里没有
    var scope: Scope?
}

/// 发给某台的待办：目标机器上当前值等于 expect 时，才把它写成 value。
/// `item` 以 `uninstall:` 开头的是「让那台卸载」：后面是 `EnvRow.id`，expect 是拍板时看到的那台的值，value 是显示名
struct Decision: Codable, Sendable {
    var id: String
    var item: String
    var expect: String
    var value: String
    var mode: Int?
    var decidedOn: String
    var decidedAt: Date
}

struct Receipt: Codable, Sendable {
    var decision: String
    var item: String
    var result: String
    var message: String
    var machine: String
    var at: Date
}

/// 基线：某条目上次两边一致时的指纹
struct BaseEntry: Codable, Sendable {
    var item: String
    var fp: String
}

/// 目录条目的值：相对路径 → 成员文件
struct DirMember: Codable, Sendable, Equatable {
    var fp: String
    var mode: Int?
}

// MARK: - 给界面的数据

/// 对比视图的数据来源；字典的 key 都是机器
public enum DiffSource: Sendable {
    /// 文本；值为 nil 表示那台没有
    case text([String: String?])
    /// 二进制，只比大小；值为 nil 表示那台没有
    case binary([String: Int?])
    /// 目录：相对路径 → 内容指纹
    case directory([String: [String: String]])
}

public enum RowStatus: Sendable, Equatable {
    case onlyChanged(String)   // 只有这台改了
    case conflict              // 两边都改了
    case firstTime             // 还没有基线
    case waiting               // 已拍板，等对面应用
    case peerOutdated          // 清单改过，对面还没按新清单扫描，它的值不可信
    case same                  // 两台一致；只用于要看全量的分类（默认打开方式）

    /// 现在没什么可拍板的，等对面
    public var isWaiting: Bool { self == .waiting || self == .peerOutdated }
}

public struct Row: Identifiable, Sendable {
    public let id: String
    public let kind: ItemKind
    /// 分组标题，如「~/.claude/skills」「默认打开方式」
    public let group: String
    /// 组内显示名，如「huashu-design」「.json」
    public let name: String
    public let title: String
    public let status: RowStatus
    /// 机器 → 状态（nil 表示那台没有这个条目的记录）
    public let states: [String: ItemState]
    /// 建议以哪台为准
    public let suggested: String?
    /// 含密钥，对比时打码、不能合并
    public let secret: Bool
    /// 两边都是文本文件，可以做三方合并
    public let mergeable: Bool

    /// 确认差异用：两边当前值的签名
    public var signature: String { SharedConfig.signature(states.mapValues(\.fpOrAbsent)) }
}

public struct Snapshot: Sendable {
    public let me: String
    public let peer: String
    public let machines: [String: MachineInfo]
    public let rows: [Row]
    public let publishedAt: [String: Date]
    public let messages: [String]
    public let peerMissing: Bool
    /// 机器 → 环境与应用报告
    public let reports: [String: MachineReport]
    public let shared: SharedConfig
    /// 机器 → 读不到的沙盒 App 名（需要在那台上给 sssync 开完全磁盘访问）
    public let blockedApps: [String: [String]]
    /// 已经让对面卸载、对面还没执行的环境 / 应用行（`EnvRow.id`）
    public var pendingRemovals: Set<String> = []

    public func label(_ machine: String) -> String { machines[machine]?.label ?? machine }
    public func emoji(_ machine: String) -> String { machines[machine]?.emoji ?? "" }
    /// 「🏠 家里」
    public func badge(_ machine: String) -> String {
        let e = emoji(machine)
        return e.isEmpty ? label(machine) : "\(e) \(label(machine))"
    }
}
