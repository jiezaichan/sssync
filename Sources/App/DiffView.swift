import SwiftUI
import SyncKit

/// 对比窗口：顶部是条目信息和拍板按钮，下面按内容类型显示文本 / 目录 / 二进制对比
struct DiffSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let row: Row
    let snapshot: Snapshot
    @State private var source: DiffSource?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let loadError {
                    ContentUnavailableView("读不到内容", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else if let source {
                    content(source)
                } else {
                    ProgressView("正在取两边的内容…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 1040, idealWidth: 1240, minHeight: 680, idealHeight: 820)
        .task {
            do { source = try await model.diffSource(row) } catch { loadError = error.localizedDescription }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.title3.weight(.semibold))
                Text(row.title).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if row.secret {
                Label("密钥已打码", systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
            }
            if row.status != .same {
                if row.mergeable && !row.status.isWaiting {
                    Button("合并两边…") { model.sheet = .merge(row) }
                }
                if !row.status.isWaiting {
                    ForEach(snapshot.machineOrder, id: \.self) { machine in
                        let title = snapshot.arrow(machine, text: "以\(snapshot.label(machine))为准")
                        if row.suggested == machine {
                            Button(title) { choose(machine) }.buttonStyle(.borderedProminent)
                        } else {
                            Button(title) { choose(machine) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func choose(_ machine: String) {
        dismiss()
        Task { await model.use(row, machine: machine) }
    }

    @ViewBuilder
    private func content(_ source: DiffSource) -> some View {
        let order = snapshot.machineOrder
        switch source {
        case .text(let texts):
            TextDiffView(snapshot: snapshot, left: texts[order[0]] ?? nil, right: texts[order[1]] ?? nil)
        case .binary(let sizes):
            BinaryDiffView(snapshot: snapshot, sizes: sizes)
        case .directory(let members):
            DirectoryDiffView(snapshot: snapshot, root: row.title, members: members)
        }
    }
}

// MARK: - 文本

struct TextDiffView: View {
    let snapshot: Snapshot
    /// nil 表示那台没有这个文件
    let left: String?
    let right: String?
    @State private var result: TextDiff.Result?
    @State private var showAll = false

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            if let result {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(result.rows) { row in
                            line(row)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: showAll) {
            let l = left ?? "", r = right ?? ""
            // 内容相同也显示全文，方便核对
            let context = (showAll || l == r) ? nil : 3
            result = await Task.detached { TextDiff.sideBySide(l, r, context: context) }.value
        }
    }

    private var columnHeader: some View {
        let order = snapshot.machineOrder
        return HStack(spacing: 0) {
            sideTitle(order[0], text: left).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            sideTitle(order[1], text: right).frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 10) {
                if let result {
                    Text("+\(result.added)").foregroundStyle(.green)
                    Text("−\(result.removed)").foregroundStyle(.red)
                }
                Toggle("展开全部", isOn: $showAll).toggleStyle(.checkbox)
            }
            .font(.callout.monospacedDigit())
            .padding(.trailing, 14)
        }
        .frame(height: 34)
        .background(.bar)
    }

    private func sideTitle(_ machine: String, text: String?) -> some View {
        HStack(spacing: 6) {
            Text(snapshot.badge(machine)).font(.callout.weight(.medium))
            Text(text.map { "\(TextDiffView.lineCount($0)) 行" } ?? "没有这个文件")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 14)
    }

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
    }

    @ViewBuilder
    private func line(_ row: TextDiff.SideRow) -> some View {
        if case .fold(let count) = row.kind {
            Button {
                showAll = true
            } label: {
                HStack {
                    Image(systemName: "chevron.up.chevron.down")
                    Text("\(count) 行相同，点击展开")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08))
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 0) {
                DiffHalf(cell: row.left, tint: tint(row.kind, left: true))
                Divider()
                DiffHalf(cell: row.right, tint: tint(row.kind, left: false))
            }
        }
    }

    private func tint(_ kind: TextDiff.RowKind, left: Bool) -> Color? {
        switch kind {
        case .removed: return left ? .red : nil
        case .added: return left ? nil : .green
        case .changed: return left ? .red : .green
        default: return nil
        }
    }
}

/// 一栏里的一行：行号 + 文本；改动的字符加深高亮
struct DiffHalf: View {
    let cell: TextDiff.Cell?
    let tint: Color?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(cell.map { String($0.number) } ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)
            Text(attributed)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
    }

    private var background: Color {
        if cell == nil { return Color.secondary.opacity(0.06) }
        return tint?.opacity(0.13) ?? .clear
    }

    private var attributed: AttributedString {
        guard let cell else { return AttributedString(" ") }
        var text = AttributedString(cell.text.isEmpty ? " " : cell.text)
        guard let tint, !cell.text.isEmpty else { return text }
        let characters = text.characters
        for mark in cell.marks where mark.upperBound <= characters.count {
            let start = characters.index(characters.startIndex, offsetBy: mark.lowerBound)
            let end = characters.index(characters.startIndex, offsetBy: mark.upperBound)
            text[start..<end].backgroundColor = tint.opacity(0.45)
        }
        return text
    }
}

// MARK: - 二进制

struct BinaryDiffView: View {
    let snapshot: Snapshot
    let sizes: [String: Int?]

    var body: some View {
        HStack(spacing: 40) {
            ForEach(snapshot.machineOrder, id: \.self) { machine in
                VStack(spacing: 8) {
                    Text(snapshot.badge(machine)).font(.headline)
                    if let size = sizes[machine] ?? nil {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    } else {
                        Text("没有这个文件").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            Text("二进制文件，只能比较大小").foregroundStyle(.secondary).offset(y: -60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 目录

struct DirectoryDiffView: View {
    @Environment(AppModel.self) private var model
    let snapshot: Snapshot
    /// 目录本身的路径，如 `~/.config/zsh/bin`
    let root: String
    /// 机器 → 相对路径 → 指纹
    let members: [String: [String: String]]
    @State private var selected: String?
    @State private var source: DiffSource?
    @State private var loadError: String?

    private struct Entry: Identifiable {
        let path: String
        let left: String?
        let right: String?
        var id: String { path }
    }

    private var entries: [Entry] {
        let order = snapshot.machineOrder
        let l = members[order[0]] ?? [:], r = members[order[1]] ?? [:]
        // 全部列出来：一致的文件也要能查看
        return Set(l.keys).union(r.keys).sorted().map { path in
            Entry(path: path, left: l[path], right: r[path])
        }
    }

    var body: some View {
        HSplitView {
            List(entries, selection: $selected) { entry in
                HStack(spacing: 8) {
                    badge(entry)
                    Text(entry.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .tag(entry.path)
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)

            Group {
                if let loadError {
                    ContentUnavailableView("读不到内容", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else if let entry = entries.first(where: { $0.path == selected }), let source {
                    switch source {
                    case .text(let texts):
                        let order = snapshot.machineOrder
                        TextDiffView(snapshot: snapshot, left: texts[order[0]] ?? nil, right: texts[order[1]] ?? nil)
                            .id(entry.path)
                    case .binary(let sizes):
                        BinaryDiffView(snapshot: snapshot, sizes: sizes)
                    case .directory:
                        EmptyView()
                    }
                } else if entries.isEmpty {
                    ContentUnavailableView("目录是空的", systemImage: "folder")
                } else {
                    let different = entries.filter { $0.left != $0.right }.count
                    ContentUnavailableView("选一个文件看对比", systemImage: "sidebar.left",
                                           description: Text(different == 0
                                               ? "共 \(entries.count) 个文件，全部一致"
                                               : "共 \(entries.count) 个文件，\(different) 个不一样"))
                }
            }
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selected == nil { selected = entries.first?.path } }
        .task(id: selected) {
            source = nil
            loadError = nil
            guard let entry = entries.first(where: { $0.path == selected }) else { return }
            let order = snapshot.machineOrder
            do {
                source = try await model.memberSource([order[0]: entry.left ?? absentFP, order[1]: entry.right ?? absentFP],
                                                      path: root + "/" + entry.path)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func badge(_ entry: Entry) -> some View {
        let order = snapshot.machineOrder
        if entry.left == entry.right {
            tag("一致", .green)
        } else if entry.left == nil {
            tag("只\(snapshot.label(order[1]))有", .green)
        } else if entry.right == nil {
            tag("只\(snapshot.label(order[0]))有", .green)
        } else {
            tag("不同", .blue)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }
}
