import SyncKit
import XCTest

final class ReconcilerTests: XCTestCase {
    private func s(_ fp: String?) -> ItemState { ItemState(fp: fp, summary: "") }

    func testOnlyOneSideChanged() {
        let r = Reconciler.reconcile(local: ["a": s("2"), "b": s("1")], peer: ["a": s("1"), "b": s("3")],
                                     base: ["a": "1", "b": "1"], pending: [])
        XCTAssertEqual(r.diffs["a"], .onlyLocal)
        XCTAssertEqual(r.diffs["b"], .onlyPeer)
    }

    func testBothChangedIsConflict() {
        let r = Reconciler.reconcile(local: ["a": s("2")], peer: ["a": s("3")], base: ["a": "1"], pending: [])
        XCTAssertEqual(r.diffs["a"], .conflict)
    }

    func testNoBaseIsFirstTime() {
        let r = Reconciler.reconcile(local: ["a": s("2")], peer: ["a": s("3")], base: [:], pending: [])
        XCTAssertEqual(r.diffs["a"], .firstTime)
    }

    func testEqualUpdatesBase() {
        let r = Reconciler.reconcile(local: ["a": s("2")], peer: ["a": s("2")], base: ["a": "1"], pending: [])
        XCTAssertTrue(r.diffs.isEmpty)
        XCTAssertEqual(r.converged, ["a": "2"])
    }

    func testMissingOnOneSideIsAbsent() {
        let r = Reconciler.reconcile(local: ["a": s("1")], peer: [:], base: ["a": "1"], pending: [])
        XCTAssertEqual(r.diffs["a"], .onlyPeer)  // 对面删掉了
        let added = Reconciler.reconcile(local: ["n": s("1")], peer: ["m": s("2")], base: [:], pending: [])
        XCTAssertEqual(added.diffs["n"], .onlyLocal)  // 没有基线、只本机有 → 本机新增
        XCTAssertEqual(added.diffs["m"], .onlyPeer)
    }

    func testPendingDecisionIsWaiting() {
        let r = Reconciler.reconcile(local: ["a": s("2")], peer: ["a": s("1")], base: ["a": "1"], pending: ["a"])
        XCTAssertEqual(r.diffs["a"], .waitingPeer)
    }
}
