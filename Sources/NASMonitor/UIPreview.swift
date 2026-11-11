import Foundation
import SwiftUI
import AppKit

/// 用离屏 NSHostingView 渲染菜单面板，构建时检查完整布局：
/// NASMonitor --render /tmp/panel.png
enum UIPreview {
    static var tab: ContentView.PanelTab = .overview
    static var dark = false
    static var forceLight = false
    static var realData = false
    /// 仅离屏预览：注入「磁盘 D 状态快照 + 读库全绿」的 stalled 场景，回归验收状态文案
    static var simulateDiskStall = false
    /// 仅离屏预览：注入「熔断 ×4 且性能采样 15 分钟未更新」的鲜活度提示
    static var simulateStale = false
    /// 仅离屏预览：再插两块盘（5 卷 / 4 阵列 / 5 物理盘），验收磁盘区数量自适应
    static var simulateExtraDisks = false
    /// 仅离屏预览：注入一个新发现服务、两个候选端口和一个已停服务
    static var simulateDiscovery = false
    /// 仅离屏预览：强制显示一张数据浮窗。离屏渲染没有真实鼠标，
    /// 不能靠 onHover 触发，所以由 ContentView 直接读 hoverPreviewState。
    static var showHoverPreview = false
    /// 仅离屏预览：强制显示电源操作二次验证卡片，验收输入态布局
    static var showPowerConfirm = false
    static var settingsMode: AppearanceObserver.Mode = .auto
    /// 设置页离屏预览高度，--settings-height 可调；用于验收靠下的分组
    static var settingsHeight: CGFloat = 430
    /// --settings-tab 指定离屏预览的初始页签
    static var settingsTab: SettingsView.SettingsTab = .general

    @MainActor
    static func render(to path: String) {
        let m = Monitor.shared
        m.installPreviewData(simulateDiskStall: simulateDiskStall,
                             simulateStale: simulateStale,
                             simulateExtraDisks: simulateExtraDisks,
                             simulateDiscovery: simulateDiscovery)

        // 总览页默认明确打上「演示数据」水印，避免被误读成真实监测结果；
        // --real-data 则改为载入 GUI 实际写入的 metrics.json，用于验收持久化链路。
        let previousDemo = Config.shared.showDemoMetrics
        if tab == .overview {
            if realData {
                m.installRealMetrics()
                Config.shared.showDemoMetrics = false
            } else {
                Config.shared.showDemoMetrics = true
            }
        }
        defer { Config.shared.showDemoMetrics = previousDemo }

        let view = ContentView()
            .environmentObject(m)
            .frame(width: 372)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        let appearance: NSAppearance? = dark ? NSAppearance(named: .darkAqua)
            : (forceLight ? NSAppearance(named: .aqua) : nil)
        if let appearance { host.appearance = appearance }
        host.frame = NSRect(x: 0, y: 0, width: 372, height: 900)
        host.layoutSubtreeIfNeeded()
        let h = max(620, host.fittingSize.height)
        host.frame = NSRect(x: 0, y: 0, width: 372, height: h)

        // 挂到一个屏幕外的窗口上，AppKit 才会完整绘制 Picker / ScrollView 等后备控件
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        if let appearance { window.appearance = appearance }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        host.display()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write("渲染失败\n".data(using: .utf8)!)
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
        print(path)
    }

    /// 把「同一张 template 图」在浅色 / 深色菜单栏下的系统渲染结果并排展示。
    /// 离屏环境没有真实 NSStatusItem 染色链路，这里用 MenuBarIcon.preview
    /// 手动模拟系统染黑 / 染白；真机效果由 macOS 自己完成，用真实截图验收。
    @MainActor
    static func renderMenuBar(to path: String) {
        let m = Monitor.shared
        m.installPreviewData()
        let health = m.health

        let view = VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .leading) {
                Color(white: 0.93)
                HStack {
                    MenuBarLabel(isDark: false, health: health)
                        .padding(.leading, 8)
                    Text("浅色菜单栏 → 系统染成黑色机箱")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.8))
                    Spacer()
                }
                .padding(.leading, 2)
            }
            .frame(height: 30)
            ZStack(alignment: .leading) {
                Color(white: 0.11)
                HStack {
                    MenuBarLabel(isDark: true, health: health)
                        .padding(.leading, 8)
                    Text("深色菜单栏 → 系统染成白色机箱")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                    Spacer()
                }
                .padding(.leading, 2)
            }
            .frame(height: 30)
        }
        .frame(width: 340)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
        print(path)
    }

    /// 离屏渲染设置页，验收「界面外观」分段按钮在自动 / 浅色 / 深色下的显示与配色。
    /// 只临时改显示模式，不写 UserDefaults、不改动 NSApp.appearance。
    @MainActor
    static func renderSettings(to path: String) {
        let m = Monitor.shared
        m.installPreviewData(simulateDiscovery: simulateDiscovery)
        if dark { AppearanceObserver.shared.force(true) }
        else if forceLight { AppearanceObserver.shared.force(false) }
        AppearanceObserver.shared.previewMode(settingsMode)
        SettingsView.previewHeight = settingsHeight
        SettingsView.previewTab = settingsTab
        defer {
            SettingsView.previewHeight = nil
            SettingsView.previewTab = .general
        }

        let view = SettingsView()
            .environmentObject(m)
            .frame(width: 460, height: settingsHeight)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        let appearance: NSAppearance? = dark ? NSAppearance(named: .darkAqua)
            : (forceLight ? NSAppearance(named: .aqua) : nil)
        if let appearance { host.appearance = appearance }
        host.frame = NSRect(x: 0, y: 0, width: 460, height: settingsHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        if let appearance { window.appearance = appearance }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
        print(path)
    }
}
