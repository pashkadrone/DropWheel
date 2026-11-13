// Рисует иконку приложения во всех нужных размерах.
// Запуск: swift tools/make_icon.swift DropWheel/Assets.xcassets/AppIcon.appiconset
import AppKit

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // Подложка: скруглённый квадрат с градиентом.
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1),
                        NSColor(red: 0.13, green: 0.10, blue: 0.42, alpha: 1)])!.draw(in: plate, angle: -90)

    // Колесо из восьми секторов, один выделен.
    let center = NSPoint(x: 512, y: 512)
    let count = 8
    let width = 360 / CGFloat(count)
    for index in 0..<count {
        let active = index == 1
        let middle = 90 - CGFloat(index) * width
        let start = middle + width / 2 - 2.2, end = middle - width / 2 + 2.2
        let outer: CGFloat = active ? 322 : 292
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: outer, startAngle: start, endAngle: end, clockwise: true)
        path.appendArc(withCenter: center, radius: 112, startAngle: end, endAngle: start, clockwise: false)
        path.close()
        (active ? NSColor(red: 1.0, green: 0.62, blue: 0.16, alpha: 1) : NSColor(white: 1, alpha: 0.93)).setFill()
        path.fill()
    }
    NSColor(white: 1, alpha: 0.93).setFill()
    NSBezierPath(ovalIn: NSRect(x: 512 - 74, y: 512 - 74, width: 148, height: 148)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [String] = []
for slot in slots {
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
    let data = drawIcon(pixels: slot.points * slot.scale).representation(using: .png, properties: [:])!
    try! data.write(to: folder.appendingPathComponent(name))
    images.append("    { \"idiom\" : \"mac\", \"size\" : \"\(slot.points)x\(slot.points)\", \"scale\" : \"\(slot.scale)x\", \"filename\" : \"\(name)\" }")
}
let json = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! json.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("готово: \(slots.count) размеров")
