// macOS 27 (Liquid Glass) 风格应用图标生成器
//
// 本项目是 SwiftPM + 手工组装 .app，没有 Xcode / Icon Composer，无法交付真正的
// 分层 .icon 文件（那种格式由系统动态施加高光 / 折射 / 半透明）。这里走传统
// .icns 链路，把玻璃观感程序化画出来，并额外输出「方形不透明背景层 + 透明前景层」
// 两份素材，供以后装了 Xcode 用 Icon Composer 重建原生分层图标。
//
// 设计依据（Apple HIG · App icons，2026-10-28 版）：
//   - 1024×1024、方形图层、内容居中、系统负责圆角遮罩
//   - 背景层 full-bleed 且不透明；优先纯色 / 渐变
//   - 前景用填充的、清晰边缘的重叠形状，避免细线 / 软边 / 文字
//   - 传统 icns 没有系统动态效果，才需要自己画克制的玻璃高光与层间阴影
//
// 用法：
//   swiftc -O make-icon-macos27.swift -o /tmp/make-icon-macos27
//   /tmp/make-icon-macos27 <输出目录>
import AppKit
import Foundation
import CoreGraphics

let S: CGFloat = 1024
let BOX = CGRect(x: 32, y: 32, width: 960, height: 960)

struct Theme {
    let tag: String
    let title: String
    let bg: [CGColor]                 // 主渐变（左上 → 右下）
    let glowA: CGColor                // 左上光晕
    let glowB: CGColor                // 右下光晕
    let halo: CGColor                 // 背景同心光环
    let lidTop: CGColor               // 机箱上盖
    let bodyTop: CGColor              // 机身上部
    let bodyBottom: CGColor           // 机身下部
    let bodyEdge: CGColor             // 机身玻璃描边
    let bayFrame: CGColor             // 盘位框
    let bayFrameEdge: CGColor
    let disk: CGColor                 // 硬盘
    let diskHi: CGColor               // 硬盘顶部高光
    let led: CGColor                  // 状态灯
    let ledWarn: CGColor              // 告警灯
    let edgeWhite: CGFloat            // 玻璃边缘高光强度
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}
private func white(_ a: CGFloat) -> CGColor { CGColor(gray: 1, alpha: a) }
private let clear = CGColor(gray: 0, alpha: 0)

private let themes: [Theme] = [
    // A · 深空玻璃：深蓝紫渐变底板 + 近白玻璃机箱 + 深蓝盘位
    Theme(tag: "A", title: "深空玻璃",
          bg: [rgb(0.20, 0.34, 0.68), rgb(0.11, 0.18, 0.42), rgb(0.045, 0.075, 0.20)],
          glowA: rgb(0.48, 0.70, 1.00, 0.42),
          glowB: rgb(0.55, 0.36, 0.96, 0.34),
          halo: white(0.075),
          lidTop: rgb(0.98, 0.99, 1.00, 0.94),
          bodyTop: rgb(0.94, 0.97, 1.00, 0.95),
          bodyBottom: rgb(0.72, 0.82, 0.96, 0.90),
          bodyEdge: white(0.60),
          bayFrame: rgb(0.10, 0.17, 0.36, 0.16),
          bayFrameEdge: rgb(0.55, 0.70, 0.96, 0.55),
          disk: rgb(0.09, 0.15, 0.33),
          diskHi: rgb(0.24, 0.36, 0.62),
          led: rgb(0.20, 0.86, 0.60),
          ledWarn: rgb(1.00, 0.62, 0.24),
          edgeWhite: 0.62),
    // B · 清透玻璃：浅蓝白渐变底板 + 深石墨蓝机箱 + 浅色盘位
    Theme(tag: "B", title: "清透玻璃",
          bg: [rgb(1.00, 1.00, 1.00), rgb(0.90, 0.94, 1.00), rgb(0.74, 0.83, 0.97)],
          glowA: white(0.95),
          glowB: rgb(0.52, 0.70, 1.00, 0.42),
          halo: rgb(0.20, 0.34, 0.62, 0.07),
          lidTop: rgb(0.16, 0.25, 0.44),
          bodyTop: rgb(0.11, 0.18, 0.34),
          bodyBottom: rgb(0.06, 0.10, 0.22),
          bodyEdge: white(0.42),
          bayFrame: white(0.10),
          bayFrameEdge: white(0.44),
          disk: rgb(0.93, 0.96, 1.00),
          diskHi: white(1.0),
          led: rgb(0.18, 0.80, 0.52),
          ledWarn: rgb(1.00, 0.58, 0.20),
          edgeWhite: 0.92)
]

