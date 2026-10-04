import Foundation
import SwiftUI
import CryptoKit

struct RuntimeArtifact: Codable {
    let name: String
    let version: String
    let filename: String
    let url: String
    let sha256: String
    let size: Int64
    let kind: String
}
struct RuntimeLock: Decodable {
    let schema: Int
    let architecture: String
    let download_bytes: Int64
    let unpacked_bytes: Int64
    let artifacts: [RuntimeArtifact]
    var python: RuntimeArtifact? { artifacts.first { $0.kind == "python" } }
    var spaceRequired: Int64 { download_bytes + unpacked_bytes * 2 }
    func validate() throws {
        guard schema == 1, architecture == "arm64", download_bytes > 0, unpacked_bytes > 0,
              download_bytes < 100_000_000_000, unpacked_bytes < 100_000_000_000,
              artifacts.filter({ $0.kind == "python" }).count == 1,
              Set(artifacts.map(\.filename)).count == artifacts.count else { throw SetupFailure("Invalid runtime manifest.") }
        for artifact in artifacts {
            guard !artifact.filename.isEmpty, ![".", ".."].contains(artifact.filename),
                  !artifact.filename.contains("/"), artifact.size > 0, artifact.size < 100_000_000_000,
                  artifact.sha256.count == 64, artifact.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let url = URL(string: artifact.url), url.scheme == "https", url.query == nil, url.fragment == nil else {
                throw SetupFailure("Invalid runtime artifact metadata.")
            }
        }
        guard artifacts.reduce(Int64(0), { $0 + $1.size }) == download_bytes,
              let python, let url = URL(string: python.url), RuntimeDownloadPolicy.allows(url) else {
            throw SetupFailure("Invalid runtime download manifest.")
        }
    }
}
struct RuntimeSelection {
    let python: URL
    let managed: URL?
}

enum RuntimeFiles {
    static func storage(_ root: URL, _ relative: String = "") throws -> URL {
        let base = root.standardizedFileURL
        guard !base.resolvingSymlinksInPath().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
              (try? base.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw SetupFailure("Managed storage cannot be a symlink or inside an application bundle.")
        }
        var path = base
        for part in relative.split(separator: "/") {
            path.appendPathComponent(String(part))
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw SetupFailure("Managed storage contains an unexpected symlink. Choose a safe runtime location before retrying.")
            }
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path.path) {
            guard let type = attributes[.type] as? FileAttributeType,
                  type == .typeDirectory || type == .typeRegular,
                  type != .typeRegular || (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw SetupFailure("Managed storage contains an unexpected special file or hard link.")
            }
        }
        return path
    }
    static func prepareStorage(_ root: URL, resources: URL) throws {
        let canonical = root.resolvingSymlinksInPath().path
        let resourcePath = resources.resolvingSymlinksInPath().path
        guard canonical != resourcePath, !canonical.hasPrefix(resourcePath + "/") else { throw SetupFailure("Runtime cannot live in application resources.") }
        let fm = FileManager.default
        try fm.createDirectory(at: storage(root), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["downloads", "staging", "installations", "logs", "temporary", "cache", "cache/huggingface", "cache/numba", "cache/pip"] {
            try fm.createDirectory(at: storage(root, name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for name in ["logs/setup.log", "active.json", "state.json", "installation.lock"] { _ = try storage(root, name) }
    }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func valid(_ file: URL, artifact: RuntimeArtifact) -> Bool {
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == artifact.size else { return false }
        return (try? hash(file)) == artifact.sha256
    }
    static func active(_ root: URL, lockHash: String) throws -> RuntimeSelection {
        let active = try JSONSerialization.jsonObject(with: Data(contentsOf: storage(root, "active.json"))) as? [String: String]
        guard let relative = active?["installation"], active?["lock_sha256"] == lockHash,
              relative.hasPrefix("installations/"), relative.split(separator: "/").count == 2,
              !relative.contains("..") else { throw SetupFailure("Managed runtime needs repair.") }
        let folder = try storage(root, relative)
        let python = folder.appendingPathComponent("python/bin/python3").resolvingSymlinksInPath()
        guard python.path.hasPrefix(folder.path + "/") else { throw SetupFailure("Invalid runtime interpreter path.") }
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: storage(root, relative + "/installation.json"))) as? [String: Any]
        let files = receipt?["files"] as? [String: [String: Any]]
        let key = String(python.path.dropFirst(folder.path.count + 1))
        guard receipt?["state"] as? String == "READY", receipt?["lock_sha256"] as? String == lockHash,
              let expected = files?[key]?["sha256"] as? String, try hash(python) == expected else {
            throw SetupFailure("Runtime interpreter is missing or changed. Repair VoxAster Runtime.")
        }
        return RuntimeSelection(python: python, managed: folder)
    }
}
struct SetupFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Redirects are checked too: an allowed entry URL cannot redirect to an arbitrary host.
final class RuntimeDownloadPolicy: NSObject, URLSessionTaskDelegate {
    static let hosts: Set<String> = ["github.com", "release-assets.githubusercontent.com"]
    static func allows(_ url: URL) -> Bool {
        url.scheme == "https" && hosts.contains(url.host ?? "") && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allows) == true ? request : nil)
    }
}

