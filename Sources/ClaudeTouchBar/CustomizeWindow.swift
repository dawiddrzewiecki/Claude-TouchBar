import AppKit
import ClaudeBarCore

final class CustomizeWindow: NSWindow {
    var onChange: ((BarLayout) -> Void)?
    var onFinish: ((BarLayout?) -> Void)?
    private let editor: CustomizeView

    init(layout: BarLayout, barWidth: CGFloat) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        editor = CustomizeView(layout: layout, barWidth: max(barWidth, 640))
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        let tint = NSView(frame: blur.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
        tint.autoresizingMask = [.width, .height]
        blur.addSubview(tint)
        editor.frame = blur.bounds
        editor.autoresizingMask = [.width, .height]
        blur.addSubview(editor)
        contentView = blur
        setFrame(screen.frame, display: false)

        editor.onChange = { [weak self] in self?.onChange?($0) }
        editor.onFinish = { [weak self] in self?.finish($0) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func present() {
        alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(editor)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            animator().alphaValue = 1
        }
    }

    private func finish(_ layout: BarLayout?) {
        onFinish?(layout)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { self.orderOut(nil) })
    }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PaletteTile: NSView {
    let kind: WidgetKind
    let well = CALayer.plain()
    private let preview: BarView?
    private let placeholder = CALayer.plain()
    private let label = NSTextField(labelWithString: "")
    private(set) var wellFrame: CGRect = .zero
    private let previewID = "tile"

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(kind: WidgetKind, sample: BarModel, barWidth: CGFloat) {
        self.kind = kind
        var contentWidth: CGFloat
        if kind == .space || kind == .flexSpace {
            preview = nil
            contentWidth = kind == .space ? 44 : 96
        } else {
            let bar = BarView(frame: NSRect(x: 0, y: 0, width: kind == .status ? 300 : 1000, height: Theme.height))
            bar.isInteractive = false
            bar.showsPageArrows = false
            bar.adaptWidth = barWidth
            bar.barLayout = BarLayout([WidgetConfig(kind, id: "tile")])
            bar.render(sample, animated: false)
            bar.layoutSubtreeIfNeeded()
            contentWidth = kind == .status ? 300 : ((bar.widgetFrames().first?.frame.maxX ?? 40) + 6)
            bar.setFrameSize(NSSize(width: contentWidth, height: Theme.height))
            preview = bar
        }
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = kind.summary

        well.backgroundColor = NSColor.black.cgColor
        well.cornerRadius = 9
        well.borderWidth = 1
        well.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
        layer?.addSublayer(well)

        label.stringValue = kind.title
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.7)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        let wellWidth = max(contentWidth + 16, 76)
        let labelWidth = ceil(label.intrinsicContentSize.width) + 8
        let width = max(wellWidth, labelWidth)
        wellFrame = CGRect(x: (width - wellWidth) / 2, y: 0, width: wellWidth, height: Theme.height + 12)
        setFrameSize(NSSize(width: width, height: wellFrame.height + 22))
        well.frame = wellFrame
        label.frame = NSRect(x: 0, y: wellFrame.maxY + 5, width: width, height: 16)
        if let preview {
            preview.setFrameOrigin(NSPoint(x: wellFrame.minX + (wellWidth - contentWidth) / 2, y: 6))
            addSubview(preview)
        } else {
            placeholder.frame = CGRect(x: (wellWidth - contentWidth) / 2, y: 9, width: contentWidth, height: Theme.height - 6)
            placeholder.cornerRadius = 5
            placeholder.borderWidth = 1.2
            placeholder.borderColor = NSColor(white: 1, alpha: 0.3).cgColor
            let arrows = CATextLayer()
            arrows.string = NSAttributedString(kind == .space ? "␣" : "⟷", font: .systemFont(ofSize: 13, weight: .medium), color: NSColor(white: 1, alpha: 0.45))
            arrows.alignmentMode = .center
            arrows.contentsScale = Theme.scale
            arrows.frame = CGRect(x: 0, y: 4, width: contentWidth, height: 18)
            placeholder.addSublayer(arrows)
            well.addSublayer(placeholder)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var isAvailable = true {
        didSet { alphaValue = isAvailable ? 1 : 0.32 }
    }

    func setHighlighted(_ on: Bool) {
        CALayer.animate(Theme.quick) {
            well.borderColor = NSColor(white: 1, alpha: on ? 0.45 : 0.1).cgColor
        }
    }

    func ghostImage() -> CGImage? {
        if let preview { return preview.widgetImage(previewID) }
        let size = CGSize(width: wellFrame.width - 16, height: Theme.height)
        return Glyphs.image(size: size) { ctx, rect in
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 3), cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.5).cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokePath()
        }
    }
}

