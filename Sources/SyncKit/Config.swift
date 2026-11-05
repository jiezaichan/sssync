import Foundation

public struct MachineInfo: Codable, Sendable, Equatable {
    /// `hw.model`，靠它认出本机
    public var model: String
    public var label: String
    public var emoji: String

    public init(model: String, label: String, emoji: String) {
        self.model = model
        self.label = label
        self.emoji = emoji
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        label = try c.decode(String.self, forKey: .label)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? ""
    }
}

/// 本机配置（`config.json`，不同步）：两台是谁、中转站在哪、常驻行为
public struct Config: Codable, Sendable {
    public var relayHost: String
    public var relayPath: String
    /// "home" / "work" → 机器信息，按 `hw.model` 认出本机
    public var machines: [String: MachineInfo]
    /// 常驻时多久自动刷新一次（分钟）
    public var refreshMinutes: Int
    /// 对面改了东西时发系统通知
    public var notify: Bool

    public static let standard = Config(
        relayHost: "new",
        relayPath: "sssync-relay",
        machines: [
            "home": MachineInfo(model: "Mac14,5", label: "家里", emoji: "🏠"),
            "work": MachineInfo(model: "Mac18,5", label: "公司", emoji: "🏢"),
        ],
        refreshMinutes: 15,
        notify: true
    )

    public init(relayHost: String, relayPath: String, machines: [String: MachineInfo], refreshMinutes: Int, notify: Bool) {
        self.relayHost = relayHost
        self.relayPath = relayPath
        self.machines = machines
        self.refreshMinutes = refreshMinutes
        self.notify = notify
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = Config.standard
        relayHost = try c.decodeIfPresent(String.self, forKey: .relayHost) ?? s.relayHost
        relayPath = try c.decodeIfPresent(String.self, forKey: .relayPath) ?? s.relayPath
        machines = try c.decodeIfPresent([String: MachineInfo].self, forKey: .machines) ?? s.machines
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? s.refreshMinutes
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? s.notify
    }

    /// 读 `~/Library/Application Support/sssync/config.json`，没有就写一份默认的
    public static func load() throws -> Config {
        if let data = try? Data(contentsOf: Paths.configFile) {
            var config = try JSON.decode(Config.self, data)
            // 旧配置没有 emoji、名字被清空：按机器 key 补默认的
            for (key, info) in config.machines {
                if info.emoji.isEmpty { config.machines[key]?.emoji = standard.machines[key]?.emoji ?? "💻" }
                if info.label.trimmingCharacters(in: .whitespaces).isEmpty {
                    config.machines[key]?.label = standard.machines[key]?.label ?? key
                }
            }
            return config
        }
        try standard.save()
        return standard
    }

    public func save() throws {
        try Paths.ensure(Paths.support)
        try JSON.encode(self, pretty: true).write(to: Paths.configFile, options: .atomic)
    }

    /// 本机的 `hw.model`
    public static var currentModel: String { Machine.model() }

    public func identify() throws -> (me: String, peer: String) {
        let model = Machine.model()
        guard let me = machines.keys.sorted().first(where: { machines[$0]?.model == model }) else {
            throw SyncError("还没指定这台电脑是哪一台（型号 \(model)），请在设置里选一下")
        }
        guard let peer = machines.keys.sorted().first(where: { $0 != me }) else {
            throw SyncError("config.json 里只配了一台机器")
        }
        return (me, peer)
    }

    public func label(_ machine: String) -> String {
        machines[machine]?.label ?? machine
    }

    /// 「🏠 家里」
    public func badge(_ machine: String) -> String {
        guard let info = machines[machine] else { return machine }
        return info.emoji.isEmpty ? info.label : "\(info.emoji) \(info.label)"
    }
}

// MARK: - 两台共用的同步清单

/// 一个受管目录：它的每个顶层子目录聚合成一个条目，顶层文件各自是一个条目
public struct DirSpec: Codable, Sendable, Equatable, Hashable {
    public var path: String
    /// 通配，按名字（任意层级）或相对受管目录的路径匹配
    public var ignore: [String]

    public init(path: String, ignore: [String]) {
        self.path = path
        self.ignore = ignore
    }
}

/// 一个 App 的偏好域，逐键同步
public struct PrefSpec: Codable, Sendable, Equatable, Hashable {
    /// 偏好域，一般就是 bundle id
    public var domain: String
    /// 沙盒 App：偏好在 `~/Library/Containers/<域>/Data/Library/Preferences/<域>.plist`
    public var container: Bool
    /// 只同步这些键；nil 表示全部（过滤噪音后）
    public var keys: [String]?
    /// 这个域额外忽略的键（通配）
    public var ignore: [String]

