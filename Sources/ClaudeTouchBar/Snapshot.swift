import AppKit
import ClaudeBarCore

enum Snapshot {
    private struct Case {
        var name: String
        var model: BarModel
        var detail: DetailKind? = nil
        var width: CGFloat = 1004
        var layout: BarLayout = .standard
    }

    private static func styled(_ style: String) -> BarLayout {
        var l = BarLayout.standard
        if let u = l.widgets.first(where: { $0.kind == .usage }) { l.update(u.setting("style", to: style)) }
        return l
    }

    private static func cases(now: Date) -> [Case] {
        let usage = SampleData.usage(now: now)
        let estimate = UsageModel(window: 5 * 3600, windowStart: now.addingTimeInterval(-(1 * 3600 + 5 * 60)), usedFraction: nil, isEstimate: true)
        let project = SampleData.project
        let long = ProjectModel(name: "payments-service-experiments", path: "/tmp/x", branch: "feature/very-long-branch-name", changedFiles: 12)

        var perm = BarModel(phase: .attention, message: "Allow command?", turnStartedAt: now.addingTimeInterval(-75), usage: usage, project: project)
        perm.request = PendingRequest(id: "p", sessionId: "a", kind: .permission, toolName: "Bash", title: "Run command?", detail: "npm run test -- --watch=false", canAlwaysAllow: true)
        var ask = BarModel(phase: .waiting, message: "Question for you", usage: usage, project: project)
        ask.request = PendingRequest(id: "q", sessionId: "a", kind: .question, toolName: "AskUserQuestion", title: "", detail: nil, questions: [
            .init(question: "Which database should we use?", header: "DB", options: [.init(label: "Postgres (Recommended)"), .init(label: "SQLite"), .init(label: "MySQL")], multiSelect: false)])
        var plan = BarModel(phase: .waiting, message: "Plan ready", usage: usage, project: project)
        plan.request = PendingRequest(id: "pl", sessionId: "a", kind: .plan, toolName: "ExitPlanMode", title: "Plan ready", detail: "Approve and start coding?")
        let working = BarModel(phase: .working, activity: .writing, detail: "ThemeToggle.tsx", turnStartedAt: now.addingTimeInterval(-42), toolCount: 7, usage: usage, project: project)

        var list: [Case] = [
            Case(name: "working", model: working),
            Case(name: "thinking", model: BarModel(phase: .working, activity: .thinking, turnStartedAt: now.addingTimeInterval(-3), usage: usage, project: project)),
            Case(name: "tests", model: BarModel(phase: .working, activity: .runningTests, detail: "npm test", turnStartedAt: now.addingTimeInterval(-131),
                                                usage: SampleData.usage(now: now, used: 0.86), project: project), layout: styled("segmented")),
            Case(name: "ask-permission", model: perm),
            Case(name: "ask-question", model: ask),
            Case(name: "ask-plan", model: plan),
            Case(name: "attention", model: BarModel(phase: .attention, message: "Allow command?", turnStartedAt: now.addingTimeInterval(-75), usage: usage, project: project)),
            Case(name: "waiting", model: BarModel(phase: .waiting, message: "Which layout do you prefer?", usage: usage, project: project)),
            Case(name: "completed", model: BarModel(phase: .completed, lastTurnDuration: 252, usage: usage, project: project)),
            Case(name: "error", model: BarModel(phase: .error, message: "Rate limit reached", usage: SampleData.usage(now: now, used: 0.99), project: project)),
            Case(name: "idle-estimate", model: BarModel(phase: .idle, usage: estimate, project: project)),
            Case(name: "offline", model: BarModel(phase: .offline, usage: estimate, project: project, source: .none)),
            Case(name: "demo-long", model: BarModel(phase: .working, activity: .searching, detail: "“useThemePreference”", turnStartedAt: now.addingTimeInterval(-605), usage: usage, project: long, source: .demo)),
            Case(name: "narrow-640", model: BarModel(phase: .working, activity: .editing, detail: "App.tsx", turnStartedAt: now.addingTimeInterval(-12), usage: usage, project: project), width: 640),
            Case(name: "detail-usage", model: working, detail: .usage),
            Case(name: "detail-project", model: working, detail: .project),
            Case(name: "detail-status", model: BarModel(phase: .working, activity: .editing, detail: "ThemeToggle.tsx", turnStartedAt: now.addingTimeInterval(-97), toolCount: 14, usage: usage, project: project), detail: .status),
        ]
        for style in ["segmented", "slim", "ring", "text"] {
            list.append(Case(name: "style-\(style)", model: working, layout: styled(style)))
        }
        for preset in BarLayout.presets.dropFirst() {
            list.append(Case(name: "preset-\(preset.name.lowercased())", model: working, layout: preset.layout))
        }
        for i in list.indices where list[i].name != "offline" {
            if list[i].model.source == .none { list[i].model.source = .live }
            SampleData.decorate(&list[i].model, pages: i % 2 == 0)
            list[i].model.pageIndex = i % 4 == 0 ? 0 : 1
            if list[i].name == "tests" { list[i].model.contextPercent = 91 }
            if list[i].name.hasPrefix("preset") || list[i].name.hasPrefix("style") || list[i].name == "working" { list[i].model.pageIndex = 0 }
        }
        return list
    }

