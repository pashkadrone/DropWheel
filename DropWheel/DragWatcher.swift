import AppKit

/// Следит за перетаскиванием файлов: Shift показывает колесо форматов, Command — колесо инструментов.
/// Работает опросом состояния мыши и клавиш, поэтому не требует системных разрешений.
final class DragWatcher {
    private let dragPasteboard = NSPasteboard(name: .drag)
    private let wheel = WheelPanel()
    private let toast = Toast()
    private var timer: Timer?
    private var wasDown = false
    private var countAtMouseDown = 0
    private var wheelCenter = NSPoint.zero

    func start() {
        wheel.wheelView.onDrop = { [weak self] urls, format in self?.convert(urls, to: format) }
        wheel.wheelView.onCancel = { [weak self] in self?.wheel.hide() }

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down && !wasDown {
            countAtMouseDown = dragPasteboard.changeCount
        }
        if down && !wheel.isVisible {
            let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.shift) && !flags.contains(.command) {
                showWheelIfDraggingFiles(tools: false)
            } else if flags.contains(.command) && !flags.contains(.shift) {
                showWheelIfDraggingFiles(tools: true)
            }
        }
        if !down && wasDown && wheel.isVisible {
            // Даём системе доставить событие «бросили файл», потом прячем колесо.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.wheel.hide() }
        }
        wasDown = down
    }

    private func showWheelIfDraggingFiles(tools: Bool) {
        // Счётчик меняется, когда начинается новое перетаскивание: так отсекаем обычные движения мыши.
        guard dragPasteboard.changeCount != countAtMouseDown,
              dragPasteboard.types?.contains(.fileURL) == true else { return }
        let urls = dragPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let provider: ([URL]) -> [Format] = { urls in
            if tools { return Converter.tools(for: urls) }
            return urls.first.map { Converter.formats(for: $0) } ?? []
        }
        let formats = provider(urls)
        guard !formats.isEmpty else { return }
        wheel.wheelView.provider = provider
        wheelCenter = NSEvent.mouseLocation
        wheel.show(at: wheelCenter, formats: formats)
    }

    private func convert(_ urls: [URL], to format: Format) {
        wheel.hide()
        let files = urls.filter { FileKind.of($0) == format.kind }
        guard !files.isEmpty else { return }
        let center = wheelCenter
        toast.show(format.isTool ? "\(format.label)…" : "Конвертирую в \(format.label)…", at: center, autoHide: false)

        Task.detached(priority: .userInitiated) { [toast] in
            var done = 0
            var lastError: String?
            if format.batch {
                do {
                    _ = try await Converter.convertBatch(files, to: format)
                    done = files.count
                } catch {
                    lastError = error.localizedDescription
                }
            } else {
                for file in files {
                    do {
                        _ = try await Converter.convert(file, to: format)
                        done += 1
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
            }
            let message: String
            if let lastError, done == 0 {
                message = "Не получилось: \(lastError)"
            } else if lastError != nil {
                message = "Готово: \(done) из \(files.count)"
            } else if format.isTool {
                message = files.count == 1 ? "Готово: \(format.label)" : "Готово: \(format.label), файлов: \(done)"
            } else {
                message = files.count == 1 ? "Готово → \(format.label)" : "Готово: \(done) → \(format.label)"
            }
            let failed = done == 0
            await MainActor.run {
                toast.show(message, at: center, autoHide: true)
                if failed { NSSound.beep() } else { NSSound(named: "Glass")?.play() }
            }
        }
    }
}