// MARK: - 画布 / 路径

private func context(_ side: Int = 1024) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                      bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 翻成左上原点，几何坐标更直观
    c.translateBy(x: 0, y: CGFloat(side))
    c.scaleBy(x: 1, y: -1)
    c.interpolationQuality = .high
    c.setAllowsAntialiasing(true)
    c.setShouldAntialias(true)
    return c
}

/// 连续曲率的 squircle，接近 Apple 图标的系统遮罩形状（纯圆弧太"方"，n≈4.4 更贴）
private func squircle(_ r: CGRect, n: CGFloat = 4.4) -> CGPath {
    let p = CGMutablePath()
    let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    var pts: [CGPoint] = []
    for i in 0...360 {
        let t = CGFloat(i) * .pi / 180
        let ct = cos(t), st = sin(t)
        pts.append(CGPoint(x: cx + a * copysign(pow(abs(ct), 2 / n), ct),
                           y: cy + b * copysign(pow(abs(st), 2 / n), st)))
    }
    p.addLines(between: pts)
    p.closeSubpath()
    return p
}

private func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func fillPath(_ c: CGContext, _ p: CGPath) {
    c.addPath(p)
    c.fillPath()
}

private func grad(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors as CFArray, locations: locs)!
}

/// 渐变默认不绘制起止点之外的区域，会留下透明角；铺满背景必须带上这两个选项
private let gradFull: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

// MARK: - 图层绘制

/// 背景层。fullBleed = true 时输出方形、全幅、不透明的 Icon Composer 背景素材；
/// false 时裁剪成 squircle 并保留透明四角（传统 .icns 需要）。
private func drawBackground(_ c: CGContext, _ t: Theme, fullBleed: Bool) {
    c.saveGState()
    if fullBleed {
        c.clip(to: CGRect(x: 0, y: 0, width: S, height: S))
    } else {
        c.addPath(squircle(BOX))
        c.clip()
    }

    // 先铺一层不透明底色，保证背景层任何像素 alpha 都是 255（Icon Composer 硬性要求）
    c.setFillColor(t.bg[0])
    c.fill(CGRect(x: 0, y: 0, width: S, height: S))
    let base = grad(t.bg, [0, 0.52, 1])
    c.drawLinearGradient(base, start: CGPoint(x: 40, y: 20),
                         end: CGPoint(x: 990, y: 1010), options: gradFull)

    // 两处大面积色光晕，模拟玻璃内部折射出的环境色
    c.drawRadialGradient(grad([t.glowA, clear], [0, 1]),
                         startCenter: CGPoint(x: 170, y: 120), startRadius: 0,
                         endCenter: CGPoint(x: 170, y: 120), endRadius: 820, options: [])
    c.drawRadialGradient(grad([t.glowB, clear], [0, 1]),
                         startCenter: CGPoint(x: 900, y: 940), startRadius: 0,
                         endCenter: CGPoint(x: 900, y: 940), endRadius: 720, options: [])

    if !fullBleed { drawGlass(c, t) }
    c.restoreGState()
}

/// 克制的玻璃质感：顶部弧面高光、内边缘高光、底部内阴影、边缘色散。
/// 传统 .icns 没有系统动态效果，这些必须由位图自己承担；分层 .icon 里应删掉。
private func drawGlass(_ c: CGContext, _ t: Theme) {
    // 顶部弧面光泽：用软渐变而不是实心椭圆，避免出现一条生硬的弧形分界线
    c.saveGState()
    c.addPath(squircle(BOX))
    c.clip()
    c.drawLinearGradient(grad([white(t.edgeWhite * 0.26), white(0.02), clear], [0, 0.34, 0.52]),
                         start: CGPoint(x: 0, y: 20), end: CGPoint(x: 0, y: 760), options: [])
    c.restoreGState()

    // 底部内阴影，给玻璃一点厚度
    c.drawLinearGradient(grad([clear, rgb(0, 0, 0.06, 0.30)], [0, 1]),
                         start: CGPoint(x: 0, y: 700),
                         end: CGPoint(x: 0, y: 1024), options: [])

    // 内边缘高光：上亮下暗，线宽 5
    c.saveGState()
    c.addPath(squircle(BOX.insetBy(dx: 3, dy: 3)))
    c.setLineWidth(5)
    c.replacePathWithStrokedPath()
    c.clip()
    c.drawLinearGradient(grad([white(t.edgeWhite), white(t.edgeWhite * 0.30), white(0.05)],
                              [0, 0.42, 1]),
                         start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1024), options: [])
    c.restoreGState()

    // 极轻的边缘色散（左上冷、右下暖）
    c.saveGState()
    c.setLineWidth(2)
    c.setStrokeColor(rgb(0.55, 0.85, 1.0, 0.20))
    c.addPath(squircle(BOX.insetBy(dx: 9, dy: 9)))
    c.strokePath()
    c.restoreGState()
}

