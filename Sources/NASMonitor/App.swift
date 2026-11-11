import SwiftUI
import AppKit
import Combine
import Foundation

@main
struct Launcher {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        // 启动即回收上次被强杀时遗留下来的 nm-* 临时文件（只删 1 小时以上、UUID 严格匹配的）。
        _ = Proc.sweepStaleTempFiles()
        // --host 只覆盖当前进程内存，不写 UserDefaults，方便用不可达主机验收阻塞保护，
        // 也不会影响正在运行的 GUI 或用户保存的真实 NAS 地址。
        if let i = args.firstIndex(of: "--host"), i + 1 < args.count {
            Config.shared.hostOverride = args[i + 1]
        }
        // GUI 验收入口：open NASMonitor.app --args --tab logs 可直接停在日志页。
        // 只影响本次进程的初始页签，不写配置；正常启动不带参数时仍是总览。
        // --render 分支后面会按自己的规则再设一次，两者不冲突。
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count {
            UIPreview.tab = args[i + 1] == "logs" ? .logs : .overview
        }
        if args.contains("--version") {
            // 版本唯一来源 = VERSION → 生成的 Version.swift；包内 plist 由 build.sh 同步写入。
            print("NASMonitor \(AppVersion.full)")
            print("版本源: VERSION → Version.swift → Info.plist（单一来源）")
            print("Tag: \(AppVersion.tag) · 发布包: \(AppVersion.zipName)")
            let c = AppVersion.bundleCheck()
            print("包内 plist 核对: \(c.description)")
            if case .mismatch = c { exit(1) }
        } else if args.contains("--version-selftest") {
            VersionSelfTest.run()
        } else if args.contains("--throttle") {
            let c = Config.shared
            print("NASMonitor 探测节流 · \(Date())")
            print("目标主机: \(c.effectiveHost)\(c.hostOverride == nil ? "" : "（--host 内存覆盖，不写配置）")")
            print("自适应节流: \(c.adaptiveThrottle ? "开启" : "关闭")")
            print(String(repeating: "-", count: 74))
            print(ProbeGovernor.shared.describe(
                probe: max(30, c.interval),
                metrics: max(30, c.metricsInterval),
                disk: max(900, c.interval * 6)))
        } else if args.contains("--throttle-selftest") {
            // 纯内存模拟：不建任何连接，只验熔断 / 回落 / 附加作业暂停的状态机
            let g = ProbeGovernor.shared
            let blocked = Snapshot(health: .stalled, summary: "模拟读库阻塞", results: [
                ProbeResult(id: "a", name: "Jellyfin Auth", layer: .storage,
                            ok: false, detail: "读库超时", ms: 6000, timedOut: true),
                ProbeResult(id: "b", name: "Amane DB", layer: .storage,
                            ok: false, detail: "读库超时", ms: 6000, timedOut: true)
            ])
            let clean = Snapshot(health: .online, summary: "模拟恢复", results: [])
            // 磁盘 D 状态 / 阵列降级也会把 health 判成 .stalled，但没有任何网络超时：
            // 这属于磁盘告警，不是 TCP 阻塞，不能触发熔断、更不能暂停性能采样。
            let diskOnly = Snapshot(health: .stalled, summary: "模拟磁盘 D 状态进程", results: [
                ProbeResult(id: "disk", name: "Disk / RAID", layer: .disk,
                            ok: false, detail: "1 个进程卡在 I/O", ms: -1, timedOut: false)
            ])
            print("初始倍率: ×\(g.multiplier)")
            _ = g.begin(.probe)
            g.end(.probe, snapshot: diskOnly)
            let diskAux = g.begin(.metrics)
            if diskAux { g.end(.metrics) }
            print("磁盘告警（.stalled 但 0 个网络超时）: 倍率=×\(g.multiplier)  附加作业=\(diskAux ? "允许" : "暂停")")
            for i in 1...3 {
                let got = g.begin(.probe)
                g.end(.probe, snapshot: blocked)
                let aux = g.begin(.metrics)
                if aux { g.end(.metrics) }
                print("第 \(i) 轮阻塞: 闸门=\(got ? "获得" : "跳过")  倍率=×\(g.multiplier)  附加作业=\(aux ? "允许" : "暂停")")
            }
            for i in 1...6 {
                _ = g.begin(.probe)
                g.end(.probe, snapshot: clean)
                print("第 \(i) 轮干净: 倍率=×\(g.multiplier)")
            }
            print("最终: \(g.statusText.isEmpty ? "已恢复基础节奏" : g.statusText)")
        } else if args.contains("--power-script") {
            // 纯干跑：只打印将要下发的脚本，不建 SSH 连接、不执行任何关机/重启。
            // sudo 密码经 stdin 注入且从不打印，便于安全地核对命令与转义。
            let c = Config.shared
            let pw = CredentialStore.get(CredentialStore.Key.sudoPassword)
            print("NASMonitor 电源指令 · 干跑 \(Date())")
            print("目标主机: \(c.effectiveHost)\(c.hostOverride == nil ? "" : "（--host 内存覆盖，不写配置）")")
            print("SSH: \(c.sshEnabled ? "\(c.sshUser)@\(c.effectiveHost)" : "未启用")")
            print("sudo 密码: \(pw.isEmpty ? "未配置（远端将尝试 sudo -n）" : "已配置，经 stdin 注入，值不打印")")
            print("stdin 前缀: \(PowerControl.stdinPayload(sudoPassword: pw) == nil ? "无" : "PW=$(base64 -d)，不含明文")")
            print("DSM 地址: \(PowerControl.dsmURL()?.absoluteString ?? "无效")")
            for a in PowerAction.allCases {
                print(String(repeating: "-", count: 74))
                print("[\(a.title)] sudo \(PowerControl.command(for: a))")
                print(PowerControl.script(for: a))
            }
        } else if args.contains("--power-url") {
            print("DSM 地址: \(PowerControl.dsmURL()?.absoluteString ?? "无效")")
            print("配置值: \(Config.shared.dsmURL.isEmpty ? "留空（自动拼接）" : Config.shared.dsmURL)")
        } else if args.contains("--power-check") {
            // 只读：只验证 SSH / 命令路径 / sudo 提权，绝不执行关机或重启
            print("NASMonitor 电源操作前置检查（只读）· \(Date())")
            print(await PowerControl.check())
        } else if args.contains("--power-selftest") {
            PowerControlSelfTest.run()
        } else if args.contains("--summary-selftest") {
            EngineSummarySelfTest.run()
        } else if args.contains("--history-selftest") {
            HistoryMigrationSelfTest.run()
        } else if args.contains("--hover-selftest") {
            // 纯内存：浮窗内容构造 + 定位边界，不建连接、不读磁盘
            HoverSelfTest.run()
        } else if args.contains("--history-migrate") {
            // 一次性清洗本地 history.json：旧版自相矛盾的 summary 按证据重写，写回前留备份
            HistoryMigration.run()
        } else if args.contains("--selftest") {
            await SelfTest.run()
        } else if args.contains("--headless") {
            await Headless.run()
        } else if args.contains("--metrics") {
            await MetricsCLI.run()
        } else if args.contains("--cancel-selftest") {
            await CancellationSelfTest.run()
        } else if args.contains("--atomic-selftest") {
            let r = AtomicFileWriter.selfTest()
            print(r.log)
            print("结果: \(r.pass) 通过 / \(r.fail) 失败")
            if r.fail > 0 { exit(1) }
        } else if args.contains("--diagnostics-selftest") {
            DiagnosticsSelfTest.run()
        } else if args.contains("--freshness-selftest") {
            FreshnessSelfTest.run()
        } else if args.contains("--inventory") {
            // 只读：随一次低频 SSH 体检列出卷 / 阵列 / 物理盘 / 监听端口，不跑分层探测
            await InventoryCLI.run()
        } else if args.contains("--services") {
            ServicesCLI.run()
        } else if args.contains("--services-selftest") {
            ServiceCatalogSelfTest.run()
        } else if args.contains("--links-selftest") {
            ServiceLinksSelfTest.run()
        } else if args.contains("--copy-report") {
            DiagnosticsCLI.copy()
        } else if args.contains("--report") {
            DiagnosticsCLI.run()
        } else if args.contains("--footprint") {
            Footprint.printReport()
        } else if let i = args.firstIndex(of: "--store-cred"), i + 1 < args.count {
            // 凭据从 stdin 读入，绝不出现在 argv / 源码 / 日志里
            let key = args[i + 1]
            let value = String(data: FileHandle.standardInput.readDataToEndOfFile(),
                               encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                print("stdin 为空，未写入 \(key)")
            } else {
                CredentialStore.set(key, value)
                print("已写入 CredentialStore: \(key) (\(value.count) 字符)")
            }
        } else if args.contains("--list-cred") {
            // 只列键名，不输出任何值
            let keys = CredentialStore.configuredKeys()
            print("已配置凭据: \(keys.isEmpty ? "无" : keys.joined(separator: ", "))")
            print("文件: \(CredentialStore.fileURL.path)")
        } else if let i = args.firstIndex(of: "--clear-cred"), i + 1 < args.count {
            let key = args[i + 1]
            CredentialStore.delete(key)
            print("已删除凭据: \(key)")
        } else if let i = args.firstIndex(of: "--set-appearance"), i + 1 < args.count {
            guard let m = AppearanceObserver.Mode(rawValue: args[i + 1].lowercased()) else {
                print("用法: --set-appearance auto|light|dark")
                return
            }
            AppearanceObserver.shared.setMode(m)
            print("外观模式已设为: \(m.title)（\(m.rawValue)）")
            print("已写入 UserDefaults: \(AppearanceObserver.modeKey)")
            print("下次启动自动应用；当前运行中的界面请到「设置 → 常规」切换以立即生效。")
            print("注: 只改变软件面板颜色；菜单栏图标由 macOS 原生 template 机制自动染色，不受影响。")
        } else if args.contains("--appearance") {
            let a = AppearanceObserver.shared
            print("外观模式: \(a.mode.title)（\(a.mode.rawValue)）")
            print("外观信号源: \(a.source)")
            if a.source.contains("启动兜底") {
                print("注: 命令行进程未创建 NSApp，此处是系统兜底值；GUI 运行时以应用界面外观为准")
            }
            print("软件界面外观: \(a.isDark ? "深色" : "浅色")")
            print("菜单栏图标: NSImage.isTemplate = true（macOS 按菜单栏底色自动染黑/白）")
            print("图标判据: 系统 NSStatusItem 渲染通路，随壁纸 / 动态桌面 / 显示模式自动重绘")
            print("说明: 界面外观与图标配色互相独立；应用不读取壁纸、不采样颜色、不轮询。")
        } else if args.contains("--menubar") || args.contains("--wallpaper") {
            // --wallpaper 保留为旧版壁纸采样诊断命令的兼容别名；新版不再读取壁纸
            print("菜单栏图标机制: NSImage.isTemplate = true（macOS 原生自动染色）")
            print("机箱形状: MenuBar-Light.png，合成 21×20 pt @2x alpha 剪影后标记 template")
            print("渲染通路: MenuBarExtra label → NSStatusItem.button.image → AppKit 按菜单栏底色染色")
            print("状态点: 独立透明 NSView 叠加在 NSStatusBarButton 上，保留绿/橙/红/灰告警色")
            print("换壁纸 / 动态桌面 / 切换浅色深色: 由 macOS 负责重绘，应用无需感知")
            print("应用侧: 不读取壁纸文件、不计算亮度、不轮询、不需要屏幕录制或辅助功能权限")
            print("面板外观: 由 AppearanceObserver 单独管理（自动 / 浅色 / 深色），与图标解耦")
        } else if let i = args.firstIndex(of: "--render-menubar"), i + 1 < args.count {
            UIPreview.renderMenuBar(to: args[i + 1])
        } else if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
            UIPreview.dark = args.contains("--dark")
            UIPreview.forceLight = args.contains("--light")
            if let j = args.firstIndex(of: "--settings-mode"), j + 1 < args.count,
               let m = AppearanceObserver.Mode(rawValue: args[j + 1].lowercased()) {
                UIPreview.settingsMode = m
            }
            if let j = args.firstIndex(of: "--settings-height"), j + 1 < args.count,
               let h = Double(args[j + 1]), h >= 300, h <= 2000 {
                UIPreview.settingsHeight = CGFloat(h)
            }
            if let j = args.firstIndex(of: "--settings-tab"), j + 1 < args.count {
                switch args[j + 1] {
                case "services": UIPreview.settingsTab = .services
                case "probes": UIPreview.settingsTab = .probes
                case "about": UIPreview.settingsTab = .about
                default: UIPreview.settingsTab = .general
                }
            }
            UIPreview.simulateDiscovery = args.contains("--simulate-new-service")
            UIPreview.renderSettings(to: args[i + 1])
        } else if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            if let t = args.firstIndex(of: "--tab"), t + 1 < args.count {
                switch args[t + 1] {
                case "logs": UIPreview.tab = .logs
                // 旧的三页结构已合并：disk / perf / services 都落到「总览」
                case "disk", "perf", "overview", "services": UIPreview.tab = .overview
                default: break
                }
            }
            UIPreview.dark = args.contains("--dark")
            UIPreview.forceLight = args.contains("--light")
            UIPreview.realData = args.contains("--real-data")
            UIPreview.simulateDiskStall = args.contains("--simulate-disk-stall")
            UIPreview.simulateStale = args.contains("--simulate-stale")
            UIPreview.simulateExtraDisks = args.contains("--simulate-extra-disks")
            UIPreview.simulateDiscovery = args.contains("--simulate-new-service")
            // 离屏渲染没有真实鼠标，--hover-preview 直接注入一张浮窗用于视觉验收；
            // --hover-kind 可选 sample / check / disk / service / sata。
            UIPreview.showHoverPreview = args.contains("--hover-preview")
            UIPreview.showPowerConfirm = args.contains("--power-confirm")
            if let h = args.firstIndex(of: "--hover-kind"), h + 1 < args.count {
                UIPreview.hoverPreviewKind = args[h + 1]
            }
            if let y = args.firstIndex(of: "--hover-anchor-y"), y + 1 < args.count,
               let v = Double(args[y + 1]), v >= 0, v <= 2000 {
                UIPreview.hoverPreviewAnchorY = CGFloat(v)
            }
            UIPreview.render(to: args[i + 1])
        } else {
            NASMonitorApp.main()
        }
    }
}

