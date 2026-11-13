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
    private var job: Task<Void, Never>?
    private var jobID = 0
    /// Номер работы, которой сейчас принадлежит плашка; nil, когда ничего не выполняется.
    private var runningID: Int?

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

        jobID += 1
        let id = jobID
        runningID = id
        let center = wheelCenter
        let title = format.isTool ? "\(format.label)…" : "Конвертирую в \(format.label)…"
        let cancel: () -> Void = { [weak self] in self?.cancelJob(id, at: center) }
        toast.show(title, at: center, autoHide: false, onClick: cancel)

        // fraction — готовность текущего файла (известна только для видео и звука из видео).
        let report: @Sendable (Int, Double?) -> Void = { [weak self] index, fraction in
            DispatchQueue.main.async {
                guard let self, self.runningID == id else { return }
                var text = title
                if let fraction { text += " \(Int(fraction * 100))%" }
                if files.count > 1 { text += " · \(index + 1) из \(files.count)" }
                let overall = (Double(index) + (fraction ?? 0)) / Double(files.count)
                self.toast.show(text, at: center, autoHide: false,
                                progress: fraction == nil && files.count == 1 ? nil : overall, onClick: cancel)
            }
        }

        job = Task.detached(priority: .userInitiated) { [weak self] in
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
                for (index, file) in files.enumerated() {
                    if Task.isCancelled { break }
                    if files.count > 1 { report(index, nil) }
                    do {
                        _ = try await Converter.convert(file, to: format) { fraction in report(index, fraction) }
                        done += 1
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
            }

            let message: String
            let cancelled = Task.isCancelled
            if cancelled {
                message = done > 0 ? "Отменено, готово файлов: \(done)" : "Отменено"
            } else if let lastError, done == 0 {
                message = "Не получилось: \(lastError)"
            } else if lastError != nil {
                message = "Готово: \(done) из \(files.count)"
            } else if format.isTool {
                message = files.count == 1 ? "Готово: \(format.label)" : "Готово: \(format.label), файлов: \(done)"
            } else {
                message = files.count == 1 ? "Готово → \(format.label)" : "Готово: \(done) → \(format.label)"
            }
            let failed = done == 0 && !cancelled
            await MainActor.run { [weak self] in
                guard let self, self.runningID == id else { return }
                self.runningID = nil
                self.toast.show(message, at: center, autoHide: true)
                if failed { NSSound.beep() } else if !cancelled { NSSound(named: "Glass")?.play() }
            }
        }
    }

    private func cancelJob(_ id: Int, at center: NSPoint) {
        guard runningID == id else { return }
        job?.cancel()
        toast.show("Отменяю…", at: center, autoHide: false)
    }
}
