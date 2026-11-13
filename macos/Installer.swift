// AI Sound Design Installer: the window a Mac user installs and updates with.
//
// It shows what can be installed (the backend services, the web UI, the Pro Tools
// plugin, the sound database), what of it is installed, and whether GitHub has
// something newer:
//   backend services   the commit in ai-services/.mac/installed-from against ai-services main
//   web UI             the checked-out commit of .mac/src/ai-sound-webui against its main
//   Pro Tools plugin   the installed plugin's version against the newest release
//   this installer     its own version against the newest release of ai-sound-design/installer;
//                      it replaces itself with that one and starts again
// The work itself is done by install-components.sh in the app's Resources, whose
// output this shows as steps, a progress bar and a log.
//
// Built by build.sh beside it (swiftc, no Xcode project); a release of the repository
// builds it on GitHub (.github/workflows/release-macos.yml).

import AppKit
import SwiftUI

// MARK: - Where things are

enum Paths {
    static let env = ProcessInfo.processInfo.environment
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let base: URL = {
        if let custom = env["AISD_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return home.appendingPathComponent("AI Sound Design")
    }()
    static var services: URL { base.appendingPathComponent("ai-services") }
    static var choices: URL { base.appendingPathComponent(".installer-choices") }
    static var installedFrom: URL { services.appendingPathComponent(".mac/installed-from") }
    static var webuiSource: URL { services.appendingPathComponent(".mac/src/ai-sound-webui") }
    static let plugin = URL(fileURLWithPath: "/Library/Application Support/Avid/Audio/Plug-Ins/AI Sound Design.aaxplugin")
    static let installedApp = base.appendingPathComponent("AI Sound Design Installer.app")

    static let servicesRepo = env["AISD_SERVICES_REPO"] ?? "ai-sound-design/ai-services"
    static let servicesRef = env["AISD_SERVICES_REF"] ?? "main"
    static let webuiRepo = env["AISD_WEBUI_REPO"] ?? "ai-sound-design/ai-sound-webui"
    static let pluginRepo = env["AISD_PLUGIN_REPO"] ?? "ai-sound-design/ai-protools-aax"
    static let installerRepo = env["AISD_INSTALLER_REPO"] ?? "ai-sound-design/installer"
}

let installerVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

/// KEY=value lines (.env, installed-from)
func readKeyValues(_ url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
        var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.first == "\"", value.last == "\"" { value = String(value.dropFirst().dropLast()) }
        values[key] = value
    }
    return values
}

func readEnv() -> [String: String] { readKeyValues(Paths.services.appendingPathComponent(".env")) }

/// The folders macOS keeps background services out of
func protectedFolder(_ path: String) -> String? {
    let home = Paths.home.path
    for (folder, name) in [("Desktop", "Desktop"), ("Documents", "Documents"), ("Downloads", "Downloads"),
                           ("Library/Mobile Documents", "iCloud Drive")] {
        if path == "\(home)/\(folder)" || path.hasPrefix("\(home)/\(folder)/") { return name }
    }
    return nil
}

