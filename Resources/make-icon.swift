// 从 icon-source.png 生成 macOS 应用图标 AppIcon.icns
// 处理：自动裁掉白边 -> 图形居中放大 -> 套白色圆角方形底板 -> 输出全尺寸 iconset
// 用法：swiftc -O make-icon.swift -o /tmp/make-icon && /tmp/make-icon <源图> <输出目录>
import AppKit
import Foundation
import CoreGraphics

let S: CGFloat = 1024

// MARK: - 裁掉白色背景，返回只包含图形的 NSImage
func trimmedGlyph(from url: URL) -> NSImage? {
    guard let src = NSImage(contentsOf: url),
          let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = cg.width, h = cg.height
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let ptr = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let stride = ctx.bytesPerRow

    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        let row = ptr + y * stride
        for x in 0..<w {
            let i = x * 4
            let r = Int(row[i]), g = Int(row[i + 1]), b = Int(row[i + 2])
            // 白色 / 近白色视为背景；抗锯齿的浅灰边缘算作图形
            if min(r, g, b) < 242 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    guard maxX > minX, maxY > minY else { return nil }
    let pad = max(4, min(w, h) / 40)
    let crop = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                      width: min(w, maxX - minX + 1 + pad * 2),
                      height: min(h, maxY - minY + 1 + pad * 2))
    guard let cropped = cg.cropping(to: crop) else { return nil }
    return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
}

func render(source: URL) -> NSImage? {
    guard let glyph = trimmedGlyph(from: source) else { return nil }
    let image = NSImage(size: NSSize(width: S, height: S))
    image.lockFocus()

    let inset: CGFloat = 32
    let box = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius: CGFloat = 214
    let shape = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

    // 底板 + 柔和投影
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.16)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 图形居中，占底板约 74%
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let gs = glyph.size
    let scale = min(box.width * 0.74 / gs.width, box.height * 0.74 / gs.height)
    let gw = gs.width * scale, gh = gs.height * scale
    glyph.draw(in: NSRect(x: (S - gw) / 2, y: (S - gh) / 2, width: gw, height: gh),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    // 极细描边，让白色图标在浅色 Finder 背景上仍有边界
    NSColor(calibratedWhite: 0.0, alpha: 0.09).setStroke()
    let border = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1),
                              xRadius: radius - 1, yRadius: radius - 1)
    border.lineWidth = 2
    border.stroke()

    image.unlockFocus()
    return image
}

let args = CommandLine.arguments
let sourceURL = URL(fileURLWithPath: args.count > 1 ? args[1] : "icon-source.png")
let outDir = args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath
guard let master = render(source: sourceURL) else { fatalError("无法处理源图: \(sourceURL.path)") }

let iconset = (outDir as NSString).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
guard let tiff = master.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("渲染失败") }
let masterURL = URL(fileURLWithPath: (iconset as NSString).appendingPathComponent("master.png"))
try png.write(to: masterURL)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes {
    let out = (iconset as NSString).appendingPathComponent(name)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task.arguments = ["-z", "\(px)", "\(px)", masterURL.path, "--out", out]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
}
try? FileManager.default.removeItem(at: masterURL)
print(iconset)