    public init(domain: String, container: Bool = false, keys: [String]? = nil, ignore: [String] = []) {
        self.domain = domain
        self.container = container
        self.keys = keys
        self.ignore = ignore
    }
}

/// 启动项模板里的一个变量：每台各有一个值
public struct TemplateVar: Codable, Sendable, Equatable, Hashable {
    public var name: String
    /// 机器 → 值
    public var values: [String: String]

    public init(name: String, values: [String: String]) {
        self.name = name
        self.values = values
    }
}

/// 管哪些东西。两台共用一份：存在中转站 `shared.json`，本机缓存一份，任一台改了另一台跟着变
public struct SharedConfig: Codable, Sendable, Equatable {
    public var files: [String]
    public var dirs: [DirSpec]
    /// 管理默认打开方式的文件扩展名
    public var handlers: [String]
    /// 视为同一个 App 的 bundle id 组，组内第一个是规范名
    public var equivalentApps: [[String]]
    public var prefs: [PrefSpec]
    /// 是否管理 `~/Library/LaunchAgents`
    public var launchAgents: Bool
    /// 启动项 label → 模板变量（同名不同参）
    public var templates: [String: [TemplateVar]]
    /// 含密钥的文件（通配，对路径）：对比时值打码
    public var secretFiles: [String]
    /// 自己补的噪音键（通配），所有 App 通用；内置规则见 `builtinNoiseKeys`
    public var noiseKeys: [String]

    /// 内置噪音键：窗口位置、最近打开、更新检查、版本号、统计……随代码更新，不存进清单
    public static let builtinNoiseKeys = [
        "NSWindow Frame *", "NSSplitView *", "NSToolbar *", "NSNavLastRootDirectory", "NSNavPanel*",
        "NSRecentDocuments*", "NSStatusItem *", "NSTableView *", "NSOutlineView *", "NSOSPLastRootDirectory",
        "NSOverlayScrollers*", "SU*", "*Sparkle*", "*LastLaunch*", "*Telemetry*", "*Analytics*", "*LastCheck*",
        "*lastCheck*", "*LaunchCount*", "*launchCount*", "*WindowFrame*", "*WindowState*", "*Version", "*version",
        "*Migrated*", "findMode*", "MSAppCenter*", "com.apple.*", "*FirstLaunch*", "*Onboarding*", "*DeviceID*",
        "*deviceId*", "*InstallDate*", "*LastUsed*", "*lastUsed*", "Bugsnag*", "*UserId", "*UserID", "*-id",
        "*session*", "*Session*", "*prompted*", "*review*", "*-dates", "*-date", "*Date",
    ]

    /// 内置 + 自己补的
    public func isNoiseKey(_ key: String) -> Bool {
        Glob.matchAny(Self.builtinNoiseKeys, key) || Glob.matchAny(noiseKeys, key)
    }

    /// 不再同步的条目 id（通配）：不管怎么变都不管
    public var ignored: [String]
    /// 确认过的差异：id → 确认时两边值的签名。只认那一刻的状态，任一边再变就重新出现
    public var acknowledged: [String: String]

    public func isAcknowledged(_ id: String, signature: String) -> Bool { acknowledged[id] == signature }

