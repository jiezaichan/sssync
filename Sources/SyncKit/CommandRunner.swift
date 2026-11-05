import AppKit

/// 在本机登录 shell 里跑补齐命令（brew / nvm / uv），边跑边把输出交给界面
public enum CommandRunner {
    /// 跑完再一次性拿结果（对面发来的卸载待办用，没人看着）
    static func collect(_ command: String) async -> (status: Int32, output: String) {
        var output = ""
        var status: Int32 = -1
        for await event in run(command) {
            switch event {
            case .output(let text): output += text
            case .finished(let code): status = code
            }
        }
        return (status, output)
    }

    /// 把 App 移到废纸篓；正在运行的不动
    public static func trash(path: String, bundleID: String) async throws {
        let running = await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
        if running { throw SyncError("\(URL(filePath: path).deletingPathExtension().lastPathComponent) 正在运行，先退出再卸载") }
        try await NSWorkspace.shared.recycle([URL(filePath: path)])
    }

    public enum Event: Sendable {
        case output(String)
        case finished(Int32)
    }

    public static func run(_ command: String) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-lic", command]
            process.environment = Shell.cleanEnvironment.merging(["HOMEBREW_NO_AUTO_UPDATE": "1"]) { $1 }
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    continuation.yield(.output(String(decoding: data, as: UTF8.self)))
                }
            }
            process.terminationHandler = { p in
                // 等管道里剩下的输出读完
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    continuation.yield(.output(String(decoding: rest, as: UTF8.self)))
                }
                continuation.yield(.finished(p.terminationStatus))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.yield(.output("启动失败：\(error.localizedDescription)\n"))
                continuation.yield(.finished(-1))
                continuation.finish()
            }
        }
    }
}
