import Foundation

/// 一台扫描时用的规则：哪些条目归它管、条目的值按什么规则算。随状态一起发布，
/// 对面据此判断这台的状态是不是按现在的清单扫的。
struct Scope: Codable, Sendable, Equatable {
    var files: [String]
    var dirs: [DirSpec]
    var handlers: [String]
    var equivalentApps: [[String]]
    var launchAgents: Bool
    var templates: [String: [TemplateVar]]

    init(_ shared: SharedConfig) {
        files = shared.files
        dirs = shared.dirs
        handlers = shared.handlers
        equivalentApps = shared.equivalentApps
        launchAgents = shared.launchAgents
        templates = shared.templates
    }

    /// 管这个条目的规则；不归这份清单管时为 nil。
    /// 两台对同一条目的规则不同，说明有一台还没按现在的清单扫过，它的值不可信（可能是「没扫」而不是「没有」）
    func rule(for id: String) -> String? {
        let key = itemKey(id)
        switch ItemKind(id: id) {
        case .file:
            if files.contains(key) { return "file" }
            guard let (spec, name) = topLevel(key), !name.contains("/"),
                  !isVersionControlDir(name), !Glob.matchAny(spec.ignore, name) else { return nil }
            return "file"
        case .dir:
            guard let (spec, name) = topLevel(key), !name.contains("/"),
                  !isVersionControlDir(name), !Glob.matchAny(spec.ignore, name) else { return nil }
            // 目录的值是成员清单，忽略规则一变值就变
            return "dir " + Self.text(spec.ignore.sorted())
        case .handler:
            return handlers.contains(key) ? "handler " + Self.text(equivalentApps) : nil
        case .agent:
            // 模板变量决定本机的值换成什么占位符
            return launchAgents ? "agent " + Self.text(templates[key] ?? []) : nil
        case nil:
            return nil
        }
    }

    private func topLevel(_ path: String) -> (DirSpec, String)? {
        for spec in dirs where path.hasPrefix(spec.path + "/") {
            return (spec, String(path.dropFirst(spec.path.count + 1)))
        }
        return nil
    }

    private static func text<T: Encodable>(_ value: T) -> String {
        (try? JSON.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
