import AppKit
import WebKit

enum Motion {
    static var enabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func basic(_ layer: CALayer?, key: String, from: Any, to: Any, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        guard enabled, let layer else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: key)
    }

    static func springScale(_ layer: CALayer?, from: CGFloat, to: CGFloat) {
        guard let layer else { return }
        let visibleScale = (layer.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber)
            .map { CGFloat(truncating: $0) } ?? from
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(scaleX: to, y: to))
        CATransaction.commit()
        guard enabled else { return }
        let animation = CASpringAnimation(keyPath: "transform.scale")
        animation.fromValue = visibleScale
        animation.toValue = to
        animation.mass = 0.45
        animation.stiffness = 600
        animation.damping = 33
        animation.duration = min(animation.settlingDuration, 0.30)
        layer.add(animation, forKey: "springScale")
    }
}

final class GlassPanel: NSView {
    let materialView = NSVisualEffectView()
    private let tint = CAGradientLayer()
    private let topLight = CAGradientLayer()
    private let progressLine = CAGradientLayer()
    private let navigationPulse = CALayer()
    private let radius: CGFloat
    private var progressFraction: CGFloat = 0

    init(radius: CGFloat = 14) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.20
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -7)

        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = radius
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.65
        materialView.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        materialView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(materialView)
        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        tint.colors = [
            NSColor.white.withAlphaComponent(0.13).cgColor,
            NSColor.white.withAlphaComponent(0.04).cgColor,
            NSColor.black.withAlphaComponent(0.05).cgColor
        ]
        tint.locations = [0, 0.5, 1]
        tint.startPoint = CGPoint(x: 0.2, y: 1)
        tint.endPoint = CGPoint(x: 0.8, y: 0)
        materialView.layer?.addSublayer(tint)

        topLight.colors = [
            NSColor.white.withAlphaComponent(0.42).cgColor,
            NSColor.white.withAlphaComponent(0.07).cgColor
        ]
        topLight.startPoint = CGPoint(x: 0, y: 0.5)
        topLight.endPoint = CGPoint(x: 1, y: 0.5)
        materialView.layer?.addSublayer(topLight)

        progressLine.colors = [
            NSColor(calibratedRed: 0.45, green: 0.78, blue: 0.95, alpha: 0.9).cgColor,
            NSColor.white.withAlphaComponent(0.92).cgColor,
            NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.48, alpha: 0.85).cgColor
        ]
        progressLine.startPoint = CGPoint(x: 0, y: 0.5)
        progressLine.endPoint = CGPoint(x: 1, y: 0.5)
        progressLine.cornerRadius = 1
        progressLine.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressLine.opacity = 0
        materialView.layer?.addSublayer(progressLine)

        navigationPulse.backgroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
        navigationPulse.cornerRadius = 1
        navigationPulse.bounds = CGRect(x: 0, y: 0, width: 16, height: 2)
        navigationPulse.opacity = 0
        navigationPulse.shadowColor = NSColor(calibratedRed: 0.47, green: 0.83, blue: 1, alpha: 1).cgColor
        navigationPulse.shadowOpacity = 0.65
        navigationPulse.shadowRadius = 6
        materialView.layer?.addSublayer(navigationPulse)
        applyTheme(BrowserTheme.profile)
        applyGlassTransparency()
    }

    func applyTheme(_ profile: PetGradientProfile) {
        BrowserTheme.apply(profile.gradients.ambient, to: tint, alpha: 0.055)
        BrowserTheme.apply(profile.gradients.working, to: progressLine)
        navigationPulse.backgroundColor = BrowserTheme.color(profile.palette.highlight, alpha: 0.9).cgColor
        navigationPulse.shadowColor = BrowserTheme.color(profile.palette.accent).cgColor
    }

    func applyGlassTransparency() {
        materialView.alphaValue = 1 - BrowserGlass.topTransparency * 0.72
        layer?.shadowOpacity = Float(0.20 * (1 - BrowserGlass.topTransparency * 0.5))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        tint.frame = materialView.bounds
        tint.cornerRadius = radius
        topLight.frame = CGRect(x: 15, y: materialView.bounds.height - 1, width: max(0, materialView.bounds.width - 30), height: 1)
        progressLine.position = CGPoint(x: 18, y: 2.5)
        progressLine.bounds = CGRect(x: 0, y: 0, width: max(0, materialView.bounds.width - 36) * progressFraction, height: 2)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    func reveal(delay: CFTimeInterval = 0, x: CGFloat = 0, y: CGFloat = 0) {
        Motion.basic(layer, key: "opacity", from: 0, to: 1, duration: 0.20, delay: delay)
        Motion.basic(layer, key: "transform.translation.x", from: x, to: 0, duration: 0.26, delay: delay)
        Motion.basic(layer, key: "transform.translation.y", from: y, to: 0, duration: 0.26, delay: delay)
    }

    func setProgress(_ fraction: Double) {
        let newFraction = max(progressFraction, CGFloat(min(max(fraction, 0), 1)))
        let oldWidth = progressLine.presentation()?.bounds.width ?? progressLine.bounds.width
        progressFraction = newFraction
        let newWidth = max(0, materialView.bounds.width - 36) * newFraction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLine.opacity = 1
        progressLine.bounds.size.width = newWidth
        CATransaction.commit()
        Motion.basic(progressLine, key: "bounds.size.width", from: oldWidth, to: newWidth, duration: 0.16)
    }

    func resetProgress() {
        progressFraction = 0
        progressLine.removeAnimation(forKey: "bounds.size.width")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLine.bounds.size.width = 0
        progressLine.opacity = 0
        CATransaction.commit()
    }

    func hideProgress() {
        Motion.basic(progressLine, key: "opacity", from: 1, to: 0, duration: 0.18)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLine.opacity = 0
        CATransaction.commit()
    }

    func emitNavigationPulse(from sourceX: CGFloat) {
        guard Motion.enabled else { return }
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = sourceX
        move.toValue = 18
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0]
        fade.keyTimes = [0, 0.28, 1]
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.28
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        navigationPulse.position = CGPoint(x: 18, y: 2.5)
        navigationPulse.add(group, forKey: "navigationPulse")
    }
}

