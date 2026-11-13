# DropWheel

Конвертер файлов для macOS, который живёт в строке меню. Начни тащить файл и зажми клавишу — вокруг курсора появится колесо. Брось файл на сектор, и копия в новом формате появится рядом с оригиналом.

- **Shift** — сменить формат: картинки (JPG, PNG, HEIC, TIFF, GIF, BMP, PDF, AVIF), видео (MP4, MOV, HEVC, 1080p, 720p, звук в M4A), аудио (M4A, WAV, AIFF), PDF в картинки.
- **Command** — инструменты: сжать, уменьшить, собрать картинки в PDF, убрать звук из видео, склеить и разделить PDF.

Работает на встроенных средствах macOS, без сторонних программ и системных разрешений.

## Сборка

Нужны macOS 15+ и Xcode. Открой `DropWheel.xcodeproj` и нажми Run, либо из терминала:

```bash
xcodebuild -project DropWheel.xcodeproj -target DropWheel -configuration Release SYMROOT="$PWD/build"
```

Готовое приложение появится в `build/Release/DropWheel.app`.
