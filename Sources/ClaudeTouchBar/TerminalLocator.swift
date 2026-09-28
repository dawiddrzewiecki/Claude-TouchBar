import AppKit
import ClaudeBarCore

enum TerminalLocator {
    static let knownTerminals = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.jetbrains.intellij",
    ]

    static func activate(_ model: BarModel) {
        let host = model.claudePid.flatMap(hostApp(of:))
        if host?.bundleIdentifier == ghostty || host == nil && isRunning(ghostty) {
            let topic = model.topic, path = model.project?.path
            scriptQueue.async {
                let focused = GhosttyTabs.focus(topic: topic, path: path)
                if !focused { DispatchQueue.main.async { activate(claudePid: model.claudePid) } }
            }
            return
        }
        activate(claudePid: model.claudePid)
    }

    private static let ghostty = "com.mitchellh.ghostty"
    private static let scriptQueue = DispatchQueue(label: "TerminalLocator.script", qos: .userInitiated)

    private static func isRunning(_ bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    static func activate(claudePid: Int32?) {
        if let pid = claudePid, let app = hostApp(of: pid) {
            app.activate()
            return
        }
        let running = NSWorkspace.shared.runningApplications
        if let app = knownTerminals.lazy.compactMap({ id in running.first { $0.bundleIdentifier == id } }).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    static func hostApp(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<12 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
            guard let parent = parentPid(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    static func parentPid(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

enum GhosttyTabs {
    struct Surface { let id, title, directory: String }

    static func focus(topic: String?, path: String?) -> Bool {
        guard let surfaces = list(), let best = pick(surfaces, topic: topic, path: path) else { return false }
        let id = best.id.replacingOccurrences(of: "\"", with: "")
        return run("tell application \"Ghostty\"\nfocus terminal id \"\(id)\"\nactivate\nend tell") != nil
    }

    static func pick(_ surfaces: [Surface], topic: String?, path: String?) -> Surface? {
        func score(_ s: Surface) -> Int {
            var n = 0
            if let topic = normalized(topic), !topic.isEmpty {
                let title = normalized(s.title) ?? ""
                if title == topic { n += 4 } else if title.contains(topic) || (!title.isEmpty && topic.hasPrefix(title)) { n += 3 }
            }
            if let path, s.directory == path { n += 2 }
            return n
        }
        let ranked = surfaces.map { ($0, score($0)) }.filter { $0.1 > 0 }
        return ranked.max { $0.1 < $1.1 }?.0
    }

    private static func normalized(_ s: String?) -> String? {
        guard var s else { return nil }
        s = String(s.drop { !$0.isLetter && !$0.isNumber })
        if s.hasSuffix("…") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func list() -> [Surface]? {
        guard let r = run("tell application \"Ghostty\" to get {id, name, working directory} of every terminal"),
              r.numberOfItems == 3 else { return nil }
        func strings(_ i: Int) -> [String] {
            guard let l = r.atIndex(i) else { return [] }
            return (0..<l.numberOfItems).map { l.atIndex($0 + 1)?.stringValue ?? "" }
        }
        let ids = strings(1), names = strings(2), dirs = strings(3)
        guard ids.count == names.count, ids.count == dirs.count else { return nil }
        return ids.indices.map { Surface(id: ids[$0], title: names[$0], directory: dirs[$0]) }
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
