import Foundation

/// 录制：开始时给一个 App 的候选位置拍快照，去 App 里改个设置，停止时再拍一次，列出变了的文件和偏好键
public enum Recorder {
    public struct Snapshot: Sendable {
        /// 绝对路径 → 大小 + 修改时间
        var files: [String: String]
        /// 偏好域（含是否沙盒）→ 键 → 值指纹
        var prefs: [PrefSpec: [String: String]]
    }

    public struct Change: Identifiable, Sendable, Hashable {
        public enum Target: Sendable, Hashable {
            /// `~/` 开头的路径
            case file(String)
            case pref(PrefSpec, String)
        }

        public let target: Target
        /// 新增 / 改了 / 删了
        public let what: String
        /// 命中默认噪音规则，默认不勾
        public let noise: Bool

        public var id: String {
            switch target {
            case .file(let path): return "file:" + path
            case .pref(let spec, let key): return "pref:\(spec.domain)\(spec.container ? "(沙盒)" : "")#\(key)"
            }
        }

        public var title: String {
            switch target {
            case .file(let path): return path
            case .pref(_, let key): return key
            }
        }
    }

    static let noisePaths = [
        "*/Caches/*", "*/Cache/*", "*/cache/*", "*/Logs/*", "*/logs/*", "*.log", "*-wal", "*-shm", "*-journal",
        "*/Crashpad/*", "*/GPUCache/*", "*/Code Cache/*", "*/Service Worker/*", "*.lock", "*/Saved Application State/*",
        "*/IndexedDB/*", "*/Local Storage/*", "*/Session Storage/*", "*/blob_storage/*", "*/.DS_Store", "*/tmp/*",
        "*/WebKit/*", "*/HTTPStorages/*", "*/Cookies*", "*session*", "*history*", "*History*", "*/state.json",
    ]

    /// 由 bundle id 和 App 名推出来的候选位置
    static func candidates(bundleID: String, name: String) -> (prefs: [PrefSpec], dirs: [URL]) {
        let home = Paths.home
        let fm = FileManager.default
        var prefs = [PrefSpec(domain: bundleID)]
        let container = home.appending(path: "Library/Containers/\(bundleID)")
        if fm.fileExists(atPath: container.path(percentEncoded: false)) {
            prefs.append(PrefSpec(domain: bundleID, container: true))
        }
        let lower = name.lowercased().replacingOccurrences(of: " ", with: "")
        var dirs = [
            container.appending(path: "Data/Library/Application Support"),
            home.appending(path: "Library/Application Support/\(name)"),
            home.appending(path: "Library/Application Support/\(bundleID)"),
            home.appending(path: ".config/\(lower)"),
            home.appending(path: ".config/\(name)"),
            home.appending(path: ".\(lower)"),
        ]
        let groups = home.appending(path: "Library/Group Containers")
        let tail = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        for group in (try? fm.contentsOfDirectory(atPath: groups.path(percentEncoded: false))) ?? []
        where group.contains(bundleID) || group.localizedCaseInsensitiveContains(tail) {
            dirs.append(groups.appending(path: group))
        }
        var seen = Set<String>()
        dirs = dirs.filter { seen.insert($0.standardizedFileURL.path(percentEncoded: false).lowercased()).inserted }
        return (prefs, dirs.filter { fm.fileExists(atPath: $0.path(percentEncoded: false)) })
    }

    /// 给出将要盯住的位置，界面上显示
    public static func describeCandidates(bundleID: String, name: String) -> [String] {
        let (prefs, dirs) = candidates(bundleID: bundleID, name: name)
        return prefs.map { $0.container ? "偏好设置（沙盒）\($0.domain)" : "偏好设置 \($0.domain)" }
            + dirs.map { abbreviate($0.path(percentEncoded: false)) }
    }

    public static func snapshot(bundleID: String, name: String) -> Snapshot {
        let (prefSpecs, dirs) = candidates(bundleID: bundleID, name: name)
        var prefs: [PrefSpec: [String: String]] = [:]
        for spec in prefSpecs {
            var keys: [String: String] = [:]
            for (key, value) in PrefProvider.read(spec) {
                if let data = try? PrefProvider.encode(key, value) { keys[key] = Hash.hex(data) }
            }
            prefs[spec] = keys
        }
        var files: [String: String] = [:]
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for dir in dirs {
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: resourceKeys) else { continue }
            for case let url as URL in walker {
                if files.count > 50_000 { break }
                guard let v = try? url.resourceValues(forKeys: Set(resourceKeys)), v.isRegularFile == true else { continue }
                let stamp = v.contentModificationDate?.timeIntervalSince1970 ?? 0
                files[url.path(percentEncoded: false)] = "\(v.fileSize ?? 0)-\(stamp)"
            }
        }
        return Snapshot(files: files, prefs: prefs)
    }

    public static func changes(before: Snapshot, after: Snapshot, shared: SharedConfig) -> [Change] {
        var out: [Change] = []
        for spec in Set(before.prefs.keys).union(after.prefs.keys) {
            let a = before.prefs[spec] ?? [:], b = after.prefs[spec] ?? [:]
            for key in Set(a.keys).union(b.keys).sorted() where a[key] != b[key] {
                let what = a[key] == nil ? "新增" : b[key] == nil ? "删了" : "改了"
                out.append(Change(target: .pref(spec, key), what: what, noise: shared.isNoiseKey(key)))
            }
        }
        for path in Set(before.files.keys).union(after.files.keys).sorted() where before.files[path] != after.files[path] {
            let what = before.files[path] == nil ? "新增" : after.files[path] == nil ? "删了" : "改了"
            out.append(Change(target: .file(abbreviate(path)), what: what, noise: Glob.matchAny(noisePaths, path)))
        }
        return out.sorted { ($0.noise ? 1 : 0, $0.id) < ($1.noise ? 1 : 0, $1.id) }
    }

    /// 把勾选的变化写进同步清单
    public static func adopt(_ changes: [Change], into shared: inout SharedConfig) {
        for change in changes {
            switch change.target {
            case .file(let path):
                if !shared.files.contains(path) { shared.files.append(path) }
            case .pref(let spec, let key):
                if let i = shared.prefs.firstIndex(where: { $0.domain == spec.domain && $0.container == spec.container }) {
                    if var keys = shared.prefs[i].keys, !keys.contains(key) {
                        keys.append(key)
                        shared.prefs[i].keys = keys
                    }
                } else {
                    shared.prefs.append(PrefSpec(domain: spec.domain, container: spec.container, keys: [key]))
                }
            }
        }
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
