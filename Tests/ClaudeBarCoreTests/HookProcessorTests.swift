import Testing
import Foundation
@testable import ClaudeBarCore

@Suite struct HookProcessorTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": name, "session_id": "s1", "cwd": "/tmp/Proj"].merging(extra) { $1 }
    }

    @Test func fullTurn() {
        var r = HookProcessor.apply(event("UserPromptSubmit"), to: nil, now: t0)!
        #expect(r.phase == .working && r.activity == .thinking)
        r = HookProcessor.apply(event("PreToolUse", ["tool_name": "Read", "tool_use_id": "a", "tool_input": ["file_path": "/x/Bar.swift"]]), to: r, now: t0 + 1)!
        #expect(r.activity == .reading && r.detail == "Bar.swift")
        r = HookProcessor.apply(event("PreToolUse", ["tool_name": "Grep", "tool_use_id": "b", "tool_input": ["pattern": "foo"]]), to: r, now: t0 + 2)!
        r = HookProcessor.apply(event("PostToolUse", ["tool_name": "Grep", "tool_use_id": "b"]), to: r, now: t0 + 3)!
        #expect(r.activity == .reading, "parallel Read still in flight")
        r = HookProcessor.apply(event("PostToolUse", ["tool_name": "Read", "tool_use_id": "a"]), to: r, now: t0 + 4)!
        #expect(r.activity == .thinking)
        r = HookProcessor.apply(event("Notification", ["notification_type": "permission_prompt", "message": "Claude needs permission"]), to: r, now: t0 + 5)!
        #expect(r.phase == .attention)
        r = HookProcessor.apply(event("Stop"), to: r, now: t0 + 60)!
        #expect(r.phase == .completed && r.lastTurnDuration == 60 && r.toolCount == 2)
        r = HookProcessor.apply(event("Notification", ["notification_type": "idle_prompt"]), to: r, now: t0 + 120)!
        #expect(r.phase == .completed)
        #expect(HookProcessor.apply(event("SessionEnd"), to: r, now: t0 + 130) == nil)
    }

    @Test func commandClassification() {
        #expect(HookProcessor.classifyCommand("cd a && swift test --parallel") == .runningTests)
        #expect(HookProcessor.classifyCommand("npm run test") == .runningTests)
        #expect(HookProcessor.classifyCommand("pytest -q tests/") == .runningTests)
        #expect(HookProcessor.classifyCommand("swift build -c release") == .building)
        #expect(HookProcessor.classifyCommand("git diff --stat") == .reviewing)
        #expect(HookProcessor.classifyCommand("ls -la") == .runningCommands)
        #expect(HookProcessor.shortCommand("cd /a/b && npm run test -- --watch") == "npm run test")
        #expect(HookProcessor.shortCommand("sleep 1; \"/Apps/My Tool/cctb\" status") == "cctb status")
        #expect(HookProcessor.shortCommand("FOO=1 make -j8 all") == "make -j8 all")
        #expect(HookProcessor.shortCommand("git log --oneline | head -5") == "git log --oneline")
        let d = HookProcessor.describeCommand("python3 - <<'EOF'\nx\nEOF\nswift test")
        #expect(d.0 == .runningCommands || d.1 != nil)
        let c = HookProcessor.describeCommand("python3 gen.py; swift test 2>&1 | tail")
        #expect(c.0 == .runningTests && c.1 == "swift test")
    }

    @Test func windowEstimate() {
        let h: TimeInterval = 3600
        let prompts = [t0, t0 + 1 * h, t0 + 6 * h, t0 + 7 * h]
        #expect(HookProcessor.estimatedWindowStart(promptTimes: prompts, window: 5 * h, now: t0 + 2 * h) == t0)
        #expect(HookProcessor.estimatedWindowStart(promptTimes: prompts, window: 5 * h, now: t0 + 7.5 * h) == t0 + 6 * h)
        #expect(HookProcessor.estimatedWindowStart(promptTimes: prompts, window: 5 * h, now: t0 + 12 * h) == nil)
    }
}

@Suite struct RequestTests {
    @Test func permissionRequestRoundTrip() throws {
        let payload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "Bash",
                                      "tool_use_id": "t1", "tool_input": ["command": "npm test"],
                                      "permission_suggestions": [["type": "addRules"]]]
        let r = try #require(RequestBuilder.request(from: payload))
        #expect(r.kind == .permission && r.title == "Run command?" && r.detail == "npm test" && r.canAlwaysAllow)
        let always = RequestBuilder.hookOutput(for: .init(id: "t1", action: .always), payload: payload)
        let decision = (always["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "allow" && decision?["updatedPermissions"] != nil)
        let deny = RequestBuilder.hookOutput(for: .init(id: "t1", action: .deny), payload: payload)
        #expect(((deny["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String == "deny")
    }

    @Test func questionAnswersGoIntoUpdatedInput() throws {
        let q: [String: Any] = ["question": "Which DB?", "header": "DB", "multiSelect": false,
                                "options": [["label": "Postgres"], ["label": "SQLite"]]]
        let payload: [String: Any] = ["session_id": "s", "tool_name": "AskUserQuestion", "tool_use_id": "t2", "tool_input": ["questions": [q]]]
        let r = try #require(RequestBuilder.request(from: payload))
        #expect(r.kind == .question && r.questions.first?.options.count == 2)
        let out = RequestBuilder.hookOutput(for: .init(id: "t2", action: .answer, answers: ["Which DB?": "SQLite"]), payload: payload)
        let decision = (out["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        let updated = decision?["updatedInput"] as? [String: Any]
        #expect((updated?["answers"] as? [String: String])?["Which DB?"] == "SQLite")
        #expect(updated?["questions"] != nil)
    }
}
