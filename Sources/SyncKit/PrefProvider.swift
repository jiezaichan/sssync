import AppKit
import Foundation

/// 偏好设置逐键条目（`pref:<域>#<键>`）。值是 `{键: 值}` 的 XML plist（键已排序，内容相同则指纹相同）。
struct PrefProvider: Sendable {
    let config: SharedConfig
    let blobs: BlobStore

    static func id(_ domain: String, _ key: String) -> String { "pref:\(domain)#\(key)" }

    /// `pref:域#键` → (域, 键)
    static func parse(_ id: String) -> (domain: String, key: String)? {
        let rest = itemKey(id)
        guard let hash = rest.firstIndex(of: "#") else { return nil }
        return (String(rest[..<hash]), String(rest[rest.index(after: hash)...]))
    }

    func scanAll(refs: inout Set<String>) throws -> [String: ItemState] {
        var out: [String: ItemState] = [:]
        let blocked = Set(blockedContainers().map(\.domain))
        for spec in config.prefs where !blocked.contains(spec.domain) {
            let values = read(spec)
            let keys = spec.keys ?? values.keys.filter { !isNoise($0, spec: spec) }
            for key in keys {
                out[Self.id(spec.domain, key)] = try state(values[key], key: key, refs: &refs)
            }
        }
        return out
    }

    func scan(_ id: String, refs: inout Set<String>) throws -> ItemState {
        guard let (domain, key) = Self.parse(id) else { throw SyncError("不是偏好设置条目：\(id)") }
        let spec = spec(for: domain)
        return try state(read(spec)[key], key: key, refs: &refs)
    }

    func apply(_ id: String, value: String, backup: Backup) throws {
        guard let (domain, key) = Self.parse(id) else { throw SyncError("不是偏好设置条目：\(id)") }
        let spec = spec(for: domain)
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: domain).first {
            throw SyncError("\(app.localizedName ?? domain) 正在运行，先退出它再同步（运行中写进去会被它自己写回旧值）")
        }
        try backup.save(Self.file(spec))
        var newValue: CFPropertyList?
        if value != absentFP {
            let data = try blobs.get(value)
            guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let v = dict[key] else { throw SyncError("偏好设置的内容坏了：\(key)") }
            newValue = v as CFPropertyList
        }
        let ref = Self.domainRef(spec)
        CFPreferencesSetValue(key as CFString, newValue, ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw SyncError("写 \(domain) 的偏好设置失败（可能需要在系统设置里允许 sssync 访问其他 App 的数据）")
        }
    }

    /// 装了但读不到的沙盒 App（App 数据保护挡住了，要给 sssync 开完全磁盘访问）
    func blockedContainers() -> [PrefSpec] {
        config.prefs.filter(\.container).filter { spec in
            let dir = Paths.home.appending(path: "Library/Containers/\(spec.domain)").path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: dir) else { return false }
            return (try? Data(contentsOf: Self.file(spec))) == nil
        }
    }

    // MARK: 读取

    func spec(for domain: String) -> PrefSpec {
        config.prefs.first { $0.domain == domain } ?? PrefSpec(domain: domain)
    }

    /// 沙盒 App 用 plist 的绝对路径当域名，否则就是 bundle id
    static func domainRef(_ spec: PrefSpec) -> CFString {
        spec.container ? file(spec).path(percentEncoded: false) as CFString : spec.domain as CFString
    }

    static func file(_ spec: PrefSpec) -> URL {
        spec.container
            ? Paths.home.appending(path: "Library/Containers/\(spec.domain)/Data/Library/Preferences/\(spec.domain).plist")
            : Paths.home.appending(path: "Library/Preferences/\(spec.domain).plist")
    }

    /// 读整个域；先同步一下，拿到 App 刚写的值而不是本进程的缓存
    static func read(_ spec: PrefSpec) -> [String: Any] {
        let ref = domainRef(spec)
        CFPreferencesSynchronize(ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyMultiple(nil, ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    private func read(_ spec: PrefSpec) -> [String: Any] { Self.read(spec) }

    func isNoise(_ key: String, spec: PrefSpec) -> Bool {
        config.isNoiseKey(key) || Glob.matchAny(spec.ignore, key)
    }

    private func state(_ value: Any?, key: String, refs: inout Set<String>) throws -> ItemState {
        guard let value else { return .absent }
        let hash = try blobs.put(try Self.encode(key, value))
        refs.insert(hash)
        return ItemState(fp: hash, summary: Self.describe(value))
    }

    static func encode(_ key: String, _ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [key: value], format: .xml, options: 0)
    }

    /// 列表里显示的简短值
    static func describe(_ value: Any) -> String {
        switch value {
        case let b as Bool where CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID():
            return b ? "开" : "关"
        case let n as NSNumber: return n.stringValue
        case let s as String: return s.count > 40 ? String(s.prefix(40)) + "…" : (s.isEmpty ? "（空）" : s)
        case let a as [Any]: return "\(a.count) 项列表"
        case let d as [String: Any]: return "\(d.count) 项设置"
        case let data as Data: return "数据 \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
        case let date as Date: return date.formatted(date: .abbreviated, time: .shortened)
        default: return String(describing: value)
        }
    }
}
