import Foundation

/// 启动项条目（`agent:<label>`，`~/Library/LaunchAgents/<label>.plist`）。
/// 值是规范化后的 XML；设了模板的，本机的变量值换回 `{{变量}}` 再比，所以两台参数不同也算一致。
struct AgentProvider: Sendable {
    let config: SharedConfig
    let blobs: BlobStore
    /// 本机是哪台，渲染模板时取这台的变量值
    let machine: String

    static let dir = Paths.home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)

    static func url(_ label: String) -> URL { dir.appending(path: label + ".plist") }

    func scanAll(refs: inout Set<String>) throws -> [String: ItemState] {
        guard config.launchAgents else { return [:] }
        var out: [String: ItemState] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.dir.path(percentEncoded: false))) ?? []
        for name in names where name.hasSuffix(".plist") {
            let label = String(name.dropLast(".plist".count))
            out["agent:" + label] = try scan(label: label, refs: &refs)
        }
        return out
    }

    func scan(label: String, refs: inout Set<String>) throws -> ItemState {
        let url = Self.url(label)
        guard let data = try? Data(contentsOf: url) else { return .absent }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return ItemState(fp: try blobs.put(data), summary: "plist 格式坏了")
        }
        let xml = String(decoding: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), as: UTF8.self)
        let vars = config.templates[label] ?? []
        let text = Template.templatize(xml, vars: vars, machine: machine)
        let hash = try blobs.put(Data(text.utf8))
        refs.insert(hash)
        let program = Self.program(plist)
        var summary = program.map { URL(filePath: $0).lastPathComponent } ?? "启动项"
        // 解释器 / 可执行文件被删或挪走时，launchd 会一直起不来，界面上直接标出来
        if let program, !FileManager.default.fileExists(atPath: program) {
            summary += " · ⚠️ 程序不存在"
        }
        if !vars.isEmpty { summary += " · 模板" }
        return ItemState(fp: hash, summary: summary)
    }

    func apply(label: String, value: String, backup: Backup) throws {
        let url = Self.url(label)
        let fm = FileManager.default
        try backup.save(url)
        let domain = "gui/\(getuid())"
        _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 30)
        if value == absentFP {
            if fm.fileExists(atPath: url.path(percentEncoded: false)) { try fm.removeItem(at: url) }
            return
        }
        let text = try Template.render(String(decoding: try blobs.get(value), as: UTF8.self),
                                       vars: config.templates[label] ?? [], machine: machine)
        let data = Data(text.utf8)
        guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil else {
            throw SyncError("\(label) 渲染出来不是合法的 plist")
        }
        try Paths.ensure(Self.dir)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false))
        do {
            try Shell.run("/bin/launchctl", ["bootstrap", domain, url.path(percentEncoded: false)], timeout: 30)
        } catch {
            throw SyncError("\(label) 的文件已经写好，但 launchctl 加载失败：\(error.localizedDescription)")
        }
    }

    static func program(_ plist: Any) -> String? {
        guard let dict = plist as? [String: Any] else { return nil }
        return dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
    }
}

/// 同名不同参的模板：本机文件里本机的值 ⇄ `{{变量}}`
public enum Template {
    public static func templatize(_ text: String, vars: [TemplateVar], machine: String) -> String {
        // 长的先换，避免一个值是另一个值的前缀时换坏
        let pairs = vars.compactMap { v in v.values[machine].map { (v.name, $0) } }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.count > $1.1.count }
        var out = text
        for (name, value) in pairs {
            out = out.replacingOccurrences(of: value, with: "{{\(name)}}")
        }
        return out
    }

    public static func render(_ text: String, vars: [TemplateVar], machine: String) throws -> String {
        var out = text
        for v in vars {
            guard out.contains("{{\(v.name)}}") else { continue }
            guard let value = v.values[machine], !value.isEmpty else {
                throw SyncError("模板变量 \(v.name) 在本机没有值，先在模板里填上")
            }
            out = out.replacingOccurrences(of: "{{\(v.name)}}", with: value)
        }
        if let range = out.range(of: #"\{\{[A-Za-z0-9_]+\}\}"#, options: .regularExpression) {
            throw SyncError("模板里的 \(out[range]) 没有定义")
        }
        return out
    }

    /// 从两边的内容猜变量：配对改动的行，各取标签里的完整值
    public static func suggest(left: String, right: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for row in TextDiff.sideBySide(left, right, context: 0).rows {
            guard case .changed = row.kind, let l = row.left?.text, let r = row.right?.text else { continue }
            let a = innerValue(l), b = innerValue(r)
            if a != b, !out.contains(where: { $0 == (a, b) }) { out.append((a, b)) }
        }
        return out
    }

    /// `<string>值</string>` → 值；不是标签行就去掉首尾空白
    static func innerValue(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("<"), let open = t.firstIndex(of: ">"), let close = t.range(of: "</", options: .backwards),
              open < close.lowerBound else { return t }
        return String(t[t.index(after: open)..<close.lowerBound])
    }
}
