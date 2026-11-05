import Foundation

public enum DiffStatus: String, Sendable, Equatable {
    case onlyLocal, onlyPeer, conflict, firstTime, waitingPeer
}

public struct Reconciliation: Sendable, Equatable {
    public var diffs: [String: DiffStatus] = [:]
    /// 两边已经一致、但基线还不是这个值的条目 → 应写入的基线
    public var converged: [String: String] = [:]
}

public enum Reconciler {
    /// 三方对账：本机现状、对面最近发布的状态、基线。某边没有记录的条目按「不存在」处理。
    public static func reconcile(
        local: [String: ItemState],
        peer: [String: ItemState],
        base: [String: String],
        pending: Set<String>
    ) -> Reconciliation {
        var result = Reconciliation()
        for id in Set(local.keys).union(peer.keys) {
            let l = local[id]?.fpOrAbsent ?? absentFP
            let p = peer[id]?.fpOrAbsent ?? absentFP
            let b = base[id]
            if l == p {
                if b != l { result.converged[id] = l }
                continue
            }
            if pending.contains(id) {
                result.diffs[id] = .waitingPeer
                continue
            }
            // 没有基线：只有一边有，算那边新增；两边都有且不同，才是首次冲突
            guard let b else {
                result.diffs[id] = p == absentFP ? .onlyLocal : l == absentFP ? .onlyPeer : .firstTime
                continue
            }
            if l != b && p == b {
                result.diffs[id] = .onlyLocal
            } else if p != b && l == b {
                result.diffs[id] = .onlyPeer
            } else {
                result.diffs[id] = .conflict
            }
        }
        return result
    }
}