func shortPath(_ path: String) -> String {
    let home = Paths.home.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func isNewer(_ latest: String, than have: String) -> Bool {
    let clean = { (v: String) in v.hasPrefix("v") ? String(v.dropFirst()) : v }
    return clean(latest).compare(clean(have), options: .numeric) == .orderedDescending
}

// MARK: - GitHub

struct Commit {
    let sha: String
    let message: String
    let date: Date?
    var summary: String {
        let first = message.split(separator: "\n").first.map(String.init) ?? ""
        let short = first.count > 90 ? String(first.prefix(87)) + "…" : first
        guard let date else { return short }
        return "\(short) (\(date.formatted(date: .abbreviated, time: .omitted)))"
    }
}

struct Release {
    let tag: String
    let assets: [String: URL]
    var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
}

enum GitHub {
    static func json(_ path: String) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(path)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func latestCommit(_ repo: String, ref: String) async -> Commit? {
        guard let json = await json("\(repo)/commits/\(ref)"), let sha = json["sha"] as? String else { return nil }
        let commit = json["commit"] as? [String: Any]
        let date = ((commit?["committer"] as? [String: Any])?["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Commit(sha: sha, message: commit?["message"] as? String ?? "", date: date)
    }

    static func latestRelease(_ repo: String) async -> Release? {
        guard let json = await json("\(repo)/releases/latest"), let tag = json["tag_name"] as? String else { return nil }
        var assets: [String: URL] = [:]
        for asset in json["assets"] as? [[String: Any]] ?? [] {
            if let name = asset["name"] as? String, let link = asset["browser_download_url"] as? String, let url = URL(string: link) {
                assets[name] = url
            }
        }
        return Release(tag: tag, assets: assets)
    }
}

// MARK: - Model

enum Part: String, CaseIterable, Identifiable {
    case backend, webui, plugin, database
    var id: String { rawValue }
    var title: String {
        switch self {
        case .backend: return "Backend services"
        case .webui: return "Web UI"
        case .plugin: return "Pro Tools plugin (AAX)"
        case .database: return "Sound database"
        }
    }
}

/// What is installed of a part, and what GitHub has
enum Freshness: Equatable {
    case notInstalled
    case checking
    case upToDate
    case update(String)          // what is new
    case localChanges            // installed from a modified checkout: not compared
    case unknown(String)         // installed, but no comparison possible (why)
}

enum RunState { case waiting, running, done, failed, skipped }
enum Phase { case choose, running, succeeded, failed }

@MainActor
final class Model: ObservableObject {
    static var shared: Model?

    @Published var phase: Phase = .choose
    @Published var chosen: Set<Part> = []
    @Published var audio = false
    @Published var dataDir = ""
    @Published var sessionsDir = ""
    @Published var bbcArchive = ""
    @Published var ownSounds = ""

    @Published var backendInstalled = false
    @Published var webuiInstalled = false
    @Published var pluginInstalled: String?
    @Published var freshness: [Part: Freshness] = [:]
    @Published var databaseSounds: Int?
    @Published var databaseLoading = false
    @Published var checking = 0

    @Published var installerUpdate: Release?
    @Published var selfUpdating = false
    @Published var selfUpdateError: String?

    @Published var states: [Part: RunState] = [:]
    @Published var status = ""
    @Published var progress: Double?
    @Published var log: [String] = []
    @Published var showLog = false
    @Published var errorMessage: String?
    @Published var inDatabasePhase = false

    private var touched = false      // the user changed the selection: no more automatic ticks
    private var process: Process?
    private var logFile: FileHandle?
    private var buffer = [UInt8]()
    private var replaceLast = false
    private var runParts: [Part] = []

    init() { refresh() }

    // MARK: what is installed, what GitHub has

    func refresh() {
        let env = readEnv()
        let fm = FileManager.default
        backendInstalled = fm.fileExists(atPath: Paths.services.appendingPathComponent("mac/backend.py").path)
            && fm.fileExists(atPath: Paths.services.appendingPathComponent(".env").path)
        webuiInstalled = backendInstalled && env["MAC_WEBUI"] != "0"
            && fm.fileExists(atPath: Paths.webuiSource.appendingPathComponent("dist").path)
        pluginInstalled = NSDictionary(contentsOf: Paths.plugin.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String

        if backendInstalled {
            var data = env["AUDIO_HOST_DIR"].map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? ""
            if data.hasPrefix("./") || data.isEmpty || data == "." {
                data = Paths.services.appendingPathComponent(data.hasPrefix("./") ? String(data.dropFirst(2)) : "data").path
            }
            dataDir = data
        }
        if let sessions = env["WEBUI_SESSIONS_DIRS"], !sessions.isEmpty { sessionsDir = sessions }
        if let archive = env["BBC_ARCHIVE_HOST_DIR"], !archive.isEmpty, !archive.hasSuffix("/data/archive") { bbcArchive = archive }
        if let own = env["OWN_SOUNDS_HOST_DIR"], !own.isEmpty, !own.hasSuffix("/data/own-sounds") { ownSounds = own }

        freshness = [
            .backend: backendInstalled ? .checking : .notInstalled,
            .webui: webuiInstalled ? .checking : .notInstalled,
            .plugin: pluginInstalled != nil ? .checking : .notInstalled,
        ]
        applyDefaults()
        checkServices(env: env)
        checkWebUI(env: env)
        checkPlugin()
        checkDatabase(env: env)
        checkInstaller()
    }

    private func track(_ work: @escaping @MainActor () async -> Void) {
        checking += 1
        Task {
            await work()
            checking -= 1
            applyDefaults()
        }
    }

    private func checkServices(env: [String: String]) {
        guard backendInstalled else { return }
        let record = readKeyValues(Paths.installedFrom)
        track {
            if record["modified"] == "1" { self.freshness[.backend] = .localChanges; return }
            guard let have = record["commit"], !have.isEmpty else {
                self.freshness[.backend] = .unknown("installed version unknown"); return
            }
            guard let latest = await GitHub.latestCommit(Paths.servicesRepo, ref: record["ref"] ?? Paths.servicesRef) else {
                self.freshness[.backend] = .unknown("GitHub not reachable"); return
            }
            self.freshness[.backend] = latest.sha == have ? .upToDate : .update(latest.summary)
        }
    }

    private func checkWebUI(env: [String: String]) {
        guard webuiInstalled else { return }
        // The installation checks out a commit, detached: HEAD holds it
        let head = (try? String(contentsOf: Paths.webuiSource.appendingPathComponent(".git/HEAD"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let repo = env["WEBUI_REPO"].flatMap { url -> String? in
            guard url.contains("github.com/") else { return nil }
            return url.components(separatedBy: "github.com/").last?.replacingOccurrences(of: ".git", with: "")
        } ?? Paths.webuiRepo
        let ref = env["WEBUI_REF"].flatMap { $0.isEmpty ? nil : $0 } ?? "main"
        track {
            guard head.count == 40 else { self.freshness[.webui] = .unknown("installed version unknown"); return }
            guard let latest = await GitHub.latestCommit(repo, ref: ref) else {
                self.freshness[.webui] = .unknown("GitHub not reachable"); return
            }
            self.freshness[.webui] = latest.sha == head ? .upToDate : .update(latest.summary)
        }
    }

    private func checkPlugin() {
        let have = pluginInstalled
        track {
            guard let release = await GitHub.latestRelease(Paths.pluginRepo) else {
                self.freshness[.plugin] = have == nil ? .notInstalled : .unknown("GitHub not reachable"); return
            }
            self.pluginLatest = release.version
            guard let have else { self.freshness[.plugin] = .notInstalled; return }
            self.freshness[.plugin] = isNewer(release.version, than: have) ? .update("Version \(release.version)") : .upToDate
        }
    }
    @Published var pluginLatest: String?

    private func checkDatabase(env: [String: String]) {
        guard backendInstalled else { databaseSounds = nil; return }
        track {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(env["SETUP_PORT"] ?? "8020")/status")!)
            request.timeoutInterval = 8
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.databaseSounds = (json["search"] as? [String: Any])?["sounds"] as? Int
            self.databaseLoading = ((json["pipeline"] as? [String: Any])?["active"] as? Bool) ?? false
        }
    }

    private func checkInstaller() {
        // For testing the self-update without publishing: AISD_INSTALLER_UPDATE="<version> <zip URL>"
        // (a third word "now" starts it at once)
        if let fake = Paths.env["AISD_INSTALLER_UPDATE"]?.split(separator: " "), fake.count >= 2, let url = URL(string: String(fake[1])) {
            installerUpdate = Release(tag: String(fake[0]), assets: ["AI-Sound-Design-Installer-macOS.zip": url])
            if fake.count > 2 && fake[2] == "now" { updateInstaller() }
            return
        }
        track {
            guard let release = await GitHub.latestRelease(Paths.installerRepo),
                  isNewer(release.version, than: installerVersion),
                  release.assets.keys.contains(where: { $0.hasSuffix(".zip") }) else { return }
            self.installerUpdate = release
        }
    }

    func hasUpdate(_ part: Part) -> Bool {
        if case .update = freshness[part] { return true }
        return false
    }

    var updates: [Part] { Part.allCases.filter(hasUpdate) }

    /// Ticks what an update is there for (nothing installed yet: the services), and the
    /// database while it is still loading; until the user changes the selection
    private func applyDefaults() {
        guard !touched, phase == .choose else { return }
        var picked = Set(updates)
        if !backendInstalled && pluginInstalled == nil { picked.insert(.backend) }
        let remembered = (try? String(contentsOf: Paths.choices, encoding: .utf8)) ?? ""
        if databaseLoading || (remembered.contains("database") && backendInstalled && (databaseSounds ?? 0) == 0) {
            picked.insert(.database)
            audio = remembered.contains("audio")
        }
        chosen = picked
    }

    // The web UI is set up by the services' installer; the database needs the services
    var backendRequired: Bool {
        chosen.contains(.webui) || (!backendInstalled && chosen.contains(.database))
    }

    func isOn(_ part: Part) -> Binding<Bool> {
        Binding(get: { self.chosen.contains(part) || (part == .backend && self.backendRequired) },
                set: { on in
                    self.touched = true
                    if on { self.chosen.insert(part) } else { self.chosen.remove(part) }
                    if part == .database && !on { self.audio = false }
                })
    }

    var anyInstalled: Bool { backendInstalled || pluginInstalled != nil }
    var parts: [Part] { Part.allCases.filter { chosen.contains($0) || ($0 == .backend && backendRequired) } }

    var actionTitle: String {
        let chosenParts = parts
        if chosenParts.isEmpty { return anyInstalled ? "Update" : "Install" }
        let installs = chosenParts.contains { part in
            switch part {
            case .backend: return !backendInstalled
            case .webui: return !webuiInstalled
            case .plugin: return pluginInstalled == nil
            case .database: return false
            }
        }
        let refreshes = chosenParts.contains { [.backend, .webui, .plugin].contains($0) && !(
            ($0 == .backend && !backendInstalled) || ($0 == .webui && !webuiInstalled) || ($0 == .plugin && pluginInstalled == nil)) }
        return installs && refreshes ? "Install and Update" : installs ? "Install" : chosenParts == [.database] ? "Load" : "Update"
    }

    // MARK: updating the installer itself

    func updateInstaller() {
        guard let release = installerUpdate,
              let zip = release.assets.first(where: { $0.key.hasSuffix(".zip") })?.value else { return }
        selfUpdating = true
        selfUpdateError = nil
        Task {
            do {
                let (download, _) = try await URLSession.shared.download(from: zip)
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("ai-sound-installer-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try run("/usr/bin/ditto", ["-x", "-k", download.path, work.path])
                guard let app = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else { throw InstallerError("the download holds no app") }
                _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
                // In place when the running copy may be replaced; a copy run from a download
                // (macOS runs it from a hidden read-only place) is replaced by the one in ~/AI Sound Design
                let me = Bundle.main.bundleURL
                let inPlace = !me.path.contains("/AppTranslocation/")
                    && FileManager.default.isWritableFile(atPath: me.deletingLastPathComponent().path)
                let target = inPlace ? me : Paths.installedApp
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
                } else {
                    try FileManager.default.moveItem(at: app, to: target)
                }
                try? FileManager.default.removeItem(at: work)
                try run("/usr/bin/open", ["-n", target.path])
                NSApp.terminate(nil)
            } catch {
                selfUpdating = false
                selfUpdateError = "The installer could not update itself: \(error.localizedDescription)"
            }
        }
    }

    // MARK: running install-components.sh

    func start() {
        runParts = parts
        guard !runParts.isEmpty else { return }
        states = Dictionary(uniqueKeysWithValues: runParts.map { ($0, RunState.waiting) })
        log = []
        showLog = true
        status = "Starting"
        progress = nil
        errorMessage = nil
        inDatabasePhase = false
        phase = .running
        try? FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
        let remembered = runParts.map(\.rawValue) + (audio && runParts.contains(.database) ? ["audio"] : [])
        try? (remembered.joined(separator: " ") + "\n").write(to: Paths.choices, atomically: true, encoding: .utf8)
        // The whole output also in ~/AI Sound Design/installer.log, for when something needs explaining
        let logURL = Paths.base.appendingPathComponent("installer.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logFile = try? FileHandle(forWritingTo: logURL)
        logFile?.write("AI Sound Design Installer \(installerVersion): \(remembered.joined(separator: " "))\n".data(using: .utf8)!)

        let resources = Bundle.main.resourceURL!
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [resources.appendingPathComponent("install-components.sh").path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["AISD_GUI"] = "1"
        env["AISD_HOME"] = Paths.base.path
        env["AISD_COMPONENTS"] = remembered.joined(separator: " ")
        env["SUDO_ASKPASS"] = resources.appendingPathComponent("askpass.sh").path
        env["AISD_ICON"] = resources.appendingPathComponent("AppIcon.icns").path   // for the app "AI Sound Design"
        env["PYTHONUNBUFFERED"] = "1"
        let folders = ["AISD_DATA_DIR": backendInstalled ? "" : dataDir, "AISD_SESSIONS_DIR": sessionsDir,
                       "AISD_BBC_ARCHIVE": bbcArchive, "AISD_OWN_SOUNDS": ownSounds]
        for (key, value) in folders where !value.isEmpty { env[key] = value }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { Model.shared?.consume(data) }
        }
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                Model.shared?.ended(code: code)
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            errorMessage = "The installer could not start: \(error.localizedDescription)"
            phase = .failed
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        // The script and everything it started (pip, curl, the database monitor)
        for pid in descendants(of: process.processIdentifier).reversed() { kill(pid, SIGTERM) }
        process.terminate()
    }

    private func descendants(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let out = Pipe()
        pgrep.standardOutput = out
        try? pgrep.run()
        pgrep.waitUntilExit()
        let children = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { pid_t($0) }
        return children + children.flatMap { descendants(of: $0) }
    }

    var isRunning: Bool { process?.isRunning ?? false }

    private func ended(code: Int32) {
        process = nil
        flushBuffer()
        try? logFile?.close()
        logFile = nil
        if code == 0 {
            for part in runParts where states[part] != .done && states[part] != .skipped { states[part] = .done }
            phase = .succeeded
            status = ""
            copySelf()
        } else {
            for part in runParts where states[part] == .running { states[part] = .failed }
            if errorMessage == nil { errorMessage = "The installation stopped. The details below say where." }
            showLog = true
            phase = .failed
        }
        touched = false
        refresh()
    }

    /// The installer beside the installation, to update and add parts later; without the
    /// quarantine mark of the download, so it opens without Gatekeeper asking again
    private func copySelf() {
        let me = Bundle.main.bundleURL
        guard me.standardizedFileURL != Paths.installedApp.standardizedFileURL,
              FileManager.default.fileExists(atPath: Paths.base.path) else { return }
        try? FileManager.default.removeItem(at: Paths.installedApp)
        guard (try? FileManager.default.copyItem(at: me, to: Paths.installedApp)) != nil else { return }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", Paths.installedApp.path])
    }

    // MARK: output

    private func consume(_ data: Data) {
        logFile?.write(data)
        for byte in data {
            if byte == 10 || byte == 13 {
                emit(String(decoding: buffer, as: UTF8.self), carriageReturn: byte == 13)
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }
    }

    private func flushBuffer() {
        if !buffer.isEmpty { emit(String(decoding: buffer, as: UTF8.self), carriageReturn: false) }
        buffer.removeAll()
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")
    private static let percent = try! NSRegularExpression(pattern: "(\\d{1,3}(?:\\.\\d+)?)%")

    private func emit(_ raw: String, carriageReturn: Bool) {
        let line = Model.ansi.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        defer { replaceLast = carriageReturn }
        if line.hasPrefix("@@") {
            command(String(line.dropFirst(2)))
            return
        }
        if line.trimmingCharacters(in: .whitespaces).isEmpty && !replaceLast { return }
        if replaceLast, !log.isEmpty { log[log.count - 1] = line } else { log.append(line) }
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("== ") {
            status = String(trimmed.dropFirst(3))
            progress = nil
        } else if carriageReturn || replaceLast || trimmed.contains("%|"),
                  let match = Model.percent.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line), let value = Double(line[range]), value <= 100 {
            progress = value / 100
        }
    }

    /// @@step <part> <running|done|failed|skipped>, @@status <text>, @@progress <0-100|->, @@error <text>
    private func command(_ text: String) {
        let words = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = words.first else { return }
        let rest = words.count > 1 ? words[1] : ""
        switch verb {
        case "step":
            let args = rest.split(separator: " ").map(String.init)
            guard args.count >= 2, let part = Part(rawValue: args[0]) else { return }
            states[part] = ["running": .running, "done": .done, "failed": .failed, "skipped": .skipped][args[1]] ?? .waiting
            if args[1] == "running" {
                status = part.title
                progress = nil
                inDatabasePhase = part == .database
            }
        case "status":
            status = rest
        case "progress":
            progress = Double(rest).map { min(max($0 / 100, 0), 1) }
        case "error":
            // The first one says what went wrong; later ones only that it stopped
            if errorMessage == nil { errorMessage = rest }
        default:
            break
        }
    }
}

struct InstallerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 { throw InstallerError("\(tool) failed (\(process.terminationStatus))") }
    return process.terminationStatus
}

// MARK: - Views

struct Header: View {
    var title: String
    var subtitle: String
    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

struct Badge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct ComponentCard<Extra: View>: View {
    @Binding var isOn: Bool
    var disabled = false
    var symbol: String
    var title: String
    var badges: [(String, Color)]
    var detail: String
    var news: String?
    var warning: String? = nil
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(disabled)
                .padding(.top, 2)
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    ForEach(badges, id: \.0) { Badge(text: $0.0, color: $0.1) }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let news {
                    Label(news, systemImage: "arrow.down.circle")
                        .font(.callout)
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isOn ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor)))
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { isOn.toggle() } }
    }
}

extension ComponentCard where Extra == EmptyView {
    init(isOn: Binding<Bool>, disabled: Bool = false, symbol: String, title: String, badges: [(String, Color)],
         detail: String, news: String? = nil) {
        self.init(isOn: isOn, disabled: disabled, symbol: symbol, title: title, badges: badges, detail: detail, news: news) { EmptyView() }
    }
}

struct FolderRow: View {
    var label: String
    @Binding var path: String
    var placeholder: String
    var enabled = true
    var help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label).frame(width: 170, alignment: .leading)
                Text(path.isEmpty ? placeholder : shortPath(path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .help(path)
                Spacer()
                if enabled && !path.isEmpty {
                    Button { path = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Use the default")
                }
                Button("Choose…") { choose() }.disabled(!enabled)
            }
            if let protected = protectedFolder(path) {
                Text("This folder is in \(protected), which macOS keeps background services out of. Choose one elsewhere.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = label
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

struct InstallerUpdateBanner: View {
    @EnvironmentObject var model: Model
    var release: Release

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill").font(.system(size: 22)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("A new installer is available: \(release.version)").font(.headline)
                Text(model.selfUpdateError ?? "This one is \(installerVersion). It updates itself and opens again.")
                    .font(.callout)
                    .foregroundStyle(model.selfUpdateError == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.selfUpdating {
                ProgressView().controlSize(.small)
            } else {
                Button("Update Installer") { model.updateInstaller() }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.12)))
    }
}

struct ChooseView: View {
    @EnvironmentObject var model: Model
    @State private var showFolders = false

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "AI Sound Design", subtitle: subtitle)
                .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let release = model.installerUpdate {
                        InstallerUpdateBanner(release: release)
                    }
                    ComponentCard(isOn: model.isOn(.backend), disabled: model.backendRequired, symbol: "cpu",
                                  title: "Backend services", badges: badges(.backend),
                                  detail: "Generation, search, spotting and Hybrid, running on this Mac's GPU. About 35 GB on disk (22 GB of that are models); the first installation takes 30 to 60 minutes.",
                                  news: news(.backend))
                    ComponentCard(isOn: model.isOn(.webui), symbol: "safari", title: "Web UI", badges: badges(.webui),
                                  detail: "The four modes in the browser, without Pro Tools; opened with the app AI Sound Design. About 1 GB.",
                                  news: news(.webui))
                    ComponentCard(isOn: model.isOn(.plugin), symbol: "slider.horizontal.3", title: "Pro Tools plugin (AAX)",
                                  badges: badges(.plugin),
                                  detail: "The newest release from GitHub, for Pro Tools. macOS asks for this Mac's password to install it. About 200 MB.",
                                  news: news(.plugin), warning: pluginWarning)
                    ComponentCard(isOn: model.isOn(.database), symbol: "waveform.badge.magnifyingglass",
                                  title: "Sound database", badges: databaseBadges,
                                  detail: "The BBC Sound Effects archive's index (about 33,000 sounds), so the services find sounds by video or prompt; about 1 GB. Free for personal, educational and research use under the BBC's terms.") {
                        Toggle(isOn: $model.audio) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Also download all of its audio and build the audio index")
                                Text("About 60 GB of audio plus 10 GB of index, and several hours. Needed for the search by sound and Hybrid's library pieces; not with an existing archive folder (below).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!model.chosen.contains(.database))
                        .padding(.top, 6)
                    }
                    DisclosureGroup(isExpanded: $showFolders) {
                        VStack(alignment: .leading, spacing: 14) {
                            FolderRow(label: "Data folder", path: $model.dataDir,
                                      placeholder: shortPath(Paths.services.appendingPathComponent("data").path),
                                      enabled: !model.backendInstalled,
                                      help: model.backendInstalled ? "Set at the first installation."
                                          : "Database, models (about 22 GB) and downloaded audio (60 GB more with the full archive).")
                            FolderRow(label: "Pro Tools sessions", path: $model.sessionsDir, placeholder: "<data folder>/sessions",
                                      help: "Where the web UI finds sessions (.ptx), read-only.")
                            FolderRow(label: "Existing BBC archive", path: $model.bbcArchive, placeholder: "None",
                                      help: "A copy of the archive on disk (<id>.wav or .mp3), used instead of downloading it.")
                            FolderRow(label: "Your own sounds", path: $model.ownSounds, placeholder: "None",
                                      help: "A folder of your own sounds, indexed read-only.")
                        }
                        .padding(.top, 10)
                        .padding(.leading, 4)
                    } label: {
                        Text("Folders").font(.headline)
                    }
                    .padding(.top, 6)
                }
                .padding(24)
            }
            Divider()
            HStack(spacing: 10) {
                if model.checking > 0 {
                    ProgressView().controlSize(.small)
                    Text("Looking for updates on GitHub…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Installer \(installerVersion) · Apple Silicon, macOS 14 or newer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { NSApp.terminate(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(model.actionTitle) { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.parts.isEmpty || model.selfUpdating)
            }
            .padding(16)
        }
    }

    private var subtitle: String {
        if !model.anyInstalled { return "Choose what to install on this Mac." }
        if model.checking > 0 { return "Looking for updates…" }
        let updates = model.updates
        if updates.isEmpty { return "Everything installed is up to date. Tick what you want to add." }
        return "Updates are available for: \(updates.map(\.title).joined(separator: ", ")). They are ticked."
    }

    private func badges(_ part: Part) -> [(String, Color)] {
        if part == .backend && model.backendRequired && !model.backendInstalled { return [("Needed by your choice", .orange)] }
        let installed: String? = {
            switch part {
            case .plugin: return model.pluginInstalled.map { "\($0) installed" }
            case .backend: return model.backendInstalled ? "Installed" : nil
            case .webui: return model.webuiInstalled ? "Installed" : nil
            case .database: return nil
            }
        }()
        var result: [(String, Color)] = []
        switch model.freshness[part] ?? .notInstalled {
        case .notInstalled:
            if part == .plugin, let latest = model.pluginLatest { result.append(("Version \(latest)", .secondary)) }
        case .checking: result.append((installed ?? "Installed", .green))
        case .upToDate: result.append((installed ?? "Installed", .green)); result.append(("Up to date", .green))
        case .update: result.append((installed ?? "Installed", .green)); result.append(("Update available", .blue))
        case .localChanges: result.append((installed ?? "Installed", .green)); result.append(("Local changes", .orange))
        case .unknown(let why): result.append((installed ?? "Installed", .green)); result.append((why.prefix(1).uppercased() + why.dropFirst(), .orange))
        }
        if part == .backend && model.backendRequired && model.backendInstalled { result.append(("Updated with the web UI", .secondary)) }
        return result
    }

    private func news(_ part: Part) -> String? {
        if case .update(let what) = model.freshness[part] { return "New: \(what)" }
        return nil
    }

    /// The plugin alone does nothing: it talks to the backend services
    private var pluginWarning: String? {
        guard model.chosen.contains(.plugin), !model.backendInstalled, !model.chosen.contains(.backend), !model.backendRequired else { return nil }
        return "Needs the backend services, which are neither installed nor chosen. Tick them as well, unless the plugin is to use a backend on another computer (set in its Settings)."
    }

    private var databaseBadges: [(String, Color)] {
        if model.databaseLoading { return [("Loading", .blue)] }
        if let sounds = model.databaseSounds, sounds > 0 { return [("\(sounds.formatted()) sounds", .green)] }
        return []
    }
}

struct StateIcon: View {
    var state: RunState
    var body: some View {
        Group {
            switch state {
            case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .running: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 16))
        .frame(width: 20, height: 20)
    }
}

struct LogView: View {
    var lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .textSelection(.enabled)
                .padding(8)
            }
            .onChange(of: lines.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct ProgressScreen: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            Header(title: title, subtitle: subtitle).padding(24)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                // Steps, status and messages keep their height; the log gets what is left
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.states.keys).sorted { $0.rank < $1.rank }) { part in
                            HStack(spacing: 10) {
                                StateIcon(state: model.states[part] ?? .waiting)
                                Text(part.title)
                                Spacer()
                                Text(stateText(part)).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if model.phase == .running {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.status.isEmpty ? " " : model.status)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.callout)
                            if let value = model.progress {
                                ProgressView(value: value)
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                        }
                    }
                    if model.inDatabasePhase && model.phase == .running {
                        Label("This window can be closed: the sound database keeps loading in the background and carries on after a restart. Opening the installer again shows where it is.",
                              systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = model.errorMessage, model.phase == .failed {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { model.showLog.toggle() }
                } label: {
                    Label("Details", systemImage: model.showLog ? "chevron.down" : "chevron.right")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                if model.showLog {
                    LogView(lines: model.log)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(-1)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(24)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            HStack {
                if model.phase == .running {
                    Text("macOS may ask for this Mac's password.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                buttons
            }
            .padding(16)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.phase {
        case .running:
            if model.inDatabasePhase {
                Button("Close") { NSApp.terminate(nil) }
            } else {
                Button("Stop") { confirmStop() }
            }
        case .succeeded:
            Button("Show in Finder") { NSWorkspace.shared.open(Paths.base) }
            if model.webuiInstalled {
                Button("Open Web UI") {
                    NSWorkspace.shared.open(URL(string: "http://localhost:\(readEnv()["WEBUI_PORT"] ?? "8030")/")!)
                }
            }
            Button("Done") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
        case .failed:
            Button("Back") { model.phase = .choose }
            Button("Close") { NSApp.terminate(nil) }
            Button("Try Again") { model.start() }.keyboardShortcut(.defaultAction)
        case .choose:
            EmptyView()
        }
    }

    private var title: String {
        switch model.phase {
        case .succeeded: return "AI Sound Design is ready"
        case .failed: return "The installation stopped"
        default: return "Installing AI Sound Design"
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .succeeded:
            return model.webuiInstalled
                ? "The web UI opens with the app \"AI Sound Design\" (Launchpad, Spotlight, Applications)."
                : "Everything chosen is installed. Run the installer again to update or add parts."
        case .failed: return "What is done stays done: Try Again carries on from there."
        default: return "This can take a while the first time: several GB are downloaded."
        }
    }

    private func stateText(_ part: Part) -> String {
        switch model.states[part] ?? .waiting {
        case .waiting: return "Waiting"
        case .running: return "In progress"
        case .done: return "Done"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }

    private func confirmStop() {
        let alert = NSAlert()
        alert.messageText = "Stop the installation?"
        alert.informativeText = "What is done stays; running the installer again carries on from there."
        alert.addButton(withTitle: "Keep Installing")
        alert.addButton(withTitle: "Stop")
        if alert.runModal() == .alertSecondButtonReturn { model.stop() }
    }
}

extension Part {
    var rank: Int { Part.allCases.firstIndex(of: self) ?? 0 }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Group {
            if model.phase == .choose { ChooseView() } else { ProgressScreen() }
        }
        .frame(width: 660, height: 740)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // For checking the layout without a screen recording permission:
    // AISD_SNAPSHOT=<file.png> writes the window into the file and quits
    // (AISD_SNAPSHOT_PHASE=running|succeeded|failed shows that screen with sample content)
    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["AISD_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["AISD_SNAPSHOT_DELAY"] ?? "") ?? 6)) {
            if let model = Model.shared, let phase = env["AISD_SNAPSHOT_PHASE"] {
                model.states = [.backend: .done, .webui: .done, .plugin: .running, .database: .waiting]
                model.status = "Downloading the plugin v0.1.1"
                model.progress = 0.42
                model.log = (1...2000).map { "   line \($0) of a long installation log: Collecting torch==2.5.1" }
                model.showLog = true
                model.phase = ["running": .running, "succeeded": .succeeded, "failed": .failed][phase] ?? .choose
                if model.phase == .failed { model.errorMessage = "The plugin download failed; try again." }
                if model.phase == .succeeded { model.states = [.backend: .done, .webui: .done, .plugin: .done, .database: .done] }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Model.shared, model.isRunning, !model.inDatabasePhase else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "The installation is still running."
        alert.informativeText = "Quitting stops it. What is done stays; running the installer again carries on from there."
        alert.addButton(withTitle: "Keep Installing")
        alert.addButton(withTitle: "Stop and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.stop()
        return .terminateNow
    }
}

@main
struct InstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: Model

    init() {
        let model = Model()
        Model.shared = model
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        Window("AI Sound Design Installer", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
