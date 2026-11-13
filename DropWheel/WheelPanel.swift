import AppKit

/// Прозрачное окно с колесом форматов, которое появляется вокруг курсора.
final class WheelPanel: NSPanel {
    static let side: CGFloat = 340
    let wheelView = WheelView(frame: NSRect(x: 0, y: 0, width: WheelPanel.side, height: WheelPanel.side))

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: WheelPanel.side, height: WheelPanel.side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        wheelView.wantsLayer = true
        contentView = wheelView
    }

    override var canBecomeKey: Bool { false }

    func show(at point: NSPoint, formats: [Format]) {
        wheelView.formats = formats
        wheelView.highlighted = nil
        var origin = NSPoint(x: point.x - WheelPanel.side / 2, y: point.y - WheelPanel.side / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let area = screen.visibleFrame
            origin.x = min(max(origin.x, area.minX), area.maxX - WheelPanel.side)
            origin.y = min(max(origin.y, area.minY), area.maxY - WheelPanel.side)
        }
        setFrameOrigin(origin)
        alphaValue = 0
        orderFrontRegardless()
        wheelView.animateIn()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
    }
}

final class WheelView: NSView {
    var formats: [Format] = [] { didSet { needsDisplay = true } }
    var highlighted: Int? { didSet { if oldValue != highlighted { needsDisplay = true } } }
    var onDrop: (([URL], Format) -> Void)?
    var onCancel: (() -> Void)?
    /// Какие секторы показать для перетаскиваемых файлов (зависит от режима: форматы или инструменты).
    var provider: (([URL]) -> [Format])?

