import Foundation

/// 本机内容仓库：按 SHA-256 存每个值（文件内容、目录清单、App bundle id）
struct BlobStore: Sendable {
    let dir: URL

    func url(_ hash: String) -> URL { dir.appending(path: hash) }

    func has(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(hash).path(percentEncoded: false))
    }

    @discardableResult
    func put(_ data: Data) throws -> String {
        let hash = Hash.hex(data)
        if !has(hash) {
            try Paths.ensure(dir)
            try data.write(to: url(hash), options: .atomic)
        }
        return hash
    }

    func get(_ hash: String) throws -> Data {
        guard has(hash) else { throw SyncError("本机缺少内容 \(hash.prefix(12))…") }
        return try Data(contentsOf: url(hash))
    }
}

/// 一次执行的备份：被覆盖或删除前，原样拷到 backups/<会话>/ 下
struct Backup: Sendable {
    let root: URL

    init(session: String) {
        root = Paths.backups.appending(path: session, directoryHint: .isDirectory)
    }

    static func newSession() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date()) + "-" + UUID().uuidString.prefix(4)
    }

    func save(_ url: URL) throws {
        let fm = FileManager.default
        let source = url.path(percentEncoded: false)
        guard fm.fileExists(atPath: source) else { return }
        let home = NSHomeDirectory() + "/"
        let relative = source.hasPrefix(home) ? "home/" + source.dropFirst(home.count) : "abs" + source
        let dest = root.appending(path: relative)
        // 同一会话里只留第一次的原样
        guard !fm.fileExists(atPath: dest.path(percentEncoded: false)) else { return }
        try Paths.ensure(dest.deletingLastPathComponent())
        try fm.copyItem(at: url, to: dest)
    }
}
