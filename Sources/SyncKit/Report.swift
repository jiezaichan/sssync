import Foundation

/// 一个安装在本机的 App
public struct AppInfo: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case appStore, brew, manual
    }

    public var bundleID: String
    public var name: String
    public var version: String
    public var source: Source
    /// brew cask 名
    public var cask: String?
    /// App Store 的数字 id
    public var storeID: String?
    public var path: String
}

public struct NodeReport: Codable, Sendable, Equatable {
    public var nvm: String?
    /// 装了的 node 版本，如 `22.23.3`
    public var versions: [String]
    public var defaultVersion: String?
    /// 全局包名 → node 版本 → 包版本
    public var globals: [String: [String: String]]
}

/// 每台发布状态时顺带上传的环境与应用报告（只读，不参与拍板）
public struct MachineReport: Codable, Sendable {
    public var collectedAt: Date
    public var macOS: String
    /// 命令 → 版本（第一行输出）；没装的不出现
    public var tools: [String: String]
    public var node: NodeReport?
    /// uv 管理的 Python 版本
    public var pythons: [String]
    /// uv tool → 版本
    public var uvTools: [String: String]
    /// brew 主动装的命令行工具（`brew leaves`）→ 版本
    public var formulae: [String: String]
    public var casks: [String: String]
    /// 登录 shell 生效后的环境变量（密钥已打码，不含 PATH）
    public var env: [String: String]
    public var path: [String]
    public var apps: [AppInfo]
    /// 采集时遇到的问题
    public var errors: [String]
}

/// 采集本机报告：一次 `zsh -lic` 拿到 shell 能看到的一切，其余直接读文件
enum ReportCollector {
    /// 名字 → 取版本的命令
    static let tools: [(String, String)] = [
        ("node", "node --version"), ("npm", "npm --version"), ("pnpm", "pnpm --version"), ("yarn", "yarn --version"),
        ("bun", "bun --version"), ("deno", "deno --version"), ("python3", "python3 --version"), ("uv", "uv --version"),
        ("go", "go version"), ("java", "java -version"), ("rustc", "rustc --version"), ("swift", "swift --version"),
        ("git", "git --version"), ("brew", "brew --version"), ("gh", "gh --version"), ("ruby", "ruby --version"),
        ("claude", "claude --version"), ("codex", "codex --version"), ("grok", "grok --version"),
    ]

    /// 每次打开 shell 都会变、或只是终端自己的变量，比较它们没有意义
    static let noisyEnv: [String] = [
        "PWD", "OLDPWD", "SHLVL", "_", "TERM", "TERM_*", "COLORTERM", "COLORFGBG", "SECURITYSESSIONID", "TMPDIR",
        "LaunchInstanceID", "XPC_*", "__CF*", "__CFBundleIdentifier", "STARSHIP_SESSION_KEY", "KAKU_SESSION",
        "KAKU_UNIX_SOCKET", "WEZTERM_*", "SSH_AUTH_SOCK", "COMMAND_MODE", "OSLogRateLimit", "NVM_BIN", "NVM_INC",
        "HOME", "USER", "LOGNAME", "SHELL", "LANG", "PATH", "ITERM_*", "LC_TERMINAL*", "CLAUDE*", "AI_AGENT",
    ]

    static let secretEnv = ["*KEY*", "*TOKEN*", "*SECRET*", "*PASSWORD*", "*PASSWD*", "*_PASS", "*AUTH*", "*COOKIE*"]

