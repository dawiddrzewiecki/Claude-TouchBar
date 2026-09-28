import Foundation
import ClaudeBarCore

final class MockEngine {
    var onChange: ((BarModel) -> Void)?
    var window: TimeInterval = 5 * 3600 { didSet { emit() } }

    private struct Step {
        var phase: Phase
        var activity: Activity? = nil
        var detail: String? = nil
        var message: String? = nil
        var duration: TimeInterval
        var edits = 0
        var request: PendingRequest? = nil
    }

    private let script: [Step] = [
        Step(phase: .working, activity: .thinking, duration: 2.6),
        Step(phase: .working, activity: .exploring, detail: "src/**/*.tsx", duration: 1.8),
        Step(phase: .working, activity: .reading, detail: "SettingsView.tsx", duration: 1.5),
        Step(phase: .working, activity: .reading, detail: "useTheme.ts", duration: 1.3),
        Step(phase: .working, activity: .searching, detail: "“prefers-color-scheme”", duration: 2.0),
        Step(phase: .working, activity: .thinking, duration: 2.4),
        Step(phase: .working, activity: .planning, duration: 2.2),
        Step(phase: .working, activity: .writing, detail: "ThemeToggle.tsx", duration: 3.0, edits: 1),
        Step(phase: .working, activity: .editing, detail: "App.tsx", duration: 2.4, edits: 1),
        Step(phase: .attention, message: "Allow command?", duration: 12,
             request: PendingRequest(id: "demo-perm", sessionId: "demo-1", kind: .permission, toolName: "Bash",
                                     title: "Run command?", detail: "npm test -- --watch=false", canAlwaysAllow: true)),
        Step(phase: .working, activity: .runningTests, detail: "npm test", duration: 4.2),
        Step(phase: .working, activity: .checkingResults, duration: 1.8),
        Step(phase: .working, activity: .editing, detail: "App.tsx", duration: 2.0),
        Step(phase: .working, activity: .runningTests, detail: "npm test", duration: 3.0),
        Step(phase: .working, activity: .reviewing, detail: "git diff", duration: 2.2),
        Step(phase: .completed, duration: 6.5),
        Step(phase: .working, activity: .thinking, duration: 2.0),
        Step(phase: .waiting, message: "Question for you", duration: 14,
             request: PendingRequest(id: "demo-q", sessionId: "demo-1", kind: .question, toolName: "AskUserQuestion",
                                     title: "Which usage label?", detail: nil, questions: [
                                        .init(question: "Which label should the usage key show?", header: "Label",
                                              options: [.init(label: "Percent (Recommended)", detail: nil), .init(label: "Time left", detail: nil), .init(label: "Time used", detail: nil)],
                                              multiSelect: false)])),
        Step(phase: .idle, duration: 3.0),
    ]

    private var index = 0
    private var loop = 0
    private var model = BarModel()
    private var work: DispatchWorkItem?
    private var used = 0.38
    private var changed = 3
    private let windowStart = Date().addingTimeInterval(-(2 * 3600 + 17 * 60))
    private var page = 0
    private let parked: [BarModel] = [
        BarModel(phase: .waiting, message: "Which layout do you prefer?", phaseSince: Date(),
                 project: ProjectModel(name: "mobile-app", path: NSHomeDirectory() + "/Developer/mobile-app", branch: "redesign", changedFiles: 9),
                 sessionId: "demo-2", source: .demo),
        BarModel(phase: .completed, lastTurnDuration: 312,
                 project: ProjectModel(name: "billing-api", path: NSHomeDirectory() + "/Developer/billing-api", branch: "main", changedFiles: 2),
                 sessionId: "demo-3", source: .demo),
    ]
    private let topics = ["Add dark mode", "Onboarding redesign", "Invoice rounding bug"]

    func respond(_ response: RequestResponse) {
        guard model.request?.id == response.id else { return }
        model.request = nil
        emit()
        work?.cancel()
        let next = DispatchWorkItem { [weak self] in self?.advance() }
        work = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: next)
    }

    func cycleSession(_ delta: Int) {
        let next = page + delta
        guard next >= 0, next <= parked.count else { return }
        page = next
        emit()
    }

    func start() {
        index = 0
        model = BarModel(phase: .idle, project: project(), sessionCount: 1, source: .demo)
        advance()
    }

    func stop() {
        work?.cancel()
        work = nil
    }

    private func project() -> ProjectModel {
        loop % 2 == 0
            ? ProjectModel(name: "acme-web", path: NSHomeDirectory() + "/Developer/acme-web", branch: "main", changedFiles: changed)
            : ProjectModel(name: "claude-touchbar", path: NSHomeDirectory() + "/Developer/claude-touchbar", branch: "feature/usage-bar", changedFiles: changed)
    }

    private func advance() {
        let now = Date()
        var step = script[index]
        if loop % 3 == 2 && step.activity == .checkingResults {
            step = Step(phase: .error, message: "Rate limit reached", duration: 4)
        }

        if model.phase != step.phase { model.phaseSince = now }
        if step.phase == .working && (model.turnStartedAt == nil || model.phase == .completed || model.phase == .idle || model.phase == .error) {
            model.turnStartedAt = now
            model.toolCount = 0
        }
        if step.phase == .completed, let start = model.turnStartedAt {
            model.lastTurnDuration = now.timeIntervalSince(start)
            model.turnStartedAt = nil
        }
        if step.phase == .idle || step.phase == .error { model.turnStartedAt = nil }
        if step.activity != nil && step.activity != .thinking { model.toolCount += 1 }

        model.phase = step.phase
        model.activity = step.activity
        model.detail = step.detail
        model.message = step.message
        model.request = step.request
        changed += step.edits
        if step.phase == .working { used = min(used + 0.0045, 0.99) }
        model.project = project()
        emit()

        index += 1
        if index == script.count {
            index = 0
            loop += 1
            if loop % 2 == 0 { changed = 3 }
        }
        let next = DispatchWorkItem { [weak self] in self?.advance() }
        work = next
        DispatchQueue.main.asyncAfter(deadline: .now() + step.duration, execute: next)
    }

    private func emit() {
        onChange?(shown(page))
    }

    func pageModel(_ index: Int) -> BarModel? {
        index >= 0 && index <= parked.count ? shown(index) : nil
    }

    private func shown(_ page: Int) -> BarModel {
        model.sessionId = "demo-1"
        let pages = [SessionPage(sessionId: "demo-1", phase: model.phase)] + parked.map { SessionPage(sessionId: $0.sessionId!, phase: $0.phase) }
        var shown = page == 0 ? model : parked[page - 1]
        shown.topic = topics[page]
        shown.pages = pages
        shown.pageIndex = page
        shown.sessionCount = pages.count
        shown.modelName = "Opus 5.5"
        shown.effort = "high"
        shown.contextPercent = page == 0 ? 38 : 71
        shown.linesAdded = 214
        shown.linesRemoved = 57
        shown.costUSD = page == 0 ? 1.84 : 0.62
        shown.usage = UsageModel(window: window, windowStart: windowStart, usedFraction: used, weeklyFraction: 0.21, isEstimate: false)
        return shown
    }
}