final class GradientSymbolView: NSView {
    private let paint = CAGradientLayer()
    private let symbolMask = CALayer()

    init(symbol: String, size: CGFloat = 16) {
        super.init(frame: .zero)
        wantsLayer = true
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(configuration)
        symbolMask.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        symbolMask.contentsGravity = .resizeAspect
        symbolMask.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        paint.mask = symbolMask
        layer?.addSublayer(paint)
        applyTheme(BrowserTheme.profile)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        paint.frame = bounds
        symbolMask.frame = bounds
    }

    func applyTheme(_ profile: PetGradientProfile) {
        BrowserTheme.apply(profile.gradients.thinking, to: paint)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class GlassButton: NSButton {
    private var themeProfile: PetGradientProfile?
    private var hovered = false
    private var pressed = false
    private var hoverArea: NSTrackingArea?
    private let highlight = CAGradientLayer()
    private let glint = CAGradientLayer()
    private let symbolView: GradientSymbolView

    init(symbol: String, label: String, target: AnyObject, action: Selector) {
        symbolView = GradientSymbolView(symbol: symbol)
        super.init(frame: .zero)
        title = ""
        self.target = target
        self.action = action
        setAccessibilityLabel(label)
        toolTip = label
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        highlight.startPoint = CGPoint(x: 0.5, y: 1)
        highlight.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(highlight)
        glint.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.17).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor
        ]
        glint.startPoint = CGPoint(x: 0, y: 0.5)
        glint.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(glint)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolView)
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18)
        ])
        updateGlass()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        highlight.frame = bounds
        highlight.cornerRadius = 8
        glint.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width, height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateGlass()
        if isEnabled {
            Motion.springScale(layer, from: 1, to: 1.035)
            Motion.basic(glint, key: "transform.translation.x", from: 0, to: bounds.width * 2, duration: 0.28)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateGlass()
        if isEnabled { Motion.springScale(layer, from: 1.035, to: 1) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        Motion.springScale(layer, from: hovered ? 1.035 : 1, to: 0.965)
        updateGlass()
        super.mouseDown(with: event)
        pressed = false
        Motion.springScale(layer, from: 0.965, to: hovered ? 1.035 : 1)
        updateGlass()
    }

    override var isEnabled: Bool {
        didSet { updateGlass() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGlass()
    }

    func applyTheme(_ profile: PetGradientProfile) {
        themeProfile = profile
        symbolView.applyTheme(profile)
        updateGlass()
    }

    private func updateGlass() {
        guard let layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let strength: CGFloat = pressed ? 0.12 : (hovered ? 0.08 : 0.035)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = NSColor.white.withAlphaComponent(dark ? strength : strength + 0.025).cgColor
        layer.borderWidth = 0.6
        layer.borderColor = BrowserTheme.color((themeProfile ?? BrowserTheme.profile).palette.highlight,
                                               alpha: hovered ? 0.38 : 0.17).cgColor
        let profile = themeProfile ?? BrowserTheme.profile
        BrowserTheme.apply(profile.gradients.ambient, to: highlight,
                           alpha: pressed ? 0.34 : (hovered ? 0.28 : 0.16))
        alphaValue = isEnabled ? 1 : 0.38
        CATransaction.commit()
    }
}

final class GlassAddressSurface: NSView, NSTextFieldDelegate {
    override var mouseDownCanMoveWindow: Bool { false }
    var onBeginEditing: ((NSTextField) -> Void)?
    var onChange: ((NSTextField) -> Void)?
    var onEndEditing: ((NSTextField) -> Void)?
    var onCommand: ((NSTextField, Selector) -> Bool)?
    var onExpandedEntranceBeam: (() -> Void)?
    private let field: NSTextField
    private let glassBackdrop = NSVisualEffectView()
    private let glazeView = NSView()
    private let glaze = CAGradientLayer()
    private let searchIcon = NSImageView()
    private let glassRim = CAGradientLayer()
    private let rimStroke = CAShapeLayer()
    private var focused = false
    private let focusSweep = CAGradientLayer()
    private let loadingTrack = CAShapeLayer()
    private let loadingBeam = CAShapeLayer()
    private let loadingGradient = CAGradientLayer()
    private let entranceTrack = CAShapeLayer()
    private let entranceAuraStroke = CAShapeLayer()
    private let entranceAura = CAGradientLayer()
    private let entranceBeam = CAShapeLayer()
    private let entranceGradient = CAGradientLayer()
    private var loadingProgress: CGFloat = 0
    private var suggestionsAttached = false
    private let attachedClip = CAShapeLayer()
    private var addressCornerRadius: CGFloat = 16
    var expandedCornerRadius: CGFloat { addressCornerRadius }

    init(field: NSTextField) {
        self.field = field
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = false
        glassBackdrop.material = .hudWindow
        glassBackdrop.blendingMode = .withinWindow
        glassBackdrop.state = .active
        glassBackdrop.wantsLayer = true
        glassBackdrop.layer?.masksToBounds = true
        addSubview(glassBackdrop)
        glazeView.wantsLayer = true
        glazeView.layer?.masksToBounds = true
        glazeView.layer?.addSublayer(glaze)
        addSubview(glazeView)
        glaze.startPoint = CGPoint(x: 0, y: 1)
        glaze.endPoint = CGPoint(x: 1, y: 0)
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.imageScaling = .scaleProportionallyDown
        addSubview(searchIcon)
        glassRim.startPoint = CGPoint(x: 0, y: 1)
        glassRim.endPoint = CGPoint(x: 1, y: 0)
        rimStroke.fillColor = nil
        rimStroke.strokeColor = NSColor.white.cgColor
        rimStroke.lineWidth = 1.2
        glassRim.mask = rimStroke
        layer?.addSublayer(glassRim)
        focusSweep.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.25).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor
        ]
        focusSweep.startPoint = CGPoint(x: 0, y: 0.5)
        focusSweep.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(focusSweep)
        loadingTrack.fillColor = nil
        loadingTrack.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        loadingTrack.lineWidth = 2
        loadingTrack.opacity = 0
        layer?.addSublayer(loadingTrack)
        loadingBeam.fillColor = nil
        loadingBeam.strokeColor = NSColor.white.cgColor
        loadingBeam.lineWidth = 2.5
        loadingBeam.lineCap = .round
        loadingBeam.strokeEnd = 0
        loadingBeam.shadowColor = NSColor.controlAccentColor.cgColor
        loadingBeam.shadowOpacity = 0.7
        loadingBeam.shadowRadius = 7
        loadingBeam.opacity = 0
        loadingGradient.mask = loadingBeam
        layer?.addSublayer(loadingGradient)
        entranceTrack.fillColor = nil
        entranceTrack.strokeColor = NSColor.systemPink.withAlphaComponent(0.25).cgColor
        entranceTrack.lineWidth = 1.25
        entranceTrack.opacity = 0
        layer?.addSublayer(entranceTrack)
        entranceAuraStroke.fillColor = nil
        entranceAuraStroke.strokeColor = NSColor.white.cgColor
        entranceAuraStroke.lineWidth = 11
        entranceAuraStroke.lineCap = .round
        entranceAuraStroke.opacity = 0
        entranceAura.mask = entranceAuraStroke
        layer?.addSublayer(entranceAura)
        entranceBeam.fillColor = nil
        entranceBeam.strokeColor = NSColor.white.cgColor
        entranceBeam.lineWidth = 3
        entranceBeam.lineCap = .round
        entranceBeam.opacity = 0
        entranceGradient.mask = entranceBeam
        layer?.addSublayer(entranceGradient)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        if (field.font?.pointSize ?? 0) < 14 { field.font = .systemFont(ofSize: 14) }
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 46),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        applyTheme(BrowserTheme.profile)
        updateGlass()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if !suggestionsAttached { addressCornerRadius = layer?.cornerRadius ?? 16 }
        glassBackdrop.frame = bounds
        glassBackdrop.layer?.cornerRadius = suggestionsAttached ? 0 : (layer?.cornerRadius ?? 16)
        glazeView.frame = bounds
        glazeView.layer?.cornerRadius = suggestionsAttached ? 0 : (layer?.cornerRadius ?? 16)
        glaze.frame = glazeView.bounds
        searchIcon.frame = NSRect(x: 17, y: (bounds.height - 19) / 2, width: 19, height: 19)
        focusSweep.frame = CGRect(x: -bounds.width * 0.5, y: bounds.height - 1, width: bounds.width * 0.5, height: 1)
        let path = CGPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                          cornerWidth: max(0, addressCornerRadius - 1.5),
                          cornerHeight: max(0, addressCornerRadius - 1.5), transform: nil)
        glassRim.frame = bounds
        rimStroke.frame = bounds
        rimStroke.path = path
        if suggestionsAttached {
            attachedClip.frame = bounds
            attachedClip.path = attachedShapePath(in: bounds)
        }
        loadingTrack.frame = bounds
        loadingTrack.path = path
        loadingBeam.frame = bounds
        loadingBeam.path = path
        loadingGradient.frame = bounds
        entranceTrack.frame = bounds
        entranceTrack.path = path
        entranceAura.frame = bounds
        entranceAuraStroke.frame = bounds
        entranceAuraStroke.path = path
        entranceBeam.frame = bounds
        entranceBeam.path = path
        entranceGradient.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === searchIcon || hit === glazeView || hit === glassBackdrop { return self }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    func applyTheme(_ profile: PetGradientProfile) {
        BrowserTheme.apply(profile.gradients.working, to: loadingGradient)
        BrowserTheme.apply(profile.gradients.ambient, to: entranceGradient)
        BrowserTheme.apply(profile.gradients.ambient, to: entranceAura)
        let accent = BrowserTheme.color(profile.palette.accent)
        loadingTrack.strokeColor = accent.withAlphaComponent(0.2).cgColor
        entranceTrack.strokeColor = accent.withAlphaComponent(0.48).cgColor
        loadingBeam.shadowColor = accent.cgColor
        glaze.colors = [BrowserTheme.color(profile.palette.highlight, alpha: 0.14).cgColor,
                        accent.withAlphaComponent(0.035).cgColor,
                        NSColor.white.withAlphaComponent(0.08).cgColor]
        glassRim.colors = [NSColor.white.withAlphaComponent(0.74).cgColor,
                           BrowserTheme.color(profile.palette.highlight, alpha: 0.55).cgColor,
                           NSColor.white.withAlphaComponent(0.20).cgColor,
                           accent.withAlphaComponent(0.48).cgColor]
        glassRim.locations = [0, 0.18, 0.65, 1]
        glassRim.shadowColor = accent.cgColor
        glassRim.shadowRadius = 6
        updateGlass()
    }

    func playEntranceBeam() {
        entranceTrack.removeAllAnimations()
        entranceAuraStroke.removeAllAnimations()
        entranceBeam.removeAllAnimations()
        if suggestionsAttached {
            onExpandedEntranceBeam?()
            return
        }
        guard Motion.enabled, bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        entranceTrack.opacity = 0
        entranceAuraStroke.opacity = 0
        entranceAuraStroke.strokeStart = 0
        entranceAuraStroke.strokeEnd = 0
        entranceBeam.opacity = 0
        entranceBeam.strokeStart = 0
        entranceBeam.strokeEnd = 0
        CATransaction.commit()

        let trackFade = CAKeyframeAnimation(keyPath: "opacity")
        trackFade.values = [0, 0.75, 0.75, 0]
        trackFade.keyTimes = [0, 0.12, 0.72, 1]
        trackFade.duration = 0.92
        entranceTrack.add(trackFade, forKey: "entranceTrack")

        let beamStart = CAKeyframeAnimation(keyPath: "strokeStart")
        beamStart.values = [0, 0, 0.69, 1]
        beamStart.keyTimes = [0, 0.20, 0.77, 1]
        beamStart.duration = 0.92
        let beamEnd = CAKeyframeAnimation(keyPath: "strokeEnd")
        beamEnd.values = [0.02, 0.28, 0.91, 1]
        beamEnd.keyTimes = [0, 0.20, 0.77, 1]
        beamEnd.duration = 0.92
        let beamOpacity = CAKeyframeAnimation(keyPath: "opacity")
        beamOpacity.values = [0, 1, 1, 0]
        beamOpacity.keyTimes = [0, 0.08, 0.78, 1]
        beamOpacity.duration = 0.92
        let sweep = CAAnimationGroup()
        sweep.animations = [beamStart, beamEnd, beamOpacity]
        sweep.duration = 0.92
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 0.72, 0.28, 1)
        entranceBeam.add(sweep, forKey: "entranceBeam")
        let auraOpacity = CAKeyframeAnimation(keyPath: "opacity")
        auraOpacity.values = [0, 0.63, 0.63, 0]
        auraOpacity.keyTimes = [0, 0.08, 0.78, 1]
        auraOpacity.duration = 0.92
        let auraSweep = CAAnimationGroup()
        auraSweep.animations = [beamStart.copy() as! CAAnimation, beamEnd.copy() as! CAAnimation, auraOpacity]
        auraSweep.duration = 0.92
        auraSweep.timingFunction = sweep.timingFunction
        entranceAuraStroke.add(auraSweep, forKey: "entranceAura")
    }

    func setSuggestionsAttached(_ attached: Bool) {
        guard suggestionsAttached != attached else { return }
        if attached { addressCornerRadius = layer?.cornerRadius ?? 16 }
        suggestionsAttached = attached
        // A CALayer rounds its own background even with masksToBounds disabled.
        // Keep the original radius in the clip path while the suggestions are attached.
        layer?.cornerRadius = attached ? 0 : addressCornerRadius
        layer?.mask = attached ? attachedClip : nil
        // The bar and results use the same material while expanded; its standalone
        // glaze would otherwise create a visible horizontal change in tone.
        glaze.opacity = attached ? 0 : 1
        glassRim.opacity = attached ? 0 : 1
        if attached {
            entranceTrack.removeAllAnimations()
            entranceAuraStroke.removeAllAnimations()
            entranceBeam.removeAllAnimations()
        }
        updateGlass()
        needsLayout = true
    }

    private func attachedShapePath(in rect: CGRect) -> CGPath {
        let radius = min(addressCornerRadius, rect.width / 2, rect.height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGlass()
    }

    func startLoading() {
        loadingProgress = 0
        loadingBeam.removeAnimation(forKey: "strokeEnd")
        loadingBeam.strokeEnd = 0
        loadingTrack.opacity = 1
        loadingBeam.opacity = 1
    }

    func setLoadingProgress(_ fraction: Double) {
        let next = max(loadingProgress, CGFloat(min(1, max(0, fraction))))
        guard next > loadingProgress else { return }
        let current = loadingBeam.presentation()?.strokeEnd ?? loadingBeam.strokeEnd
        loadingProgress = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loadingBeam.strokeEnd = next
        CATransaction.commit()
        Motion.basic(loadingBeam, key: "strokeEnd", from: current, to: next, duration: 0.16)
    }

    func stopLoading() {
        loadingBeam.removeAnimation(forKey: "strokeEnd")
        loadingTrack.opacity = 0
        loadingBeam.opacity = 0
        loadingProgress = 0
        loadingBeam.strokeEnd = 0
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        let oldColor = layer?.borderColor
        focused = true
        updateGlass()
        if let oldColor, let newColor = layer?.borderColor {
            Motion.basic(layer, key: "borderColor", from: oldColor, to: newColor, duration: 0.18)
        }
        Motion.basic(focusSweep, key: "transform.translation.x", from: 0, to: bounds.width * 1.5, duration: 0.34)
        onBeginEditing?(field)
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        onCommand?(field, commandSelector) ?? false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let oldColor = layer?.borderColor
        focused = false
        updateGlass()
        if let oldColor, let newColor = layer?.borderColor {
            Motion.basic(layer, key: "borderColor", from: oldColor, to: newColor, duration: 0.18)
        }
        onEndEditing?(field)
    }

    private func updateGlass() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let transparency = BrowserGlass.topTransparency
        glassBackdrop.alphaValue = suggestionsAttached ? 1 : 0.60 - transparency * 0.18
        layer?.backgroundColor = suggestionsAttached
            ? NSColor.black.withAlphaComponent(0.12).cgColor
            : NSColor.black.withAlphaComponent((dark ? 0.17 : 0.07) * (1 - transparency * 0.65)).cgColor
        layer?.borderWidth = suggestionsAttached ? 0 : 0.5
        layer?.borderColor = focused
            ? BrowserTheme.color(BrowserTheme.profile.palette.accent, alpha: 0.72).cgColor
            : NSColor.white.withAlphaComponent(dark ? 0.32 : 0.42).cgColor
        glassRim.shadowOpacity = focused ? 0.42 : 0.18
    }

    func applyGlassTransparency() { updateGlass() }
}
