import AppKit
import SwiftUI
import SyncKit

/// 开发环境 / 应用：两台逐项对齐；本机缺的可以一键补上，本机多的可以卸载，对面缺的给出命令
struct EnvList: View {
    @Environment(AppModel.self) private var model
    let sections: [EnvSection]
    let emptyText: String
    @State private var onlyDiff = true
    @State private var search = ""

    var body: some View {
        if let snapshot = model.snapshot {
            if let missing = snapshot.machineOrder.first(where: { snapshot.reports[$0] == nil }) {
                ContentUnavailableView("\(snapshot.badge(missing)) 还没上传环境报告", systemImage: "hourglass",
                                       description: Text("在那台上把 sssync 更新到最新版并刷新一次"))
            } else {
                content(snapshot)
            }
        } else {
            ProgressView("正在扫描…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ snapshot: Snapshot) -> some View {
        let shown = filtered
        return VStack(spacing: 0) {
            HStack {
                Text("「确认差异」= 两边就这样，不再提醒；「安装 / 升级」= 补成跟对面一样；「卸载」= 删掉只有一边有的")
                    .lineLimit(2)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("搜索", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
                Toggle("只看没确认的差异", isOn: $onlyDiff).toggleStyle(.checkbox)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            HStack(spacing: 14) {
                Text("项目").envNameColumn()
                ForEach(snapshot.machineOrder, id: \.self) { m in
                    Text(snapshot.badge(m)).envValueColumn()
                }
                Text("操作").frame(width: EnvLayout.action, alignment: .leading)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 26)
            .padding(.vertical, 8)
            Divider()
            if shown.allSatisfy({ $0.rows.isEmpty }) {
                ContentUnavailableView(onlyDiff && search.isEmpty ? emptyText : "没有匹配的项",
                                       systemImage: "checkmark.circle")
            } else {
                List {
                    ForEach(shown) { section in
                        if !section.rows.isEmpty {
                            Section {
                                ForEach(section.rows) { row in
                                    EnvRowView(row: row, snapshot: snapshot)
                                }
                            } header: {
                                Label(section.title, systemImage: section.systemImage)
                            } footer: {
                                if let footer = section.footer { Text(footer).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var filtered: [EnvSection] {
        sections.map { section in
            let rows = section.rows.filter { row in
                (!onlyDiff || (!row.same && !model.isAcked(row)) || section.id == "errors")
                    && (search.isEmpty || row.name.localizedCaseInsensitiveContains(search)
                        || row.values.values.contains { $0.localizedCaseInsensitiveContains(search) })
            }
            return EnvSection(id: section.id, title: section.title, systemImage: section.systemImage, rows: rows, footer: section.footer)
        }
    }
}

/// 所有确认过的差异集中在一处：同步条目、开发环境、应用，都能取消确认
struct AcknowledgedList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let snapshot = model.snapshot {
            let groups = model.visibleGroups
            let reports = model.ackedReportSections
            if groups.isEmpty && reports.isEmpty {
                ContentUnavailableView("还没有确认过的差异", systemImage: "checkmark.circle",
                                       description: Text("在待同步、开发环境、应用里点 ✓ 确认：两边就这样，不再提醒；任一边再变会重新出现"))
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.rows) { RowView(row: $0, snapshot: snapshot) }
                        } header: {
                            Label(group.title, systemImage: "arrow.left.arrow.right")
                        }
                    }
                    ForEach(reports) { section in
                        Section {
                            ForEach(section.rows) { EnvRowView(row: $0, snapshot: snapshot) }
                        } header: {
                            Label(section.title, systemImage: section.systemImage)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

/// 两边的值先拿到宽度，名字拿剩下的，但至少留 `name` 宽
enum EnvLayout {
    static let name: CGFloat = 170
    static let valueMin: CGFloat = 80
    static let value: CGFloat = 180
    static let action: CGFloat = 330
}

extension View {
    func envNameColumn() -> some View {
        frame(minWidth: EnvLayout.name, maxWidth: .infinity, alignment: .leading)
    }

    func envValueColumn() -> some View {
        frame(minWidth: EnvLayout.valueMin, idealWidth: EnvLayout.value, maxWidth: EnvLayout.value, alignment: .leading)
            .layoutPriority(1)
    }
}

struct EnvRowView: View {
    @Environment(AppModel.self) private var model
    let row: EnvRow
    let snapshot: Snapshot
    @State private var confirmRemove = false
    @State private var confirmPeerRemove = false

    var body: some View {
        let acked = !row.same && model.isAcked(row)
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: row.same ? "checkmark.circle.fill" : acked ? "checkmark.circle" : "exclamationmark.circle.fill")
                    .foregroundStyle(row.same ? Color.green : acked ? Color.secondary : Color.orange)
                    .help(acked ? "已确认的差异" : "")
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).lineLimit(1).truncationMode(.middle).help(row.name)
                    if let note = row.note {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(note)
                    }
                }
            }
            .envNameColumn()

            ForEach(snapshot.machineOrder, id: \.self) { m in
                Group {
                    if let value = row.values[m] {
                        Text(value).lineLimit(2).truncationMode(.tail).textSelection(.enabled).help(value)
                    } else {
                        Text("没有").foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                .envValueColumn()
            }

            actions.frame(width: EnvLayout.action, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if !row.same && row.values.count > 0 {
                if model.isAcked(row) {
                    Button("取消确认") { Task { await model.unacknowledge([row.ackID]) } }
                } else {
                    Button {
                        Task { await model.acknowledge([row]) }
                    } label: {
                        Label("确认差异", systemImage: "checkmark")
                    }
                    .help("确认差异：两边就这样，不再提醒；值再变会重新出现")
                }
            }
            if let fix = row.fixes[snapshot.me] {
                // 本机已经有、只是版本旧，就是更新
                let has = row.values[snapshot.me] != nil
                Button(fix.isOpen ? (has ? "去 App Store 更新" : "去 App Store 安装") : (has ? "在本机升级" : "在本机安装")) {
                    model.run(fix, title: "\(row.name)：\(has ? "升级" : "装到")\(snapshot.label(snapshot.me))")
                }
                .help(fix.text)
            }
            if let removal = row.removals[snapshot.me] {
                Button("在本机卸载", role: .destructive) { confirmRemove = true }
                    .help("\(snapshot.label(snapshot.peer))没有这一项，在本机卸载掉两边就一样了：\n\(removal.text)")
                    .confirmationDialog("在\(snapshot.label(snapshot.me))卸载「\(row.name)」？", isPresented: $confirmRemove) {
                        Button("卸载", role: .destructive) {
                            model.run(removal, title: "\(row.name)：从\(snapshot.label(snapshot.me))卸载")
                        }
                    } message: {
                        Text(removal.text)
                    }
            }
            if row.removals[snapshot.peer] != nil {
                let peer = snapshot.label(snapshot.peer)
                if snapshot.pendingRemovals.contains(row.id) {
                    Text("等\(peer)卸载").font(.caption).foregroundStyle(.secondary)
                        .help("\(peer)的 sssync 下次刷新时会自己卸载，结果会通知到这台")
                } else {
                    Button("让\(peer)卸载", role: .destructive) { confirmPeerRemove = true }
                        .help("\(snapshot.label(snapshot.me))没有这一项。写成待办，\(peer)的 sssync 下次刷新时自己卸掉（那台情况变了就不动）")
                        .confirmationDialog("让\(peer)卸载「\(row.name)」？", isPresented: $confirmPeerRemove) {
                            Button("让\(peer)卸载", role: .destructive) {
                                Task { await model.requestUninstall(row, on: snapshot.peer) }
                            }
                        } message: {
                            Text("\(peer)的 sssync 下次刷新时执行：\n\(row.removals[snapshot.peer]!.text)")
                        }
                }
            }
            if let fix = row.fixes[snapshot.peer] {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fix.text, forType: .string)
                } label: {
                    Label("复制安装命令", systemImage: "doc.on.doc")
                }
                .help("\(snapshot.label(snapshot.peer))缺这一项。复制后到\(snapshot.label(snapshot.peer))上执行，或在那台的 sssync 里点「在本机安装」：\n\(fix.text)")
            }
        }
        .controlSize(.small)
    }
}

extension Fix {
    var isOpen: Bool {
        if case .open = self { return true }
        return false
    }
}

/// 跑补齐命令，实时显示输出；跑完自动刷新
struct CommandSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let job: CommandJob
    @State private var output = ""
    @State private var status: Int32?
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.title).font(.title3.weight(.semibold))
            Text(job.command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            ScrollViewReader { proxy in
                ScrollView {
                    Text(output.isEmpty ? (started ? "运行中…" : "点「运行」后在本机执行这条命令") : output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .border(.separator)
                .onChange(of: output) { proxy.scrollTo("end") }
            }
            HStack {
                if let status {
                    Label(status == 0 ? "完成" : "失败（退出码 \(status)）",
                          systemImage: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(status == 0 ? .green : .red)
                } else if started {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !started {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("运行") { start() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("关闭") {
                        dismiss()
                        Task { await model.refresh() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(status == nil)
                }
            }
        }
        .padding(18)
        .frame(width: 720, height: 480)
    }

    private func start() {
        started = true
        Task {
            for await event in CommandRunner.run(job.command) {
                switch event {
                case .output(let text): output += text
                case .finished(let code): status = code
                }
            }
        }
    }
}
