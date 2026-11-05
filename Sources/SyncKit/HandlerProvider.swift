import AppKit
import UniformTypeIdentifiers

/// 默认打开方式条目（`handler:<扩展名>`）。值是默认 App 的 bundle id（等价 App 归一成规范名）。
struct HandlerProvider: Sendable {
    let config: SharedConfig
    let blobs: BlobStore

    func scanAll(refs: inout Set<String>) throws -> [String: ItemState] {
        var out: [String: ItemState] = [:]
        for ext in config.handlers {
            out["handler:" + ext] = try scan(ext: ext, refs: &refs)
        }
        return out
    }

    func scan(ext: String, refs: inout Set<String>) throws -> ItemState {
        guard let type = UTType(filenameExtension: ext),
              let app = NSWorkspace.shared.urlForApplication(toOpen: type) else {
            return ItemState(fp: nil, summary: "无")
        }
        let bundleID = Bundle(url: app)?.bundleIdentifier ?? app.path(percentEncoded: false)
        let hash = try blobs.put(Data(config.canonicalApp(bundleID).utf8))
        refs.insert(hash)
        return ItemState(fp: hash, summary: app.deletingPathExtension().lastPathComponent)
    }

    @MainActor
    func apply(ext: String, value: String) async throws {
        guard value != absentFP else { throw SyncError("不能把 .\(ext) 设成「无默认 App」") }
        let bundleID = String(decoding: try blobs.get(value), as: UTF8.self)
        let workspace = NSWorkspace.shared
        guard let app = config.equivalents(of: bundleID).lazy.compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first else {
            throw SyncError("本机没装 \(bundleID)，先装上再同步 .\(ext)")
        }
        guard let type = UTType(filenameExtension: ext) else { throw SyncError("系统不认识 .\(ext)") }
        try await workspace.setDefaultApplication(at: app, toOpen: type)
    }
}