    static func collect(shared: SharedConfig) -> MachineReport {
        var errors: [String] = []
        var sections: [String: [String]] = [:]
        do {
            sections = parseSections(try Shell.zsh(script, timeout: 120))
        } catch {
            errors.append("登录 shell 没跑通：\(error.localizedDescription)")
        }

        var env: [String: String] = [:]
        var path: [String] = []
        for line in sections["ENV"] ?? [] {
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            let name = String(line[..<eq])
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            let value = String(line[line.index(after: eq)...])
            if name == "PATH" { path = value.split(separator: ":").map(String.init); continue }
            if Glob.matchAny(noisyEnv, name) { continue }
            env[name] = Glob.matchAny(secretEnv, name.uppercased()) ? Secrets.masked(value) : value
        }

        var tools: [String: String] = [:]
        for line in sections["TOOLS"] ?? [] {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 { tools[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces) }
        }

        let casks = versions(sections["CASKS"] ?? [])
        let allFormulae = versions(sections["FORMULAE"] ?? [])
        var formulae: [String: String] = [:]
        for name in sections["LEAVES"] ?? [] where !name.isEmpty {
            // tap 里的公式 leaves 带前缀（user/tap/name），list 里不带
            let short = name.split(separator: "/").last.map(String.init) ?? name
            formulae[name] = allFormulae[short] ?? ""
        }

        return MachineReport(
            collectedAt: Date(),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            tools: tools,
            node: node(env: sections, nvmDir: env["NVM_DIR"]),
            pythons: pythons(sections["UVPY"] ?? []),
            uvTools: uvTools(sections["UVTOOLS"] ?? []),
            formulae: formulae,
            casks: casks,
            env: env,
            path: path,
            apps: apps(caskApps: caskApps((sections["CASKAPPS"] ?? []).joined(separator: "\n")), shared: shared),
            errors: errors
        )
    }

    private static var script: String {
        var lines = ["print -r -- '@@ENV'; env"]
        lines.append("print -r -- '@@NVM'; nvm --version 2>/dev/null")
        lines.append("print -r -- '@@NVMDEFAULT'; nvm version default 2>/dev/null")
        lines.append("print -r -- '@@TOOLS'")
        for (name, command) in tools {
            lines.append("command -v \(name) >/dev/null 2>&1 && print -r -- \"\(name)\t$(\(command) 2>&1 </dev/null | head -1)\"")
        }
        lines += [
            "print -r -- '@@UVPY'; uv python list --only-installed --managed-python 2>/dev/null",
            "print -r -- '@@UVTOOLS'; uv tool list 2>/dev/null",
            "print -r -- '@@LEAVES'; brew leaves 2>/dev/null",
            "print -r -- '@@FORMULAE'; brew list --formula --versions 2>/dev/null",
            "print -r -- '@@CASKS'; brew list --cask --versions 2>/dev/null",
            "print -r -- '@@CASKAPPS'; brew info --json=v2 --installed --cask 2>/dev/null",
            "print -r -- '@@END'",
        ]
        return lines.joined(separator: "\n")
    }

