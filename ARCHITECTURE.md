# Claude Touch Bar — architecture notes

## What this machine offers

| Fact | How it was verified |
|---|---|
| MacBookPro17,1 (M1, 13") with a Touch Bar, macOS 27.0 | `sysctl hw.model`, `TouchBarServer` running |
| Swift 6.4 + Command Line Tools only (no Xcode) | `swift --version`, `xcodebuild` missing → SwiftPM + hand-assembled `.app` |
| `NSTouchBar` public API: only shows while *our* app is frontmost | Apple docs |
| System-wide ("system modal") bar + Control Strip item: private `DFRFoundation` + `NSTouchBar` class methods, all present on 27.0 | runtime probe (`dlsym`, `class_getClassMethod`) |

## What Claude Code exposes locally (v2.1.283)

| Source | Status | What we get |
|---|---|---|
| **Hooks** (`~/.claude/settings.json`) | documented, stable | `UserPromptSubmit`, `PreToolUse`/`PostToolUse` (tool name + input), `PermissionRequest`, `Notification` (`permission_prompt`, `idle_prompt`), `Stop`, `StopFailure`, `PreCompact`, `SessionStart`/`SessionEnd`. Every payload has `session_id` and `cwd`. |
| **Status line command** | documented, stable | JSON on stdin incl. `rate_limits.five_hour.{used_percentage, resets_at}` — the *real* 5‑hour usage (subscribers only). |
| `~/.claude/sessions/<pid>.json` | internal, undocumented | pid, sessionId, cwd, `status: busy/idle`. Used only as a best-effort fallback (works before hooks are installed) and to find the terminal. |
| git | `.git/HEAD` (branch, no process), `git status --porcelain` (changed files, debounced, off-main) |

There is **no** API that streams Claude's spinner text. The status shown on the bar is derived
from real hook events (e.g. `PreToolUse Grep` → “Searching code”, `Bash` running `swift test`
→ “Running tests”). Nothing is invented: between tools the model is genuinely thinking.

## The usage limit — honest model

Claude's limit is *usage inside a 5‑hour rolling window*, not five hours of wall-clock time.

```
UsageModel
  window        : TimeInterval   // configurable: 3h / 5h / 10h / custom (default 5h)
  windowStart   : Date?          // from resets_at − window, or estimated from prompts
  usedFraction  : Double?        // live from rate_limits (nil when not available)
  isEstimate    : Bool
  → elapsed, remaining, fraction
```

* **Live** (status-line bridge installed, subscriber): bar fill = real `used_percentage`,
  a faint “buffered” segment = time elapsed in the window (like a video player's buffer).
* **Estimated** (hooks only): window start is inferred from prompt timestamps, fill = elapsed time, marked `~`.

## Components

```
Claude Code ──hooks / statusLine──▶ cctb (tiny Foundation-only helper, <10 ms, always exit 0)
                                      │ atomic JSON writes + flock
                                      ▼
                 ~/Library/Application Support/ClaudeTouchBar/{sessions/*.json, usage.json}
                                      │ FSEvents (no polling)
                                      ▼
ClaudeTouchBar.app (LSUIElement agent)
  ClaudeMonitor  ─ merges hook records + ~/.claude/sessions, process-exit sources, git
  MockEngine     ─ scripted realistic session for UI work (clearly labelled “Demo”)
  BarModel       ─ one value type = everything the bar renders
  BarLayout      ─ the user's widgets + per-widget options (JSON in UserDefaults), presets
  BarView        ─ lays out one Widget layer per entry; all looping animation runs in the render server
  CustomizeWindow ─ full-screen drag-and-drop editor with palette, live bar preview and inspector
  TouchBarPresenter ─ system-modal bar + Control Strip button (private API, runtime-checked)
  PreviewPanel   ─ same BarView in a floating panel (Macs without a Touch Bar)
  StatusItem     ─ menu bar: settings, demo mode, connect/disconnect Claude Code
```

Energy rules: no polling timers. Looping motion = `CAAnimation` (render server). The only
timers are a 1 Hz elapsed-seconds tick *while working*, a minute-aligned tick for usage labels,
and one-shot decay timers (Completed → Ready).
