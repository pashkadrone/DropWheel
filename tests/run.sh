#!/bin/zsh
# Автотесты DropWheel: собирает приложение и прогоняет все конвертации и инструменты
# на свежих тестовых файлах. Запуск: tests/run.sh. Код возврата 0 — всё прошло.

ROOT="${0:A:h:h}"
cd "$ROOT" || exit 1
WORK="$(mktemp -d)"
# Отдельное хранилище настроек: тесты не читают и не меняют настоящие настройки пользователя.
export DROPWHEEL_SUITE="local.dropwheel.tests"
setting() { defaults write "$DROPWHEEL_SUITE" "$@"; }
reset_settings() { defaults delete "$DROPWHEEL_SUITE" >/dev/null 2>&1; }
reset_settings
trap 'rm -rf "$WORK"; reset_settings' EXIT
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ок    $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  СБОЙ  $1${2:+ — $2}"; }
size() { stat -f %z "$1" 2>/dev/null || echo 0; }
width() { sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/ {print $2}'; }

# is <название> <получено> <ожидалось>
is() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "получено «$2», ожидалось «$3»"; }
# made <название> <файл>: файл существует и не пустой
made() { [[ -s "$2" ]] && ok "$1" || bad "$1" "нет файла ${2:t}"; }

echo "Сборка…"
if ! xcodebuild -project DropWheel.xcodeproj -target DropWheel -configuration Release SYMROOT="$ROOT/build" 2>&1 | grep -q "BUILD SUCCEEDED"; then
    echo "СБОЙ: приложение не собралось"; exit 1
fi
APP="$ROOT/build/Release/DropWheel.app/Contents/MacOS/DropWheel"
swiftc -O "$ROOT/tests/helper.swift" -o "$WORK/helper" 2>/dev/null || { echo "СБОЙ: не собрался tests/helper.swift"; exit 1; }
H="$WORK/helper"

echo "Тестовые файлы…"
SRC="$(find "/System/Library/Desktop Pictures" -maxdepth 1 -name '*.heic' 2>/dev/null | head -1)"
[[ -n "$SRC" ]] || SRC="/System/Library/CoreServices/DefaultDesktop.heic"
sips -Z 3000 -s format jpeg "$SRC" --out "$WORK/a.jpg" >/dev/null 2>&1
sips -Z 2000 -s format png "$SRC" --out "$WORK/b.png" >/dev/null 2>&1
sips -Z 2000 -s format heic "$SRC" --out "$WORK/c.heic" >/dev/null 2>&1
cp /System/Library/Sounds/Glass.aiff "$WORK/sound.aiff"
"$H" gen "$WORK/big.mov"
for f in a.jpg b.png c.heic sound.aiff big.mov; do
    [[ -s "$WORK/$f" ]] || { echo "СБОЙ: не удалось подготовить $f"; exit 1; }
done

convert() { "$APP" --convert "$WORK/$1" "$2" >/dev/null 2>&1; }
tool()    { local name="$1"; shift; "$APP" --tool "$name" "${@/#/$WORK/}" >/dev/null 2>&1; }

echo "Картинки: смена формата"
for pair in JPG:jpg PNG:png TIFF:tiff GIF:gif BMP:bmp PDF:pdf AVIF:avif; do
    convert c.heic "${pair%%:*}"; made "HEIC → ${pair%%:*}" "$WORK/c.${pair##*:}"
done
is "JPG сохраняет размер кадра" "$(width "$WORK/c.jpg")" "2000"
convert a.jpg JPG; is "формат оригинала в колесе не предлагается" "$?" "2"

