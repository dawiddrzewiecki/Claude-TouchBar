import Foundation
import ClaudeBarCore

enum SampleData {
    static let project = ProjectModel(name: "acme-web", path: NSHomeDirectory() + "/Developer/acme-web", branch: "main", changedFiles: 4)

    static func usage(now: Date = Date(), used: Double = 0.42) -> UsageModel {
        UsageModel(window: 5 * 3600, windowStart: now.addingTimeInterval(-(2 * 3600 + 17 * 60)), usedFraction: used, weeklyFraction: 0.18, isEstimate: false)
    }

    static func model(now: Date = Date()) -> BarModel {
        var m = BarModel(phase: .working, activity: .writing, detail: "ThemeToggle.tsx", turnStartedAt: now.addingTimeInterval(-42),
                         toolCount: 7, usage: usage(now: now), project: project, sessionId: "a", sessionCount: 3, source: .live)
        decorate(&m)
        return m
    }

    static func decorate(_ m: inout BarModel, pages: Bool = true) {
        m.topic = "Add dark mode"
        m.sessionId = m.sessionId ?? "a"
        m.modelName = "Opus 5.5"
        m.effort = "high"
        m.contextPercent = 38
        m.linesAdded = 214
        m.linesRemoved = 57
        m.costUSD = 1.84
        if pages {
            m.pages = [SessionPage(sessionId: "a", phase: m.phase), SessionPage(sessionId: "b", phase: .attention), SessionPage(sessionId: "c", phase: .completed)]
            m.sessionCount = 3
        }
    }
}
