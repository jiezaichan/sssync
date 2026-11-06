import SwiftUI
import SyncKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("同步") {
                    Label("待同步", systemImage: "arrow.left.arrow.right")
                        .badge(model.count(.pending))
                        .tag(SidebarItem.pending)
                    Label(waitingTitle, systemImage: "clock")
                        .badge(model.count(.waiting))
                        .tag(SidebarItem.waiting)
                    Label("已确认的差异", systemImage: "checkmark.circle")
                        .badge(model.count(.acknowledged))
                        .tag(SidebarItem.acknowledged)
                }
                Section("环境（只读对比）") {
                    Label("开发环境", systemImage: "wrench.and.screwdriver")
                        .badge(model.count(.env))
                        .tag(SidebarItem.env)
                    Label("应用", systemImage: "square.grid.2x2")
                        .badge(model.count(.apps))
                        .tag(SidebarItem.apps)
                }
                Section("分类") {
                    Label("文件", systemImage: "doc.on.doc")
                        .badge(model.count(.files))
                        .tag(SidebarItem.files)
                    Label("App 设置", systemImage: "slider.horizontal.3")
                        .badge(model.count(.prefs))
                        .tag(SidebarItem.prefs)
                    Label("启动项", systemImage: "bolt.horizontal")
                        .badge(model.count(.agents))
                        .tag(SidebarItem.agents)
                    Label("默认打开方式", systemImage: "arrow.up.forward.app")
                        .badge(model.count(.handlers))
                        .tag(SidebarItem.handlers)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                StatusBar()
                Divider()
                Banners()
                switch model.selection {
                case .env:
                    EnvList(sections: model.envSections, emptyText: "两台的开发环境完全一致")
                case .apps:
                    EnvList(sections: model.appSections, emptyText: "两台装的应用完全一致")
                case .acknowledged:
                    AcknowledgedList()
                default:
                    RowList()
                }
            }
        }
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItem {
                Button {
                    model.sheet = .record
                } label: {
                    Label("录制 App 配置", systemImage: "record.circle")
                }
                .help("录制：找出一个 App 的设置存在哪里，加进同步")
                .disabled(model.snapshot == nil)
            }
        }
        .sheet(item: $model.sheet) { sheet in
            if let snapshot = model.snapshot {
                switch sheet {
                case .diff(let row): DiffSheet(row: row, snapshot: snapshot).environment(model)
                case .merge(let row): MergeSheet(row: row, snapshot: snapshot).environment(model)
                case .template(let row): TemplateSheet(row: row, snapshot: snapshot).environment(model)
                case .command(let job): CommandSheet(job: job).environment(model)
                case .record: RecordSheet(snapshot: snapshot).environment(model)
                }
            }
        }
        .onChange(of: model.needsSetup, initial: true) { _, needs in
            if needs { openSettings() }
        }
    }

    private var waitingTitle: String {
        guard let s = model.snapshot else { return "等对面" }
        return "等\(s.label(s.peer))"
    }
}