private final class InspectorView: NSView {
    var onChange: ((WidgetConfig) -> Void)?
    var onRemove: (() -> Void)?
    private var config: WidgetConfig?
    private let stack = NSStackView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 26
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        addSubview(stack)
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat = 1) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = NSColor(white: 1, alpha: alpha)
        return l
    }

    func show(_ config: WidgetConfig?) {
        self.config = config
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let config else {
            let hint = label("Click a widget on the Touch Bar to change its style.  Drag it off the bar to remove it.", size: 13, alpha: 0.55)
            stack.addArrangedSubview(NSView())
            stack.addArrangedSubview(hint)
            stack.addArrangedSubview(NSView())
            stack.distribution = .equalCentering
            return
        }
        stack.distribution = .fill

        let heading = NSStackView(views: [label(config.kind.title, size: 15, weight: .semibold),
                                          label(config.kind.summary, size: 11.5, alpha: 0.55)])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3
        (heading.arrangedSubviews[1] as? NSTextField)?.preferredMaxLayoutWidth = 240
        (heading.arrangedSubviews[1] as? NSTextField)?.maximumNumberOfLines = 2
        heading.widthAnchor.constraint(equalToConstant: 250).isActive = true
        stack.addArrangedSubview(heading)

        let options = config.kind.options
        if options.isEmpty {
            stack.addArrangedSubview(label("No options for this widget.", size: 12.5, alpha: 0.45))
        }
        for option in options {
            let control: NSView
            if option.isToggle {
                let toggle = NSSwitch()
                toggle.state = config.isOn(option.key) ? .on : .off
                toggle.identifier = NSUserInterfaceItemIdentifier(option.key)
                toggle.target = self
                toggle.action = #selector(toggled(_:))
                toggle.controlSize = .small
                control = toggle
            } else {
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: option.choices.map(\.title))
                popup.selectItem(at: option.choices.firstIndex { $0.value == config.value(option.key) } ?? 0)
                popup.identifier = NSUserInterfaceItemIdentifier(option.key)
                popup.target = self
                popup.action = #selector(picked(_:))
                popup.controlSize = .regular
                control = popup
            }
            let group = NSStackView(views: [label(option.title.uppercased(), size: 10, weight: .semibold, alpha: 0.45), control])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 5
            stack.addArrangedSubview(group)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        let remove = NSButton(title: "Remove", image: NSImage(systemSymbolName: "trash", accessibilityDescription: nil)!, target: self, action: #selector(removeTapped))
        remove.bezelStyle = .rounded
        remove.imagePosition = .imageLeading
        stack.addArrangedSubview(remove)
    }

    @objc private func toggled(_ sender: NSSwitch) {
        guard let config, let key = sender.identifier?.rawValue else { return }
        let new = config.setting(key, to: sender.state == .on ? "on" : "off")
        self.config = new
        onChange?(new)
    }

    @objc private func picked(_ sender: NSPopUpButton) {
        guard let config, let key = sender.identifier?.rawValue,
              let option = config.kind.options.first(where: { $0.key == key }), sender.indexOfSelectedItem >= 0 else { return }
        let new = config.setting(key, to: option.choices[sender.indexOfSelectedItem].value)
        self.config = new
        onChange?(new)
    }

    @objc private func removeTapped() { onRemove?() }
}

final class CustomizeView: NSView {
    var onChange: ((BarLayout) -> Void)?
    var onFinish: ((BarLayout?) -> Void)?

    private static let rows: [(String, [WidgetKind])] = [
        ("Claude", [.session, .status, .timer, .tools, .model]),
        ("Limits", [.usage, .weekly, .context, .reset, .cost]),
        ("Project", [.project, .branch, .diff, .terminal, .finder]),
        ("Layout", [.clock, .divider, .space, .flexSpace]),
    ]

    private enum Source { case palette(WidgetKind), bar(String) }