    static func renderAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        var cases = cases(now: now)
        if let only = ProcessInfo.processInfo.environment["SNAPSHOT_ONLY"] { cases = cases.filter { $0.name == only } }

        let scale: CGFloat = 2
        let rowH: CGFloat = Theme.height + 26
        let sheetW = (cases.map(\.width).max() ?? 1004) + 32
        let sheetH = rowH * CGFloat(cases.count) + 10
        guard let sheet = CGContext(data: nil, width: Int(sheetW * scale), height: Int(sheetH * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        sheet.scaleBy(x: scale, y: scale)
        sheet.setFillColor(NSColor(white: 0.11, alpha: 1).cgColor)
        sheet.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

        for (index, c) in cases.enumerated() {
            let view = BarView(frame: NSRect(x: 0, y: 0, width: c.width, height: Theme.height))
            view.barLayout = c.layout
            view.render(c.model, now: now, animated: false)
            view.layout()
            if let kind = c.detail { view.showDetail(kind) }
            view.layer?.layoutIfNeeded()
            view.layer?.sublayers?.forEach { layoutTree($0) }

            let y = sheetH - CGFloat(index + 1) * rowH
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: sheet, flipped: false)
            NSAttributedString(c.name, font: .systemFont(ofSize: 10, weight: .medium), color: NSColor(white: 1, alpha: 0.45)).draw(at: CGPoint(x: 16, y: y + Theme.height + 8))
            NSGraphicsContext.restoreGraphicsState()
            sheet.saveGState()
            sheet.translateBy(x: 16, y: y + 4)
            sheet.setFillColor(NSColor.black.cgColor)
            sheet.addPath(CGPath(roundedRect: CGRect(x: -6, y: 0, width: c.width + 12, height: Theme.height), cornerWidth: 6, cornerHeight: 6, transform: nil))
            sheet.fillPath()
            view.layer?.render(in: sheet)
            sheet.restoreGState()

            if let image = Glyphs.image(size: CGSize(width: c.width + 16, height: Theme.height + 12), draw: { ctx, rect in
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillPath()
                ctx.translateBy(x: 8, y: 6)
                view.layer?.render(in: ctx)
            }) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(c.name).png"))
            }
        }
        if let image = sheet.makeImage() {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("sheet.png"))
        }
        print("wrote \(dir.appendingPathComponent("sheet.png").path)")
    }

    static func renderCustomizer(to file: URL, size: CGSize = CGSize(width: 1440, height: 900)) {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let view = CustomizeView(layout: .standard, barWidth: 1004)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        view.frame = root.bounds
        root.addSubview(view)
        root.layoutSubtreeIfNeeded()
        view.previewSelection()
        root.layoutSubtreeIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("wrote \(file.path)")
    }

    static func renderIconSet(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = CGFloat(base * scale)
                guard let image = Glyphs.image(size: CGSize(width: px, height: px), scale: 1, draw: { ctx, rect in
                    let tile = rect.insetBy(dx: px * 0.1, dy: px * 0.1)
                    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil))
                    ctx.setFillColor(Theme.clay.cgColor)
                    ctx.fillPath()
                    ctx.addPath(Glyphs.sparkPath(in: tile.insetBy(dx: tile.width * 0.2, dy: tile.width * 0.2)))
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fillPath()
                }) else { continue }
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
        }
    }

    static func png(of view: NSView, scale: CGFloat = 2) -> Data? {
        let size = view.bounds.size
        guard size.width > 0, let layer = view.layer,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        (layer.presentation() ?? layer).render(in: ctx)
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func layoutTree(_ layer: CALayer) {
        layer.layoutIfNeeded()
        layer.sublayers?.forEach { layoutTree($0) }
    }
}
