import SwiftUI
import AppKit
import Combine
import Foundation

// MARK: - 菜单栏图标（macOS 原生 template 自适应）
//
// 旧实现会读壁纸文件、还原缩放裁剪、采样屏幕顶部 5% 亮度，并每 3 秒轮询
// 壁纸文件是否更换，再在「白色机箱 / 黑色机箱」两张 PNG 之间切换。
//
// 现在完全交给系统：MenuBar-Light.png 是纯黑 alpha 剪影，合成成一张
// `isTemplate = true` 的 NSImage 交给 MenuBarExtra（底层 NSStatusItem.button.image）。
// macOS 会按菜单栏当前底色自动把它染成黑色或白色——和 Wi-Fi、电池、控制中心
// 等系统图标走的是同一条 AppKit 渲染通路。换壁纸、动态桌面推进、切换浅色/深色，
// 全部由系统负责重绘；应用侧零壁纸读取、零亮度计算、零轮询、零额外权限。
//
// 一个已验证的关键事实（真机 2026-11-07 探针）：
//   SwiftUI `MenuBarExtra` 的 label 用 `Image(nsImage:)` 时会把 NSImage 原样
//   透传给 NSStatusItem，`isTemplate` 即使外面套了 Group/.frame/.help 也保留；
//   按钮的 effectiveAppearance 是系统给出的 NSAppearanceNameVibrantDark/Light，
//   就是菜单栏按壁纸 tint 得出的那套外观。
//
// 彩色状态点不能放进 template 图（template 会吞掉所有颜色、只留 alpha），
// 因此单独用一个 NSView 叠在 NSStatusBarButton 上绘制，颜色与 Health 一致。

enum MenuBarIcon {
    /// 机箱 template：只有 alpha 形状，黑/白由 macOS 决定。
    /// 21×20 pt @2x 画布，机箱画在 (0,2)-(18,20)，右下角留给状态点。
    static let template: NSImage = makeTemplate()

    /// 离屏预览 / 设置页示意图专用：手动把机箱染成黑或白并叠加彩色状态点。
    /// 真机 GUI **不走这里**，真机只使用上面的 template 图。
    static func preview(isDark: Bool, health: Health) -> NSImage? {
        guard let base = image(isDark: isDark),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: 42, pixelsHigh: 40,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return image(isDark: isDark)
        }
        rep.size = NSSize(width: 21, height: 20)   // 42x40 像素 = 21x20 pt @2x
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        base.draw(in: NSRect(x: 0, y: 2, width: 18, height: 18),
                  from: .zero, operation: .sourceOver, fraction: 1)

        let dot = NSRect(x: 13.5, y: 1.2, width: 6.5, height: 6.5)
        // 细描边把状态点与机箱分隔开
        let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -0.55, dy: -0.55))
        (isDark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        ring.fill()
        dotColor(health).setFill()
        NSBezierPath(ovalIn: dot).fill()

        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: 21, height: 20))
        out.addRepresentation(rep)
        return out
    }

    /// 预览用的黑 / 白机箱原图（template 机制下真机只用 Light 那张做形状）
    static func image(isDark: Bool) -> NSImage? { isDark ? dark : light }
    static let light: NSImage? = load("MenuBar-Light")
    static let dark: NSImage? = load("MenuBar-Dark")

    /// 与 Health.color 保持一致的 RGB，但不经 SwiftUI Color → NSColor 转换
    /// （语义色 / 动态色在离屏位图上下文里解析不稳定，会退化成灰色）。
    static func dotColor(_ h: Health) -> NSColor {
        switch h {
        case .unknown:  return NSColor(white: 0.60, alpha: 1)
        case .online:   return NSColor(srgbRed: 0.18, green: 0.72, blue: 0.38, alpha: 1)
        case .degraded: return NSColor(srgbRed: 0.95, green: 0.68, blue: 0.12, alpha: 1)
        case .stalled:  return NSColor(srgbRed: 0.93, green: 0.28, blue: 0.24, alpha: 1)
        case .offline:  return NSColor(srgbRed: 0.48, green: 0.50, blue: 0.55, alpha: 1)
        case .away:     return NSColor(srgbRed: 0.55, green: 0.58, blue: 0.66, alpha: 1)
        }
    }

    /// 把纯黑机箱剪影画进 21×20 pt 画布，并标记为 template。
    /// template 图只取 alpha，颜色写黑或写白都无所谓，这里沿用黑色剪影源图。
    private static func makeTemplate() -> NSImage {
        let canvas = NSSize(width: 21, height: 20)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: 42, pixelsHigh: 40,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return fallbackTemplate()
        }
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        if let base = light {
            base.draw(in: NSRect(x: 0, y: 2, width: 18, height: 18),
                      from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 17, height: 15),
                         xRadius: 3, yRadius: 3).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: canvas)
        out.addRepresentation(rep)
        out.isTemplate = true          // ← 唯一开关：交给 macOS 按菜单栏底色染色
        return out
    }

    private static func fallbackTemplate() -> NSImage {
        let img = NSImage(size: NSSize(width: 21, height: 20))
        img.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 17, height: 15),
                     xRadius: 3, yRadius: 3).fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        // 源图是 36x36 @2x，按 18x18 pt 显示
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = false
        return img
    }
}