// MARK: - 顶部状态栏

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(model.totalOpen)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("项待处理").foregroundStyle(.secondary)
            }
            .help("待同步 \(model.count(.pending)) · 开发环境 \(model.count(.env)) · 应用 \(model.count(.apps))。拍板、补齐或确认差异都会让它变少")
            if model.count(.waiting) > 0, let s = model.snapshot {
                Text("\(model.count(.waiting)) 项在等\(s.label(s.peer))")
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            if model.snapshot != nil {
                let envDiff = model.count(.env)
                Button {
                    model.selection = .env
                } label: {
                    Label(envDiff == 0 ? "环境一致" : "环境 \(envDiff) 处不同",
                          systemImage: envDiff == 0 ? "checkmark.seal" : "wrench.and.screwdriver")
                        .font(.callout)
                        .foregroundStyle(envDiff == 0 ? Color.green : Color.orange)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((envDiff == 0 ? Color.green : Color.orange).opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("开发环境：nvm、node、全局包、brew、uv、命令版本、环境变量")
            }
            Spacer()
            if let s = model.snapshot {
                ForEach(s.machineOrder, id: \.self) { machine in
                    MachineChip(snapshot: s, machine: machine)
                }
            }
            Button {
                Task { await model.refresh() }
            } label: {
                if model.busy {
                    ProgressView().controlSize(.small).frame(width: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("刷新（⌘R）")
            .disabled(model.busy)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

struct MachineChip: View {
    let snapshot: Snapshot
    let machine: String

    var body: some View {
        HStack(spacing: 6) {
            Text(snapshot.emoji(machine))
            VStack(alignment: .leading, spacing: 0) {
                Text(snapshot.label(machine) + (machine == snapshot.me ? "（本机）" : ""))
                    .font(.callout.weight(.medium))
                Text(freshness(snapshot.publishedAt[machine]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func freshness(_ date: Date?) -> String {
        guard let date else { return "还没发布过" }
        if Date().timeIntervalSince(date) < 60 { return "刚刚更新" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return f.localizedString(for: date, relativeTo: Date()) + "更新"
    }
}

// MARK: - 提示条

struct Banners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorText {
                banner(error, systemImage: "exclamationmark.triangle.fill", tint: .red)
            }
            if let s = model.snapshot {
                if s.peerMissing {
                    banner("\(s.badge(s.peer)) 还没发布过状态：在那台电脑上打开一次 sssync 就有了",
                           systemImage: "info.circle.fill", tint: .orange)
                }
                ForEach(s.machineOrder.filter { s.blockedApps[$0] != nil }, id: \.self) { machine in
                    HStack {
                        Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
                        Text("\(s.badge(machine))读不到 \(s.blockedApps[machine]!.joined(separator: "、")) 的设置，这些 App 先不对比。macOS 不让读别的 App 的沙盒数据：在\(s.label(machine))上给 sssync 开「完全磁盘访问」，再刷新（只需一次）。")
                        Spacer()
                        if machine == s.me {
                            Button("打开系统设置") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08))
                }
                ForEach(s.messages, id: \.self) { message in
                    banner(message, systemImage: "checkmark.circle.fill", tint: .blue)
                }
            }
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08))
    }
}

// MARK: - 列表

enum Layout {
    static let value: CGFloat = 140
    static let actions: CGFloat = 320
}

struct RowList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.snapshot == nil {
            ProgressView(model.errorText == nil ? "正在扫描…" : "")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleGroups.isEmpty {
            ContentUnavailableView("两边一致", systemImage: "checkmark.circle",
                                   description: Text("这里没有需要处理的差异"))
        } else if let snapshot = model.snapshot {
            VStack(spacing: 0) {
                ColumnHeader(snapshot: snapshot)
                Divider()
                List {
                    ForEach(model.visibleGroups) { group in
                        Section {
                            ForEach(group.rows) { row in
                                RowView(row: row, snapshot: snapshot)
                            }
                        } header: {
                            Text(group.title)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct ColumnHeader: View {
    let snapshot: Snapshot

    var body: some View {
        HStack(spacing: 14) {
            Text("条目").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(snapshot.machineOrder, id: \.self) { machine in
                Text(snapshot.badge(machine)).frame(width: Layout.value, alignment: .leading)
            }
            Text("以哪边为准").frame(width: Layout.actions, alignment: .leading)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 26)
        .padding(.vertical, 8)
    }
}

struct RowView: View {
    @Environment(AppModel.self) private var model
    let row: Row
    let snapshot: Snapshot
    @State private var confirmDelete: String?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.title)
                StatusTag(row: row, snapshot: snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(snapshot.machineOrder, id: \.self) { machine in
                ValueCell(state: row.states[machine], highlighted: row.suggested == machine)
                    .frame(width: Layout.value, alignment: .leading)
            }

            actions.frame(width: Layout.actions, alignment: .leading)
        }
        .padding(.vertical, 6)
        .confirmationDialog("确定吗？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            if let machine = confirmDelete {
                Button("删除\(snapshot.badge(snapshot.other(than: machine)))上的「\(row.name)」", role: .destructive) {
                    Task { await model.use(row, machine: machine) }
                }
            }
        } message: {
            Text("\(confirmDelete.map(snapshot.badge) ?? "")上没有这一项。以它为准，就会把另一台上的删掉（删之前会备份）。")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if row.status == .waiting {
            Label("已拍板，等\(snapshot.label(snapshot.peer))应用", systemImage: "clock")
                .foregroundStyle(.secondary)
        } else if row.status == .peerOutdated {
            Label("清单改过，等\(snapshot.label(snapshot.peer))按新清单刷新", systemImage: "arrow.clockwise")
                .foregroundStyle(.secondary)
                .help("\(snapshot.label(snapshot.peer))上次是按旧清单扫描的，它那边的值还不知道")
        } else {
            HStack(spacing: 6) {
                ForEach(snapshot.machineOrder, id: \.self) { machine in
                    choose(machine)
                }
                if model.isAcked(row) {
                    Button {
                        Task { await model.unacknowledge([row.id]) }
                    } label: {
                        Label("取消确认", systemImage: "arrow.uturn.backward")
                    }
                    .help("取消确认，放回待同步")
                } else {
                    Button {
                        Task { await model.acknowledge([row]) }
                    } label: {
                        Label("确认差异", systemImage: "checkmark")
                    }
                    .help("确认差异：两边就这样，不再提醒；任一边再变会重新出现")
                }
                if row.kind != .handler {
                    Button {
                        model.sheet = .diff(row)
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .help("左右对比")
                    .accessibilityLabel("对比 \(row.name)")
                }
                Menu {
                    if row.mergeable {
                        Button("合并两边…") { model.sheet = .merge(row) }
                    }
                    if row.kind == .agent {
                        Button("设为模板（两台参数不同）…") { model.sheet = .template(row) }
                    }
                    Button("不再同步这一项") { Task { await model.ignore(row) } }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多")
            }
            .controlSize(.regular)
            .disabled(model.busy)
        }
    }

    @ViewBuilder
    private func choose(_ machine: String) -> some View {
        let title = snapshot.arrow(machine)
        let help = "以\(snapshot.label(machine))为准，覆盖\(snapshot.label(snapshot.other(than: machine)))"
        let action = {
            if row.states[machine]?.fp == nil {
                confirmDelete = machine
            } else {
                Task { await model.use(row, machine: machine) }
            }
        }
        if row.suggested == machine {
            Button(title, action: action).buttonStyle(.borderedProminent).help(help)
        } else {
            Button(title, action: action).buttonStyle(.bordered).help(help)
        }
    }
}

struct ValueCell: View {
    let state: ItemState?
    let highlighted: Bool

    var body: some View {
        if let state, state.fp != nil {
            Text(state.summary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fontWeight(highlighted ? .medium : .regular)
        } else {
            Text(state?.summary ?? "没有")
                .foregroundStyle(.tertiary)
        }
    }
}

struct StatusTag: View {
    let row: Row
    let snapshot: Snapshot

    var body: some View {
        let (text, color) = describe()
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func describe() -> (String, Color) {
        switch row.status {
        case .onlyChanged(let machine):
            let other = snapshot.other(than: machine)
            let who = snapshot.badge(machine)
            if row.states[machine]?.fp == nil { return ("\(who) 删了", .red) }
            if row.states[other]?.fp == nil { return ("\(who) 新增", .green) }
            return ("\(who) 改了", .blue)
        case .conflict:
            return ("两边都改了", .orange)
        case .firstTime:
            return ("首次对比", .gray)
        case .waiting:
            return ("等\(snapshot.label(snapshot.peer))应用", .gray)
        case .peerOutdated:
            return ("等\(snapshot.label(snapshot.peer))刷新", .gray)
        }
    }
}
