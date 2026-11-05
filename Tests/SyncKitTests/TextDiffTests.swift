@testable import SyncKit
import XCTest

final class TextDiffTests: XCTestCase {
    func testIdentical() {
        let r = TextDiff.sideBySide("a\nb\nc\n", "a\nb\nc\n", context: nil)
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(r.removed, 0)
        XCTAssertTrue(r.rows.allSatisfy { $0.kind == .same })
    }

    func testInsertAndDelete() {
        let r = TextDiff.sideBySide("a\nb\nc\n", "a\nc\nd\n", context: nil)
        XCTAssertEqual(r.removed, 1)
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.rows.map(\.kind), [.same, .removed, .same, .added])
        XCTAssertEqual(r.rows[1].left?.text, "b")
        XCTAssertEqual(r.rows[3].right?.number, 3)
    }

    func testChangedLineHasCharMarks() {
        let r = TextDiff.sideBySide("let port = 22022\n", "let port = 22023\n", context: nil)
        XCTAssertEqual(r.rows.map(\.kind), [.changed])
        XCTAssertEqual(r.rows[0].left?.marks, [15..<16])
        XCTAssertEqual(r.rows[0].right?.marks, [15..<16])
    }

    func testChineseCharMarks() {
        let (l, rr) = TextDiff.charMarks("所有回复使用中文", "所有回复优先用中文")
        XCTAssertFalse(l.isEmpty)
        XCTAssertFalse(rr.isEmpty)
    }

    func testFoldsLongUnchangedRuns() {
        let same = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let r = TextDiff.sideBySide(same + "\nold\n", same + "\nnew\n", context: 2)
        XCTAssertEqual(r.rows.first?.kind, .fold(18))
        XCTAssertEqual(r.rows.last?.kind, .changed)
    }

    func testAgainstEmpty() {
        let r = TextDiff.sideBySide("", "x\ny\n")
        XCTAssertEqual(r.added, 2)
        XCTAssertEqual(r.rows.map(\.kind), [.added, .added])
    }
}
