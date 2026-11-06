import SwiftUI
import SyncKit

// MARK: - 合并

/// 三方合并：自动合入只有一边改的块，冲突块写成标记，手动改完作为这一条的决定
struct MergeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let row: Row
    let snapshot: Snapshot
    @State private var text = ""
    @State private var note: String?
    @State private var loadError: String?
    @State private var loaded = false
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("合并 \(row.name)").font(.title3.weight(.semibold))
                    Text(row.title).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if loaded {
                    let left = Merge.remainingConflicts(text)
                    Label(left == 0 ? "没有冲突了" : "还有 \(left) 处冲突", systemImage: left == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(left == 0 ? .green : .orange)
                }
            }
            if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            if let loadError {
                ContentUnavailableView("没法合并", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if loaded {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .border(.separator)
            } else {
                ProgressView("正在取基线和两边的内容…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text("冲突块格式：<<<<<<< 左边 … ======= … >>>>>>> 右边，留下想要的、删掉标记")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("两边都改成这个") {
                    if Merge.remainingConflicts(text) > 0 { confirm = true } else { apply() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!loaded || loadError != nil)
            }
        }
        .padding(18)
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 620, idealHeight: 780)
        .confirmationDialog("还有冲突标记没处理", isPresented: $confirm) {
            Button("照样使用", role: .destructive) { apply() }
        } message: {
            Text("文件里会留下 <<<<<<< 这样的标记。")
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let source = try await model.mergeSource(row)
            let order = snapshot.machineOrder
            guard let left = source.texts[order[0]], let right = source.texts[order[1]] else { return }
            let base = source.base ?? Merge.commonBase(left, right)
            if source.base == nil {
                note = "没有基线（两边从没一致过），按两边共有的行合并：只一边有的行都保留了，请检查一遍。"
            } else {
                note = "以上次两边一致时的内容为基线：只有一边改过的地方已自动合入。"
            }
            let result = Merge.merge(base: base, left: left, right: right,
                                     leftLabel: snapshot.badge(order[0]), rightLabel: snapshot.badge(order[1]))
            text = result.text
            loaded = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func apply() {
        let merged = text
        dismiss()
        Task { await model.useMerged(row, text: merged) }
    }
}

// MARK: - 启动项模板

/// 同名不同参的启动项：把两台不一样的值定义成变量，对账比模板，应用时按本机的值渲染
struct TemplateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let row: Row
    let snapshot: Snapshot
    @State private var vars: [EditableVar] = []
    @State private var loading = true

    struct EditableVar: Identifiable {
        let id = UUID()
        var name: String
        var values: [String: String]
    }

    private var label: String { row.name }

    var body: some View {
        let order = snapshot.machineOrder
        VStack(alignment: .leading, spacing: 12) {
            Text("模板：\(label)").font(.title3.weight(.semibold))
            Text("两台上这几个值不同，其余内容必须一样。对比时双方的值都换成 {{变量}}，所以只要模板一致就算同步好了；写入时按每台自己的值填回去。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("变量名")
                        ForEach(order, id: \.self) { Text(snapshot.badge($0)) }
                        Text("")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach($vars) { $v in
                        GridRow {
                            TextField("名字", text: $v.name).frame(width: 110)
                            ForEach(order, id: \.self) { m in
                                TextField("值", text: Binding(get: { v.values[m] ?? "" }, set: { v.values[m] = $0 }))
                                    .font(.callout.monospaced())
                            }
                            Button {
                                vars.removeAll { $0.id == v.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                Button {
                    vars.append(EditableVar(name: "var\(vars.count + 1)", values: [:]))
                } label: {
                    Label("加一个变量", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            Spacer()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存模板") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || vars.contains { $0.name.isEmpty || $0.name.contains(where: { !($0.isLetter || $0.isNumber || $0 == "_") }) })
            }
        }
        .padding(18)
        .frame(width: 820, height: 460)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        let order = snapshot.machineOrder
        let existing = snapshot.shared.templates[label] ?? []
        vars = existing.map { EditableVar(name: $0.name, values: $0.values) }
        // 从两边的差异里猜还没定义的变量
        guard case .text(let texts)? = try? await model.diffSource(row),
              let left = texts[order[0]] ?? nil, let right = texts[order[1]] ?? nil else { return }
        for (a, b) in Template.suggest(left: left, right: right) {
            vars.append(EditableVar(name: "var\(vars.count + 1)", values: [order[0]: a, order[1]: b]))
        }
    }

    private func save() {
        let result = vars.map { TemplateVar(name: $0.name, values: $0.values.filter { !$0.value.isEmpty }) }
        let label = label
        dismiss()
        Task { await model.updateShared { $0.templates[label] = result.isEmpty ? nil : result } }
    }
}
