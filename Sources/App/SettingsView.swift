import AppKit
import SwiftUI
import SyncKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
            SyncListSettings()
                .tabItem { Label("同步清单", systemImage: "list.bullet.rectangle") }
        }
        // 分组表单自己会滚动，设置窗口按理想高度定尺寸会被压扁，所以给固定高度
        .frame(width: 640, height: 620)
    }
}

// MARK: - 通用（本机配置）

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var draft: Config?

    var body: some View {
        Group {
            if let draft = Binding($draft) {
                form(draft)
            } else {
                ProgressView()
            }
        }
        .onAppear { draft = model.config ?? .standard }
        .onChange(of: model.config?.machines) { draft = model.config ?? draft }
    }

    private func form(_ draft: Binding<Config>) -> some View {
        let keys = draft.wrappedValue.machines.keys.sorted()
        return Form {
            Section {
                LabeledContent("本机型号", value: Config.currentModel)
                Picker("这台电脑是", selection: thisMachine(draft)) {
                    Text("未指定").tag(String?.none)
                    ForEach(keys, id: \.self) { key in
                        Text(draft.wrappedValue.badge(key)).tag(Optional(key))
                    }
                }
            } header: {
                Text("本机")
            } footer: {
                Text("靠型号（hw.model）认出本机，两台电脑各设一次。")
            }

            Section {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("图标")
                        Text("名字")
                        Text("型号（hw.model）")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(keys, id: \.self) { key in
                        if let info = Binding(draft.machines[key]) {
                            GridRow {
                                TextField("图标", text: info.emoji, prompt: Text("🖥"))
                                    .multilineTextAlignment(.center)
                                    .frame(width: 48)
                                TextField("名字", text: info.label, prompt: Text("名字"))
                                    .frame(width: 140)
                                TextField("型号", text: info.model, prompt: Text("如 Mac14,5"))
                                    .font(.body.monospaced())
                            }
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            } header: {
                Text("两台电脑")
            } footer: {
                Text("图标可以填任意 emoji，界面上用它区分两台。")
            }

            Section("中转站") {
                TextField("ssh 主机", text: draft.relayHost)
                TextField("目录", text: draft.relayPath)
            }

            Section("常驻") {
                Toggle("登录时自动启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Stepper("每 \(draft.wrappedValue.refreshMinutes) 分钟自动刷新", value: draft.refreshMinutes, in: 5...240, step: 5)
                Toggle("对面改了东西时发通知", isOn: draft.notify)
            }

            HStack {
                if let error = model.errorText {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                Spacer()
                if let problem = validate(draft.wrappedValue) {
                    Text(problem).foregroundStyle(.orange).font(.callout)
                }
                Button("保存") {
                    Task { await model.saveConfig(draft.wrappedValue) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validate(draft.wrappedValue) != nil)
            }
        }
        .formStyle(.grouped)
    }

    private func validate(_ config: Config) -> String? {
        for key in config.machines.keys.sorted() {
            guard let info = config.machines[key] else { continue }
            if info.label.trimmingCharacters(in: .whitespaces).isEmpty { return "名字不能为空" }
            if info.model.trimmingCharacters(in: .whitespaces).isEmpty { return "\(info.label) 的型号不能为空" }
        }
        if config.relayHost.isEmpty || config.relayPath.isEmpty { return "中转站不能为空" }
        return nil
    }

    /// 选中哪台，就把本机型号写到那台上，其余同型号的清掉
    private func thisMachine(_ draft: Binding<Config>) -> Binding<String?> {
        Binding(
            get: {
                let model = Config.currentModel
                return draft.wrappedValue.machines.keys.sorted().first { draft.wrappedValue.machines[$0]?.model == model }
            },
            set: { selected in
                let model = Config.currentModel
                for key in draft.wrappedValue.machines.keys {
                    if key == selected {
                        draft.wrappedValue.machines[key]?.model = model
                    } else if draft.wrappedValue.machines[key]?.model == model {
                        draft.wrappedValue.machines[key]?.model = ""
                    }
                }
            }
        )
    }
}

// MARK: - 同步清单（两台共用）

struct SyncListSettings: View {
    @Environment(AppModel.self) private var model
    @State private var draft: SharedConfig?
    @State private var newFile = ""
    @State private var newDir = ""
    @State private var newDomain = ""
    @State private var newDomainContainer = false

    var body: some View {
        Group {
            if let draft = Binding($draft) {
                form(draft)
            } else {
                ContentUnavailableView("还没连上中转站", systemImage: "network.slash",
                                       description: Text("刷新成功一次后才能编辑同步清单"))
            }
        }
        .onAppear { draft = model.shared }
        .onChange(of: model.shared) { draft = model.shared }
    }

    private func form(_ draft: Binding<SharedConfig>) -> some View {
        Form {
            Section {
                ForEach(draft.wrappedValue.files, id: \.self) { path in
                    removable(path) { draft.wrappedValue.files.removeAll { $0 == path } }
                }
                HStack {
                    TextField("~/路径/文件", text: $newFile).textFieldStyle(.roundedBorder)
                    Button("选择…") { if let p = choose(directory: false) { newFile = p } }
                    Button("添加") {
                        let p = newFile.trimmingCharacters(in: .whitespaces)
                        if !p.isEmpty, !draft.wrappedValue.files.contains(p) { draft.wrappedValue.files.append(p) }
                        newFile = ""
                    }
                    .disabled(newFile.isEmpty)
                }
            } header: {
                Text("文件")
            }

            Section {
                ForEach(draft.wrappedValue.dirs, id: \.path) { spec in
                    removable(spec.path, detail: spec.ignore.isEmpty ? nil : "忽略：" + spec.ignore.joined(separator: "  ")) {
                        draft.wrappedValue.dirs.removeAll { $0.path == spec.path }
                    }
                }
                HStack {
                    TextField("~/路径/目录", text: $newDir).textFieldStyle(.roundedBorder)
                    Button("选择…") { if let p = choose(directory: true) { newDir = p } }
                    Button("添加") {
                        let p = newDir.trimmingCharacters(in: .whitespaces)
                        if !p.isEmpty, !draft.wrappedValue.dirs.contains(where: { $0.path == p }) {
                            draft.wrappedValue.dirs.append(DirSpec(path: p, ignore: [".git", ".DS_Store", "node_modules"]))
                        }
                        newDir = ""
                    }
                    .disabled(newDir.isEmpty)
                }
            } header: {
                Text("目录")
            } footer: {
                Text("目录里每个顶层子目录算一项、每个顶层文件算一项。")
            }

            Section {
                ForEach(draft.wrappedValue.prefs, id: \.self) { spec in
                    let what = spec.keys.map { "\($0.count) 个键" } ?? "全部设置（过滤噪音）"
                    removable("\(AppNames.name(of: spec.domain))  \(spec.domain)", detail: (spec.container ? "沙盒 · " : "") + what) {
                        draft.wrappedValue.prefs.removeAll { $0 == spec }
                    }
                }
                HStack {
                    TextField("bundle id，如 com.googlecode.iterm2", text: $newDomain).textFieldStyle(.roundedBorder)
                    Toggle("沙盒", isOn: $newDomainContainer).toggleStyle(.checkbox)
                    Button("添加") {
                        let d = newDomain.trimmingCharacters(in: .whitespaces)
                        if !d.isEmpty { draft.wrappedValue.prefs.append(PrefSpec(domain: d, container: newDomainContainer)) }
                        newDomain = ""
                    }
                    .disabled(newDomain.isEmpty)
                }
            } header: {
                Text("App 设置（逐键）")
            } footer: {
                Text("不知道 App 的设置存在哪，用主窗口工具栏的「录制」。")
            }

            Section("启动项与默认打开方式") {
                Toggle("管理 ~/Library/LaunchAgents", isOn: draft.launchAgents)
                if !draft.wrappedValue.templates.isEmpty {
                    LabeledContent("模板", value: draft.wrappedValue.templates.keys.sorted().joined(separator: "、"))
                }
                TextField("扩展名（空格分隔）", text: Binding(
                    get: { draft.wrappedValue.handlers.joined(separator: " ") },
                    set: { draft.wrappedValue.handlers = $0.split(separator: " ").map(String.init) }
                ))
            }

            Section {
                ForEach(draft.wrappedValue.ignored, id: \.self) { id in
                    removable(id) { draft.wrappedValue.ignored.removeAll { $0 == id } }
                }
                if draft.wrappedValue.ignored.isEmpty { Text("没有").foregroundStyle(.secondary) }
            } header: {
                Text("不同步的条目")
            } footer: {
                Text("列表里「⋯ → 不再同步这一项」加到这里；删掉就恢复同步。支持 * 通配。")
            }

            HStack {
                Text("这份清单两台共用，保存后对面下次刷新时跟着更新。").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("还原") { self.draft = model.shared }
                    .disabled(draft.wrappedValue == model.shared)
                Button("保存") {
                    let new = draft.wrappedValue
                    Task { await model.updateShared { $0 = new } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.wrappedValue == model.shared)
            }
        }
        .formStyle(.grouped)
    }

    private func removable(_ text: String, detail: String? = nil, remove: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.callout.monospaced()).textSelection(.enabled)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("从清单里去掉（不会删文件）")
        }
    }

    private func choose(directory: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(filePath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let path = url.path(percentEncoded: false).trimmingSuffix("/")
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
