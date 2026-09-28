import AppKit
import ClaudeBarCore
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let presenter = TouchBarPresenter()
    private var preview: PreviewPanel?
    private let monitor = ClaudeMonitor()
    private let mock = MockEngine()
    private var statusItem: NSStatusItem?
    private var model = BarModel()
    private var clock: DispatchSourceTimer?
    private var clockInterval: TimeInterval = 0
    private var offlineWork: DispatchWorkItem?
    private var customizer: CustomizeWindow?

    private var barViews: [BarView] { [presenter.barView] + (preview.map { [$0.barView] } ?? []) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Store.ensureDirectories()
        try? "\(getpid())".write(to: Store.appPidFile, atomically: true, encoding: .utf8)
        setUpStatusItem()
        for view in barViews { configure(view) }
        presenter.onTrayTap = { [weak self] in self?.toggleTouchBar() }

        if presenter.isAvailable {
            presenter.install()
            presenter.present()
        } else {
            showPreview(true)
        }

        monitor.window = settings.limit
        mock.window = settings.limit
        monitor.onChange = { [weak self] m in if self?.settings.demoMode == false { self?.apply(m) } }
        mock.onChange = { [weak self] m in if self?.settings.demoMode == true { self?.apply(m) } }
        startSource()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(dumpDiagnostics), name: .init("com.claudetouchbar.dump"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(menuCustomize), name: .init("com.claudetouchbar.customize"), object: nil)
    }

    @objc private func dumpDiagnostics() {
        let dir = Store.supportDirectory.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let view = presenter.barView
        var info: [String: Any] = [
            "widgets": view.diagnostics,
            "touchBarAvailable": "\(presenter.isAvailable)",
            "presented": "\(presenter.isPresented)",
            "visible": "\(presenter.isVisible)",
            "barFrame": NSStringFromRect(view.frame),
            "inWindow": "\(view.window != nil)",
            "trayFrame": NSStringFromRect(presenter.trayView.frame),
            "phase": model.phase.rawValue,
            "source": model.source.rawValue,
        ]
        if let png = Snapshot.png(of: view) {
            try? png.write(to: dir.appendingPathComponent("touchbar.png"))
            info["png"] = dir.appendingPathComponent("touchbar.png").path
        }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("state.json"))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: Store.appPidFile)
        clock?.cancel()
        monitor.stop()
        mock.stop()
        presenter.uninstall()
    }

    private func configure(_ view: BarView) {
        view.barLayout = settings.layout
        view.answerKeysEnabled = settings.answerKeys
        view.onAction = { [weak self] action in self?.handle(action) }
        view.pageModel = { [weak self] index in
            guard let self else { return nil }
            return self.settings.demoMode ? self.mock.pageModel(index) : self.monitor.pageModel(index)
        }
    }

    private func startSource() {
        if settings.demoMode {
            monitor.stop()
            mock.start()
        } else {
            mock.stop()
            monitor.start()
        }
    }

    private func apply(_ new: BarModel) {
        let old = model
        model = new
        for view in barViews { view.render(new) }
        presenter.trayView.update(new.phase)
        updateStatusItem()
        updateClock()

        if presenter.isAvailable {
            let startedWorking = new.phase == .working && old.phase != .working && settings.autoPresent
            let needsUser = new.phase.needsUser && !old.phase.needsUser && settings.presentOnRequest
            if (startedWorking || needsUser) && !presenter.isVisible { presenter.present() }
            offlineWork?.cancel()
            if new.phase == .offline && settings.hideWhenOffline {
                let work = DispatchWorkItem { [weak self] in
                    if self?.model.phase == .offline { self?.presenter.minimize() }
                }
                offlineWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
            }
        }
    }

    private var clockAnchor: Date?

    private func updateClock() {
        let live = model.phase == .working || model.phase.needsUser
        let interval: TimeInterval = live ? 1 : 60
        let anchor = live ? model.turnStartedAt : Date(timeIntervalSinceReferenceDate: 0)
        guard interval != clockInterval || anchor != clockAnchor else { return }
        clockInterval = interval
        clockAnchor = anchor
        clock?.cancel()
        var firstFire = interval
        if let anchor {
            let phase = Date().timeIntervalSince(anchor).truncatingRemainder(dividingBy: interval)
            firstFire = interval - phase + 0.01
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + firstFire, repeating: interval, leeway: .milliseconds(interval < 2 ? 15 : 300))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for view in self.barViews { view.tick(now: now) }
        }
        timer.resume()
        clock = timer
    }

    private func handle(_ action: BarAction) {
        switch action {
        case .openTerminal:
            TerminalLocator.activate(model)
        case .openFinder:
            if let path = model.project?.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        case .nextSession:
            if settings.demoMode { mock.cycleSession(1) } else { monitor.cycleSession(1) }
        case .previousSession:
            if settings.demoMode { mock.cycleSession(-1) } else { monitor.cycleSession(-1) }
        case .respond(let response):
            if settings.demoMode { mock.respond(response) } else { monitor.respond(response) }
        case .showDetail, .closeDetail:
            break
        }
    }

    @objc private func screensChanged() {
        guard presenter.isAvailable else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.presenter.install()
            if self.presenter.isPresented { self.presenter.present() }
        }
    }

    private func toggleTouchBar() {
        if presenter.isVisible { presenter.minimize() } else { presenter.present() }
    }

    private func showPreview(_ on: Bool) {
        if on {
            if preview == nil {
                let panel = PreviewPanel()
                configure(panel.barView)
                preview = panel
                panel.barView.render(model, animated: false)
            }
            preview?.orderFrontRegardless()
        } else {
            preview?.orderOut(nil)
            preview = nil
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Glyphs.menuBarImage()
        item.button?.toolTip = "Claude Touch Bar"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func updateStatusItem() {
        statusItem?.button?.appearsDisabled = model.phase == .offline
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: headerText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let project = model.project {
            let p = NSMenuItem(title: [project.name, project.branch].compactMap { $0 }.joined(separator: " · "), action: nil, keyEquivalent: "")
            p.isEnabled = false
            menu.addItem(p)
        }
        menu.addItem(.separator())

        if presenter.isAvailable {
            add(menu, presenter.isVisible ? "Hide from Touch Bar" : "Show on Touch Bar", #selector(menuToggleTouchBar))
        }
        add(menu, preview == nil ? "Show On-Screen Preview" : "Hide On-Screen Preview", #selector(menuTogglePreview))
        add(menu, "Open Terminal", #selector(menuOpenTerminal))
        menu.addItem(.separator())
        add(menu, "Customize Touch Bar…", #selector(menuCustomize), key: ",")
        let presets = NSMenu()
        let current = settings.layout
        for (i, preset) in BarLayout.presets.enumerated() {
            let item = add(presets, preset.name, #selector(menuApplyPreset(_:)))
            item.representedObject = i
            item.state = preset.layout.widgets.map(\.kind) == current.widgets.map(\.kind) ? .on : .off
        }
        submenu(menu, "Layout", presets)

        let limit = NSMenu()
        for hours in [3.0, 5.0, 10.0] {
            let i = add(limit, Format.hours(hours * 3600), #selector(menuSetLimit(_:)))
            i.representedObject = hours
            i.state = settings.limitHours == hours ? .on : .off
        }
        let custom = add(limit, "Custom…", #selector(menuCustomLimit))
        custom.state = [3.0, 5.0, 10.0].contains(settings.limitHours) ? .off : .on
        submenu(menu, "Usage Window (\(Format.hours(settings.limit)))", limit)

        let behaviour = NSMenu()
        add(behaviour, "Show When Claude Starts Working", #selector(menuToggleAutoPresent)).state = settings.autoPresent ? .on : .off
        add(behaviour, "Show When Claude Needs You", #selector(menuTogglePresentOnRequest)).state = settings.presentOnRequest ? .on : .off
        add(behaviour, "Answer Claude from the Touch Bar", #selector(menuToggleAnswerKeys)).state = settings.answerKeys ? .on : .off
        add(behaviour, "Fold Away When Claude Isn’t Running", #selector(menuToggleHideOffline)).state = settings.hideWhenOffline ? .on : .off
        add(behaviour, "Launch at Login", #selector(menuToggleLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        submenu(menu, "Behavior", behaviour)
        menu.addItem(.separator())

        switch Installer.status() {
        case .installed: add(menu, "Disconnect from Claude Code…", #selector(menuUninstall))
        case .partial: add(menu, "Repair Claude Code Connection…", #selector(menuInstall))
        case .notInstalled: add(menu, "Connect to Claude Code…", #selector(menuInstall))
        }
        add(menu, "Demo Mode", #selector(menuToggleDemo)).state = settings.demoMode ? .on : .off
        menu.addItem(.separator())
        add(menu, "Quit Claude Touch Bar", #selector(NSApplication.terminate(_:)), key: "q").target = NSApp
    }

    private func headerText() -> String {
        let prefix = model.source == .demo ? "Demo · " : ""
        switch model.phase {
        case .offline: return prefix + "Claude Code isn’t running"
        default:
            let sessions = model.sessionCount > 1 ? " · \(model.sessionCount) sessions" : ""
            return prefix + model.statusTitle + sessions
        }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func submenu(_ menu: NSMenu, _ title: String, _ sub: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
    }

    @objc private func menuToggleTouchBar() { toggleTouchBar() }
    @objc private func menuTogglePreview() { showPreview(preview == nil) }
    @objc private func menuOpenTerminal() { TerminalLocator.activate(model) }

    @objc private func menuSetLimit(_ sender: NSMenuItem) {
        guard let hours = sender.representedObject as? Double else { return }
        setLimit(hours)
    }

    @objc private func menuCustomLimit() {
        let alert = NSAlert()
        alert.messageText = "Usage window length"
        alert.informativeText = "Hours per limit window. Claude’s session limit resets every 5 hours."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = String(format: "%g", settings.limitHours)
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let hours = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")), hours >= 0.25, hours <= 168 else { return }
        setLimit(hours)
    }

    private func setLimit(_ hours: Double) {
        settings.limitHours = hours
        monitor.window = settings.limit
        mock.window = settings.limit
        barViews.forEach { $0.needsLayout = true }
    }

    @objc private func menuCustomize() { openCustomizer() }

    @objc private func menuApplyPreset(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int, i < BarLayout.presets.count else { return }
        setLayout(BarLayout.presets[i].layout, save: true)
    }

    private func setLayout(_ layout: BarLayout, save: Bool) {
        if save { settings.layout = layout }
        for view in barViews { view.barLayout = layout }
    }

    private func openCustomizer() {
        if let customizer {
            customizer.makeKeyAndOrderFront(nil)
            return
        }
        let original = settings.layout
        let window = CustomizeWindow(layout: original, barWidth: presenter.isAvailable ? presenter.barView.bounds.width : PreviewPanel.barWidth)
        window.onChange = { [weak self] layout in self?.setLayout(layout, save: false) }
        window.onFinish = { [weak self] layout in
            guard let self else { return }
            self.setLayout(layout ?? original, save: layout != nil)
            self.customizer = nil
        }
        customizer = window
        if presenter.isAvailable && !presenter.isVisible { presenter.present() }
        window.present()
    }

    @objc private func menuToggleAutoPresent() { settings.autoPresent.toggle() }
    @objc private func menuToggleHideOffline() { settings.hideWhenOffline.toggle() }
    @objc private func menuTogglePresentOnRequest() { settings.presentOnRequest.toggle() }

    @objc private func menuToggleAnswerKeys() {
        settings.answerKeys.toggle()
        for view in barViews { view.answerKeysEnabled = settings.answerKeys }
    }

    @objc private func menuToggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func menuToggleDemo() {
        settings.demoMode.toggle()
        startSource()
    }

    private var helperPath: String? {
        let exe = Bundle.main.executableURL!.resolvingSymlinksInPath()
        let candidates = [
            exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/cctb"),
            exe.deletingLastPathComponent().appendingPathComponent("cctb"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }

    @objc private func menuInstall() {
        guard let helper = helperPath else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Connect Claude Touch Bar to Claude Code?"
        alert.informativeText = """
        This adds lightweight hooks and a status-line bridge to \(Installer.settingsURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). \
        They only report what Claude is doing (tool names, file names, usage limits) to this app — nothing leaves your Mac.

        A backup of your settings is saved first. If you already have a status line, it keeps working unchanged. \
        New Claude Code sessions pick up the change.
        """
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try Installer.install(helperPath: helper) } catch { NSAlert(error: error).runModal() }
    }

    @objc private func menuUninstall() {
        let alert = NSAlert()
        alert.messageText = "Disconnect from Claude Code?"
        alert.informativeText = "Removes only the entries Claude Touch Bar added. Your own hooks and status line are restored as they were."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try Installer.uninstall() } catch { NSAlert(error: error).runModal() }
    }
}
