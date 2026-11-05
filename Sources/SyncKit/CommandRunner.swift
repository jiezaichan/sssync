import Foundation

/// 在本机登录 shell 里跑补齐命令（brew / nvm / uv），边跑边把输出交给界面
public enum CommandRunner {
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