// MARK: - 彩色状态点（叠在 template 图标之上）
//
// template 图会被系统单色化，绿/橙/红/灰告警色无法保留；用一个透明 NSView
// 作为 NSStatusBarButton 的子视图单独绘制，就能同时拥有「系统自动黑白」和
// 「彩色健康状态」。子视图不参与命中测试，点击仍然落到按钮上。
//
// SwiftUI 的 MenuBarExtra 状态项虽然不对外暴露，但它创建的 NSStatusBarWindow
// 会出现在 NSApp.windows 里，从视图树里能找到唯一的 NSStatusBarButton。
// 挂载是一次性的；每次健康状态变化顺带自愈一次（状态项若被系统重建也能恢复）。

@MainActor
final class MenuBarBadge: NSObject {
    static let shared = MenuBarBadge()

    private let badge = BadgeView()
    private var cancellable: AnyCancellable?
    private var started = false

    private override init() { super.init() }

    func start(monitor: Monitor) {
        guard !started else { return }
        started = true
        badge.health = monitor.health

        // 状态项由 SwiftUI 在 run loop 启动后创建，稍等一次再挂
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.attach(health: monitor.health)
        }

        cancellable = monitor.$health
            .receive(on: DispatchQueue.main)
            .sink { [weak self] health in
                guard let self else { return }
                self.attach(health: health)   // 顺带自愈：状态项被重建时重新挂上
            }
    }

    private func attach(health: Health) {
        guard let button = statusButton() else { return }
        if badge.superview !== button {
            badge.removeFromSuperview()
            button.addSubview(badge)
        }
        // 未来 macOS 版本若调整状态项间距 / 高度，button.bounds 会变；
        // 每次健康检查都按实际 bounds 重设一次，不假设 21×20 恒定。
        // BadgeView.draw 同样基于 bounds 动态计算圆点位置，避免 subview 偏移。
        if badge.frame != button.bounds { badge.frame = button.bounds }
        badge.autoresizingMask = [.width, .height]
        badge.health = health
        button.toolTip = "NASMonitor · \(health.title)"
    }

    /// 从 NSApp.windows 里找 SwiftUI MenuBarExtra 建出来的状态按钮。
    /// 不用私有 API，只遍历公开窗口与视图树，找 NSStatusBarButton 类型。
    private func statusButton() -> NSStatusBarButton? {
        func find(_ v: NSView) -> NSStatusBarButton? {
            if let b = v as? NSStatusBarButton { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        for w in NSApp.windows where w.isVisible && w.frame.origin.y > 0 {
            if let cv = w.contentView, let b = find(cv) { return b }
        }
        for w in NSApp.windows {
            if let cv = w.contentView, let b = find(cv) { return b }
        }
        return nil
    }
}

private final class BadgeView: NSView {
    var health: Health = .unknown {
        didSet { if health != oldValue { needsDisplay = true } }
    }

    /// template 图的逻辑尺寸。按钮 bounds 变化时按比例居中，不写死绝对坐标。
    private let iconSize = NSSize(width: 21, height: 20)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 背景透明，只画圆点；不拦截点击
        wantsLayer = false
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: self)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func frameDidChange(_ n: Notification) { needsDisplay = true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // 系统可能给状态按钮不同的宽高（菜单栏间距、辅助功能字号等），
        // 一律按实际 bounds 把 21×20 的图标居中，再按比例缩放圆点。
        let iw = min(iconSize.width, bounds.width)
        let ih = min(iconSize.height, bounds.height)
        let ox = (bounds.width - iw) / 2
        let oy = (bounds.height - ih) / 2
        let scale = min(iw / iconSize.width, ih / iconSize.height, 1.0)
        let dot = NSRect(x: ox + 13.5 * scale, y: oy + 1.2 * scale,
                         width: 6.5 * scale, height: 6.5 * scale)
        // 中性灰描边：机箱被染成黑或白时都能把状态点分隔开
        NSColor(calibratedWhite: 0.5, alpha: 0.45).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -0.55 * scale, dy: -0.55 * scale)).fill()
        MenuBarIcon.dotColor(health).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}

