@testable import SyncKit
import XCTest

final class MergeTests: XCTestCase {
    func testNonOverlappingChangesMergeCleanly() {
        let base = "a\nb\nc\nd\n"
        let r = Merge.merge(base: base, left: "A\nb\nc\nd\n", right: "a\nb\nc\nD\n", leftLabel: "L", rightLabel: "R")
        XCTAssertEqual(r.conflicts, 0)
        XCTAssertEqual(r.text, "A\nb\nc\nD\n")
    }

    func testSameChangeOnBothSides() {
        let r = Merge.merge(base: "a\nb\n", left: "a\nX\n", right: "a\nX\n", leftLabel: "L", rightLabel: "R")
        XCTAssertEqual(r.conflicts, 0)
        XCTAssertEqual(r.text, "a\nX\n")
    }

    func testConflictGetsMarkers() {
        let r = Merge.merge(base: "a\nb\nc\n", left: "a\nL\nc\n", right: "a\nR\nc\n", leftLabel: "🏠", rightLabel: "🏢")
        XCTAssertEqual(r.conflicts, 1)
        XCTAssertEqual(r.text, "a\n<<<<<<< 🏠\nL\n=======\nR\n>>>>>>> 🏢\nc\n")
        XCTAssertEqual(Merge.remainingConflicts(r.text), 1)
    }

    func testAdditionsAtEnds() {
        let r = Merge.merge(base: "m\n", left: "top\nm\n", right: "m\nbottom\n", leftLabel: "L", rightLabel: "R")
        XCTAssertEqual(r.conflicts, 0)
        XCTAssertEqual(r.text, "top\nm\nbottom\n")
    }

    func testCommonBaseKeepsOneSidedLines() {
        let left = "a\nonly-left\nb\n", right = "a\nb\nonly-right\n"
        let r = Merge.merge(base: Merge.commonBase(left, right), left: left, right: right, leftLabel: "L", rightLabel: "R")
        XCTAssertEqual(r.conflicts, 0)
        XCTAssertEqual(r.text, "a\nonly-left\nb\nonly-right\n")
    }
}

final class TemplateTests: XCTestCase {
    let vars = [
        TemplateVar(name: "key", values: ["home": "/k/id_rtunnel_home", "work": "/k/id_rtunnel"]),
        TemplateVar(name: "port", values: ["home": "127.0.0.1:22023", "work": "127.0.0.1:22022"]),
    ]

    func testBothMachinesProduceSameTemplate() throws {
        let home = "<string>/k/id_rtunnel_home</string>\n<string>127.0.0.1:22023:localhost:22</string>"
        let work = "<string>/k/id_rtunnel</string>\n<string>127.0.0.1:22022:localhost:22</string>"
        let t1 = Template.templatize(home, vars: vars, machine: "home")
        let t2 = Template.templatize(work, vars: vars, machine: "work")
        XCTAssertEqual(t1, t2)
        XCTAssertEqual(try Template.render(t1, vars: vars, machine: "work"), work)
        XCTAssertEqual(try Template.render(t1, vars: vars, machine: "home"), home)
    }

    func testRenderFailsWithoutValue() {
        XCTAssertThrowsError(try Template.render("{{key}}", vars: [TemplateVar(name: "key", values: ["home": "x"])], machine: "work"))
        XCTAssertThrowsError(try Template.render("{{nope}}", vars: [], machine: "work"))
    }

    func testSuggestTakesWholeTagValue() {
        let s = Template.suggest(left: "<a>\n\t<string>/k/id_rtunnel_home</string>\n</a>", right: "<a>\n\t<string>/k/id_rtunnel</string>\n</a>")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.0, "/k/id_rtunnel_home")
        XCTAssertEqual(s.first?.1, "/k/id_rtunnel")
    }
}

final class SupportTests: XCTestCase {
    func testGlob() {
        XCTAssertTrue(Glob.match("*.zwc", "zshrc.zwc"))
        XCTAssertTrue(Glob.match("agent:com.google.*", "agent:com.google.keystone.agent"))
        XCTAssertFalse(Glob.match("NSWindow Frame *", "HotKeys"))
        XCTAssertTrue(SharedConfig.standard.isSecret("~/.config/zsh/secrets.zsh"))
        XCTAssertFalse(SharedConfig.standard.isSecret("~/.config/zsh/env.zsh"))
    }

