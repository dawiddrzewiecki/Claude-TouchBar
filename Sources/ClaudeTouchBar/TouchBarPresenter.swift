import AppKit
import ClaudeBarCore

final class TouchBarPresenter: NSObject, NSTouchBarDelegate {
    static let barItemID = NSTouchBarItem.Identifier("com.claudetouchbar.bar")
    static let trayItemID = NSTouchBarItem.Identifier("com.claudetouchbar.tray")

    let barView = BarView(frame: NSRect(x: 0, y: 0, width: 780, height: Theme.height))
    let trayView = TrayView(frame: NSRect(x: 0, y: 0, width: 38, height: Theme.height))
    private let touchBar = NSTouchBar()
    private var trayItem: NSCustomTouchBarItem?
    private(set) var isPresented = false
    var onTrayTap: (() -> Void)?

    private typealias SetPresence = @convention(c) (NSString, ObjCBool) -> Void
    private typealias ShowsCloseBox = @convention(c) (ObjCBool) -> Void
    private typealias PresentFn = @convention(c) (AnyObject, Selector, NSTouchBar, Int64, NSString) -> Void
    private typealias TouchBarFn = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
    private typealias ItemFn = @convention(c) (AnyObject, Selector, NSTouchBarItem) -> Void

    private let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

    private var setPresence: SetPresence? { dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier").map { unsafeBitCast($0, to: SetPresence.self) } }
    private var showsCloseBox: ShowsCloseBox? { dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost").map { unsafeBitCast($0, to: ShowsCloseBox.self) } }

    private func classMethod<T>(_ cls: AnyClass, _ name: String, as: T.Type) -> (Selector, T)? {
        let sel = NSSelectorFromString(name)
        guard let m = class_getClassMethod(cls, sel) else { return nil }
        return (sel, unsafeBitCast(method_getImplementation(m), to: T.self))
    }

    lazy var isAvailable: Bool = {
        dfr != nil && setPresence != nil
            && classMethod(NSTouchBar.self, "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:", as: PresentFn.self) != nil
            && classMethod(NSTouchBarItem.self, "addSystemTrayItem:", as: ItemFn.self) != nil
            && Self.hasTouchBarHardware()
    }()

    override init() {
        super.init()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [Self.barItemID]
        touchBar.principalItemIdentifier = Self.barItemID
    }

    func install() {
        guard isAvailable else { return }
        showsCloseBox?(true)
        let item = NSCustomTouchBarItem(identifier: Self.trayItemID)
        trayView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([trayView.widthAnchor.constraint(equalToConstant: 38)])
        item.view = trayView
        trayView.onTap = { [weak self] in self?.onTrayTap?() }
        trayItem = item
        if let (sel, fn) = classMethod(NSTouchBarItem.self, "addSystemTrayItem:", as: ItemFn.self) {
            fn(NSTouchBarItem.self, sel, item)
        }
        setPresence?(Self.trayItemID.rawValue as NSString, true)
    }

    func present() {
        guard isAvailable, let (sel, fn) = classMethod(NSTouchBar.self, "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:", as: PresentFn.self) else { return }
        fn(NSTouchBar.self, sel, touchBar, 1, Self.trayItemID.rawValue as NSString)
        isPresented = true
    }

    func minimize() {
        guard isAvailable, let (sel, fn) = classMethod(NSTouchBar.self, "minimizeSystemModalTouchBar:", as: TouchBarFn.self) else { return }
        fn(NSTouchBar.self, sel, touchBar)
        isPresented = false
    }

    var isVisible: Bool { isPresented && touchBar.isVisible }

    func uninstall() {
        guard isAvailable else { return }
        if let (sel, fn) = classMethod(NSTouchBar.self, "dismissSystemModalTouchBar:", as: TouchBarFn.self) {
            fn(NSTouchBar.self, sel, touchBar)
        }
        setPresence?(Self.trayItemID.rawValue as NSString, false)
        if let trayItem, let (sel, fn) = classMethod(NSTouchBarItem.self, "removeSystemTrayItem:", as: ItemFn.self) {
            fn(NSTouchBarItem.self, sel, trayItem)
        }
        isPresented = false
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.barItemID else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        barView.translatesAutoresizingMaskIntoConstraints = false
        let preferred = barView.widthAnchor.constraint(equalToConstant: 1000)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([preferred, barView.widthAnchor.constraint(greaterThanOrEqualToConstant: 480)])
        item.view = barView
        return item
    }

    static func hasTouchBarHardware() -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return false }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).contains { p in
            withUnsafePointer(to: p.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            } == "TouchBarServer"
        }
    }
}

final class TrayView: NSView {
    var onTap: (() -> Void)?
    private let spark = CAShapeLayer()
    private let spinner = StateGlyphLayer()
    private let badge = CAShapeLayer()
    private let highlight = CALayer.plain()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer.plain()
        wantsLayer = true
        allowedTouchTypes = [.direct]
        highlight.backgroundColor = Theme.pressed.cgColor
        highlight.cornerRadius = 7
        highlight.opacity = 0
        layer?.addSublayer(highlight)
        spark.path = Glyphs.sparkPath(in: CGRect(x: 0, y: 0, width: 16, height: 16))
        spark.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        spark.fillColor = Theme.claude.cgColor
        layer?.addSublayer(spark)
        spinner.opacity = 0
        layer?.addSublayer(spinner)
        badge.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 7, height: 7), transform: nil)
        badge.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        badge.strokeColor = NSColor.black.cgColor
        badge.lineWidth = 1.5
        badge.opacity = 0
        layer?.addSublayer(badge)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: Theme.height) }

    override func layout() {
        super.layout()
        CALayer.still {
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            highlight.frame = bounds.insetBy(dx: 1, dy: 1)
            spark.position = c
            spinner.position = c
            badge.position = CGPoint(x: c.x + 7, y: c.y - 6)
        }
    }

    func update(_ phase: Phase) {
        spinner.show(phase == .working ? .working : .idle, animated: true)
        let badgeColor: NSColor? = [Phase.waiting: Theme.blue, .attention: Theme.amber, .error: Theme.red, .completed: Theme.green][phase]
        CALayer.animate(Theme.normal) {
            spinner.opacity = phase == .working ? 1 : 0
            spark.opacity = phase == .working ? 0 : 1
            spark.fillColor = (phase == .offline ? Theme.tertiary : Theme.claude).cgColor
            if let badgeColor { badge.fillColor = badgeColor.cgColor }
            badge.opacity = badgeColor == nil ? 0 : 1
        }
    }

    private func press(_ on: Bool) {
        CALayer.animate(on ? 0.08 : Theme.normal) { highlight.opacity = on ? 1 : 0 }
    }

    override func touchesBegan(with event: NSEvent) { press(true) }
    override func touchesCancelled(with event: NSEvent) { press(false) }
    override func touchesEnded(with event: NSEvent) {
        press(false)
        onTap?()
    }
    override func mouseDown(with event: NSEvent) { press(true) }
    override func mouseUp(with event: NSEvent) {
        press(false)
        onTap?()
    }
}
