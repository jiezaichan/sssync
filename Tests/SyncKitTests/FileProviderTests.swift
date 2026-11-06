@testable import SyncKit
import XCTest

final class FileProviderTests: XCTestCase {
    private var root: URL!
    private var blobs: BlobStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "sssync-provider-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        blobs = BlobStore(dir: root.appending(path: "blobs"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func provider(ignore: [String] = []) -> FileProvider {
        let config = SharedConfig(
            files: [], dirs: [DirSpec(path: root.path(percentEncoded: false), ignore: ignore)],
            handlers: [], equivalentApps: [], launchAgents: false, templates: [:],
            secretFiles: [], ignored: []
        )
        return FileProvider(config: config, blobs: blobs)
    }

    private func write(_ text: String, to path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// 顶层 .git 不生成条目，清单不写 ignore 也一样
    func testTopLevelGitNotScanned() throws {
        try write("ref: refs/heads/master", to: ".git/HEAD")
        try write("export PATH=$PATH:/x", to: "env.zsh")
        var refs = Set<String>()
        let items = try provider().scanAll(refs: &refs)
        XCTAssertNil(items["dir:\(root.path(percentEncoded: false))/.git"])
        XCTAssertNil(items["file:\(root.path(percentEncoded: false))/.git"])
        XCTAssertNotNil(items["file:\(root.path(percentEncoded: false))/env.zsh"])
    }

    /// 子目录里的 .git 不进目录清单
    func testNestedGitExcludedFromManifest() throws {
        try write("ref: refs/heads/master", to: "bin/.git/HEAD")
        try write("#!/bin/sh\n", to: "bin/tool")
        var refs = Set<String>()
        let items = try provider().scanAll(refs: &refs)
        guard let state = items["dir:\(root.path(percentEncoded: false))/bin"], let fp = state.fp else {
            return XCTFail("没有扫到 bin")
        }
        XCTAssertEqual(Set(try provider().manifest(fp).keys), ["tool"])
    }
}