struct NASMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = Monitor.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
        } label: {
            // 单张 template NSImage，label 保持完全静态：
            // 颜色由 macOS 按菜单栏底色自动决定，换壁纸 / 动态桌面 / 切换显示模式
            // 都由系统重绘，应用侧不需要任何观察、轮询或 .id 重建。
            // 真机探针确认 Image(nsImage:) 会把 isTemplate 原样透传给 NSStatusItem。
            Image(nsImage: MenuBarIcon.template)
        }
        .menuBarExtraStyle(.window)

        Window("NASMonitor 设置", id: "settings") {
            SettingsView()
                .environmentObject(monitor)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// 仅用于 `--render-menubar` 离屏预览：模拟 macOS 把同一张 template 图
/// 在「浅色菜单栏 / 深色菜单栏」下染成黑 / 白，并画上彩色状态点。
/// 真机 GUI 不使用这个视图——真机 label 是单张静态 template Image，
/// 状态点由 MenuBarBadge 以 AppKit 子视图叠加绘制。
struct MenuBarLabel: View {
    var isDark: Bool
    var health: Health = .unknown

    var body: some View {
        Group {
            if let icon = MenuBarIcon.preview(isDark: isDark, health: health) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 21, height: 20)
            } else {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isDark ? Color.white : Color.black.opacity(0.82))
            }
        }
        .frame(width: 21, height: 20)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 启动时应用用户选择的外观模式（只影响软件面板颜色）。
        AppearanceObserver.shared.start()
        // 彩色状态点挂到 SwiftUI 创建的 NSStatusBarButton 上；
        // 图标本体的黑白由 macOS template 机制负责，这里不读取任何壁纸信息。
        MenuBarBadge.shared.start(monitor: .shared)

        // 仅验证用：自动模式下允许环境变量强制覆盖外观，便于截图比对。
        // 用户手动选择的模式优先，不会被环境变量覆盖；正常启动不设置该变量。
        if AppearanceObserver.shared.mode == .auto,
           let v = ProcessInfo.processInfo.environment["NASMON_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: v.lowercased() == "dark" ? .darkAqua : .aqua)
            AppearanceObserver.shared.refresh()
        }
        Monitor.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false
    }
}

