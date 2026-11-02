// make_icon.swift — рисует иконку LayoutSwitcher (синяя клавиатура) в PNG 1024x1024.
// Чистый Core Graphics (bitmap context) — работает в CLI без окна. Используется build_app.sh.
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let S: CGFloat = 1024

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

guard let ctx = CGContext(
    data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

func fill(_ path: CGPath, _ color: CGColor, shadow: Bool = false, dy: CGFloat = 0, blur: CGFloat = 0) {
    ctx.saveGState()
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: blur,
                              color: CGColor(red: 0.03, green: 0.13, blue: 0.35, alpha: 0.28)) }
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}

// Фон — скруглённый квадрат с синим градиентом (стиль macOS).
let bg = rr(0, 0, S, S, S * 0.223)
ctx.saveGState()
ctx.addPath(bg)
ctx.clip()
let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.27, green: 0.62, blue: 1.00, alpha: 1),
        CGColor(red: 0.05, green: 0.35, blue: 0.88, alpha: 1),
    ] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// Подложка клавиатуры: тень + белая панель.
let slab = CGRect(x: 116, y: 232, width: 792, height: 528)
fill(rr(slab.minX, slab.minY - 16, slab.width, slab.height, 60),
     CGColor(red: 0.03, green: 0.13, blue: 0.35, alpha: 0.28), shadow: true, dy: -16, blur: 40)
fill(rr(slab.minX, slab.minY, slab.width, slab.height, 60), CGColor(red: 1, green: 1, blue: 1, alpha: 1))

// Клавиши: 4 ряда, синие; служебные (backspace/enter/модификаторы и пробел) темнее.
let keyH: CGFloat = 74
let gapH: CGFloat = 22
let gapV: CGFloat = 26
let keyColor = CGColor(red: 0.20, green: 0.52, blue: 0.95, alpha: 1)
let modColor = CGColor(red: 0.12, green: 0.40, blue: 0.82, alpha: 1)
let rows: [[CGFloat]] = [
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1.5],
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1.5],
    [1, 1, 1.3, 4.8, 1.3, 1, 1],
]
let area = slab.insetBy(dx: 42, dy: 48)
var y = area.maxY - keyH
for (ri, row) in rows.enumerated() {
    let gaps = (CGFloat(row.count) - 1) * gapH
    let u = (area.width - gaps) / row.reduce(0, +)
    let rowW = row.reduce(0, +) * u + gaps
    var x = area.minX + (area.width - rowW) / 2
    for (ki, w) in row.enumerated() {
        let isMod = (ri == 1 && ki == 9) || (ri == 2 && ki == 9) || (ri == 3 && ki >= 2 && ki <= 4)
        fill(rr(x, y, w * u, keyH, 17), isMod ? modColor : keyColor)
        x += w * u + gapH
    }
    y -= keyH + gapV
}

guard let cgImage = ctx.makeImage() else { fatalError("no image") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let url = URL(fileURLWithPath: out) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("no destination")
}
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("OK: \(out)")