    /// 两边值 → 签名（与机器顺序无关）
    public static func signature(_ values: [String: String]) -> String {
        Hash.hex(Data(values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n").utf8))
    }

    public static let standard = SharedConfig(
        files: [
            "~/.claude/CLAUDE.md",
            "~/.claude/tech-approach-playbook.md",
            "~/.config/zed/settings.json",
            "~/.config/zed/keymap.json",
            "~/.config/kaku/kaku.lua",
            "~/.zshrc",
            "~/.zprofile",
            "~/.gitconfig",
        ],
        dirs: [
            DirSpec(path: "~/.claude/skills", ignore: [
                ".git", ".DS_Store", "node_modules", "__pycache__", ".venv", ".bsk.lock",
                "db-query/scripts/.env", "depu/.pane", "depu/.pane.nick",
            ]),
            // local.zsh 是本机专属的约定位置：共用的 zshrc 最后 source 它，永不同步
            DirSpec(path: "~/.config/zsh", ignore: [
                ".git", ".DS_Store", "local.zsh", "history.zsh", "*.zwc", ".zcompdump*",
            ]),
        ],
        handlers: ["json", "md", "yaml", "yml", "toml", "txt", "log", "csv", "xml", "js", "ts", "py", "sh", "swift"],
        equivalentApps: [["dev.zed.Zed", "dev.zed-i18n.Zed"]],
        prefs: [
            PrefSpec(domain: "im.manico.Manico", container: true),
            PrefSpec(domain: "com.googlecode.iterm2", ignore: ["NoSync*", "NeverWarnAbout*", "Window Arrangements"]),
        ],
        launchAgents: true,
        templates: [
            "com.jiezaichan.rtunnel-new": [
                TemplateVar(name: "key", values: [
                    "home": "/Users/jiezaichan/.ssh/id_ed25519_rtunnel_home",
                    "work": "/Users/jiezaichan/.ssh/id_ed25519_rtunnel",
                ]),
                TemplateVar(name: "port", values: ["home": "127.0.0.1:22023", "work": "127.0.0.1:22022"]),
            ],
        ],
        secretFiles: ["*/secrets.zsh", "*/.env", "*/.env.*"],
        noiseKeys: [],
        ignored: [
            "agent:com.google.*", "agent:com.citrolabs.*", "agent:com.topazlabs.*",
            "agent:com.microsoft.*", "agent:homebrew.*", "agent:io.github.clash-verge-rev.*",
        ]
    )

    public init(files: [String], dirs: [DirSpec], handlers: [String], equivalentApps: [[String]], prefs: [PrefSpec],
                launchAgents: Bool, templates: [String: [TemplateVar]], secretFiles: [String], noiseKeys: [String],
                ignored: [String], acknowledged: [String: String] = [:]) {
        self.acknowledged = acknowledged
        self.files = files
        self.dirs = dirs
        self.handlers = handlers
        self.equivalentApps = equivalentApps
        self.prefs = prefs
        self.launchAgents = launchAgents
        self.templates = templates
        self.secretFiles = secretFiles
        self.noiseKeys = noiseKeys
        self.ignored = ignored
    }

    /// 缺的字段按默认值补，以后加字段不会读坏旧文件
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = SharedConfig.standard
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? s.files
        dirs = try c.decodeIfPresent([DirSpec].self, forKey: .dirs) ?? s.dirs
        handlers = try c.decodeIfPresent([String].self, forKey: .handlers) ?? s.handlers
        equivalentApps = try c.decodeIfPresent([[String]].self, forKey: .equivalentApps) ?? s.equivalentApps
        prefs = try c.decodeIfPresent([PrefSpec].self, forKey: .prefs) ?? s.prefs
        launchAgents = try c.decodeIfPresent(Bool.self, forKey: .launchAgents) ?? s.launchAgents
        templates = try c.decodeIfPresent([String: [TemplateVar]].self, forKey: .templates) ?? s.templates
        secretFiles = try c.decodeIfPresent([String].self, forKey: .secretFiles) ?? s.secretFiles
        noiseKeys = try c.decodeIfPresent([String].self, forKey: .noiseKeys) ?? s.noiseKeys
        ignored = try c.decodeIfPresent([String].self, forKey: .ignored) ?? s.ignored
        acknowledged = try c.decodeIfPresent([String: String].self, forKey: .acknowledged) ?? [:]
    }

    /// 本机缓存；没有就用默认清单
    static func loadCached() -> SharedConfig {
        guard let data = try? Data(contentsOf: Paths.sharedFile),
              let shared = try? JSON.decode(SharedConfig.self, data) else { return .standard }
        return shared
    }

    func saveCache() throws {
        try Paths.ensure(Paths.support)
        try JSON.encode(self, pretty: true).write(to: Paths.sharedFile, options: .atomic)
    }

    public func isIgnored(_ id: String) -> Bool { Glob.matchAny(ignored, id) }

    public func isSecret(_ path: String) -> Bool { Glob.matchAny(secretFiles, path) }

    /// 把等价 App 归一成组内第一个 bundle id
    public func canonicalApp(_ bundleID: String) -> String {
        equivalentApps.first { $0.contains(bundleID) }?.first ?? bundleID
    }

    /// 与 bundleID 等价的全部 App，bundleID 本身排第一
    func equivalents(of bundleID: String) -> [String] {
        let group = equivalentApps.first { $0.contains(bundleID) } ?? [bundleID]
        return [bundleID] + group.filter { $0 != bundleID }
    }
}