// MARK: - 共享小组件

struct SectionHeader: View {
    let title: String
    var trailing: String = ""
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// 卡片表面：浅 / 深色各给一层明确但不抢眼的底色、1pt 描边和极淡投影。
/// 旧版 `controlBackgroundColor.opacity(0.75)` 叠在窗口白底上几乎同色，
/// `separatorColor.opacity(0.5)` 的 0.5pt 描边也基本看不见，板块边界因此模糊。
/// 只增强边界，不改内边距 / 圆角 / 间距，面板高度与留白维持原样。
private struct CardSurface: ViewModifier {
    let inset: CGFloat
    let vertical: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 8)
        let fill: Color = dark ? Color.white.opacity(0.055) : Color.black.opacity(0.032)
        let stroke: Color = dark ? Color.white.opacity(0.16) : Color.black.opacity(0.13)
        let shade: Color = dark ? Color.clear : Color.black.opacity(0.05)
        return content
            .padding(.horizontal, inset)
            .padding(.vertical, vertical)
            .background(shape.fill(fill).shadow(color: shade, radius: 1.2, y: 0.5))
            .overlay(shape.stroke(stroke, lineWidth: 1))
    }
}

extension View {
    /// 卡片内边距：水平 / 垂直可分开调整。
    /// 总览页用更矮的上下留白，避免「内容不满一屏」时框里出现大片空白。
    func card(inset: CGFloat = 10, verticalInset: CGFloat? = nil) -> some View {
        modifier(CardSurface(inset: inset, vertical: verticalInset ?? inset))
    }
}