echo "Картинки: инструменты"
tool "Сжать" a.jpg; made "Сжать JPG" "$WORK/a сжато.jpg"
[[ $(size "$WORK/a сжато.jpg") -lt $(size "$WORK/a.jpg") ]] && ok "сжатая копия меньше оригинала" || bad "сжатая копия меньше оригинала"
tool "Сжать" b.png; made "Сжать PNG даёт JPG" "$WORK/b сжато.jpg"
tool "Сжать" "a сжато.jpg"; is "повторное сжатие отклоняется" "$?" "1"
[[ ! -e "$WORK/a сжато сжато.jpg" ]] && ok "бесполезная копия не остаётся" || bad "бесполезная копия не остаётся"
tool "50%" a.jpg; is "50% уменьшает вдвое" "$(width "$WORK/a 50%.jpg")" "1500"
tool "1920px" a.jpg; is "1920px" "$(width "$WORK/a 1920px.jpg")" "1920"
tool "1280px" c.heic; is "1280px сохраняет HEIC" "$(width "$WORK/c 1280px.heic")" "1280"
height() { sips -g pixelHeight "$1" 2>/dev/null | awk '/pixelHeight/ {print $2}'; }
"$APP" --crop "$WORK/a.jpg" 0.25 0.25 0.5 0.25 >/dev/null 2>&1
is "Обрезать: ширина области" "$(width "$WORK/a обрезано.jpg")" "1500"
is "Обрезать: высота области" "$(height "$WORK/a обрезано.jpg")" "750"
"$APP" --crop "$WORK/c.heic" 0.5 0.5 1 1 >/dev/null 2>&1
is "Обрезать: область за краем урезается, HEIC сохраняется" "$(width "$WORK/c обрезано.heic")x$(height "$WORK/c обрезано.heic")" "1000x1000"
"$APP" --crop "$WORK/b.png" 0.2 0.2 0 0 >/dev/null 2>&1; is "Обрезать: пустая область отклоняется" "$?" "1"
"$APP" --render-crop "$WORK/crop.png" "$WORK/a.jpg" >/dev/null 2>&1; made "окно обрезки рисуется" "$WORK/crop.png"
rm -f "$WORK/c.pdf"
tool "В PDF" a.jpg b.png c.heic; is "В PDF: три картинки — три страницы" "$("$H" info "$WORK/a и ещё 2.pdf")" "pages=3"
[[ $(size "$WORK/a и ещё 2.pdf") -lt 8000000 ]] && ok "PDF из картинок сжат" || bad "PDF из картинок сжат" "$(size "$WORK/a и ещё 2.pdf") байт"

echo "PDF"
cp "$WORK/a и ещё 2.pdf" "$WORK/doc.pdf"; cp "$WORK/doc.pdf" "$WORK/doc2.pdf"
tool "Разделить" doc.pdf
made "Разделить: страница 1" "$WORK/doc-1.pdf"; made "Разделить: страница 3" "$WORK/doc-3.pdf"
is "страница после разделения одна" "$("$H" info "$WORK/doc-2.pdf")" "pages=1"
tool "Склеить" doc.pdf doc2.pdf; is "Склеить: 3 + 3 = 6 страниц" "$("$H" info "$WORK/doc (склеено).pdf")" "pages=6"
tool "Склеить" doc.pdf; is "Склеить не предлагается для одного файла" "$?" "2"
tool "В JPG" doc2.pdf; made "PDF → JPG по страницам" "$WORK/doc2-3.jpg"
convert doc2.pdf PNG; made "PDF → PNG по страницам" "$WORK/doc2-1.png"

echo "Аудио"
convert sound.aiff M4A; made "AIFF → M4A" "$WORK/sound.m4a"
convert sound.aiff WAV; made "AIFF → WAV" "$WORK/sound.wav"

echo "Видео"
convert big.mov MP4;  is "MOV → MP4 без перекодирования" "$("$H" info "$WORK/big.mp4")" "size=1920x1080 codec=avc1 audio=1"
convert big.mov HEVC; is "MOV → HEVC" "$("$H" info "$WORK/big HEVC.mp4")" "size=1920x1080 codec=hvc1 audio=1"
convert big.mov 720p; is "720p" "$("$H" info "$WORK/big 720p.mp4")" "size=1280x720 codec=avc1 audio=1"
convert big.mov M4A;  made "звук из видео в M4A" "$WORK/big.m4a"
tool "480p" big.mov;  is "480p" "$("$H" info "$WORK/big 480p.mp4")" "size=640x360 codec=avc1 audio=1"
tool "Без звука" big.mov; is "Без звука" "$("$H" info "$WORK/big без звука.mov")" "size=1920x1080 codec=avc1 audio=0"
tool "Сжать" big.mov; is "Сжать видео в HEVC" "$("$H" info "$WORK/big сжато.mp4")" "size=1920x1080 codec=hvc1 audio=1"
convert "big без звука.mov" M4A; is "M4A из видео без звука отклоняется" "$?" "1"