/// 前景层：NAS 机箱 + 三盘位 + 状态灯。全部是填充的、边缘清晰的重叠圆角形状。
/// withShadow / withHalo 只给传统 .icns 位图用；导出 Icon Composer 分层素材时全部关掉，
/// 因为系统自己会施加阴影、高光和发光，图层里预烘焙会造成重影。
private func drawForeground(_ c: CGContext, _ t: Theme,
                            withHalo: Bool = true, withShadow: Bool = true) {
    if withHalo {
        // 背后的同心监测环（很淡，只给层次）
        c.saveGState()
        c.setStrokeColor(t.halo)
        c.setLineWidth(30)
        c.strokeEllipse(in: CGRect(x: 168, y: 168, width: 688, height: 688))
        c.restoreGState()
    }

    let lid = CGRect(x: 252, y: 278, width: 520, height: 96)
    let body = CGRect(x: 222, y: 342, width: 580, height: 378)

    // 机箱轻微投影，让它浮在玻璃底板上（分层素材不烘焙）
    if withShadow {
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 22), blur: 40,
                    color: CGColor(gray: 0, alpha: 0.30))
        c.addPath(rr(lid, 40))
        c.setFillColor(t.lidTop)
        c.fillPath()
        c.restoreGState()
    }

    // 上盖
    c.addPath(rr(lid, 40))
    c.setFillColor(t.lidTop)
    c.fillPath()
    c.addPath(rr(lid.insetBy(dx: 2, dy: 2), 38))
    c.setLineWidth(2)
    c.setStrokeColor(t.bodyEdge)
    c.strokePath()

    // 机身：垂直渐变 + 顶部内高光 + 玻璃描边
    c.saveGState()
    c.addPath(rr(body, 50))
    c.clip()
    c.drawLinearGradient(grad([t.bodyTop, t.bodyBottom], [0, 1]),
                         start: CGPoint(x: 0, y: body.minY),
                         end: CGPoint(x: 0, y: body.maxY), options: [])
    c.setFillColor(white(0.16))
    fillPath(c, rr(CGRect(x: body.minX, y: body.minY, width: body.width, height: 90), 50))
    c.restoreGState()
    c.addPath(rr(body.insetBy(dx: 1.5, dy: 1.5), 49))
    c.setLineWidth(3)
    c.setStrokeColor(t.bodyEdge)
    c.strokePath()

    // 左侧状态灯（光晕仅位图版）
    if withShadow {
        c.saveGState()
        c.setShadow(offset: .zero, blur: 26, color: t.led)
        c.setFillColor(t.led)
        c.fillEllipse(in: CGRect(x: 266, y: 578, width: 46, height: 46))
        c.restoreGState()
    }
    c.setFillColor(t.led)
    c.fillEllipse(in: CGRect(x: 266, y: 578, width: 46, height: 46))

    // 盘位框
    let frame = CGRect(x: 350, y: 386, width: 324, height: 292)
    c.addPath(rr(frame, 28))
    c.setFillColor(t.bayFrame)
    c.fillPath()
    c.addPath(rr(frame.insetBy(dx: 3, dy: 3), 25))
    c.setLineWidth(6)
    c.setStrokeColor(t.bayFrameEdge)
    c.strokePath()

    // 三块硬盘 + 顶部状态点
    let diskRects = [CGRect(x: 368, y: 406, width: 84, height: 250),
                     CGRect(x: 470, y: 406, width: 84, height: 250),
                     CGRect(x: 572, y: 406, width: 84, height: 250)]
    for (i, r) in diskRects.enumerated() {
        c.saveGState()
        c.addPath(rr(r, 22))
        c.clip()
        c.drawLinearGradient(grad([t.diskHi, t.disk], [0, 0.30]),
                             start: CGPoint(x: 0, y: r.minY),
                             end: CGPoint(x: 0, y: r.maxY), options: [])
        c.restoreGState()
        c.setFillColor(i == 2 ? t.ledWarn : t.led)
        c.fillEllipse(in: CGRect(x: r.midX - 8, y: 424, width: 16, height: 16))
        // 盘面下方一条浅浅的玻璃高光
        c.setFillColor(white(0.10))
        fillPath(c, rr(CGRect(x: r.minX + 14, y: r.minY + 40, width: r.width - 28, height: 8), 4))
    }
}

