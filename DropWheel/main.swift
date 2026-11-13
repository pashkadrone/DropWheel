import AppKit

// Проверка конвертации из терминала: DropWheel --convert <файл> <формат>
let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "--convert" {
    let url = URL(fileURLWithPath: arguments[2])
    let wanted = arguments[3].lowercased()
    guard let format = Converter.formats(for: url).first(where: { $0.label.lowercased() == wanted }) else {
        print("Нет такого формата. Доступны: \(Converter.formats(for: url).map(\.label).joined(separator: ", "))")
        exit(2)
    }
    Task.detached {
        do {
            let outputs = try await Converter.convert(url, to: format)
            print(outputs.map(\.path).joined(separator: "\n"))
            exit(0)
        } catch {
            print("Ошибка: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
}

// Проверка инструментов из терминала: DropWheel --tool <название> <файлы…>
if arguments.count >= 4, arguments[1] == "--tool" {
    let urls = arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }
    guard let tool = Converter.tools(for: urls).first(where: { $0.label == arguments[2] }) else {
        print("Нет такого инструмента. Доступны: \(Converter.tools(for: urls).map(\.label).joined(separator: ", "))")
        exit(2)
    }
    Task.detached {
        do {
            var outputs: [URL] = []
            if tool.batch {
                outputs = try await Converter.convertBatch(urls, to: tool)
            } else {
                for url in urls { outputs += try await Converter.convert(url, to: tool) }
            }
            print(outputs.map(\.path).joined(separator: "\n"))
            exit(0)
        } catch {
            print("Ошибка: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
