@testable import SyncKit
import XCTest

final class ScopeTests: XCTestCase {
    private let base = SharedConfig(
        files: ["~/.zshrc"],
        dirs: [DirSpec(path: "~/.claude/skills", ignore: [".git"])],
        handlers: ["json"], equivalentApps: [],
        prefs: [PrefSpec(domain: "com.a", ignore: ["Tmp*"]), PrefSpec(domain: "com.b", keys: ["Only"])],
        launchAgents: true, templates: [:], secretFiles: [], noiseKeys: [], ignored: []
    )

    func testRuleCoversWhatScanningCovers() {
        let scope = Scope(base)
        XCTAssertNotNil(scope.rule(for: "file:~/.zshrc"))
        XCTAssertNotNil(scope.rule(for: "file:~/.claude/skills/README.md"))
        XCTAssertNotNil(scope.rule(for: "dir:~/.claude/skills/foo"))
        XCTAssertNil(scope.rule(for: "dir:~/.claude/skills/.git"))
        XCTAssertNil(scope.rule(for: "file:~/.other"))
        XCTAssertNotNil(scope.rule(for: "pref:com.a#Theme"))
        XCTAssertNil(scope.rule(for: "pref:com.a#TmpPath"))
        XCTAssertNil(scope.rule(for: "pref:com.a#NSWindow Frame Main"))
        XCTAssertNotNil(scope.rule(for: "pref:com.b#Only"))
        XCTAssertNil(scope.rule(for: "pref:com.b#Other"))
        XCTAssertNil(scope.rule(for: "pref:com.c#Theme"))
        XCTAssertNotNil(scope.rule(for: "handler:json"))
        XCTAssertNotNil(scope.rule(for: "agent:x"))
    }

    /// 本机加了忽略规则：对面旧状态里的这个键不再归清单管，不能被当成「本机删了」推过去
    func testNewIgnoreTakesKeyOutOfScope() {
        var changed = base
        changed.prefs[0].ignore.append("Theme")
        XCTAssertNotNil(Scope(base).rule(for: "pref:com.a#Theme"))
        XCTAssertNil(Scope(changed).rule(for: "pref:com.a#Theme"))
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
        XCTAssertEqual(old.rule(for: "pref:com.a#Theme"), new.rule(for: "pref:com.a#Theme"))
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
