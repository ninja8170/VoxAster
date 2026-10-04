import Foundation

extension Phase1Tests {
    static func runtimeSetupTests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxaster-setup-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture")
        try Data("verified".utf8).write(to: file)
        let artifact = RuntimeArtifact(name: "test", version: "1", filename: "fixture", url: "https://github.com/a/b", sha256: try RuntimeFiles.hash(file), size: 8, kind: "python")
        check(RuntimeFiles.valid(file, artifact: artifact), "runtime artifact SHA and size accepted")
        try Data("corrupt!".utf8).write(to: file)
        check(!RuntimeFiles.valid(file, artifact: artifact), "runtime equal-size corruption rejected")
        check(!RuntimeFiles.valid(root.appendingPathComponent("missing"), artifact: artifact), "missing runtime triggers setup")
        for url in ["http://github.com/a", "https://github.com.evil.test/a", "https://" + "user:pass" + "@" + "github.com/a", "https://github.com:444/a", "file:///tmp/python"] {
            check(!RuntimeDownloadPolicy.allows(URL(string:url)!), "unapproved runtime URL rejected")
        }
        check(RuntimeDownloadPolicy.allows(URL(string:"https://release-assets.githubusercontent.com/a")!), "approved release redirect allowed")
        let setup = RuntimeSetupController(root: root, resources: root)
        check(setup.manifest == nil, "incomplete application cannot offer downloads")
        let selection = RuntimeSelection(python: root.appendingPathComponent("python/bin/python3"), managed: root)
        let env = setup.environment(selection: selection)
        check(env["PATH"] == root.appendingPathComponent("python/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin", "managed runtime excludes Homebrew and developer shell paths")
        check(env["PYTHONDONTWRITEBYTECODE"] == "1" && env["PYTHONNOUSERSITE"] == "1", "managed runtime disables bytecode and user-site packages")
        check(env["OMNIVOICE_MANAGED_ROOT"] == root.path, "managed model root forwarded")
        check(env["HF_HOME"]!.hasPrefix(root.path), "managed caches outside bundle")
        let folder = root.appendingPathComponent("installations/good")
        let python = folder.appendingPathComponent("python/bin/python3")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("interpreter".utf8).write(to: python)
        let receipt: [String:Any] = ["state":"READY","lock_sha256":"lock","files":["python/bin/python3":["sha256":try RuntimeFiles.hash(python)]]]
        try JSONSerialization.data(withJSONObject:receipt).write(to:folder.appendingPathComponent("installation.json"))
        try JSONSerialization.data(withJSONObject:["installation":"installations/good","lock_sha256":"lock"]).write(to:root.appendingPathComponent("active.json"))
        let active = try RuntimeFiles.active(root, lockHash:"lock")
        check(active.python == python, "validated managed interpreter selected")
        check((try? RuntimeFiles.active(root, lockHash:"different")) == nil, "different runtime lock rejected")
        try Data("bad interpreter".utf8).write(to:python)
        check((try? RuntimeFiles.active(root, lockHash:"lock")) == nil, "corrupt interpreter rejected before execution")
        try JSONSerialization.data(withJSONObject:["installation":"installations/../escape","lock_sha256":"lock"]).write(to:root.appendingPathComponent("active.json"))
        check((try? RuntimeFiles.active(root, lockHash:"lock")) == nil, "unsafe activation path rejected")

        let outside = root.appendingPathComponent("outside"); try Data("keep".utf8).write(to: outside)
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("setup.log"), withDestinationURL: outside)
        check((try? RuntimeFiles.storage(root, "logs/setup.log")) == nil, "setup rejects redirected log writes")
        check((try? RuntimeFiles.storage(root, "../outside")) == nil, "setup rejects parent traversal")
        check((try? RuntimeFiles.storage(root.appendingPathComponent("Fixture.app/Contents/Other"))) == nil, "setup rejects any bundle-local storage")
        let injected = ["PYTHONINSPECT":"1", "PYTHONPYCACHEPREFIX":"/unexpected", "HF_HUB_CACHE":"/unexpected", "__PYVENV_LAUNCHER__":"/unexpected", "TAR_OPTIONS":"--absolute-paths"]
        let cleanEnv = setup.environment(selection: selection, inherited: injected)
        check(injected.keys.allSatisfy { cleanEnv[$0] == nil }, "managed launch strips inherited interpreter, archive and cache overrides")
        check(cleanEnv["PYTHONDONTWRITEBYTECODE"] == "1", "bytecode prevention restored after environment sanitization")
        let manifest = RuntimeLock(schema: 1, architecture: "arm64", download_bytes: 8, unpacked_bytes: 16, artifacts: [artifact])
        check((try? manifest.validate()) != nil, "valid native manifest accepted")
        let invalid = RuntimeArtifact(name: "test", version: "1", filename: "../escape", url: artifact.url, sha256: artifact.sha256, size: 8, kind: "python")
        check((try? RuntimeLock(schema: 1, architecture: "arm64", download_bytes: 8, unpacked_bytes: 16, artifacts: [invalid]).validate()) == nil, "native manifest rejects traversal before download")
        check(setup.sizeDescription.contains("unavailable"), "missing lock has actionable storage message")
    }
}
