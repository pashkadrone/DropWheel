import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = DragWatcher()
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()

        let menu = NSMenu()
        menu.delegate = self
        for title in ["Тащи файл и зажми Shift — сменить формат", "Тащи файл и зажми Command — инструменты"] {
            let hint = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        watcher.start()
    }

    /// Маленькое колесо из шести секторов; шаблонная картинка сама подстраивается под светлую и тёмную строку меню.
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            for index in 0..<6 {
                let middle = 90 - CGFloat(index) * 60
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: 8, startAngle: middle + 25, endAngle: middle - 25, clockwise: true)
                path.appendArc(withCenter: center, radius: 3.4, startAngle: middle - 25, endAngle: middle + 25, clockwise: false)
                path.close()
                NSColor.black.setFill()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DropWheel"
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }
}
