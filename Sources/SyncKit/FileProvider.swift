import Foundation

/// 文件条目（`file:`）和目录条目（`dir:`，受管目录的一个顶层子目录）
struct FileProvider: Sendable {
    let config: SharedConfig
    let blobs: BlobStore

    // MARK: 扫描

    func scanAll(refs: inout Set<String>) throws -> [String: ItemState] {
        var out: [String: ItemState] = [:]
        for path in config.files {
            out["file:" + path] = try scanFile(Paths.expand(path), refs: &refs)
        }
        let fm = FileManager.default
        for spec in config.dirs {
            let root = Paths.expand(spec.path)
            let names = (try? fm.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
            for name in names.sorted() where !isIgnored(name: name, relative: name, spec: spec) {
                let url = root.appending(path: name)
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true { continue }
                let path = spec.path + "/" + name
                if values?.isDirectory == true {
                    out["dir:" + path] = try scanDir(url, spec: spec, relativeBase: name, refs: &refs)
                } else {
                    out["file:" + path] = try scanFile(url, refs: &refs)
                }
            }
        }
        return out
    }

    func scan(_ id: String, refs: inout Set<String>) throws -> ItemState {
        let key = itemKey(id)
        switch ItemKind(id: id) {
        case .file:
            return try scanFile(Paths.expand(key), refs: &refs)
        case .dir:
            let (spec, relative) = try owningSpec(of: key)
            return try scanDir(Paths.expand(key), spec: spec, relativeBase: relative, refs: &refs)
        default:
            throw SyncError("不是文件条目：\(id)")
        }
    }

    private func scanFile(_ url: URL, refs: inout Set<String>) throws -> ItemState {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir), !isDir.boolValue else {
            return .absent
        }
        let data = try Data(contentsOf: url)
        let hash = try blobs.put(data)
        refs.insert(hash)
        return ItemState(fp: hash, summary: describe(data), mode: mode(of: url))
    }

    private func scanDir(_ url: URL, spec: DirSpec, relativeBase: String, refs: inout Set<String>) throws -> ItemState {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue else {
            return .absent
        }
        let members = try manifest(of: url, spec: spec, relativeBase: relativeBase, refs: &refs)
        let hash = try blobs.put(try JSON.encode(members))
        refs.insert(hash)
        return ItemState(fp: hash, summary: "\(members.count) 个文件")
    }

    /// 目录清单：相对路径 → 内容指纹 + 权限；跳过忽略项和软链
    private func manifest(of url: URL, spec: DirSpec, relativeBase: String, refs: inout Set<String>) throws -> [String: DirMember] {
        var members: [String: DirMember] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return members }
        let rootPath = url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/") + "/"
        for case let file as URL in enumerator {
            let full = file.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
            guard full.hasPrefix(rootPath) else { continue }
            let relative = String(full.dropFirst(rootPath.count))
            let values = try file.resourceValues(forKeys: Set(keys))
            if isIgnored(name: file.lastPathComponent, relative: relativeBase + "/" + relative, spec: spec) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true || values.isRegularFile != true { continue }
            let hash = try blobs.put(try Data(contentsOf: file))
            refs.insert(hash)
            members[relative] = DirMember(fp: hash, mode: mode(of: file))
        }
        return members
    }

    /// 目录条目的值引用到的全部成员内容
    func members(ofManifest hash: String) throws -> [String] {
        try JSON.decode([String: DirMember].self, try blobs.get(hash)).values.map(\.fp)
    }

    func manifest(_ hash: String) throws -> [String: DirMember] {
        try JSON.decode([String: DirMember].self, try blobs.get(hash))
    }

    // MARK: 应用

    func apply(_ id: String, value: String, mode: Int?, backup: Backup) throws {
        let url = Paths.expand(itemKey(id))
        let fm = FileManager.default
        switch ItemKind(id: id) {
        case .file:
            try backup.save(url)
            if value == absentFP {
                if fm.fileExists(atPath: url.path(percentEncoded: false)) { try fm.removeItem(at: url) }
            } else {
                try write(try blobs.get(value), to: url, mode: mode)
            }
        case .dir:
            if value == absentFP {
                try backup.save(url)
                if fm.fileExists(atPath: url.path(percentEncoded: false)) { try fm.removeItem(at: url) }
                return
            }
            let (spec, relative) = try owningSpec(of: itemKey(id))
            let target = try JSON.decode([String: DirMember].self, try blobs.get(value))
            var ignoredRefs = Set<String>()
            let current = fm.fileExists(atPath: url.path(percentEncoded: false))
                ? try manifest(of: url, spec: spec, relativeBase: relative, refs: &ignoredRefs) : [:]
            for (path, member) in target where current[path] != member {
                let file = url.appending(path: path)
                try backup.save(file)
                try write(try blobs.get(member.fp), to: file, mode: member.mode)
            }
            for path in current.keys where target[path] == nil {
                let file = url.appending(path: path)
                try backup.save(file)
                try fm.removeItem(at: file)
            }
        default:
            throw SyncError("不是文件条目：\(id)")
        }
    }

    private func write(_ data: Data, to url: URL, mode: Int?) throws {
        try Paths.ensure(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    // MARK: 工具

    private func owningSpec(of path: String) throws -> (DirSpec, String) {
        for spec in config.dirs where path.hasPrefix(spec.path + "/") {
            return (spec, String(path.dropFirst(spec.path.count + 1)))
        }
        throw SyncError("\(path) 不在任何受管目录里")
    }

    private func isIgnored(name: String, relative: String, spec: DirSpec) -> Bool {
        Glob.matchAny(spec.ignore, name) || Glob.matchAny(spec.ignore, relative)
    }

    private func mode(of url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    private func describe(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            return "\(lines) 行"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
