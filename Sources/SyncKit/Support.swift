import CryptoKit
import Foundation

public struct SyncError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Paths {
    public static let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    public static let support = home.appending(path: "Library/Application Support/sssync", directoryHint: .isDirectory)
    public static let blobs = support.appending(path: "blobs", directoryHint: .isDirectory)
    public static let outbox = support.appending(path: "outbox", directoryHint: .isDirectory)
    public static let backups = support.appending(path: "backups", directoryHint: .isDirectory)
    public static let configFile = support.appending(path: "config.json")
    public static let sharedFile = support.appending(path: "shared.json")

    /// `~/x` → 绝对路径
    public static func expand(_ path: String) -> URL {
        path.hasPrefix("~/") ? home.appending(path: String(path.dropFirst(2))) : URL(filePath: path)
    }

    public static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

enum Hash {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum JSON {
    static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(value)
    }

    /// 单行 JSON + 换行，中转站上的小文件都用这种格式，便于一次 `cat` 多个
    static func line<T: Encodable>(_ value: T) throws -> Data {
        try encode(value) + Data("\n".utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(type, from: data)
    }
}

enum Shell {
    /// 同步执行，返回 stdout；非零退出时抛出带 stderr 的错误。stderr 写临时文件，避免两个管道互相堵塞。
    /// `timeout` 秒后还没结束就杀掉；`environment` 为 nil 时继承本进程的环境。
    @discardableResult
    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]? = nil, timeout: TimeInterval? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        let errURL = FileManager.default.temporaryDirectory.appending(path: "sssync-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errURL.path(percentEncoded: false), contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)
        process.standardError = errHandle
        defer {
            try? errHandle.close()
            try? FileManager.default.removeItem(at: errURL)
        }
        try process.run()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [process] in
                if process.isRunning { process.terminate() }
            }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal, let timeout {
            throw SyncError("\(URL(filePath: executable).lastPathComponent) 超过 \(Int(timeout)) 秒没结束，已停止")
        }
        guard process.terminationStatus == 0 else {
            let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            let name = URL(filePath: executable).lastPathComponent
            throw SyncError("\(name) 失败（退出码 \(process.terminationStatus)）：\(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 干净的登录 shell 环境：不继承 sssync 自己的环境，只由 zsh 配置决定，两台才可比
    static var cleanEnvironment: [String: String] {
        let user = NSUserName()
        return [
            "HOME": NSHomeDirectory(), "USER": user, "LOGNAME": user, "SHELL": "/bin/zsh",
            "TERM": "xterm-256color", "LANG": "zh_CN.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    }

    /// 在 `zsh -lic` 里跑一段脚本（nvm 这类 shell 函数只在交互式 shell 里有）
    static func zsh(_ script: String, timeout: TimeInterval = 60) throws -> String {
        try run("/bin/zsh", ["-lic", script], environment: cleanEnvironment, timeout: timeout)
    }
}

/// shell 风格的通配：`*` 任意多个字符，`?` 一个字符
public enum Glob {
    public static func match(_ pattern: String, _ text: String) -> Bool {
        fnmatch(pattern, text, 0) == 0
    }

    public static func matchAny(_ patterns: [String], _ text: String) -> Bool {
        patterns.contains { match($0, text) }
    }
}

enum Machine {
    static func model() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