// MARK: - 应用界面外观观察者
//
// 只负责 SwiftUI 面板的浅色 / 深色，与菜单栏图标完全解耦：
// 图标颜色由 macOS template 机制按菜单栏底色决定，切换界面模式不会改变图标。
// 用户可在「自动 / 浅色 / 深色」间切换：
//   - 自动：`NSApp.appearance = nil`，面板跟随系统；
//   - 浅色 / 深色：设置 `NSApp.appearance`，整个软件面板真正换色。
@MainActor
final class AppearanceObserver: ObservableObject {
    static let shared = AppearanceObserver()

    /// 外观模式，锁定的是软件界面，不影响菜单栏图标配色。
    enum Mode: String, CaseIterable, Identifiable {
        case auto = "auto"
        case light = "light"
        case dark = "dark"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "自动"
            case .light: return "浅色"
            case .dark:  return "深色"
            }
        }
    }

    static let modeKey = "appearanceMode"

    @Published private(set) var isDark: Bool = false
    /// 判据来源，只用于 CLI / 设置页展示
    @Published private(set) var source: String = ""
    @Published private(set) var mode: Mode = .auto

    /// 仅离屏预览用的强制值，优先级最高；GUI 不会设置
    private var forced: Bool?
    private var token: NSObjectProtocol?
    private var started = false

    private init() {
        mode = Self.readMode()
        (isDark, source) = Self.detect(mode: mode)
    }

    private static func readMode() -> Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .auto
    }

    /// 切换模式：持久化 → 立即把外观应用到 NSApp（面板 colorScheme）→ 刷新判据。
    func setMode(_ newMode: Mode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey)
        applyModeToApp()
        refresh()
    }

    /// 把模式映射成 `NSApp.appearance`；SwiftUI 面板颜色会随之实时变化。
    /// 自动模式清掉应用级外观，交还给系统。离屏预览进程不改动 NSApp。
    func applyModeToApp() {
        guard let app = NSApp, forced == nil else { return }
        switch mode {
        case .auto:  app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark:  app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// GUI 启动后调用：此时 NSApp 与 run loop 才真正就绪，重新校准一次。
    func start() {
        guard !started else { return }
        started = true
        applyModeToApp()
        refresh()
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            // 系统外观变化时手动模式要重新施加，避免被系统带走
            Task { @MainActor in self?.applyModeToApp(); self?.refresh() }
        }
        // 兜底：某些环境收不到分布式通知，低频轮询确保外观最终一致。
        // 只在值变化时才写 isDark/source，不会造成界面频繁重绘。
        Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.refresh()
            }
        }
    }

    func refresh() {
        if let forced {
            if isDark != forced { isDark = forced }
            if source != "离屏预览强制" { source = "离屏预览强制" }
            return
        }
        let (dark, src) = Self.detect(mode: mode)
        if source != src { source = src }
        if isDark != dark { isDark = dark }
    }

    /// 供 --render 预览指定外观
    func force(_ dark: Bool) {
        forced = dark
        refresh()
    }

    /// 仅供 --render-settings 预览：临时显示某个模式，不写 UserDefaults、不改动 NSApp。
    /// 避免在生成预览图时污染用户真实的外观设置。
    func previewMode(_ m: Mode) {
        mode = m
        refresh()
    }

    /// 返回 (界面是否深色, 判据说明)。
    /// 优先级：离屏强制 > 手动模式 > 应用级显式外观 > effectiveAppearance > 系统全局域兜底。
    static func detect(mode: Mode? = nil) -> (Bool, String) {
        switch mode ?? readMode() {
        case .light: return (false, "手动 · 始终浅色（软件界面）")
        case .dark:  return (true,  "手动 · 始终深色（软件界面）")
        case .auto:  break
        }
        guard let app = NSApp else {
            // 只在进程启动、NSApp 尚未创建的一瞬间走到这里；start() 会立刻重新校准
            let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") ?? ""
            return (style.localizedCaseInsensitiveContains("Dark"), "系统全局域（启动兜底）")
        }
        if let explicit = app.appearance {
            let m = explicit.bestMatch(from: [.aqua, .darkAqua]) ?? explicit.name
            return (isDarkName(m), "应用界面外观（显式设定）")
        }
        let m = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            ?? app.effectiveAppearance.name
        return (isDarkName(m), "应用界面外观（effectiveAppearance）")
    }

    private static func isDarkName(_ n: NSAppearance.Name) -> Bool {
        n == .darkAqua || n.rawValue.contains("Dark") || n.rawValue.contains("dark")
    }

    static func systemIsDark() -> Bool { detect().0 }
}
