import AppKit

enum Glyphs {
    static func sparkPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let lengths: [CGFloat] = [1.0, 0.82, 0.94, 0.78, 0.98, 0.86, 0.92, 0.8, 1.0, 0.84, 0.9, 0.79]
        for (i, k) in lengths.enumerated() {
            let a = CGFloat(i) / CGFloat(lengths.count) * .pi * 2 + .pi / 2
            let ray = CGMutablePath()
            ray.move(to: CGPoint(x: c.x + cos(a) * r * 0.16, y: c.y + sin(a) * r * 0.16))
            ray.addLine(to: CGPoint(x: c.x + cos(a) * r * k, y: c.y + sin(a) * r * k))
            path.addPath(ray.copy(strokingWithWidth: r * 0.2, lineCap: .round, lineJoin: .round, miterLimit: 1))
        }
        path.addEllipse(in: CGRect(x: c.x - r * 0.24, y: c.y - r * 0.24, width: r * 0.48, height: r * 0.48))
        return path
    }

    static func checkPath(in rect: CGRect) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.50))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.24))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.76))
        return p
    }

    static func chevronLeftPath(in rect: CGRect) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.minY))
        return p
    }

    static let spinnerCharacters = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    static func spinnerFrames(size: CGFloat, color: NSColor) -> [CGImage] {
        spinnerCharacters.compactMap { character in
            image(size: CGSize(width: size, height: size)) { ctx, rect in
                let font = NSFont.systemFont(ofSize: size * 0.95, weight: .semibold)
                let text = NSAttributedString(character, font: font, color: color)
                let s = text.size()
                let glyphBounds = text.boundingRect(with: rect.size, options: [.usesDeviceMetrics])
                let x = rect.midX - s.width / 2
                let y = rect.midY - glyphBounds.midY + font.descender
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                text.draw(at: CGPoint(x: x, y: y))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium, color: NSColor) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let size = base.size
        return image(size: size) { ctx, rect in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func image(size: CGSize, scale: CGFloat = Theme.scale, draw: (CGContext, CGRect) -> Void) -> CGImage? {
        let w = Int(ceil(size.width * scale)), h = Int(ceil(size.height * scale))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx, CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            let path = sparkPath(in: rect.insetBy(dx: 2, dy: 2))
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.addPath(path)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