    private let outerRadius: CGFloat = 140
    private let innerRadius: CGFloat = 46
    /// Насколько активный сектор выдвигается наружу.
    private let pop: CGFloat = 9

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    /// Появление: колесо «вырастает» из курсора с лёгкой пружиной.
    func animateIn() {
        guard let layer else { return }
        let middle = center
        var small = CATransform3DMakeTranslation(middle.x, middle.y, 0)
        small = CATransform3DScale(small, 0.72, 0.72, 1)
        small = CATransform3DTranslate(small, -middle.x, -middle.y, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = small
        spring.toValue = CATransform3DIdentity
        spring.damping = 15
        spring.stiffness = 280
        spring.duration = min(spring.settlingDuration, 0.5)
        layer.add(spring, forKey: "appear")
    }

    /// Номер сектора под точкой; nil в центре и за пределами колеса.
    private func sector(at point: NSPoint) -> Int? {
        guard !formats.isEmpty else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= innerRadius, distance <= outerRadius + 18 else { return nil }
        let width = 2 * CGFloat.pi / CGFloat(formats.count)
        var angle = atan2(dx, dy) // 0 сверху, растёт по часовой стрелке
        if angle < 0 { angle += 2 * .pi }
        return Int((angle + width / 2) / width) % formats.count
    }

    // MARK: - Рисование

    private struct Theme {
        let fill, activeText, text, mutedText, border: NSColor
    }

    private var theme: Theme {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? Theme(fill: NSColor(white: 0.12, alpha: 0.93), activeText: .white, text: .white,
                    mutedText: NSColor(white: 1, alpha: 0.5), border: NSColor(white: 1, alpha: 0.14))
            : Theme(fill: NSColor(white: 0.985, alpha: 0.95), activeText: .white, text: NSColor(white: 0.13, alpha: 1),
                    mutedText: NSColor(white: 0, alpha: 0.42), border: NSColor(white: 0, alpha: 0.1))
    }

    private func sectorPath(index: Int, count: Int, outer: CGFloat) -> NSBezierPath {
        let width = 360 / CGFloat(count)
        let gap: CGFloat = count > 1 ? 1.3 : 0
        let middle = 90 - CGFloat(index) * width
        let start = middle + width / 2 - gap, end = middle - width / 2 + gap
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: outer, startAngle: start, endAngle: end, clockwise: true)
        path.appendArc(withCenter: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: false)
        path.close()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = formats.count
        guard count > 0 else { return }
        let theme = theme
        let width = 360 / CGFloat(count)

        // Мягкая тень под всем колесом.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - outerRadius, y: center.y - outerRadius,
                                               width: outerRadius * 2, height: outerRadius * 2))
        ring.append(NSBezierPath(ovalIn: NSRect(x: center.x - innerRadius, y: center.y - innerRadius,
                                                width: innerRadius * 2, height: innerRadius * 2)).reversed)
        theme.fill.withAlphaComponent(0.5).setFill()
        ring.fill()
        NSGraphicsContext.restoreGraphicsState()

        for index in 0..<count {
            let isActive = index == highlighted
            let path = sectorPath(index: index, count: count, outer: outerRadius + (isActive ? pop : 0))
            (isActive ? NSColor.controlAccentColor : theme.fill).setFill()
            path.fill()
            if !isActive {
                theme.border.setStroke()
                path.lineWidth = 1
                path.stroke()
            }

            let radians = (90 - CGFloat(index) * width) * .pi / 180
            let radius = (outerRadius + innerRadius) / 2 + (isActive ? pop / 2 : 0)
            let point = NSPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
            let color = isActive ? theme.activeText : theme.text
            let label = formats[index].label
            let fontSize: CGFloat = label.count > 6 ? 11.5 : 13.5
            let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)

            if let icon = Self.icon(for: formats[index], size: isActive ? 20 : 18, color: color) {
                let size = icon.size
                icon.draw(in: NSRect(x: point.x - size.width / 2, y: point.y + 13 - size.height / 2,
                                     width: size.width, height: size.height))
                drawLabel(label, at: NSPoint(x: point.x, y: point.y - 12), font: font, color: color)
            } else {
                drawLabel(label, at: point, font: font, color: color)
            }
        }

        // Центр: бросить сюда — отменить.
        let hubRadius = innerRadius - 6
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - hubRadius, y: center.y - hubRadius,
                                              width: hubRadius * 2, height: hubRadius * 2))
        theme.fill.setFill()
        hub.fill()
        theme.border.setStroke()
        hub.lineWidth = 1
        hub.stroke()
        if let cross = Self.symbol("xmark", size: 15, color: theme.mutedText) {
            let size = cross.size
            cross.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                  width: size.width, height: size.height))
        }
    }

    private func drawLabel(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }

    // MARK: - Иконки секторов

    private static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private static func icon(for format: Format, size: CGFloat, color: NSColor) -> NSImage? {
        let name: String
        switch format.label {
        case "Сжать": name = "arrow.down.right.and.arrow.up.left"
        case "50%", "1920px", "1280px": name = "arrow.up.left.and.arrow.down.right"
        case "В PDF": name = "doc.on.doc"
        case "Без звука": name = "speaker.slash"
        case "Склеить": name = "rectangle.stack"
        case "Разделить": name = "square.split.2x1"
        case "В JPG": name = "photo.on.rectangle"
        case "PDF": name = "doc.richtext"
        case "GIF": name = "photo.stack"
        case "MP4", "MOV": name = "film"
        case "HEVC": name = "film.stack"
        case "1080p", "720p", "480p": name = "rectangle.compress.vertical"
        case "M4A", "WAV", "AIFF": name = "waveform"
        default: name = "photo"
        }
        return symbol(name, size: size, color: color)
    }

    // MARK: - Приём перетаскиваемых файлов

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let actual = provider?(fileURLs(sender)), !actual.isEmpty,
           actual.map(\.label) != formats.map(\.label) {
            formats = actual
        }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = sector(at: convert(sender.draggingLocation, from: nil))
        return highlighted == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard let index = sector(at: convert(sender.draggingLocation, from: nil)), !urls.isEmpty else {
            onCancel?()
            return false
        }
        onDrop?(urls, formats[index])
        return true
    }
}
