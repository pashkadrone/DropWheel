import AppKit

/// Прозрачное окно с колесом форматов, которое появляется вокруг курсора.
final class WheelPanel: NSPanel {
    static let side: CGFloat = 320
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    /// Номер сектора под точкой; nil в центре и за пределами колеса.
    private func sector(at point: NSPoint) -> Int? {
        guard !formats.isEmpty else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= innerRadius, distance <= outerRadius + 14 else { return nil }
        let width = 2 * CGFloat.pi / CGFloat(formats.count)
        var angle = atan2(dx, dy) // 0 сверху, растёт по часовой стрелке
        if angle < 0 { angle += 2 * .pi }
        return Int((angle + width / 2) / width) % formats.count
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = formats.count
        guard count > 0 else { return }
        let width = 360 / CGFloat(count)
        let gap: CGFloat = count > 1 ? 1.4 : 0

        for index in 0..<count {
            let middle = 90 - CGFloat(index) * width
            let start = middle + width / 2 - gap
            let end = middle - width / 2 + gap
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: true)
            path.appendArc(withCenter: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: false)
            path.close()

            let isActive = index == highlighted
            (isActive ? NSColor.controlAccentColor : NSColor(white: 0.11, alpha: 0.9)).setFill()
            path.fill()

            let radians = middle * .pi / 180
            let labelRadius = (outerRadius + innerRadius) / 2
            let labelPoint = NSPoint(x: center.x + cos(radians) * labelRadius,
                                     y: center.y + sin(radians) * labelRadius)
            let label = formats[index].label
            let base: CGFloat = label.count > 6 ? 12.5 : 15
            drawLabel(label, at: labelPoint,
                      font: .systemFont(ofSize: isActive ? base + 2 : base, weight: .bold), color: .white)
        }

        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - innerRadius + 5, y: center.y - innerRadius + 5,
                                              width: (innerRadius - 5) * 2, height: (innerRadius - 5) * 2))
        NSColor(white: 0.11, alpha: 0.9).setFill()
        hub.fill()
        drawLabel("отмена", at: center, font: .systemFont(ofSize: 11, weight: .medium),
                  color: NSColor(white: 1, alpha: 0.55))
    }

    private func drawLabel(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
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