    private struct Drag {
        var source: Source
        var config: WidgetConfig
        var ghost: CALayer
        var grab: CGPoint
        var home: CGRect
        var index: Int?
    }

    private var working: BarLayout
    private let barWidth: CGFloat
    private let sample = SampleData.model()
    private let bezel = NSView()
    private let bar: BarView
    private let overlay = PassthroughView()
    private let inspector = InspectorView()
    private var tiles: [PaletteTile] = []
    private var rowLabels: [NSTextField] = []
    private let presetLabel = NSTextField(labelWithString: "PRESETS")
    private var presetButtons: [NSButton] = []
    private let titleLabel = NSTextField(labelWithString: "Customize Touch Bar")
    private let subtitle = NSTextField(labelWithString: "Drag widgets onto the bar, drag them around to reorder, or drag them off to remove. Changes show on your Touch Bar right away.")
    private let hint = NSTextField(labelWithString: "")
    private let done = NSButton(title: "Done", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let reset = NSButton(title: "Restore Default", target: nil, action: nil)

    private let selection = CAShapeLayer()
    private let hover = CAShapeLayer()
    private var spaceOutlines: [CAShapeLayer] = []

    private var selectedID: String?
    private var hoveredID: String?
    private var hoveredTile: PaletteTile?
    private var pending: (source: Source, start: CGPoint)?
    private var drag: Drag?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(layout: BarLayout, barWidth: CGFloat) {
        self.working = layout
        self.barWidth = barWidth
        bar = BarView(frame: NSRect(x: 0, y: 0, width: barWidth, height: Theme.height))
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.textColor = .white
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = NSColor(white: 1, alpha: 0.6)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = NSColor(white: 1, alpha: 0.45)
        hint.alignment = .center
        for v in [titleLabel, subtitle, hint] { addSubview(v) }

        for (name, kinds) in Self.rows {
            let l = NSTextField(labelWithString: name.uppercased())
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = NSColor(white: 1, alpha: 0.4)
            rowLabels.append(l)
            addSubview(l)
            for kind in kinds {
                var m = sample
                if kind != .session { m.pages = [] }
                let tile = PaletteTile(kind: kind, sample: m, barWidth: barWidth)
                tiles.append(tile)
                addSubview(tile)
            }
        }
        presetLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        presetLabel.textColor = NSColor(white: 1, alpha: 0.4)
        addSubview(presetLabel)
        for (i, preset) in BarLayout.presets.enumerated() {
            let b = NSButton(title: preset.name, target: self, action: #selector(applyPreset(_:)))
            b.bezelStyle = .rounded
            b.tag = i
            presetButtons.append(b)
            addSubview(b)
        }

        bezel.wantsLayer = true
        bezel.layer?.backgroundColor = NSColor.black.cgColor
        bezel.layer?.cornerRadius = 12
        bezel.layer?.borderWidth = 1
        bezel.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        bezel.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 30
            s.shadowColor = NSColor(white: 0, alpha: 0.6)
            s.shadowOffset = NSSize(width: 0, height: -8)
            return s
        }()
        addSubview(bezel)
        bar.isInteractive = false
        bar.barLayout = working
        bar.render(sample, animated: false)
        bezel.addSubview(bar)

        inspector.onChange = { [weak self] config in self?.updateWidget(config) }
        inspector.onRemove = { [weak self] in self?.removeSelected() }
        addSubview(inspector)

        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.target = self
        done.action = #selector(doneTapped)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        reset.bezelStyle = .rounded
        reset.target = self
        reset.action = #selector(resetTapped)
        for b in [done, cancel, reset] {
            b.controlSize = .large
            addSubview(b)
        }

        overlay.wantsLayer = true
        addSubview(overlay)
        for l in [hover, selection] {
            l.fillColor = nil
            l.contentsScale = Theme.scale
            overlay.layer?.addSublayer(l)
        }
        hover.strokeColor = NSColor(white: 1, alpha: 0.35).cgColor
        hover.lineWidth = 1.5
        selection.strokeColor = Theme.keyBlue.cgColor
        selection.lineWidth = 2.5
        selection.shadowColor = Theme.keyBlue.cgColor
        selection.shadowRadius = 6
        selection.shadowOpacity = 0.8
        selection.shadowOffset = .zero
        refreshTiles()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let barW = min(barWidth, W - 80)
        let contentW = min(max(barW + 28, 980), W - 80)
        let x0 = round((W - contentW) / 2)
        let extra = max(H - 880, 0)
        var y = 44 + extra * 0.3

        titleLabel.sizeToFit()
        titleLabel.setFrameOrigin(NSPoint(x: x0, y: y))
        y += titleLabel.frame.height + 6
        subtitle.frame = NSRect(x: x0, y: y, width: contentW, height: 20)
        y += 44

        var tileIndex = 0
        for (row, (_, kinds)) in Self.rows.enumerated() {
            rowLabels[row].sizeToFit()
            rowLabels[row].setFrameOrigin(NSPoint(x: x0, y: y + 14))
            var x = x0 + 96
            var rowHeight: CGFloat = 0
            for _ in kinds {
                let tile = tiles[tileIndex]
                tileIndex += 1
                if x + tile.frame.width > x0 + contentW {
                    x = x0 + 96
                    y += rowHeight + 12
                }
                tile.setFrameOrigin(NSPoint(x: x, y: y))
                x += tile.frame.width + 14
                rowHeight = max(rowHeight, tile.frame.height)
            }
            y += rowHeight + 18
        }
        presetLabel.sizeToFit()
        presetLabel.setFrameOrigin(NSPoint(x: x0, y: y + 8))
        var px = x0 + 96
        for b in presetButtons {
            b.sizeToFit()
            b.setFrameOrigin(NSPoint(x: px, y: y))
            px += b.frame.width + 8
        }
        y += 40 + max(extra * 0.25, 20)

        let bezelFrame = NSRect(x: round((W - barW - 28) / 2), y: y, width: barW + 28, height: Theme.height + 18)
        bezel.frame = bezelFrame
        bar.frame = NSRect(x: 14, y: 9, width: barW, height: Theme.height)
        y = bezelFrame.maxY + 12
        hint.frame = NSRect(x: x0, y: y, width: contentW, height: 18)
        y += 34
        inspector.frame = NSRect(x: x0, y: y, width: contentW, height: 92)

        let buttonsY = max(inspector.frame.maxY + 28, H - 60 - extra * 0.2)
        for b in [done, cancel, reset] { b.sizeToFit() }
        done.frame.size.width = max(done.frame.width, 96)
        done.setFrameOrigin(NSPoint(x: x0 + contentW - done.frame.width, y: buttonsY))
        cancel.setFrameOrigin(NSPoint(x: done.frame.minX - cancel.frame.width - 10, y: buttonsY))
        reset.setFrameOrigin(NSPoint(x: x0, y: buttonsY))

        overlay.frame = bounds
        updateOverlay(animated: false)
    }

    private var barFrames: [String: CGRect] {
        Dictionary(bar.widgetFrames().map { ($0.id, overlay.convert($0.frame, from: bar)) }, uniquingKeysWith: { a, _ in a })
    }

    private func updateOverlay(animated: Bool) {
        let frames = barFrames
        CALayer.animate(animated ? Theme.normal : 0) {
            func outline(_ layer: CAShapeLayer, _ id: String?) {
                guard let id, let f = frames[id] else { layer.opacity = 0; return }
                layer.path = CGPath(roundedRect: f.insetBy(dx: -5, dy: -3), cornerWidth: 8, cornerHeight: 8, transform: nil)
                layer.opacity = 1
            }
            outline(selection, drag == nil ? selectedID : nil)
            outline(hover, drag == nil && hoveredID != selectedID ? hoveredID : nil)
        }
        spaceOutlines.forEach { $0.removeFromSuperlayer() }
        spaceOutlines = working.widgets.filter { $0.kind == .space || $0.kind == .flexSpace }.compactMap { w in
            guard let f = frames[w.id], f.width > 2 else { return nil }
            let l = CAShapeLayer()
            l.path = CGPath(roundedRect: f.insetBy(dx: 1, dy: 5), cornerWidth: 5, cornerHeight: 5, transform: nil)
            l.fillColor = nil
            l.strokeColor = NSColor(white: 1, alpha: 0.25).cgColor
            l.lineDashPattern = [4, 3]
            l.contentsScale = Theme.scale
            overlay.layer?.insertSublayer(l, at: 0)
            return l
        }

        let overflow = bar.overflowedIDs().compactMap { id in working.widgets.first { $0.id == id }?.kind.title }
        if !overflow.isEmpty {
            hint.stringValue = "Not enough room for \(overflow.joined(separator: ", ")). Remove a widget or pick a compact style."
            hint.textColor = Theme.amber
        } else {
            hint.stringValue = "The preview uses sample data. Click a widget to change its style."
            hint.textColor = NSColor(white: 1, alpha: 0.45)
        }
    }

    private func refreshTiles() {
        for t in tiles { t.isAvailable = working.canInsert(t.kind) }
        for (i, b) in presetButtons.enumerated() {
            b.state = BarLayout.presets[i].layout.widgets.map(\.kind) == working.widgets.map(\.kind) ? .on : .off
        }
    }

    private func commit(_ new: BarLayout, animated: Bool = true) {
        working = new
        if let s = selectedID, !working.widgets.contains(where: { $0.id == s }) { selectedID = nil }
        bar.setBarLayout(working, animated: animated)
        inspector.show(working.widgets.first { $0.id == selectedID })
        refreshTiles()
        updateOverlay(animated: animated)
        onChange?(working)
    }

    private func updateWidget(_ config: WidgetConfig) {
        var new = working
        new.update(config)
        working = new
        bar.setBarLayout(new, animated: true)
        refreshTiles()
        updateOverlay(animated: true)
        onChange?(new)
    }

    private func select(_ id: String?) {
        selectedID = id
        inspector.show(working.widgets.first { $0.id == id })
        updateOverlay(animated: true)
    }

    private func removeSelected() {
        guard let id = selectedID else { return }
        var new = working
        new.remove(id: id)
        selectedID = nil
        commit(new)
    }

    func previewSelection() {
        if let usage = working.widgets.first(where: { $0.kind == .usage }) { select(usage.id) }
    }

    @objc private func applyPreset(_ sender: NSButton) {
        guard sender.tag < BarLayout.presets.count else { return }
        selectedID = nil
        commit(BarLayout.presets[sender.tag].layout)
    }

    @objc private func doneTapped() { onFinish?(working) }
    @objc private func cancelTapped() { onFinish?(nil) }

    @objc private func resetTapped() {
        selectedID = nil
        commit(.standard)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: removeSelected()
        case 53: onFinish?(nil)
        default: super.keyDown(with: event)
        }
    }

