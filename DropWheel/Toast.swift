import AppKit

/// Небольшая плашка с сообщением о ходе и результате конвертации.
final class Toast {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.94).cgColor
        background.layer?.cornerRadius = 12
        panel.contentView = background

        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        background.addSubview(label)
    }

    func show(_ text: String, at point: NSPoint, autoHide: Bool) {
        hideWork?.cancel()
        label.stringValue = text
        label.sizeToFit()
        let width = min(label.frame.width, 420)
        let size = NSSize(width: width + 32, height: 40)
        label.frame = NSRect(x: 16, y: (size.height - label.frame.height) / 2, width: width, height: label.frame.height)

        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let area = screen.visibleFrame
            origin.x = min(max(origin.x, area.minX + 8), area.maxX - size.width - 8)
            origin.y = min(max(origin.y, area.minY + 8), area.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        if autoHide {
            let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
        }
    }
}
