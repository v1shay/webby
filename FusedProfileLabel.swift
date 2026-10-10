import AppKit

/// The sidebar title keeps its normal AppKit text for accessibility. In Fuse mode
/// a small Core Animation gradient is clipped to the word itself.
@MainActor final class FusedProfileLabel: NSTextField {
    private let fusedPaint = CAGradientLayer()
    private let fusedMask = CATextLayer()
    private var isFused = false
    private let fuseFont = NSFont.systemFont(ofSize: 16, weight: .bold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 11, weight: .semibold)
        textColor = .secondaryLabelColor
        wantsLayer = true
        // Colors sampled from the user's sky gradient: blue, mist, warm gold,
        // then a restrained coral edge. One fixed palette keeps Fuse cohesive.
        let stops = BrowserTheme.fuseProfile.gradients.ambient.stops
        fusedPaint.colors = stops.map { BrowserTheme.color($0.color).cgColor }
        fusedPaint.locations = stops.map { NSNumber(value: $0.location) }
        fusedPaint.startPoint = CGPoint(x: 0.5, y: 0)
        fusedPaint.endPoint = CGPoint(x: 0.5, y: 1)
        fusedPaint.mask = fusedMask
        fusedPaint.opacity = 0
        layer?.addSublayer(fusedPaint)
        fusedMask.string = "Fuse"
        fusedMask.font = fuseFont
        fusedMask.fontSize = fuseFont.pointSize
        fusedMask.alignmentMode = .center
        fusedMask.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        fusedMask.foregroundColor = NSColor.white.cgColor
    }

    override func layout() {
        super.layout()
        let size = ("Fuse" as NSString).size(withAttributes: [.font: fuseFont])
        let width = min(bounds.width, ceil(size.width) + 3)
        let rect = CGRect(x: (bounds.width - width) / 2,
                          y: (bounds.height - ceil(size.height)) / 2,
                          width: width, height: ceil(size.height) + 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fusedPaint.frame = rect
        fusedMask.frame = CGRect(origin: .zero, size: rect.size)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit's field editor can leave a faint copy of clear text behind a
        // layer-backed label. In Fuse mode, only the masked gradient draws it.
        if !isFused { super.draw(dirtyRect) }
    }

    func showProfile(_ name: String, animated: Bool) {
        isFused = false
        // Remove the masked layer entirely. Keeping it attached at opacity 0
        // left a cached copy of "Fuse" behind the normal profile name.
        layer?.removeAllAnimations()
        fusedPaint.removeAllAnimations()
        fusedPaint.removeFromSuperlayer()
        stringValue = name
        font = .systemFont(ofSize: 11, weight: .semibold)
        textColor = .secondaryLabelColor
        fusedPaint.opacity = 0
        needsDisplay = true
    }

    func showFuse(animated: Bool) {
        let changed = !isFused
        isFused = true
        stringValue = "Fuse"
        font = fuseFont
        textColor = .clear
        if fusedPaint.superlayer == nil { layer?.addSublayer(fusedPaint) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fusedPaint.opacity = 1
        CATransaction.commit()
        if animated && changed && Motion.enabled {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.24
            appear.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
            fusedPaint.add(appear, forKey: "fuseAppear")
            let settle = CABasicAnimation(keyPath: "transform.scale")
            settle.fromValue = 0.92
            settle.toValue = 1
            settle.duration = 0.24
            settle.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
            fusedPaint.add(settle, forKey: "fuseSettle")
        }
        needsLayout = true
    }
}