echo "Видео: прогресс и отмена"
rm -f "$WORK/big HEVC.mp4"
STEPS=$("$APP" --convert "$WORK/big.mov" HEVC 2>&1 >/dev/null | grep -c '^progress ')
[[ "$STEPS" -ge 1 ]] && ok "во время конвертации приходит прогресс ($STEPS шагов)" || bad "во время конвертации приходит прогресс"
rm -f "$WORK/big HEVC.mp4"
DROPWHEEL_CANCEL_AFTER=0.25 "$APP" --convert "$WORK/big.mov" HEVC >/dev/null 2>&1
is "отмена прерывает конвертацию" "$?" "3"
[[ ! -e "$WORK/big HEVC.mp4" ]] && ok "после отмены не остаётся недописанного файла" || bad "после отмены не остаётся недописанного файла"

echo "Настройки"
setting jpegQuality -float 0.6
convert c.heic JPG
[[ -s "$WORK/c 2.jpg" && $(size "$WORK/c 2.jpg") -lt $(size "$WORK/c.jpg") ]] && ok "низкое качество даёт файл меньше" || bad "низкое качество даёт файл меньше"
reset_settings
setting outputFolder -string "$WORK/готовое"
convert b.png JPG; made "результат кладётся в выбранную папку" "$WORK/готовое/b.jpg"
[[ ! -e "$WORK/b.jpg" ]] && ok "рядом с оригиналом копии нет" || bad "рядом с оригиналом копии нет"
tool "50%" b.png; made "инструменты тоже кладут в выбранную папку" "$WORK/готовое/b 50%.png"
setting outputFolder -string "/System/нет-такой-папки"
convert b.png GIF; made "недоступная папка: результат рядом с оригиналом" "$WORK/b.gif"
reset_settings
setting hiddenFormats -array "image.TIFF" "video.HEVC"
convert b.png TIFF; is "скрытый формат картинок пропадает из колеса" "$?" "2"
convert big.mov HEVC; is "скрытый формат видео пропадает из колеса" "$?" "2"
convert b.png BMP; made "остальные форматы работают" "$WORK/b.bmp"
reset_settings
convert b.png TIFF; made "после сброса настроек формат возвращается" "$WORK/b.tiff"
menu() { "$APP" --dump-menu 2>/dev/null; }
menu | grep -q "✓ Высокое (90%)" && menu | grep -q "✓ Рядом с оригиналом" && menu | grep -q "✓ TIFF" \
    && ok "меню: настройки по умолчанию отмечены" || bad "меню: настройки по умолчанию отмечены"
setting jpegQuality -float 0.75; setting outputFolder -string "$WORK/готовое"; setting hiddenFormats -array "image.TIFF"
menu | grep -q "✓ Среднее (75%)" && ok "меню: отмечено выбранное качество" || bad "меню: отмечено выбранное качество"
menu | grep -q "✓ В папку «готовое»" && ok "меню: показана выбранная папка" || bad "меню: показана выбранная папка"
menu | grep -q "^    TIFF$" && ok "меню: скрытый формат без галочки" || bad "меню: скрытый формат без галочки"
reset_settings

echo "Внешний вид"
for look in "dark shift c.heic" "light command a.jpg" "dark shift big.mov" "light command doc.pdf"; do
    parts=(${=look})
    "$APP" --render-wheel "$WORK/wheel.png" $parts[1] $parts[2] 1 "$WORK/$parts[3]" >/dev/null 2>&1
    is "колесо рисуется: $look" "$(width "$WORK/wheel.png" | awk '{print ($1 >= 340) ? "да" : "нет"}')" "да"
    rm -f "$WORK/wheel.png"
done
made "иконка приложения в сборке" "$ROOT/build/Release/DropWheel.app/Contents/Resources/AppIcon.icns"

echo
echo "Прошло: $PASS, сбоев: $FAIL"
[[ $FAIL -eq 0 ]]
