@testable import SyncKit
import XCTest

final class ScopeTests: XCTestCase {
    private let base = SharedConfig(
        files: ["~/.zshrc"],
        dirs: [DirSpec(path: "~/.claude/skills", ignore: [".git"])],
        handlers: ["json"], equivalentApps: [],
        launchAgents: true, templates: [:], secretFiles: [], ignored: []
    )

    func testRuleCoversWhatScanningCovers() {
        let scope = Scope(base)
        XCTAssertNotNil(scope.rule(for: "file:~/.zshrc"))
        XCTAssertNotNil(scope.rule(for: "file:~/.claude/skills/README.md"))
        XCTAssertNotNil(scope.rule(for: "dir:~/.claude/skills/foo"))
        XCTAssertNil(scope.rule(for: "dir:~/.claude/skills/.git"))
        XCTAssertNil(scope.rule(for: "file:~/.other"))
        XCTAssertNotNil(scope.rule(for: "handler:json"))
        XCTAssertNotNil(scope.rule(for: "agent:x"))
    }

    /// 清单没写 .git 也不归它管：版本库元数据永远排除
    func testVersionControlDirNeverInScope() {
        var config = base
        config.dirs = [DirSpec(path: "~/.config/zsh", ignore: ["local.zsh"])]
        let scope = Scope(config)
        XCTAssertNil(scope.rule(for: "dir:~/.config/zsh/.git"))
        XCTAssertNil(scope.rule(for: "file:~/.config/zsh/.git"))
        XCTAssertNotNil(scope.rule(for: "dir:~/.config/zsh/bin"))
    }

    /// 规则变了的条目两台算出来不同，对面的值要当成未知
    func testChangedRulesDiffer() {
        var changed = base
        changed.dirs[0].ignore.append("node_modules")
        changed.files.append("~/.gitconfig")
        changed.templates["x"] = [TemplateVar(name: "port", values: ["home": "1", "work": "2"])]
        let old = Scope(base), new = Scope(changed)
        XCTAssertNotEqual(old.rule(for: "dir:~/.claude/skills/foo"), new.rule(for: "dir:~/.claude/skills/foo"))
        XCTAssertNotEqual(old.rule(for: "file:~/.gitconfig"), new.rule(for: "file:~/.gitconfig"))
        XCTAssertNotEqual(old.rule(for: "agent:x"), new.rule(for: "agent:x"))
        XCTAssertEqual(old.rule(for: "file:~/.zshrc"), new.rule(for: "file:~/.zshrc"))
    }

    func testOldStateDocDecodesWithoutScope() throws {
        let doc = try JSON.decode(StateDoc.self, Data(#"{"machine":"home","publishedAt":"2026-11-06T00:00:00Z","items":{}}"#.utf8))
        XCTAssertNil(doc.scope)
    }

    /// 设置页保存只带走自己改的字段，对面期间加的确认差异、忽略不会被盖掉
    func testSettingsEditKeepsPeerChanges() {
        let original = base
        var edited = original
        edited.files.append("~/.gitconfig")
        var latest = original
        latest.acknowledged["file:~/.zshrc"] = "sig"
        latest.ignored.append("agent:foo")
        latest.apply(edits: edited, from: original)
        XCTAssertEqual(latest.files, ["~/.zshrc", "~/.gitconfig"])
        XCTAssertEqual(latest.acknowledged["file:~/.zshrc"], "sig")
        XCTAssertEqual(latest.ignored, ["agent:foo"])
    }
}
