import Foundation

/// 三方合并（diff3）：以基线为参照，只有一边改的块直接取改的那边，两边改得不一样才标冲突
public enum Merge {
    public struct Result: Sendable, Equatable {
        public let text: String
        public let conflicts: Int
    }

    public static let startMarker = "<<<<<<< "
    public static let middleMarker = "======="
    public static let endMarker = ">>>>>>> "

    public static func merge(base: String, left: String, right: String, leftLabel: String, rightLabel: String) -> Result {
        let b = split(base), l = split(left), r = split(right)
        let ml = matches(b, l), mr = matches(b, r)
        var out: [String] = []
        var conflicts = 0
        var i = 0, a = 0, c = 0
        while true {
            // 三边都对得上的稳定行，原样输出
            while i < b.count, ml[i] == a, mr[i] == c {
                out.append(b[i])
                i += 1; a += 1; c += 1
            }
            if i >= b.count, a >= l.count, c >= r.count { break }
            // 下一个稳定行之前是一个改动块
            var j = i
            while j < b.count, ml[j] == nil || mr[j] == nil { j += 1 }
            let aEnd = j < b.count ? ml[j]! : l.count
            let cEnd = j < b.count ? mr[j]! : r.count
            let baseChunk = Array(b[i..<j]), leftChunk = Array(l[a..<aEnd]), rightChunk = Array(r[c..<cEnd])
            if leftChunk == baseChunk {
                out += rightChunk
            } else if rightChunk == baseChunk || leftChunk == rightChunk {
                out += leftChunk
            } else {
                conflicts += 1
                out.append(startMarker + leftLabel)
                out += leftChunk
                out.append(middleMarker)
                out += rightChunk
                out.append(endMarker + rightLabel)
            }
            i = j; a = aEnd; c = cEnd
        }
        return Result(text: out.joined(separator: "\n"), conflicts: conflicts)
    }

    /// 没有基线时，拿两边共有的行当基线：只一边有的行会被保留，两边在同一处写得不一样才是冲突
    public static func commonBase(_ left: String, _ right: String) -> String {
        let l = split(left), r = split(right)
        var out: [String] = []
        for edit in TextDiff.edits(l, r) {
            if case .equal(let i, _) = edit { out.append(l[i]) }
        }
        return out.joined(separator: "\n")
    }

    /// 文本里还剩几处冲突标记
    public static func remainingConflicts(_ text: String) -> Int {
        split(text).filter { $0.hasPrefix(startMarker) }.count
    }

    static func split(_ text: String) -> [String] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// 基线每一行在另一边对应的行号（没对上为 nil）
    static func matches(_ base: [String], _ other: [String]) -> [Int?] {
        var out = [Int?](repeating: nil, count: base.count)
        for edit in TextDiff.edits(base, other) {
            if case .equal(let i, let j) = edit { out[i] = j }
        }
        return out
    }
}
