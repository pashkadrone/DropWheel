import AppKit

/// Окно обрезки: показывает картинку, даёт выделить область мышью и сохраняет обрезанную копию.
final class CropWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let cropView: CropView
    private let sizeLabel = NSTextField(labelWithString: "")
    private let url: URL
    private let fullSize: CGSize
    /// nil — пользователь отменил обрезку.
    private let onFinish: (Result<URL, Error>?) -> Void
    private var finished = false

    private static let barHeight: CGFloat = 52
    private static let aspects: [(title: String, value: CGFloat?)] = [
        ("Свободно", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("16:9", 16.0 / 9),
    ]

    init?(url: URL, onFinish: @escaping (Result<URL, Error>?) -> Void) {
        guard let preview = Converter.previewImage(url, maxPixel: 2400) else { return nil }
        self.url = url
        self.fullSize = preview.fullSize
        self.onFinish = onFinish

        // Картинка вписывается в 80% экрана, но не больше 1000×700.
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let limit = NSSize(width: min(screen.width * 0.8, 1000), height: min(screen.height * 0.8 - Self.barHeight, 700))
        let scale = min(limit.width / preview.fullSize.width, limit.height / preview.fullSize.height, 1)
        let viewSize = NSSize(width: max(preview.fullSize.width * scale, 60).rounded(),
                              height: max(preview.fullSize.height * scale, 60).rounded())
        let contentSize = NSSize(width: max(viewSize.width, 560), height: viewSize.height + Self.barHeight)

        cropView = CropView(frame: NSRect(x: ((contentSize.width - viewSize.width) / 2).rounded(), y: Self.barHeight,
                                          width: viewSize.width, height: viewSize.height), image: preview.image)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        window.title = "Обрезка — \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))
        window.contentView = content
        content.addSubview(cropView)

        let aspectControl = NSSegmentedControl(labels: Self.aspects.map(\.title), trackingMode: .selectOne,
                                               target: self, action: #selector(aspectChanged(_:)))
        aspectControl.selectedSegment = 0
        aspectControl.sizeToFit()
        aspectControl.setFrameOrigin(NSPoint(x: 16, y: (Self.barHeight - aspectControl.frame.height) / 2))
        content.addSubview(aspectControl)

        let cropButton = NSButton(title: "Обрезать", target: self, action: #selector(confirm))
        cropButton.keyEquivalent = "\r"
        cropButton.sizeToFit()
        cropButton.setFrameOrigin(NSPoint(x: contentSize.width - cropButton.frame.width - 16,
                                          y: (Self.barHeight - cropButton.frame.height) / 2))
        content.addSubview(cropButton)

        let cancelButton = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.sizeToFit()
        cancelButton.setFrameOrigin(NSPoint(x: cropButton.frame.minX - cancelButton.frame.width - 8,
                                            y: cropButton.frame.minY))
        content.addSubview(cancelButton)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.frame = NSRect(x: aspectControl.frame.maxX + 12, y: (Self.barHeight - 16) / 2,
                                 width: max(cancelButton.frame.minX - aspectControl.frame.maxX - 20, 0), height: 16)
        content.addSubview(sizeLabel)

        cropView.onChange = { [weak self] in self?.updateSizeLabel() }
        updateSizeLabel()
    }

    /// Только для проверки внешнего вида из терминала.
    var contentViewForRendering: NSView? {
        window.layoutIfNeeded()
        window.display()
        return window.contentView
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func updateSizeLabel() {
        let area = cropView.normalized
        sizeLabel.stringValue = "\(Int((area.width * fullSize.width).rounded())) × \(Int((area.height * fullSize.height).rounded()))"
    }

    @objc private func aspectChanged(_ sender: NSSegmentedControl) {
        cropView.aspect = Self.aspects[sender.selectedSegment].value
    }

    @objc private func confirm() {
        guard !finished else { return }
        finished = true
        let url = url, area = cropView.normalized, onFinish = onFinish
        window.close()
        Task.detached(priority: .userInitiated) {
            let result = Result { try Converter.cropImage(url, to: area) }
            await MainActor.run { onFinish(result) }
        }
    }

    @objc private func cancel() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        onFinish(nil)
    }
}

/// Картинка с рамкой выделения. Тянуть за угол — менять размер, внутри рамки — двигать, снаружи — выделить заново.
final class CropView: NSView {
    private let image: CGImage
    private(set) var selection: CGRect
    var onChange: (() -> Void)?
    /// Соотношение сторон (ширина / высота); nil — свободное.
    var aspect: CGFloat? { didSet { applyAspect() } }

    private enum Drag {
        case stretch(anchor: CGPoint)
        case move(offset: CGSize)
    }
    private var drag: Drag?
    private var selectionBeforeDrag = CGRect.zero

    init(frame: NSRect, image: CGImage) {
        self.image = image
        selection = CGRect(origin: .zero, size: frame.size).insetBy(dx: frame.width * 0.1, dy: frame.height * 0.1)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    /// Выделение в долях картинки, начало координат в левом верхнем углу.
    var normalized: CGRect {
        CGRect(x: selection.minX / bounds.width, y: 1 - selection.maxY / bounds.height,
               width: selection.width / bounds.width, height: selection.height / bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)

        // Затемняем всё, кроме выделения.
        context.addRect(bounds)
        context.addRect(selection)
        context.setFillColor(CGColor(gray: 0, alpha: 0.58))
        context.fillPath(using: .evenOdd)

        // Сетка третей.
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        context.setLineWidth(1)
        for step in 1...2 {
            let x = selection.minX + selection.width * CGFloat(step) / 3
            let y = selection.minY + selection.height * CGFloat(step) / 3
            context.move(to: CGPoint(x: x, y: selection.minY)); context.addLine(to: CGPoint(x: x, y: selection.maxY))
            context.move(to: CGPoint(x: selection.minX, y: y)); context.addLine(to: CGPoint(x: selection.maxX, y: y))
        }
        context.strokePath()

        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1.5)
        context.stroke(selection)

        // Ручки по углам.
        context.setShadow(offset: .zero, blur: 3, color: CGColor(gray: 0, alpha: 0.5))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for corner in corners(of: selection) {
            context.fillEllipse(in: CGRect(x: corner.x - 5.5, y: corner.y - 5.5, width: 11, height: 11))
        }
    }

    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    /// Прямоугольник от неподвижной точки до курсора с учётом соотношения сторон.
    private func rect(from anchor: CGPoint, to point: CGPoint) -> CGRect {
        var width = point.x - anchor.x, height = point.y - anchor.y
        if let aspect {
            let absWidth = abs(width), absHeight = abs(height)
            if absHeight == 0 || absWidth / absHeight > aspect {
                width = (width < 0 ? -1 : 1) * absHeight * aspect
            } else {
                height = (height < 0 ? -1 : 1) * absWidth / aspect
            }
        }
        return CGRect(x: min(anchor.x, anchor.x + width), y: min(anchor.y, anchor.y + height),
                      width: abs(width), height: abs(height))
    }

    private func applyAspect() {
        guard let aspect else { return }
        var width = selection.width, height = width / aspect
        if height > bounds.height { height = bounds.height; width = height * aspect }
        if width > bounds.width { width = bounds.width; height = width / aspect }
        let x = min(max(selection.midX - width / 2, 0), bounds.width - width)
        let y = min(max(selection.midY - height / 2, 0), bounds.height - height)
        selection = CGRect(x: x, y: y, width: width, height: height)
        needsDisplay = true
        onChange?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        selectionBeforeDrag = selection
        let all = corners(of: selection)
        if let index = all.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= 12 }) {
            drag = .stretch(anchor: all[(index + 2) % 4]) // неподвижен противоположный угол
        } else if selection.contains(point) {
            drag = .move(offset: CGSize(width: point.x - selection.minX, height: point.y - selection.minY))
        } else {
            drag = .stretch(anchor: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        switch drag {
        case .stretch(let anchor):
            selection = rect(from: anchor, to: point)
        case .move(let offset):
            selection.origin = CGPoint(x: min(max(point.x - offset.width, 0), bounds.width - selection.width),
                                       y: min(max(point.y - offset.height, 0), bounds.height - selection.height))
        case nil:
            return
        }
        needsDisplay = true
        onChange?()
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        // Случайный клик не должен оставить выделение размером в точку.
        if selection.width < 8 || selection.height < 8 {
            selection = selectionBeforeDrag
            needsDisplay = true
            onChange?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}
