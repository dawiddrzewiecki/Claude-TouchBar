import AppKit

final class PreviewPanel: NSPanel {
    let barView: BarView
    static let barWidth: CGFloat = 1000

    init() {
        barView = BarView(frame: NSRect(x: 0, y: 0, width: Self.barWidth, height: Theme.height))
        let inset = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        let size = NSSize(width: Self.barWidth + inset.left + inset.right, height: Theme.height + inset.top + inset.bottom)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let bezel = NSView(frame: NSRect(origin: .zero, size: size))
        bezel.wantsLayer = true
        bezel.layer?.backgroundColor = NSColor(white: 0.02, alpha: 1).cgColor
        bezel.layer?.cornerRadius = 11
        bezel.layer?.borderWidth = 1
        bezel.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        barView.frame = NSRect(x: inset.left, y: inset.bottom, width: Self.barWidth, height: Theme.height)
        bezel.addSubview(barView)
        contentView = bezel

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 18))
        }
        setFrameAutosaveName("ClaudeTouchBarPreview")
    }

    override var canBecomeKey: Bool { false }
}
