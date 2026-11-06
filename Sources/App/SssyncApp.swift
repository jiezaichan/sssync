import SwiftUI

@main
struct SssyncApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("sssync", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("刷新") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        // 常驻：关掉主窗口后还在菜单栏里定时刷新、发通知
        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            let count = model.totalOpen
            Image(systemName: count > 0 ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
            if count > 0 { Text("\(count)") }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let s = model.snapshot {
            Text("\(model.totalOpen) 项待处理")
            Text("待同步 \(model.count(.pending)) · 开发环境 \(model.count(.env)) · 应用 \(model.count(.apps))")
            if model.count(.waiting) > 0 { Text("\(model.count(.waiting)) 项在等\(s.label(s.peer))") }
        } else if let error = model.errorText {
            Text(error)
        } else {
            Text("正在扫描…")
        }
        Divider()
        Button("打开 sssync") { show() }
        Button(model.busy ? "正在刷新…" : "立即刷新") { Task { await model.refresh() } }
            .disabled(model.busy)
        Divider()
        Button("退出 sssync") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}
