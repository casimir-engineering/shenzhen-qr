// Renders icon.iconset/ from a QR code of "ShenzhenQR" on a rounded tile. Run once: swift make-icon.swift
import AppKit
import CoreImage.CIFilterBuiltins
let f = CIFilter.qrCodeGenerator(); f.message = Data("ShenzhenQR".utf8); f.correctionLevel = "M"
let qr = f.outputImage!
let rep = NSCIImageRep(ciImage: qr); let qrImage = NSImage(size: rep.size); qrImage.addRepresentation(rep)
try? FileManager.default.createDirectory(atPath: "icon.iconset", withIntermediateDirectories: true)
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),
                   (256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let s = CGFloat(px)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let tile = NSRect(x: s*0.1, y: s*0.1, width: s*0.8, height: s*0.8)
    NSColor(calibratedRed: 0.85, green: 0.12, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: s*0.18, yRadius: s*0.18).fill()
    NSColor.white.setFill()
    let inner = tile.insetBy(dx: s*0.1, dy: s*0.1)
    NSBezierPath(roundedRect: inner, xRadius: s*0.05, yRadius: s*0.05).fill()
    NSGraphicsContext.current?.imageInterpolation = .none
    qrImage.draw(in: inner.insetBy(dx: s*0.035, dy: s*0.035))
    NSGraphicsContext.restoreGraphicsState()
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon.iconset/icon_\(name).png"))
}
