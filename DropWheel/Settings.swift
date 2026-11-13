import Foundation

/// Настройки пользователя. Хранятся в стандартных настройках macOS и переживают перезапуск.
enum Settings {
    /// Автотесты подставляют отдельное хранилище через DROPWHEEL_SUITE, чтобы не трогать настоящие настройки.
    static let defaults: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["DROPWHEEL_SUITE"],
           let separate = UserDefaults(suiteName: suite) {
            return separate
        }
        return .standard
    }()

    // MARK: Качество картинок со сжатием (JPG, HEIC, AVIF)

    static let qualityLevels: [(title: String, value: Double)] = [
        ("Высокое", 0.9), ("Среднее", 0.75), ("Низкое", 0.6),
    ]

    static var quality: Double {
        get {
            let stored = defaults.double(forKey: "jpegQuality")
            return (0.1...1).contains(stored) ? stored : 0.9
        }
        set { defaults.set(newValue, forKey: "jpegQuality") }
    }

    // MARK: Куда класть результат

    /// nil — рядом с оригиналом.
    static var outputFolder: URL? {
        get {
            guard let path = defaults.string(forKey: "outputFolder"), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { defaults.set(newValue?.path, forKey: "outputFolder") }
    }

    // MARK: Скрытые секторы колеса форматов

    private static var hidden: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenFormats") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "hiddenFormats") }
    }

    static func isHidden(_ kind: FileKind, _ label: String) -> Bool {
        hidden.contains("\(kind.rawValue).\(label)")
    }

    static func setHidden(_ isHidden: Bool, _ kind: FileKind, _ label: String) {
        var all = hidden
        if isHidden { all.insert("\(kind.rawValue).\(label)") } else { all.remove("\(kind.rawValue).\(label)") }
        hidden = all
    }
}
