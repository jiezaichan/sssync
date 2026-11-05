import Foundation

/// 中转站（`new:~/sssync-relay`），经 ssh / rsync 读写：
///
///     machines/<机器>/state.json   各台最新状态
///     blobs/<sha256>                内容
///     base/<sha256(条目)>.json      基线
///     decisions/<目标机器>/<id>.json 待办
///     receipts/<id>.json            回执
struct Relay: Sendable {
    let host: String
    let path: String

    private static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]

    struct Meta: Sendable {
        var peer: StateDoc?
        var base: [String: String] = [:]
        var mine: [Decision] = []
        var theirs: [Decision] = []
        /// 两台共用的同步清单；中转站上还没有时为 nil
        var shared: SharedConfig?
    }

    @discardableResult
    func ssh(_ command: String) throws -> String {
        try Shell.run("/usr/bin/ssh", Self.sshOptions + [host, command])
    }

    private func rsync(_ arguments: [String]) throws {
        let ssh = (["/usr/bin/ssh"] + Self.sshOptions).joined(separator: " ")
        try Shell.run("/usr/bin/rsync", ["-e", ssh] + arguments)
    }

    private func remote(_ sub: String) -> String { "\(host):\(path)/\(sub)" }

    func setup(machines: [String]) throws {
        var dirs = ["blobs", "base", "receipts"]
        for m in machines { dirs += ["machines/\(m)", "decisions/\(m)"] }
        try ssh("mkdir -p " + dirs.map { "\(path)/\($0)" }.joined(separator: " ") + " && chmod 700 \(path)")
    }

    /// 一次 ssh 取回对面状态、基线、双方待办
    func fetchMeta(me: String, peer: String) throws -> Meta {
        let script = """
        cd \(path) || exit 1
        echo '##PEER'; cat machines/\(peer)/state.json 2>/dev/null; echo
        echo '##BASE'; for f in base/*.json; do [ -f "$f" ] && cat "$f"; done
        echo '##MINE'; for f in decisions/\(me)/*.json; do [ -f "$f" ] && cat "$f"; done
        echo '##THEIRS'; for f in decisions/\(peer)/*.json; do [ -f "$f" ] && cat "$f"; done
        echo '##SHARED'; cat shared.json 2>/dev/null; echo
        echo '##END'
        """
        var sections: [String: [String]] = [:]
        var current = ""
        for line in try ssh(script).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("##") { current = String(line.dropFirst(2)); continue }
            sections[current, default: []].append(String(line))
        }
        var meta = Meta()
        let peerText = (sections["PEER"] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !peerText.isEmpty { meta.peer = try JSON.decode(StateDoc.self, Data(peerText.utf8)) }
        for line in sections["BASE"] ?? [] where !line.isEmpty {
            if let entry = try? JSON.decode(BaseEntry.self, Data(line.utf8)) { meta.base[entry.item] = entry.fp }
        }
        meta.mine = (sections["MINE"] ?? []).compactMap { try? JSON.decode(Decision.self, Data($0.utf8)) }
        meta.theirs = (sections["THEIRS"] ?? []).compactMap { try? JSON.decode(Decision.self, Data($0.utf8)) }
        let sharedText = (sections["SHARED"] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sharedText.isEmpty { meta.shared = try? JSON.decode(SharedConfig.self, Data(sharedText.utf8)) }
        return meta
    }

    /// 一批小文件一次 rsync 上去；rsync 先写临时文件再改名，对端读不到半截
    func put(_ files: [(sub: String, data: Data)]) throws {
        guard !files.isEmpty else { return }
        let staging = Paths.outbox.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        for file in files {
            let url = staging.appending(path: file.sub)
            try Paths.ensure(url.deletingLastPathComponent())
            try file.data.write(to: url)
        }
        try rsync(["-r", staging.path(percentEncoded: false).trimmingSuffix("/") + "/", "\(host):\(path)/"])
    }

    func remove(_ subs: [String]) throws {
        guard !subs.isEmpty else { return }
        try ssh("cd \(path) && rm -f " + subs.joined(separator: " "))
    }

    func uploadBlobs(_ hashes: Set<String>, from store: BlobStore) throws {
        guard !hashes.isEmpty else { return }
        try transferBlobs(Array(hashes), arguments: { list in
            ["-a", "--ignore-existing", "--files-from=\(list)", store.dir.path(percentEncoded: false).trimmingSuffix("/") + "/", remote("blobs/")]
        })
    }

    func downloadBlobs(_ hashes: [String], into store: BlobStore) throws {
        let missing = hashes.filter { $0 != absentFP && !store.has($0) }
        guard !missing.isEmpty else { return }
        try Paths.ensure(store.dir)
        try transferBlobs(missing, arguments: { list in
            ["-a", "--files-from=\(list)", remote("blobs/"), store.dir.path(percentEncoded: false).trimmingSuffix("/") + "/"]
        })
    }

    private func transferBlobs(_ hashes: [String], arguments: (String) -> [String]) throws {
        let list = FileManager.default.temporaryDirectory.appending(path: "sssync-\(UUID().uuidString).list")
        defer { try? FileManager.default.removeItem(at: list) }
        try Data(hashes.joined(separator: "\n").utf8).write(to: list)
        try rsync(arguments(list.path(percentEncoded: false)))
    }
}
