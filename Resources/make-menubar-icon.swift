// 从 icon-source.png 生成菜单栏图标（透明底单色剪影，浅色/深色各一套）
// 用法：swiftc -O make-menubar-icon.swift -o /tmp/make-menubar-icon \
//       && /tmp/make-menubar-icon <源图> <输出目录>
//
// 菜单栏图标不放白色圆角底板，只保留 NAS 机箱图形本身：
// 深色像素 -> 不透明前景，白色像素 -> 完全透明，灰色边缘 -> 半透明（保留抗锯齿）。
// 输出 36x36 @2x PNG，应用内按 18x18 pt 显示。
import AppKit
import Foundation
import CoreGraphics

let PIXELS = 36
let PAD: CGFloat = 2

let args = CommandLine.arguments
let sourceURL = URL(fileURLWithPath: args.count > 1 ? args[1] : "icon-source.png")
let outDir = args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath

guard let src = NSImage(contentsOf: sourceURL),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("无法读取源图: \(sourceURL.path)")
}

let W = cg.width, H = cg.height
let cs = CGColorSpaceCreateDeviceRGB()
let alphaInfo = CGImageAlphaInfo.premultipliedLast.rawValue

guard let readCtx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs, bitmapInfo: alphaInfo) else {
    fatalError("创建读取上下文失败")
}
readCtx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
guard let readPtr = readCtx.data?.assumingMemoryBound(to: UInt8.self) else {
    fatalError("读取像素失败")
}
let stride = readCtx.bytesPerRow

// 亮度 -> 不透明度。深色机箱 (~34) 完全不透明，白底 (255) 完全透明。
func opacity(_ r: Int, _ g: Int, _ b: Int) -> Int {
    let lum = min(r, g, b)
    if lum >= 248 { return 0 }
    if lum <= 60 { return 255 }
    return min(255, (248 - lum) * 255 / (248 - 60))
}

// 图形包围盒（内存坐标 = CG 底起坐标，全流程统一，避免上下翻转）
var minX = W, minY = H, maxX = 0, maxY = 0
for y in 0..<H {
    let row = readPtr + y * stride
    for x in 0..<W {
        let i = x * 4
        if opacity(Int(row[i]), Int(row[i + 1]), Int(row[i + 2])) > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}
guard maxX > minX, maxY > minY else { fatalError("源图里找不到图形") }
let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)

func render(foreground: (CGFloat, CGFloat, CGFloat), to name: String) {
    // 构造同尺寸 RGBA 剪影：颜色固定，alpha 取自亮度
    let outPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: W * H * 4)
    outPtr.initialize(repeating: 0, count: W * H * 4)
    defer { outPtr.deallocate() }
    for y in 0..<H {
        let row = readPtr + y * stride
        for x in 0..<W {
            let i = x * 4
            let a = opacity(Int(row[i]), Int(row[i + 1]), Int(row[i + 2]))
            if a == 0 { continue }
            let o = (y * W + x) * 4
            // premultipliedLast
            outPtr[o]     = UInt8(min(255, Int(foreground.0 * 255) * a / 255))
            outPtr[o + 1] = UInt8(min(255, Int(foreground.1 * 255) * a / 255))
            outPtr[o + 2] = UInt8(min(255, Int(foreground.2 * 255) * a / 255))
            outPtr[o + 3] = UInt8(a)
        }
    }
    guard let maskCtx = CGContext(data: outPtr, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: W * 4, space: cs, bitmapInfo: alphaInfo),
          let maskImage = maskCtx.makeImage(),
          let glyph = maskImage.cropping(to: crop) else {
        fatalError("构造剪影失败")
    }

    let gW = CGFloat(glyph.width), gH = CGFloat(glyph.height)
    let box = CGFloat(PIXELS) - PAD * 2
    let scale = min(box / gW, box / gH)
    let dW = gW * scale, dH = gH * scale
    let dest = CGRect(x: (CGFloat(PIXELS) - dW) / 2,
                      y: (CGFloat(PIXELS) - dH) / 2,
                      width: dW, height: dH)

    guard let drawCtx = CGContext(data: nil, width: PIXELS, height: PIXELS,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: alphaInfo) else {
        fatalError("创建绘制上下文失败")
    }
    drawCtx.setAllowsAntialiasing(true)
    drawCtx.interpolationQuality = .high
    drawCtx.draw(glyph, in: dest)
    guard let image = drawCtx.makeImage() else { fatalError("输出图像失败") }

    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG 编码失败")
    }
    let url = URL(fileURLWithPath: (outDir as NSString).appendingPathComponent(name))
    try? png.write(to: url, options: .atomic)
    print(url.path)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
// 浅色模式：深色机箱；深色模式：白色机箱
render(foreground: (0.10, 0.11, 0.13), to: "MenuBar-Light.png")
render(foreground: (1.00, 1.00, 1.00), to: "MenuBar-Dark.png")
