// Renders the ShenzhenQR icon at any square pixel size, in ShenzhenPDF's family (gfx/make-shenzhen-pdf-logo.swift
// in shenzhen-pdf): the same warm backdrop, a saturated blue object with soft lighting and the white Shenzhen
// signature. Here the object is a scanner tile with viewfinder corners instead of a page.
//
//   swift make-icon.swift <out.png> <pixel-size>
import AppKit

guard CommandLine.arguments.count == 3, let pixelSize = Int(CommandLine.arguments[2]), pixelSize > 0 else {
    FileHandle.standardError.write(
        "usage: make-icon.swift <out.png> <pixel-size>\n".data(using: .utf8)!
    )
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CGFloat(pixelSize)
let scale = size / 1024.0

func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: x * scale, y: y * scale)
}

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1.0) -> NSColor {
    NSColor(calibratedRed: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: alpha)
}

func documentPath(offsetX: CGFloat = 0, offsetY: CGFloat = 0) -> NSBezierPath {
    NSBezierPath(roundedRect: rect(200 + offsetX, 200 + offsetY, 624, 624), xRadius: 118 * scale, yRadius: 118 * scale)
}

func drawText(_ text: String, y: CGFloat, font: NSFont, tracking: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 48, 142, 0.22)
    shadow.shadowBlurRadius = 7 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -3 * scale)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
        .kern: tracking * scale,
        .shadow: shadow,
    ]
    NSAttributedString(string: text, attributes: attributes).draw(in: rect(250, y, 524, 220))
}

guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                    pixelsWide: pixelSize,
                                    pixelsHigh: pixelSize,
                                    bitsPerSample: 8,
                                    samplesPerPixel: 4,
                                    hasAlpha: true,
                                    isPlanar: false,
                                    colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0,
                                    bitsPerPixel: 0) else {
    fatalError("failed to create bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
NSGraphicsContext.current?.shouldAntialias = true

let canvas = rect(0, 0, 1024, 1024)
NSColor.clear.setFill()
canvas.fill()

let backdrop = NSGradient(colorsAndLocations:
    (color(255, 253, 250), 0.0),
    (color(255, 235, 211), 0.46),
    (color(255, 174, 94), 1.0))!
backdrop.draw(in: canvas, angle: -38)

let glow = NSGradient(colorsAndLocations:
    (color(255, 255, 255, 0.72), 0.0),
    (color(255, 255, 255, 0.0), 1.0))!
glow.draw(in: rect(-160, 490, 760, 700), relativeCenterPosition: NSPoint(x: -0.25, y: 0.25))

let castShadow = NSShadow()
castShadow.shadowColor = color(12, 70, 155, 0.30)
castShadow.shadowBlurRadius = 54 * scale
castShadow.shadowOffset = NSSize(width: 0, height: -25 * scale)
NSGraphicsContext.current?.saveGraphicsState()
castShadow.set()
color(0, 74, 196).setFill()
documentPath(offsetX: 18, offsetY: -18).fill()
NSGraphicsContext.current?.restoreGraphicsState()

let rearPage = documentPath(offsetX: 22, offsetY: -18)
NSGradient(starting: color(0, 73, 190), ending: color(0, 112, 236))!
    .draw(in: rearPage, angle: 92)

let page = documentPath()
NSGradient(colorsAndLocations:
    (color(24, 151, 255), 0.0),
    (color(4, 111, 244), 0.50),
    (color(0, 79, 215), 1.0))!
    .draw(in: page, angle: 104)

let topHighlight = NSBezierPath()
topHighlight.move(to: point(330, 824))
topHighlight.line(to: point(694, 824))
topHighlight.lineWidth = max(1, 5 * scale)
topHighlight.lineCapStyle = .round
color(144, 216, 255, 0.72).setStroke()
topHighlight.stroke()

// Viewfinder corners
let corners = NSBezierPath()
let lo: CGFloat = 262, hi: CGFloat = 762, arm: CGFloat = 78
for (cx, cy, dx, dy) in [(lo, lo, 1.0, 1.0), (hi, lo, -1.0, 1.0), (lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    corners.move(to: point(cx + dx * arm, cy))
    corners.line(to: point(cx, cy))
    corners.line(to: point(cx, cy + dy * arm))
}
corners.lineWidth = max(1, 20 * scale)
corners.lineCapStyle = .round
corners.lineJoinStyle = .round
color(255, 255, 255, 0.92).setStroke()
corners.stroke()

if pixelSize >= 64 {
    let divider = NSBezierPath()
    divider.move(to: point(372, 428))
    divider.line(to: point(652, 428))
    divider.lineWidth = max(1, 4 * scale)
    divider.lineCapStyle = .round
    color(203, 235, 255, 0.55).setStroke()
    divider.stroke()
}

let hanziFont = NSFont(name: "PingFangSC-Semibold", size: 190 * scale)
    ?? NSFont.systemFont(ofSize: 190 * scale, weight: .bold)
let pdfFont = NSFont.systemFont(ofSize: 126 * scale, weight: .heavy)
drawText("深圳", y: 476, font: hanziFont)
drawText("QR", y: 262, font: pdfFont, tracking: 6)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [.compressionFactor: 0.92]) else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: outputURL)
