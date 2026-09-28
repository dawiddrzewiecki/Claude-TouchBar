import Foundation
import ClaudeBarCore
import notify

final class ClaudeMonitor {
    var onChange: ((BarModel) -> Void)?
    var window: TimeInterval = 5 * 3600 { didSet { rebuild() } }

    private struct RegistryEntry: Decodable {
        var pid: Int32
        var sessionId: String?
        var cwd: String?
        var status: String?
        var statusUpdatedAt: Double?
        var updatedAt: Double?
        var startedAt: Double?
    }

    private struct BasicState {
        var busy: Bool
        var since: Date
        var turnStart: Date?
        var lastDuration: TimeInterval?
        var completedAt: Date?
    }

    private var stream: FSEventStreamRef?
    private var exitSources: [Int32: DispatchSourceProcess] = [:]
    private var basic: [Int32: BasicState] = [:]
    private var reloadScheduled = false
    private var timeWork: DispatchWorkItem?
    private var last: BarModel?
    private var records: [SessionRecord] = []
    private var registry: [RegistryEntry] = []
    private var usage: UsageRecord?
    private var ordered: [BarModel] = []
    private var pinned: String?
    private var pinnedAt: Date?
    private var metas: [String: SessionMeta] = [:]
    private var requests: [String: PendingRequest] = [:]
    private var answered = Set<String>()
    private var firstSeen: [String: Date] = [:]
    private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID
    private let git = GitInspector()
    private let topics = TopicReader()
    static let pinDuration: TimeInterval = 5 * 60

    static let completedDecay: TimeInterval = 12 * 60

    init() {
        git.onUpdate = { [weak self] in self?.rebuild() }
    }

    func start() {
        Store.ensureDirectories()
        startStream()
        notify_register_dispatch(Store.changeNotification, &notifyToken, .main) { [weak self] _ in self?.reload() }
        reload()
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        if notifyToken != NOTIFY_TOKEN_INVALID { notify_cancel(notifyToken) }
        notifyToken = NOTIFY_TOKEN_INVALID
        exitSources.values.forEach { $0.cancel() }
        exitSources = [:]
        timeWork?.cancel()
    }

    func respond(_ response: RequestResponse) {
        answered.insert(response.id)
        Store.write(response, to: Store.responseFile(response.id))
        notify_post(Store.responseNotification)
        rebuild()
    }

    func cycleSession(_ delta: Int) {
        guard ordered.count > 1 else { return }
        let current = ordered.firstIndex { $0.sessionId == (pinned ?? last?.sessionId) } ?? 0
        let next = current + delta
        guard next >= 0, next < ordered.count else { return }
        pinned = ordered[next].sessionId
        pinnedAt = Date()
        rebuild()
    }