final class RuntimeSetupController: ObservableObject {
    @Published var presented = false
    @Published var busy = false
    @Published var repair = false
    @Published var stage = "Set up VoxAster"
    @Published var message = "VoxAster needs to install its local voice runtime and models before first use."
    @Published var progress: Double = 0
    @Published var amount = ""
    @Published var manifest: RuntimeLock?
    var beforeInstall: (() -> Void)?
    var onReady: ((RuntimeSelection) -> Void)?
    let root: URL
    let resources: URL
    private var task: Task<Void, Never>?
    private let processLock = NSLock()
    private var child: Process?
    private var cancelled = false
    init(root: URL? = nil, resources: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmniVoice/managed-runtime/v1")
        self.resources = resources ?? Bundle.main.resourceURL ?? URL(fileURLWithPath: "/unavailable")
        if let lock = try? JSONDecoder().decode(RuntimeLock.self, from: Data(contentsOf: self.resources.appendingPathComponent("bootstrap-lock.json"))),
           (try? lock.validate()) != nil { manifest = lock }
    }
    var logURL: URL { root.appendingPathComponent("logs/setup.log") }
    var sizeDescription: String {
        guard let manifest else { return "Setup manifest unavailable. Download a complete VoxAster application." }
        func size(_ n: Int64) -> String { String(format: "%.2f GiB", Double(n) / 1_073_741_824) }
        return "Download: \(size(manifest.download_bytes)). Installed runtime: approximately 3.98 GiB, plus retained downloads. Setup checks for \(size(manifest.spaceRequired)) of free space for staging and installation."
    }
    func environment(selection: RuntimeSelection, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = PythonBackendLaunch.environment(from: inherited)
        if let folder = selection.managed {
            for key in Array(env.keys) where ["VIRTUAL_ENV", "__PYVENV_LAUNCHER__", "TAR_OPTIONS"].contains(key) || ["PYTHON", "PIP_", "DYLD_", "HF_", "HUGGINGFACE_", "TRANSFORMERS_", "XDG_", "NUMBA_"].contains(where: key.hasPrefix) { env.removeValue(forKey: key) }
            env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
            env["PYTHONUNBUFFERED"] = "1"
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            env["PYTHONNOUSERSITE"] = "1"
            env["HF_HUB_DISABLE_TELEMETRY"] = "1"
            env["COPYFILE_DISABLE"] = "1"
            env["PIP_CONFIG_FILE"] = "/dev/null"
            env["PIP_NO_INDEX"] = "1"
            env["PIP_NO_CACHE_DIR"] = "1"
            env["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
            env["DO_NOT_TRACK"] = "1"
            env["OMNIVOICE_MANAGED_ROOT"] = folder.path
            env["PATH"] = folder.appendingPathComponent("python/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            env["HF_HOME"] = root.appendingPathComponent("cache/huggingface").path
            env["NUMBA_CACHE_DIR"] = root.appendingPathComponent("cache/numba").path
            env["TMPDIR"] = root.appendingPathComponent("temporary").path
        }
        return env
    }
    private func execute(_ executable: URL, _ arguments: [String], selection: RuntimeSelection? = nil, events: Bool = false) throws {
        let fm = FileManager.default
        try RuntimeFiles.prepareStorage(root, resources: resources)
        try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
        try log.seekToEnd()
        let p = Process(); p.executableURL = executable; p.arguments = arguments
        p.currentDirectoryURL = root
        p.environment = environment(selection: selection ?? RuntimeSelection(python: executable, managed: root))
        p.standardError = log
        let pipe = Pipe()
        if events {
            p.standardOutput = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                guard !data.isEmpty else { return }
                // JSON lines can span reads; parsing is performed from the accumulated stream below.
                self?.receive(data)
            }
        } else { p.standardOutput = log }
        processLock.lock()
        if cancelled { processLock.unlock(); throw CancellationError() }
        child = p
        do { try p.run() } catch { child = nil; processLock.unlock(); throw error }
        processLock.unlock()
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        processLock.lock(); child = nil; let wasCancelled = cancelled; processLock.unlock()
        if wasCancelled { throw CancellationError() }
        eventLock.lock(); let detail = eventError; eventLock.unlock()
        guard p.terminationStatus == 0 else { throw SetupFailure(detail ?? "Setup or runtime validation failed. Open the setup log for details, then Retry or Repair. Your projects and voices are unchanged.") }
    }
    private var eventBuffer = Data()
    private var eventError: String?
    private let eventLock = NSLock()
    private func receive(_ data: Data) {
        eventLock.lock(); defer { eventLock.unlock() }
        eventBuffer.append(data)
        while let newline = eventBuffer.firstIndex(of: 10) {
            let line = eventBuffer[..<newline]; eventBuffer.removeSubrange(...newline)
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let error = value["error"] as? String { eventError = error }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stage = value["stage"] as? String ?? self.stage
                if let error = value["error"] as? String { self.message = error }
                if let done = value["completed"] as? Double, let total = value["total"] as? Double, total > 0 {
                    self.progress = min(done / total, 1)
                    self.amount = ByteCountFormatter.string(fromByteCount: Int64(done), countStyle: .binary) + " / " + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .binary)
                }
            }
        }
    }
    func inspect(legacy: URL) {
        busy = true; stage = "Checking local runtime"
        task = Task.detached { [weak self] in
            guard let self else { return }
            do {
                let selection: RuntimeSelection
                if FileManager.default.fileExists(atPath: self.root.appendingPathComponent("active.json").path) {
                    selection = try RuntimeFiles.active(self.root, lockHash: RuntimeFiles.hash(self.resources.appendingPathComponent("bootstrap-lock.json")))
                    try self.execute(selection.python, ["-B", self.resources.appendingPathComponent("bootstrap.py").path, "--root", self.root.path, "--resources", self.resources.path, "--verify"], selection: selection, events: true)
                } else if FileManager.default.isExecutableFile(atPath: legacy.path) {
                    selection = RuntimeSelection(python: legacy, managed: nil)
                    try self.execute(legacy, ["-B", self.resources.appendingPathComponent("runtime_check.py").path], selection: selection)
                } else { throw SetupFailure("Internet access is required for initial setup. Existing voices and projects will stay where they are.") }
                try Task.checkCancellation()
                await MainActor.run { self.busy = false; self.onReady?(selection) }
            } catch {
                await MainActor.run {
                    self.busy = false; self.presented = true
                    self.repair = FileManager.default.fileExists(atPath: self.root.appendingPathComponent("active.json").path)
                    self.stage = self.repair ? "Repair VoxAster Runtime" : "Set up VoxAster"
                    self.message = error.localizedDescription
                }
            }
        }
    }
    func cancel() {
        processLock.lock(); cancelled = true; let p = child; processLock.unlock()
        task?.cancel()
        if p?.isRunning == true { p?.terminate() }
    }
    func begin() {
        guard !busy, let manifest, let python = manifest.python else { return }
        beforeInstall?()
        eventLock.lock(); eventBuffer = Data(); eventError = nil; eventLock.unlock()
        processLock.lock(); cancelled = false; processLock.unlock()
        busy = true; progress = 0; amount = ""; stage = "Preparing runtime"
        message = "Verified downloads are retained if you cancel or retry."
        task = Task.detached { [weak self] in
            guard let self else { return }
            var stageURL: URL?
            do {
                #if !arch(arm64)
                throw SetupFailure("VoxAster requires an Apple Silicon Mac.")
                #endif
                let fm = FileManager.default
                try manifest.validate()
                try RuntimeFiles.prepareStorage(self.root, resources: self.resources)
                let free = (try fm.attributesOfFileSystem(forPath: self.root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                guard free >= manifest.spaceRequired else { throw SetupFailure("Not enough free storage for setup. " + self.sizeDescription) }
                let archive = try RuntimeFiles.storage(self.root, "downloads/" + python.filename)
                if !RuntimeFiles.valid(archive, artifact: python) {
                    guard let url = URL(string: python.url), RuntimeDownloadPolicy.allows(url) else { throw SetupFailure("Unapproved Python source.") }
                    let session = URLSession(configuration: .ephemeral, delegate: RuntimeDownloadPolicy(), delegateQueue: nil)
                    defer { session.invalidateAndCancel() }
                    let (temporary, response) = try await session.download(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, RuntimeFiles.valid(temporary, artifact: python) else { throw SetupFailure("Python download failed integrity verification. Retry to obtain a clean copy.") }
                    try Task.checkCancellation()
                    if fm.fileExists(atPath: archive.path) { try fm.removeItem(at: archive) }
                    try fm.moveItem(at: temporary, to: archive)
                }
                try Task.checkCancellation()
                let stage = self.root.appendingPathComponent("staging/" + UUID().uuidString); stageURL = stage
                try fm.createDirectory(at: stage, withIntermediateDirectories: false)
                // The exact upstream archive is SHA-256 verified before extraction/execution.
                try self.execute(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "--no-same-owner", "--no-same-permissions", "-C", stage.path])
                let interpreter = stage.appendingPathComponent("python/bin/python3")
                try self.execute(interpreter, ["-B", self.resources.appendingPathComponent("bootstrap.py").path, "--root", self.root.path, "--stage", stage.path, "--resources", self.resources.path], selection: RuntimeSelection(python: interpreter, managed: stage), events: true)
                let selection = try RuntimeFiles.active(self.root, lockHash: RuntimeFiles.hash(self.resources.appendingPathComponent("bootstrap-lock.json")))
                try Task.checkCancellation()
                await MainActor.run { self.busy = false; self.presented = false; self.stage = "Starting VoxAster"; self.onReady?(selection) }
            } catch {
                if let stageURL { try? FileManager.default.removeItem(at: stageURL) }
                await MainActor.run {
                    self.busy = false
                    self.stage = "Setup needs attention"
                    if error is CancellationError { self.message = "Setup cancelled. Verified downloads are retained. Retry when ready." }
                    else if (error as NSError).domain == NSURLErrorDomain { self.message = "Internet access is required to finish initial setup. Check your connection and retry." }
                    else { self.message = error.localizedDescription }
                }
            }
        }
    }
}

struct RuntimeSetupPresentation: View {
    @ObservedObject var setup: RuntimeSetupController
    @State private var understandsTerms = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0).sheet(isPresented: $setup.presented) {
            VStack(alignment: .leading, spacing: 16) {
                Text(setup.repair ? "Repair VoxAster Runtime" : "Set up VoxAster").font(.title2.bold())
                Text("VoxAster installs its local voice runtime and models in Application Support. Your voices, projects and drafts are kept separately.")
                Text(setup.sizeDescription).foregroundStyle(.secondary)
                Text(setup.stage).font(.headline)
                if setup.busy { ProgressView(value: setup.progress); Text(setup.amount).font(.caption.monospacedDigit()) }
                Text(setup.message).font(.callout)
                if !setup.busy {
                    Text("OmniVoice weights are restricted to non-commercial use (CC-BY-NC per the pinned model card). Models retain their own terms, including the Boson/Meta use restrictions and Boson's separate licence requirement above 100,000 annual active users. No training is included.").font(.caption)
                    HStack {
                        Link("OmniVoice model card", destination: URL(string: "https://huggingface.co/k2-fsa/OmniVoice/blob/c5fdb5ccb189668d56333f77ba2629f4cd7535f4/README.md")!)
                        Link("Boson terms", destination: URL(string: "https://huggingface.co/bosonai/higgs-audio-v2-tokenizer/blob/815a03f1b57dcb5ae918db415f22cd0c8a6f0f54/LICENSE")!)
                        Button("Included notices") { NSWorkspace.shared.open(setup.resources.appendingPathComponent("Notice")) }
                    }
                    Toggle("I have reviewed the model terms and am eligible to use these models.", isOn: $understandsTerms)
                }
                HStack {
                    Button("Open setup log") { NSWorkspace.shared.open(setup.logURL) }
                    Spacer()
                    Button(setup.busy ? "Cancel setup" : "Not now") { if setup.busy { setup.cancel() } else { setup.presented = false } }
                    if !setup.busy {
                        Button(setup.repair ? "Repair" : "Set Up / Retry") { setup.begin() }
                            .disabled(!understandsTerms || setup.manifest == nil).keyboardShortcut(.defaultAction)
                    }
                }
            }.padding(24).frame(width: 600).interactiveDismissDisabled(setup.busy)
        }
    }
}