private func compose(_ t: Theme, fullBleed: Bool = false) -> CGContext {
    let c = context()
    if !fullBleed {
        // 图标落在桌面上的柔和外阴影
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 20), blur: 46,
                    color: CGColor(gray: 0, alpha: 0.24))
        c.addPath(squircle(BOX))
        c.setFillColor(CGColor(gray: 0, alpha: 1))
        c.fillPath()
        c.restoreGState()
    }
    drawBackground(c, t, fullBleed: fullBleed)
    if !fullBleed { drawForeground(c, t) }
    return c
}

private func writePNG(_ c: CGContext, _ path: String) throws {
    guard let img = c.makeImage() else { fatalError("无法生成图像") }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 编码失败") }
    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: - 输出

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
func out(_ name: String) -> String { (outDir as NSString).appendingPathComponent(name) }

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]

for t in themes {
    let master = out("方案\(t.tag)-\(t.title)-1024.png")
    try writePNG(compose(t), master)
    print("✓ \(master)")

    // 分层素材：给以后 Icon Composer 用（背景 full-bleed 不透明 / 前景透明）
    try writePNG({ () -> CGContext in
        let c = context()
        drawBackground(c, t, fullBleed: true)
        return c
    }(), out("方案\(t.tag)-背景层-方形.png"))
    try writePNG({ () -> CGContext in
        let c = context()
        drawForeground(c, t, withHalo: false, withShadow: false)
        return c
    }(), out("方案\(t.tag)-前景层-透明.png"))

    // iconset → icns，可直接替换 Resources/AppIcon.icns
    let iconset = out("AppIcon-\(t.tag).iconset")
    try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
    for (px, name) in sizes {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        task.arguments = ["-z", "\(px)", "\(px)", master, "--out",
                          (iconset as NSString).appendingPathComponent(name)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
    let ic = Process()
    ic.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    ic.arguments = ["-c", "icns", iconset, "-o", out("AppIcon-方案\(t.tag).icns")]
    ic.standardOutput = FileHandle.nullDevice
    ic.standardError = FileHandle.nullDevice
    try? ic.run()
    ic.waitUntilExit()
    print("✓ \(out("AppIcon-方案\(t.tag).icns"))")
}

// 并排对比图：两个大图 + 三档小尺寸，方便看小图标是否还认得出
do {
    let W = 1180, H = 700
    let cs = CGColorSpaceCreateDeviceRGB()
    let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(H)); c.scaleBy(x: 1, y: -1)
    c.setFillColor(rgb(0.96, 0.965, 0.98))
    c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    for (i, t) in themes.enumerated() {
        guard let img = compose(t).makeImage() else { continue }
        let x = CGFloat(70 + i * 560)
        // 浅色卡片
        c.setFillColor(white(1))
        fillPath(c, rr(CGRect(x: x - 20, y: 60, width: 500, height: 500), 32))
        c.draw(img, in: CGRect(x: x, y: 80, width: 460, height: 460))
        for (j, side) in [128, 64, 32].enumerated() {
            let s = CGFloat(side)
            let sx = x + 20 + CGFloat(j) * 150 + (150 - s) / 2
            c.draw(img, in: CGRect(x: sx, y: 590 + (128 - s) / 2, width: s, height: s))
        }
    }
    try writePNG(c, out("macOS27图标-方案对比.png"))
    print("✓ \(out("macOS27图标-方案对比.png"))")
}