    /// `@@名字` 分节；第一个标记之前的输出（zshrc 打印的欢迎语之类）丢掉
    static func parseSections(_ output: String) -> [String: [String]] {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                current = String(line.dropFirst(2))
                sections[current!] = []
                continue
            }
            if let current { sections[current, default: []].append(String(line)) }
        }
        return sections
    }

    /// `name 1.2 1.3` → name: 1.3
    private static func versions(_ lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: " ")
            guard let name = parts.first else { continue }
            out[String(name)] = parts.dropFirst().last.map(String.init) ?? ""
        }
        return out
    }

    private static func node(env sections: [String: [String]], nvmDir: String?) -> NodeReport? {
        let dir = URL(filePath: nvmDir ?? (NSHomeDirectory() + "/.nvm")).appending(path: "versions/node")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) else { return nil }
        let versions = entries.filter { $0.hasPrefix("v") }.map { String($0.dropFirst()) }.sorted(by: versionLess)
        var globals: [String: [String: String]] = [:]
        for version in versions {
            let modules = dir.appending(path: "v\(version)/lib/node_modules")
            for (name, packageVersion) in packages(in: modules) where name != "npm" && name != "corepack" {
                globals[name, default: [:]][version] = packageVersion
            }
        }
        let first = { (key: String) in sections[key]?.first { !$0.isEmpty }?.trimmingCharacters(in: .whitespaces) }
        var defaultVersion = first("NVMDEFAULT")
        if defaultVersion?.hasPrefix("v") == true { defaultVersion = String(defaultVersion!.dropFirst()) }
        if defaultVersion == "N/A" { defaultVersion = nil }
        return NodeReport(nvm: first("NVM"), versions: versions, defaultVersion: defaultVersion, globals: globals)
    }

    /// node_modules 下的包（含 @scope/包）→ 版本
    private static func packages(in modules: URL) -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        func read(_ name: String, _ url: URL) {
            guard let data = try? Data(contentsOf: url.appending(path: "package.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            out[name] = json["version"] as? String ?? ""
        }
        for name in (try? fm.contentsOfDirectory(atPath: modules.path(percentEncoded: false))) ?? [] where !name.hasPrefix(".") {
            let url = modules.appending(path: name)
            if name.hasPrefix("@") {
                for sub in (try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? [] where !sub.hasPrefix(".") {
                    read("\(name)/\(sub)", url.appending(path: sub))
                }
            } else {
                read(name, url)
            }
        }
        return out
    }

    /// `cpython-3.12.11-macos-aarch64-none  路径` → 3.12.11
    private static func pythons(_ lines: [String]) -> [String] {
        var out = Set<String>()
        for line in lines {
            guard let first = line.split(separator: " ").first else { continue }
            let parts = first.split(separator: "-")
            if parts.count >= 2 { out.insert(parts[0] == "cpython" ? String(parts[1]) : "\(parts[0])-\(parts[1])") }
        }
        return out.sorted(by: versionLess)
    }

    /// `name v1.2.3` 一行一个工具，下面 `- 命令` 的行跳过
    private static func uvTools(_ lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines where !line.hasPrefix("-") && !line.hasPrefix("warning") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { continue }
            out[String(parts[0])] = parts[1].hasPrefix("v") ? String(parts[1].dropFirst()) : String(parts[1])
        }
        return out
    }

    /// brew cask 装出来的 .app 文件名 → cask 名
    private static func caskApps(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                for app in artifact["app"] as? [Any] ?? [] {
                    if let name = app as? String { out[name] = token }
                }
            }
        }
        return out
    }

    static func apps(caskApps: [String: String], shared: SharedConfig) -> [AppInfo] {
        let fm = FileManager.default
        var bundles: [URL] = []
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let rootURL = URL(filePath: root, directoryHint: .isDirectory)
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") {
                let url = rootURL.appending(path: name)
                if name.hasSuffix(".app") {
                    bundles.append(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // 再往下一层，如 /Applications/Utilities、厂商文件夹
                    for sub in (try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? [] where sub.hasSuffix(".app") {
                        bundles.append(url.appending(path: sub))
                    }
                }
            }
        }
        var seen = Set<String>()
        var out: [AppInfo] = []
        for url in bundles {
            // 直接读 Info.plist：Bundle(url:) 在进程里按路径缓存，App 升级后还是旧版本号，常驻时就一直报旧的
            guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let id = info["CFBundleIdentifier"] as? String, !id.hasPrefix("com.apple.") else { continue }
            let canonical = shared.canonicalApp(id)
            guard seen.insert(canonical).inserted else { continue }
            let fileName = url.lastPathComponent
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? ""
            var app = AppInfo(bundleID: canonical, name: name, version: version, source: .manual, path: url.path(percentEncoded: false))
            if fm.fileExists(atPath: url.appending(path: "Contents/_MASReceipt").path(percentEncoded: false)) {
                app.source = .appStore
                app.storeID = storeID(url)
            } else if let cask = caskApps[fileName] {
                app.source = .brew
                app.cask = cask
            }
            out.append(app)
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func storeID(_ url: URL) -> String? {
        let raw = try? Shell.run("/usr/bin/mdls", ["-raw", "-name", "kMDItemAppStoreAdamID", url.path(percentEncoded: false)], timeout: 10)
        guard let raw, !raw.isEmpty, raw != "(null)" else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `1.10.2` 按数字比较
func versionLess(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: .numeric) == .orderedAscending
}
