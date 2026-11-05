import Foundation

/// 自写的 Myers 差分：行级对齐成左右两栏，成对改动的行再做字符级高亮
public enum TextDiff {
    enum Edit: Equatable {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// 编辑距离超过这个值就放弃精确对齐，整段算删除 + 新增（避免巨大文件吃光内存）
    static let maxEditDistance = 4000

    /// Myers O(ND)：返回把 a 变成 b 的最短编辑脚本
    static func edits<T: Equatable>(_ a: [T], _ b: [T]) -> [Edit] {
        let n = a.count, m = b.count
        let maxD = min(n + m, maxEditDistance)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false

        search: for d in 0...maxD {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]))
                    ? v[k + 1 + offset] : v[k - 1 + offset] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[k + offset] = x
                if x >= n, y >= m {
                    found = true
                    break search
                }
            }
        }
        guard found else {
            return (0..<n).map { .delete($0) } + (0..<m).map { .insert($0) }
        }

        var result: [Edit] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK = (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) ? k + 1 : k - 1
            let prevX = v[prevK + offset]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                result.append(.equal(x - 1, y - 1))
                x -= 1
                y -= 1
            }
            if d > 0 {
                result.append(x == prevX ? .insert(y - 1) : .delete(x - 1))
            }
            x = prevX
            y = prevY
        }
        return result.reversed()
    }

    // MARK: 左右两栏

    public struct Cell: Sendable, Equatable {
        public let number: Int
        public let text: String
        /// 本行里被改动的字符范围（按 Character 下标）
        public let marks: [Range<Int>]
    }

    public enum RowKind: Sendable, Equatable {
        case same, changed, removed, added
        /// 折叠起来的相同行
        case fold(Int)
    }

    public struct SideRow: Sendable, Identifiable, Equatable {
        public let id: Int
        public let kind: RowKind
        public let left: Cell?
        public let right: Cell?
    }

    public struct Result: Sendable {
        public let rows: [SideRow]
        public let added: Int
        public let removed: Int
    }

    /// context：改动前后各保留几行相同内容，其余折叠；nil 表示全部展开
    public static func sideBySide(_ left: String, _ right: String, context: Int? = 3) -> Result {
        let a = lines(left), b = lines(right)
        let script = edits(a, b)

        var raw: [(RowKind, Cell?, Cell?)] = []
        var added = 0, removed = 0
        var dels: [Int] = [], ins: [Int] = []

        func flush() {
            for i in 0..<max(dels.count, ins.count) {
                let l = i < dels.count ? dels[i] : nil
                let r = i < ins.count ? ins[i] : nil
                if let l, let r {
                    let (lm, rm) = charMarks(a[l], b[r])
                    raw.append((.changed, Cell(number: l + 1, text: a[l], marks: lm), Cell(number: r + 1, text: b[r], marks: rm)))
                } else if let l {
                    raw.append((.removed, Cell(number: l + 1, text: a[l], marks: []), nil))
                } else if let r {
                    raw.append((.added, nil, Cell(number: r + 1, text: b[r], marks: [])))
                }
            }
            removed += dels.count
            added += ins.count
            dels = []
            ins = []
        }

        for edit in script {
            switch edit {
            case .equal(let i, let j):
                flush()
                raw.append((.same, Cell(number: i + 1, text: a[i], marks: []), Cell(number: j + 1, text: b[j], marks: [])))
            case .delete(let i): dels.append(i)
            case .insert(let j): ins.append(j)
            }
        }
        flush()

        return Result(rows: fold(raw, context: context), added: added, removed: removed)
    }

    private static func fold(_ raw: [(RowKind, Cell?, Cell?)], context: Int?) -> [SideRow] {
        var rows: [SideRow] = []
        guard let context else {
            for (i, r) in raw.enumerated() { rows.append(SideRow(id: i, kind: r.0, left: r.1, right: r.2)) }
            return rows
        }
        // 标出离改动 context 行以内的相同行
        var keep = [Bool](repeating: false, count: raw.count)
        for (i, r) in raw.enumerated() where r.0 != .same {
            for j in max(0, i - context)...min(raw.count - 1, i + context) { keep[j] = true }
        }
        var i = 0
        while i < raw.count {
            if raw[i].0 != .same || keep[i] {
                rows.append(SideRow(id: i, kind: raw[i].0, left: raw[i].1, right: raw[i].2))
                i += 1
            } else {
                var j = i
                while j < raw.count, raw[j].0 == .same, !keep[j] { j += 1 }
                rows.append(SideRow(id: i, kind: .fold(j - i), left: nil, right: nil))
                i = j
            }
        }
        return rows
    }

    /// 一对改动行的字符级差异：左边被删的字符、右边新增的字符
    static func charMarks(_ left: String, _ right: String) -> ([Range<Int>], [Range<Int>]) {
        let a = Array(left), b = Array(right)
        guard a.count + b.count < 4000 else { return ([0..<a.count], [0..<b.count]) }
        var lm: [Range<Int>] = [], rm: [Range<Int>] = []
        for edit in edits(a, b) {
            switch edit {
            case .equal: break
            case .delete(let i): append(&lm, i)
            case .insert(let j): append(&rm, j)
            }
        }
        return (lm, rm)
    }

    private static func append(_ ranges: inout [Range<Int>], _ index: Int) {
        if let last = ranges.last, last.upperBound == index {
            ranges[ranges.count - 1] = last.lowerBound..<(index + 1)
        } else {
            ranges.append(index..<(index + 1))
        }
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