    private var dropZone: CGRect { bezel.frame.insetBy(dx: -40, dy: -56) }

    private func tile(at p: CGPoint) -> PaletteTile? {
        tiles.first { $0.frame.contains(p) }
    }

    private func barWidget(at p: CGPoint) -> String? {
        guard bezel.frame.insetBy(dx: 0, dy: -4).contains(p) else { return nil }
        let q = overlay.convert(p, from: self)
        let frames = barFrames
        return frames.first { $0.value.insetBy(dx: -8, dy: -8).contains(q) }?.key
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = tile(at: p)
        if t !== hoveredTile {
            hoveredTile?.setHighlighted(false)
            if t?.isAvailable == true { t?.setHighlighted(true) }
            hoveredTile = t
        }
        let id = barWidget(at: p)
        if id != hoveredID {
            hoveredID = id
            updateOverlay(animated: false)
        }
        ((t?.isAvailable == true || id != nil) ? NSCursor.openHand : NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let t = tile(at: p), t.isAvailable {
            if event.clickCount == 2 {
                var new = working
                let config = WidgetConfig(t.kind)
                new.insert(config, at: new.widgets.count)
                selectedID = config.id
                commit(new)
                return
            }
            pending = (.palette(t.kind), p)
        } else if let id = barWidget(at: p) {
            pending = (.bar(id), p)
        } else {
            pending = nil
            if !inspector.frame.contains(p) { select(nil) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if drag == nil, let pending, hypot(p.x - pending.start.x, p.y - pending.start.y) > 4 {
            beginDrag(pending.source, at: pending.start)
        }
        guard drag != nil else { return }
        moveDrag(to: p)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if drag != nil {
            endDrag(at: p)
        } else if let pending, case .bar(let id) = pending.source {
            select(id)
        }
        pending = nil
    }

    private func beginDrag(_ source: Source, at start: CGPoint) {
        let config: WidgetConfig
        let image: CGImage?
        let home: CGRect
        switch source {
        case .palette(let kind):
            guard let t = tiles.first(where: { $0.kind == kind }) else { return }
            config = WidgetConfig(kind)
            image = t.ghostImage()
            home = overlay.convert(t.wellFrame, from: t)
        case .bar(let id):
            guard let c = working.widgets.first(where: { $0.id == id }), let f = barFrames[id] else { return }
            config = c
            image = bar.widgetImage(id)
            home = f
        }
        let ghost = CALayer.plain()
        ghost.contents = image
        let size = image.map { CGSize(width: CGFloat($0.width) / Theme.scale, height: CGFloat($0.height) / Theme.scale) } ?? CGSize(width: 60, height: Theme.height)
        ghost.bounds = CGRect(origin: .zero, size: size)
        ghost.cornerRadius = 7
        ghost.shadowColor = NSColor.black.cgColor
        ghost.shadowOpacity = 0.7
        ghost.shadowRadius = 14
        ghost.shadowOffset = CGSize(width: 0, height: -6)
        ghost.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        ghost.borderWidth = 1
        let s = overlay.convert(start, from: self)
        let grab = CGPoint(x: s.x - home.midX, y: s.y - home.midY)
        CALayer.still {
            ghost.position = CGPoint(x: home.midX, y: home.midY)
            overlay.layer?.addSublayer(ghost)
        }
        CALayer.animate(Theme.quick) { ghost.setAffineTransform(CGAffineTransform(scaleX: 1.06, y: 1.06)) }
        drag = Drag(source: source, config: config, ghost: ghost, grab: grab, home: home, index: nil)
        hoveredTile?.setHighlighted(false)
        NSCursor.closedHand.set()
        if case .bar(let id) = source {
            drag?.index = working.widgets.firstIndex { $0.id == id }
            var base = working
            base.remove(id: id)
            working = base
            selectedID = nil
            inspector.show(nil)
            showPreview()
        }
        refreshTiles()
        updateOverlay(animated: false)
    }

    private func insertionIndex(for p: CGPoint) -> Int {
        guard let d = drag else { return working.widgets.count }
        let x = overlay.convert(p, from: self).x
        let frames = barFrames
        var index = 0
        for (i, w) in working.widgets.enumerated() where w.id != d.config.id {
            if let f = frames[w.id], f.midX < x { index = i + 1 }
        }
        return index
    }

    private func showPreview() {
        guard let d = drag else { return }
        var preview = working
        if let i = d.index { preview.insert(d.config, at: i) }
        bar.setBarLayout(preview, animated: true)
        updateOverlay(animated: true)
    }

    private func moveDrag(to p: CGPoint) {
        guard var d = drag else { return }
        let q = overlay.convert(p, from: self)
        CALayer.still { d.ghost.position = CGPoint(x: q.x - d.grab.x, y: q.y - d.grab.y) }
        let inside = dropZone.contains(p)
        let index: Int? = inside ? insertionIndex(for: p) : nil
        if index != d.index {
            d.index = index
            drag = d
            showPreview()
        }
        CALayer.animate(Theme.quick) { d.ghost.opacity = inside ? 0.55 : 1 }
        if case .bar = d.source, !inside { NSCursor.disappearingItem.set() } else { NSCursor.closedHand.set() }
    }

    private func endDrag(at p: CGPoint) {
        guard let d = drag else { return }
        drag = nil
        let inside = dropZone.contains(p)
        var new = working
        if inside, let i = d.index {
            new.insert(d.config, at: i)
            selectedID = d.config.id
        }
        commit(new, animated: true)
        let target: CGRect?
        if inside {
            target = barFrames[d.config.id]
        } else if case .palette = d.source {
            target = d.home
        } else {
            target = nil
        }
        CALayer.animate(Theme.normal, Theme.easeOut, {
            if let target {
                d.ghost.position = CGPoint(x: target.midX, y: target.midY)
                d.ghost.setAffineTransform(.identity)
                d.ghost.opacity = 0
            } else {
                d.ghost.setAffineTransform(CGAffineTransform(scaleX: 0.3, y: 0.3))
                d.ghost.opacity = 0
            }
        }, completion: { d.ghost.removeFromSuperlayer() })
        NSCursor.arrow.set()
    }
}
