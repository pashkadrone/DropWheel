import AppKit

// Запуск из терминала для автотестов (tests/run.sh):
//   DropWheel --convert <файл> <формат>
//   DropWheel --tool <название> <файлы…>
// Прогресс пишется в stderr строками «progress 0.42». Переменная DROPWHEEL_CANCEL_AFTER=<секунды>
// отменяет работу через указанное время. Коды возврата: 0 готово, 1 ошибка, 2 нет такого сектора, 3 отменено.
func runFromTerminal(_ urls: [URL], _ format: Format) -> Never {
    let task = Task.detached {
        do {
            var outputs: [URL] = []
            if format.batch {
                outputs = try await Converter.convertBatch(urls, to: format)
            } else {
                for url in urls {
                    outputs += try await Converter.convert(url, to: format) { fraction in
                        FileHandle.standardError.write(Data("progress \(fraction)\n".utf8))
                    }
                }
            }
            print(outputs.map(\.path).joined(separator: "\n"))
            exit(0)
        } catch {
            if error is CancellationError || Task.isCancelled {
                print("Отменено")
                exit(3)
            }
            print("Ошибка: \(error.localizedDescription)")
            exit(1)
        }
    }
    if let value = ProcessInfo.processInfo.environment["DROPWHEEL_CANCEL_AFTER"], let seconds = Double(value) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { task.cancel() }
    }
    dispatchMain()
}

func sector(_ label: String, in sectors: [Format]) -> Format {
    guard let found = sectors.first(where: { $0.label.lowercased() == label.lowercased() }) else {
        print("Нет такого сектора. Доступны: \(sectors.map(\.label).joined(separator: ", "))")
        exit(2)
    }
    return found
}

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "--convert" {
    let url = URL(fileURLWithPath: arguments[2])
    runFromTerminal([url], sector(arguments[3], in: Converter.formats(for: url)))
}
if arguments.count >= 4, arguments[1] == "--tool" {
    let urls = arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }
    runFromTerminal(urls, sector(arguments[2], in: Converter.tools(for: urls)))
}

// Картинка колеса для проверки внешнего вида:
//   DropWheel --render-wheel <out.png> <dark|light> <shift|command> <активный сектор> <файлы…>
if arguments.count >= 7, arguments[1] == "--render-wheel" {
    _ = NSApplication.shared
    let urls = arguments.dropFirst(6).map { URL(fileURLWithPath: $0) }
    let view = WheelView(frame: NSRect(x: 0, y: 0, width: WheelPanel.side, height: WheelPanel.side))
    view.appearance = NSAppearance(named: arguments[3] == "dark" ? .darkAqua : .aqua)
    view.formats = arguments[4] == "command" ? Converter.tools(for: urls) : Converter.formats(for: urls[0])
    view.highlighted = Int(arguments[5])
    guard !view.formats.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]),
          (try? data.write(to: URL(fileURLWithPath: arguments[2]))) != nil else { exit(1) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