    private func startStream() {
        let paths = [Store.supportDirectory.path, Store.claudeSessionsDirectory.path] as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ClaudeMonitor>.fromOpaque(info).takeUnretainedValue().scheduleReload()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    private func reload() {
        let fm = FileManager.default
        let sessionFiles = (try? fm.contentsOfDirectory(at: Store.sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        records = sessionFiles.filter { $0.pathExtension == "json" }.compactMap { Store.read(SessionRecord.self, from: $0) }

        let registryFiles = (try? fm.contentsOfDirectory(at: Store.claudeSessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        registry = registryFiles.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(RegistryEntry.self, from: data)
        }.filter { isAlive($0.pid) }

        usage = Store.read(UsageRecord.self, from: Store.usageFile)
        let requestFiles = (try? fm.contentsOfDirectory(at: Store.requestsDirectory, includingPropertiesForKeys: nil)) ?? []
        var byRequestSession: [String: PendingRequest] = [:]
        for file in requestFiles where !file.lastPathComponent.hasSuffix(".response.json") {
            guard let r = Store.read(PendingRequest.self, from: file), !answered.contains(r.id) else { continue }
            if (byRequestSession[r.sessionId]?.createdAt ?? .distantPast) < r.createdAt { byRequestSession[r.sessionId] = r }
        }
        requests = byRequestSession
        let metaFiles = (try? fm.contentsOfDirectory(at: Store.metaDirectory, includingPropertiesForKeys: nil)) ?? []
        metas = Dictionary(metaFiles.compactMap { Store.read(SessionMeta.self, from: $0) }.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        trackBasicTurns()
        watchExits()
        cleanUpDeadRecords()
        rebuild()
    }

    private func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    private func watchExits() {
        let pids = Set(registry.map(\.pid) + records.compactMap(\.claudePid).filter(isAlive))
        for (pid, source) in exitSources where !pids.contains(pid) {
            source.cancel()
            exitSources[pid] = nil
        }
        for pid in pids where exitSources[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                self?.exitSources[pid]?.cancel()
                self?.exitSources[pid] = nil
                self?.basic[pid] = nil
                self?.reload()
            }
            source.resume()
            exitSources[pid] = source
        }
    }

    private func cleanUpDeadRecords() {
        let now = Date()
        for r in records {
            let dead = r.claudePid.map { !isAlive($0) } ?? (now.timeIntervalSince(r.updatedAt) > 6 * 3600)
            if dead && now.timeIntervalSince(r.updatedAt) > 30 {
                try? FileManager.default.removeItem(at: Store.sessionFile(r.sessionId))
                try? FileManager.default.removeItem(at: Store.metaFile(r.sessionId))
            }
        }
        records.removeAll { r in r.claudePid.map { !isAlive($0) } ?? false }
    }

    private func trackBasicTurns() {
        let now = Date()
        for e in registry {
            let busy = e.status == "busy"
            let since = e.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
            guard var s = basic[e.pid] else {
                basic[e.pid] = BasicState(busy: busy, since: since, turnStart: busy ? since : nil)
                continue
            }
            if busy && !s.busy {
                s.turnStart = since
                s.completedAt = nil
            } else if !busy && s.busy {
                s.lastDuration = s.turnStart.map { since.timeIntervalSince($0) }
                s.completedAt = since
                s.turnStart = nil
            }
            s.busy = busy
            s.since = since
            basic[e.pid] = s
        }
    }

    private func rebuild() {
        let now = Date()
        var sessions: [BarModel] = []
        var usedRecords = Set<String>()

        for e in registry {
            let hook = records.first { $0.sessionId == e.sessionId }
                ?? records.filter { $0.claudePid == e.pid }.max { $0.updatedAt < $1.updatedAt }
            if let hook {
                usedRecords.insert(hook.sessionId)
                sessions.append(model(from: hook, registry: e, now: now))
            } else {
                sessions.append(basicModel(e, now: now))
            }
        }
        for r in records where !usedRecords.contains(r.sessionId) {
            if let pid = r.claudePid, sessions.contains(where: { $0.claudePid == pid }) { continue }
            if r.claudePid == nil && now.timeIntervalSince(r.updatedAt) > 3 * 3600 { continue }
            sessions.append(model(from: r, registry: nil, now: now))
        }

        for m in sessions where firstSeen[m.sessionId ?? ""] == nil { firstSeen[m.sessionId ?? ""] = now }
        for (i, m) in sessions.enumerated() {
            if let e = registry.first(where: { $0.pid == m.claudePid }), let started = e.startedAt {
                firstSeen[m.sessionId ?? ""] = min(firstSeen[m.sessionId ?? ""] ?? now, Date(timeIntervalSince1970: started / 1000))
            }
            sessions[i] = decorate(m)
        }
        ordered = sessions.sorted { (firstSeen[$0.sessionId ?? ""] ?? now) < (firstSeen[$1.sessionId ?? ""] ?? now) }

        if let at = pinnedAt, now.timeIntervalSince(at) > Self.pinDuration { pinned = nil; pinnedAt = nil }
        var chosen = ordered.first { $0.sessionId == pinned } ?? ordered.max { rank($0) < rank($1) }
        if chosen?.sessionId != pinned { pinned = nil; pinnedAt = nil }

        if chosen == nil {
            chosen = BarModel(phase: .offline, project: last?.project, source: .none)
        }
        let result = finish(chosen!, now: now)
        if let p = result.project, result.phase != .offline { git.refreshChanges(for: p.path) }

        scheduleTimeTransition(result, now: now)
        guard result != last else { return }
        last = result
        onChange?(result)
    }

    private func finish(_ chosen: BarModel, now: Date) -> BarModel {
        var result = chosen
        result.sessionCount = ordered.count
        result.pages = ordered.map { SessionPage(sessionId: $0.sessionId ?? "", phase: $0.phase) }
        result.pageIndex = ordered.firstIndex { $0.sessionId == result.sessionId } ?? 0
        result.usage = usageModel(now: now)
        if var p = result.project {
            let info = git.info(for: p.path)
            p.name = info.name
            p.branch = info.branch
            p.changedFiles = info.changedFiles
            result.project = p
        }
        return result
    }

    func pageModel(_ index: Int) -> BarModel? {
        ordered.indices.contains(index) ? finish(ordered[index], now: Date()) : nil
    }

    private func rank(_ m: BarModel) -> Double {
        let base: Double
        switch m.phase {
        case .attention: base = 6
        case .waiting: base = 5
        case .working: base = 4
        case .error: base = 3
        case .completed: base = 2
        case .idle: base = 1
        case .offline: base = 0
        }
        return base * 1e10 + m.phaseSince.timeIntervalSince1970
    }

    private func model(from r: SessionRecord, registry e: RegistryEntry?, now: Date) -> BarModel {
        var m = BarModel(phase: r.phase, activity: r.activity, detail: r.detail, message: r.message, phaseSince: r.phaseSince,
                         turnStartedAt: r.turnStartedAt, lastTurnDuration: r.lastTurnDuration, toolCount: r.toolCount,
                         project: ProjectModel(name: (r.cwd as NSString).lastPathComponent, path: r.cwd),
                         sessionId: r.sessionId, claudePid: r.claudePid ?? e?.pid, source: .live)

        if let e, let t = e.statusUpdatedAt.map({ Date(timeIntervalSince1970: $0 / 1000) }), t > r.updatedAt.addingTimeInterval(1) {
            if e.status == "idle" && (m.phase == .working || m.phase.needsUser) {
                m.phase = .idle
                m.phaseSince = t
                m.turnStartedAt = nil
                m.activity = nil
                m.detail = nil
            } else if e.status == "busy" && (m.phase == .idle || m.phase == .completed) {
                m.phase = .working
                m.activity = .thinking
                m.phaseSince = t
                m.turnStartedAt = t
            }
        }
        if m.phase == .completed && now.timeIntervalSince(m.phaseSince) > Self.completedDecay { m.phase = .idle }
        return m
    }

    private func decorate(_ input: BarModel) -> BarModel {
        var m = input
        guard let id = m.sessionId else { return m }
        let meta = metas[id]
        m.modelName = meta?.model
        m.effort = meta?.effort
        m.contextPercent = meta?.contextPercent
        m.linesAdded = meta?.linesAdded
        m.linesRemoved = meta?.linesRemoved
        m.costUSD = meta?.costUSD
        let transcript = records.first { $0.sessionId == id }?.transcriptPath ?? meta?.transcriptPath
            ?? m.project.map { TopicReader.defaultTranscriptPath(cwd: $0.path, sessionId: id) }
        m.topic = meta?.sessionName ?? transcript.flatMap { topics.title(path: $0) }
        if let r = requests[id], !answered.contains(r.id), m.phase.needsUser { m.request = r }
        return m
    }

    private func basicModel(_ e: RegistryEntry, now: Date) -> BarModel {
        let s = basic[e.pid]
        var m = BarModel(phase: .idle, phaseSince: s?.since ?? now, claudePid: e.pid, source: .basic)
        m.sessionId = e.sessionId ?? "pid-\(e.pid)"
        if let cwd = e.cwd { m.project = ProjectModel(name: (cwd as NSString).lastPathComponent, path: cwd) }
        if s?.busy == true {
            m.phase = .working
            m.activity = .working
            m.turnStartedAt = s?.turnStart
        } else if let done = s?.completedAt, now.timeIntervalSince(done) < Self.completedDecay {
            m.phase = .completed
            m.phaseSince = done
            m.lastTurnDuration = s?.lastDuration
        }
        return m
    }

    private func usageModel(now: Date) -> UsageModel? {
        guard let usage else { return nil }
        if let five = usage.fiveHour, five.resetsAt > now {
            return UsageModel(window: window, windowStart: five.resetsAt.addingTimeInterval(-window),
                              usedFraction: five.usedPercentage / 100,
                              weeklyFraction: usage.sevenDay.flatMap { $0.resetsAt > now ? $0.usedPercentage / 100 : nil },
                              isEstimate: false)
        }
        let start = HookProcessor.estimatedWindowStart(promptTimes: usage.promptTimes, window: window, now: now)
        return UsageModel(window: window, windowStart: start, usedFraction: nil, isEstimate: true)
    }

    private func scheduleTimeTransition(_ m: BarModel, now: Date) {
        timeWork?.cancel()
        var candidates: [Date] = []
        if m.phase == .completed { candidates.append(m.phaseSince.addingTimeInterval(Self.completedDecay)) }
        if let reset = m.usage?.resetsAt { candidates.append(reset) }
        if let at = pinnedAt { candidates.append(at.addingTimeInterval(Self.pinDuration)) }
        guard let next = candidates.filter({ $0 > now }).min() else { return }
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        timeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSince(now) + 0.5, execute: work)
    }
}

final class TopicReader {
    private struct Entry { var offset: UInt64 = 0; var title: String? }
    private var entries: [String: Entry] = [:]
    private static let markers = [Data(#""type":"summary""#.utf8), Data(#""type":"ai-title""#.utf8)]
    private static let maxRead: UInt64 = 64 << 20

    static func defaultTranscriptPath(cwd: String, sessionId: String) -> String {
        let folder = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.claude")
        return "\(root)/projects/\(folder)/\(sessionId).jsonl"
    }

    func title(path: String) -> String? {
        var entry = entries[path] ?? Entry()
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value else { return entry.title }
        if size < entry.offset { entry = Entry() }
        guard size > entry.offset, let handle = FileHandle(forReadingAtPath: path) else { return entry.title }
        defer { try? handle.close() }
        let start = size - entry.offset > Self.maxRead ? size - Self.maxRead : entry.offset
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(size - start)), !data.isEmpty,
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return entry.title }
        let complete = data[data.startIndex...lastNewline]
        for marker in Self.markers {
            var searchFrom = complete.startIndex
            while let r = complete.range(of: marker, in: searchFrom..<complete.endIndex) {
                let lineStart = complete[..<r.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? complete.startIndex
                let lineEnd = complete[r.upperBound...].firstIndex(of: UInt8(ascii: "\n")) ?? complete.endIndex
                if let obj = try? JSONSerialization.jsonObject(with: complete[lineStart..<lineEnd]) as? [String: Any],
                   let t = (obj["aiTitle"] as? String) ?? (obj["summary"] as? String), !t.isEmpty {
                    entry.title = t
                }
                searchFrom = lineEnd
            }
        }
        entry.offset = start + UInt64(complete.count)
        entries[path] = entry
        return entry.title
    }
}

final class GitInspector {
    struct Info { var name: String; var branch: String?; var changedFiles: Int? }
    var onUpdate: (() -> Void)?

    private var changes: [String: Int] = [:]
    private var lastRun: [String: Date] = [:]
    private var running = Set<String>()
    private var trailing = Set<String>()
    private let queue = DispatchQueue(label: "git", qos: .utility)
    static let throttle: TimeInterval = 5

    func info(for path: String) -> Info {
        guard let root = Self.repoRoot(for: path) else {
            return Info(name: (path as NSString).lastPathComponent, branch: nil, changedFiles: nil)
        }
        return Info(name: (root as NSString).lastPathComponent, branch: Self.branch(root: root), changedFiles: changes[root])
    }

    func refreshChanges(for path: String) {
        guard let root = Self.repoRoot(for: path) else { return }
        if running.contains(root) { trailing.insert(root); return }
        let since = lastRun[root].map { Date().timeIntervalSince($0) } ?? .infinity
        if since < Self.throttle {
            guard !trailing.contains(root) else { return }
            trailing.insert(root)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.throttle - since) { [weak self] in
                self?.trailing.remove(root)
                self?.refreshChanges(for: root)
            }
            return
        }
        running.insert(root)
        lastRun[root] = Date()
        queue.async { [weak self] in
            let count = Self.countChanges(root: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running.remove(root)
                if let count, self.changes[root] != count {
                    self.changes[root] = count
                    self.onUpdate?()
                }
                if self.trailing.remove(root) != nil { self.refreshChanges(for: root) }
            }
        }
    }

    static func repoRoot(for path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }

    static func branch(root: String) -> String? {
        var gitDir = URL(fileURLWithPath: root).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir)
        if !isDir.boolValue, let text = try? String(contentsOf: gitDir, encoding: .utf8), text.hasPrefix("gitdir:") {
            let target = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: root, isDirectory: true))
        }
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst(16)) }
        return head.count >= 7 ? String(head.prefix(7)) : nil
    }

    static func countChanges(root: String) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root, "status", "--porcelain=v1", "--untracked-files=normal", "--no-renames"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timeout.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return data.split(separator: UInt8(ascii: "\n")).count
    }
}
