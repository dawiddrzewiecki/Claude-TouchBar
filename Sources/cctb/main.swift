import ClaudeBarCore
import Darwin
import Foundation
import notify

func readStdin() -> Data { FileHandle.standardInput.readDataToEndOfFile() }

func claudeAncestorPid() -> Int32? {
    var pid = getppid()
    for _ in 0..<6 where pid > 1 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if path.hasSuffix("/claude") || path.contains("/claude/versions/") || path.contains("claude-code") { return pid }
        }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

func logEvent(_ payload: [String: Any]) {
    let url = Store.supportDirectory.appendingPathComponent("events.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(payload["hook_event_name"] as? String ?? "?") \(payload["tool_name"] as? String ?? "") \((payload["session_id"] as? String)?.prefix(8) ?? "")\n"
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), (attrs[.size] as? Int ?? 0) > 64_000 {
        try? FileManager.default.removeItem(at: url)
    }
    if let h = FileHandle(forWritingAtPath: url.path) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: url, atomically: false, encoding: .utf8)
    }
}

func runHook() {
    let data = readStdin()
    guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let sessionId = payload["session_id"] as? String else { return }
    logEvent(payload)
    defer {
        if payload["hook_event_name"] as? String == "PermissionRequest" { runPermissionRequest(payload) }
    }
    let now = Date()
    Store.withLock {
        let file = Store.sessionFile(sessionId)
        let existing = Store.read(SessionRecord.self, from: file)
        if var record = HookProcessor.apply(payload, to: existing, now: now) {
            if record.claudePid == nil { record.claudePid = claudeAncestorPid() }
            Store.write(record, to: file)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
        switch payload["hook_event_name"] as? String {
        case "PostToolUse", "PostToolUseFailure":
            Store.clearRequests(sessionId: sessionId, toolUseId: payload["tool_use_id"] as? String)
        case "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd", "SessionStart":
            Store.clearRequests(sessionId: sessionId)
        default:
            break
        }
        if payload["hook_event_name"] as? String == "UserPromptSubmit" {
            var usage = Store.read(UsageRecord.self, from: Store.usageFile) ?? UsageRecord()
            let dayAgo = now.addingTimeInterval(-86_400)
            usage.promptTimes = usage.promptTimes.filter { $0 > dayAgo } + [now]
            Store.write(usage, to: Store.usageFile)
        }
    }
    Store.postChange()
}

func runPermissionRequest(_ payload: [String: Any]) {
    guard let request = RequestBuilder.request(from: payload) else { return }
    Store.ensureDirectories()
    Store.write(request, to: Store.requestFile(request.id))
    Store.postChange()
    guard Store.appIsRunning() else { return }

    let responseURL = Store.responseFile(request.id)
    let requestURL = Store.requestFile(request.id)
    let deadline = Date().addingTimeInterval(10 * 60)
    let claude = claudeAncestorPid()
    var token: Int32 = 0
    notify_register_check(Store.responseNotification, &token)
    defer { notify_cancel(token) }

    while Date() < deadline {
        if let response = Store.read(RequestResponse.self, from: responseURL), response.id == request.id {
            try? FileManager.default.removeItem(at: responseURL)
            try? FileManager.default.removeItem(at: requestURL)
            logEvent(["hook_event_name": "TouchBarAnswer", "tool_name": response.action.rawValue, "session_id": request.sessionId])
            let output = RequestBuilder.hookOutput(for: response, payload: payload)
            if let data = try? JSONSerialization.data(withJSONObject: output) {
                FileHandle.standardOutput.write(data)
            }
            Store.postChange()
            return
        }
        if !FileManager.default.fileExists(atPath: requestURL.path) { return }
        if let claude, kill(claude, 0) != 0 && errno != EPERM { break }
        var changed: Int32 = 0
        for _ in 0..<25 {
            notify_check(token, &changed)
            if changed != 0 { break }
            usleep(10_000)
        }
    }
    try? FileManager.default.removeItem(at: requestURL)
    Store.postChange()
}

func runStatusLine() {
    let data = readStdin()
    let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

    func rateWindow(_ key: String) -> RateWindow? {
        guard let limits = payload["rate_limits"] as? [String: Any],
              let w = limits[key] as? [String: Any],
              let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
              let resets = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
        return RateWindow(usedPercentage: used, resetsAt: Date(timeIntervalSince1970: resets))
    }

    if let sessionId = payload["session_id"] as? String {
        var meta = SessionMeta(sessionId: sessionId)
        meta.sessionName = (payload["session_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let model = payload["model"] as? [String: Any]
        meta.model = model?["display_name"] as? String
        meta.effort = (payload["effort"] as? [String: Any])?["level"] as? String
        meta.contextPercent = ((payload["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue
        let cost = payload["cost"] as? [String: Any]
        meta.linesAdded = (cost?["total_lines_added"] as? NSNumber)?.intValue
        meta.linesRemoved = (cost?["total_lines_removed"] as? NSNumber)?.intValue
        meta.costUSD = (cost?["total_cost_usd"] as? NSNumber)?.doubleValue
        meta.transcriptPath = payload["transcript_path"] as? String
        let file = Store.metaFile(sessionId)
        if Store.read(SessionMeta.self, from: file) != meta {
            Store.ensureDirectories()
            Store.write(meta, to: file)
            Store.postChange()
        }
    }

    let five = rateWindow("five_hour")
    let seven = rateWindow("seven_day")
    if payload["rate_limits"] != nil {
        Store.withLock {
            var usage = Store.read(UsageRecord.self, from: Store.usageFile) ?? UsageRecord()
            if usage.fiveHour != five || usage.sevenDay != seven {
                usage.fiveHour = five
                usage.sevenDay = seven
                usage.rateLimitsUpdatedAt = Date()
                Store.write(usage, to: Store.usageFile)
                Store.postChange()
            }
        }
    }

    if let command = Installer.chainedStatusLineCommand() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.standardOutput
        do {
            try process.run()
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {}
        return
    }

    var parts: [String] = []
    if let workspace = payload["workspace"] as? [String: Any], let dir = workspace["current_dir"] as? String {
        parts.append((dir as NSString).lastPathComponent)
    }
    if let model = (payload["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
    if let five { parts.append("5h \(Int(five.usedPercentage.rounded()))%") }
    print(parts.joined(separator: " · "))
}

func helperPath() -> String {
    let arg = CommandLine.arguments[0]
    let url = arg.contains("/") ? URL(fileURLWithPath: arg) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(arg)
    return url.resolvingSymlinksInPath().standardizedFileURL.path
}

func printStatus() {
    print("settings: \(Installer.settingsURL.path) — \(Installer.status())")
    let files = (try? FileManager.default.contentsOfDirectory(at: Store.sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "json" {
        guard let r = Store.read(SessionRecord.self, from: file) else { continue }
        print("• \(r.sessionId.prefix(8))  \(r.phase.rawValue)  \(r.activity?.title ?? "-")  \(r.detail ?? "")  [\(r.cwd)]")
    }
    if let usage = Store.read(UsageRecord.self, from: Store.usageFile) {
        if let five = usage.fiveHour { print("5h window: \(five.usedPercentage)% — resets \(five.resetsAt)") }
        print("prompts in last 24h: \(usage.promptTimes.count)")
    }
}

switch CommandLine.arguments.dropFirst().first {
case "hook":
    runHook()
case "statusline":
    runStatusLine()
case "install":
    do {
        try Installer.install(helperPath: helperPath(), includeStatusLine: !CommandLine.arguments.contains("--no-statusline"))
        print("Connected. Hooks + status line added to \(Installer.settingsURL.path) (backup saved next to it).")
    } catch {
        FileHandle.standardError.write("install failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
case "uninstall":
    do {
        try Installer.uninstall()
        print("Disconnected. Removed Claude Touch Bar entries from \(Installer.settingsURL.path).")
    } catch {
        FileHandle.standardError.write("uninstall failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
case "status":
    printStatus()
case "dump":
    DistributedNotificationCenter.default().postNotificationName(.init("com.claudetouchbar.dump"), object: nil, deliverImmediately: true)
    print(Store.supportDirectory.appendingPathComponent("diagnostics").path)
case "customize":
    DistributedNotificationCenter.default().postNotificationName(.init("com.claudetouchbar.customize"), object: nil, deliverImmediately: true)
default:
    print("usage: cctb hook | statusline | install [--no-statusline] | uninstall | status | dump | customize")
}
exit(0)