    func testSecretsMask() {
        let masked = Secrets.mask("# 注释\nexport OPENAI_KEY=\"sk-123\"\nTOKEN=abc\nsource x.zsh")
        let lines = masked.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "# 注释")
        XCTAssertFalse(masked.contains("sk-123"))
        XCTAssertFalse(masked.contains("abc"))
        XCTAssertTrue(lines[1].hasPrefix("export OPENAI_KEY= ••••"))
        XCTAssertEqual(lines[3], "source x.zsh")
        // 值相同，打码也相同
        XCTAssertEqual(Secrets.masked("sk-123"), Secrets.masked("sk-123"))
    }

    func testSharedConfigDecodesOldFileWithDefaults() throws {
        let shared = try JSON.decode(SharedConfig.self, Data(#"{"files": ["~/a"]}"#.utf8))
        XCTAssertEqual(shared.files, ["~/a"])
        XCTAssertEqual(shared.noiseKeys, SharedConfig.standard.noiseKeys)
    }

    func testParseSectionsDropsBanner() {
        let s = ReportCollector.parseSections("欢迎\n@@A\n1\n2\n@@B\n@@END\n")
        XCTAssertNil(s["欢迎"])
        XCTAssertEqual(s["A"], ["1", "2"])
        XCTAssertEqual(s["B"], [])
    }
}

final class EnvCompareTests: XCTestCase {
    func report(node: [String: [String: String]], formulae: [String: String], apps: [AppInfo] = [],
                env: [String: String] = ["A": "1"], path: [String] = ["/bin"],
                localEnv: [String]? = nil, localPath: [String]? = nil) -> MachineReport {
        MachineReport(collectedAt: Date(), macOS: "27.2", tools: ["git": "2.54"],
                      node: NodeReport(nvm: "0.40", versions: ["22.23.3"], defaultVersion: "22.23.3", globals: node),
                      pythons: [], uvTools: [:], formulae: formulae, casks: [:], env: env, path: path,
                      apps: apps, errors: [], localEnv: localEnv, localPath: localPath)
    }

    func testGlobalPackagesComparedByPackageNotNodeDir() {
        let home = report(node: ["pnpm": ["20.19.5": "9.0.0"]], formulae: [:])
        let work = report(node: ["pnpm": ["22.23.3": "9.0.0"]], formulae: [:])
        let sections = EnvCompare.environment(["home": home, "work": work], machines: ["home", "work"])
        let row = sections.first { $0.id == "npm" }!.rows.first!
        XCTAssertTrue(row.same)
        XCTAssertNotNil(row.note)
    }

    func testMissingFormulaGetsInstallOnlyWhereMissing() {
        let home = report(node: [:], formulae: ["jq": "1.7"])
        let work = report(node: [:], formulae: [:])
        let row = EnvCompare.environment(["home": home, "work": work], machines: ["home", "work"])
            .first { $0.id == "brew" }!.rows.first!
        XCTAssertFalse(row.same)
        XCTAssertNil(row.fixes["home"])
        XCTAssertEqual(row.fixes["work"], .run("brew install jq"))
        XCTAssertEqual(row.removals["home"], .run("brew uninstall jq"))
        XCTAssertNil(row.removals["work"])
    }

    func testBothHaveDifferentVersionsNoRemoval() {
        let home = report(node: [:], formulae: ["jq": "1.7"])
        let work = report(node: [:], formulae: ["jq": "1.6"])
        let row = EnvCompare.environment(["home": home, "work": work], machines: ["home", "work"])
            .first { $0.id == "brew" }!.rows.first!
        XCTAssertTrue(row.removals.isEmpty)
        XCTAssertEqual(row.fixes["work"], .run("brew upgrade jq"))
    }

    func testAppFromStoreOpensStore() {
        let app = AppInfo(bundleID: "im.manico.Manico", name: "Manico", version: "3.9", source: .appStore, cask: nil, storeID: "724472954", path: "/Applications/Manico.app")
        let home = report(node: [:], formulae: [:], apps: [app])
        let work = report(node: [:], formulae: [:])
        let row = EnvCompare.apps(["home": home, "work": work], machines: ["home", "work"]).first!.rows.first!
        XCTAssertEqual(row.fixes["work"], .open("macappstore://apps.apple.com/app/id724472954"))
        XCTAssertEqual(row.removals["home"], .trash(path: "/Applications/Manico.app", bundleID: "im.manico.Manico"))
    }

    func testLocalEnvVarMarkedLocalOnly() {
        let home = report(node: [:], formulae: [:])
        let work = report(node: [:], formulae: [:], env: ["A": "1", "GITLAB_TOKEN": "x"], localEnv: ["GITLAB_TOKEN"])
        let row = EnvCompare.environment(["home": home, "work": work], machines: ["home", "work"])
            .first { $0.id == "env" }!.rows.first { $0.name == "GITLAB_TOKEN" }!
        XCTAssertTrue(row.localOnly)
        XCTAssertFalse(row.same)
    }

    func testLocalEnvNamesIgnoresMultilineAndPath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString).zsh")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        # export COMMENTED=1
        export ADB_MDNS=0
        export JENKINS_JOBS="
        node = cwork_release_xg-node
        all = n k
        "
        . "$HOME/.local/bin/env"
        export PATH="$HOME/bin:$PATH"
        export GITLAB3_TOKEN=abc
        (( $#_om_cft )) && export OM_CHROME="$_om_cft[1]"
        """.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ReportCollector.localEnvNames(at: url.path), ["ADB_MDNS", "GITLAB3_TOKEN", "JENKINS_JOBS", "OM_CHROME"])
    }

    func testPathOrderDifferenceIsNotADiff() {
        let home = report(node: [:], formulae: [:], path: ["/a", "/bin"], localPath: ["/a"])
        let work = report(node: [:], formulae: [:], path: ["/bin"])
        let rows = EnvCompare.environment(["home": home, "work": work], machines: ["home", "work"])
            .first { $0.id == "path" }!.rows
        XCTAssertTrue(rows.first { $0.name == "/bin" }!.same)
        let only = rows.first { $0.name == "/a" }!
        XCTAssertFalse(only.same)
        XCTAssertTrue(only.localOnly)
    }

    func testLocalPathEntriesExpandsHomeAndSkipsPATH() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString).zsh")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        export PATH="$HOME/bin:$PATH"
        export PATH="/opt/foo/bin:${PATH}"
        (( $#x )) && export PATH="$HOME/.local/bin:$PATH"
        export PATH='$HOME/quoted/bin:$PATH'
        export PATH="$(brew --prefix)/bin:$PATH"
        """.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ReportCollector.localPathEntries(at: url.path),
                       [NSHomeDirectory() + "/bin", "/opt/foo/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/quoted/bin"])
        // PATH 不算环境变量那一栏的「本机专属」，它自己那一段处理
        XCTAssertEqual(ReportCollector.localEnvNames(at: url.path), [])
    }
}
