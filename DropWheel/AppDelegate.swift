import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = DragWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
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

    // MARK: - Меню

    /// Меню собирается заново при каждом открытии, поэтому галочки всегда соответствуют настройкам.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for title in ["Тащи файл и зажми Shift — сменить формат", "Тащи файл и зажми Command — инструменты"] {
            let hint = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())

        // Качество
        let quality = NSMenu()
        for level in Settings.qualityLevels {
            let item = action("\(level.title) (\(Int(level.value * 100))%)", #selector(chooseQuality(_:)))
            item.representedObject = level.value
            item.state = abs(Settings.quality - level.value) < 0.001 ? .on : .off
            quality.addItem(item)
        }
        menu.addItem(submenu("Качество JPG, HEIC и AVIF", quality))

        // Куда сохранять
        let folder = NSMenu()
        let beside = action("Рядом с оригиналом", #selector(saveBeside))
        beside.state = Settings.outputFolder == nil ? .on : .off
        folder.addItem(beside)
        if let current = Settings.outputFolder {
            let item = NSMenuItem(title: "В папку «\(current.lastPathComponent)»", action: nil, keyEquivalent: "")
            item.state = .on
            item.toolTip = current.path
            folder.addItem(item)
        }
        folder.addItem(.separator())
        folder.addItem(action("Выбрать папку…", #selector(chooseFolder)))
        menu.addItem(submenu("Куда сохранять", folder))

        // Какие форматы показывать в колесе
        for (title, kind) in [("Форматы картинок", FileKind.image), ("Форматы видео", FileKind.video)] {
            let formats = NSMenu()
            for label in Converter.formatLabels(for: kind) {
                let item = action(label, #selector(toggleFormat(_:)))
                item.representedObject = [kind.rawValue, label]
                item.state = Settings.isHidden(kind, label) ? .off : .on
                formats.addItem(item)
            }
            menu.addItem(submenu(title, formats))
        }

        menu.addItem(.separator())
        let login = action("Запускать при входе", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: - Действия

    @objc private func chooseQuality(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { Settings.quality = value }
    }

    @objc private func saveBeside() {
        Settings.outputFolder = nil
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Папка, куда DropWheel будет класть готовые файлы"
        panel.directoryURL = Settings.outputFolder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Settings.outputFolder = url
        }
    }

    @objc private func toggleFormat(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let kind = FileKind(rawValue: pair[0]) else { return }
        let label = pair[1]
        if Settings.isHidden(kind, label) {
            Settings.setHidden(false, kind, label)
            return
        }
        // Хотя бы два формата должны остаться, иначе для части файлов колесо окажется пустым.
        let visible = Converter.formatLabels(for: kind).filter { !Settings.isHidden(kind, $0) }
        if visible.count > 2 {
            Settings.setHidden(true, kind, label)
        } else {
            NSSound.beep()
        }
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
