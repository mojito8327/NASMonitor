import SwiftUI
import AppKit

/// 主面板：只有「总览 / 日志」两页，共用一个外层 ScrollView，避免嵌套滚动。
/// 总览 = 整机性能（CPU/内存/网络） + 磁盘（读写吞吐/阵列/卷） + 压缩后的服务状态 + 趋势条；
/// 日志页 = 状态变化记录 + SATA / I/O 告警明细。
/// 状态 / 异常提示放在内容区最下面；ScrollView 高度随内容伸缩（上限 530），内容少时框里不留空白。
struct ContentView: View {
    @EnvironmentObject private var monitor: Monitor
    @ObservedObject private var cfg = Config.shared
    @ObservedObject private var catalog = ServiceCatalog.shared
    @Environment(\.openWindow) private var openWindow
    @State private var tab: PanelTab = UIPreview.tab
    @State private var showHelp = false
    // 顶部电源操作：先弹破坏性确认，再异步下发，最后展示「已下发 / 未下发」回执
    @State private var pendingPower: PowerAction?
    @State private var powerBusy = false
    @State private var showPowerResult = false
    @State private var powerResultTitle = ""
    @State private var powerResultText = ""
    @State private var showReportResult = false
    @State private var reportResultText = ""
    /// ScrollView 内容的实测高度。MenuBarExtra 弹出窗口给的是无限高度提议，
    /// ScrollView 单独用 maxHeight 会折叠成 0（真机验证过），必须显式给一个确定高度。
    @State private var contentHeight: CGFloat = 0
    /// 全面板共用一个 hover 目标；浮窗画在根视图 overlay 上（ScrollView 之外）。
    @State private var hover: HoverState?
    @State private var hoverCardMeasurement = HoverCardMeasurement(id: "", size: .zero)

    enum PanelTab: String, CaseIterable, Identifiable {
        case overview = "总览"
        case logs = "日志"
        var id: String { rawValue }
    }

    private static let diskReadColor = Color(red: 0.20, green: 0.68, blue: 0.88)
    private static let diskWriteColor = Color(red: 0.93, green: 0.45, blue: 0.55)
    /// 顶部页签与三个快捷按钮共用同一高度，避免出现「按钮比页签矮一截」的错位
    private static let topBarHeight: CGFloat = 24

    /// 探针 → 服务的聚合不再用写死的 ID 表：按 `tcp.<key>` / `stat.<key>…` /
    /// `sto.<key>…` 命名约定动态归属，见 ServiceCatalog.probeBelongs。
    struct ServiceStatus: Identifiable {
        let spec: ServiceSpec
        let results: [ProbeResult]
        /// 配置里有、但最近一次体检没看到它在监听
        let missing: Bool
        /// 由端口发现自动纳入
        let discovered: Bool
        var id: String { spec.id }
        var ok: Bool { !results.isEmpty && results.allSatisfy { $0.ok && !$0.timedOut } }
        var hasTimeout: Bool { results.contains { $0.timedOut } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶部只有一行：左边「总览 / 日志」页签，右边三个快捷按钮。
            // 不再单独占一行，避免面板凭空长高、内容区出现空白。
            topBar

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .overview:
                        // 1) 整机性能置顶
                        MetricsPanel(compact: true)
                        // 2) 磁盘性能与磁盘健康（原「磁盘」页压缩并入）
                        diskOverviewSection
                        // 3) 服务状态压成两列单行，给上面两块让出高度
                        servicesSection
                        if let warning = storageWarning {
                            Text(warning)
                                .font(.system(size: 9.5))
                                .foregroundStyle(monitor.health == .stalled ? Color.red : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 3)
                        }
                        // 趋势条移到内容区之外（见下方），卷 / 服务变多时也不会被裁掉
                    case .logs:
                        logsContent
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 用 background + GeometryReader 量出内容真实高度，避免 ScrollView
                // 在弹出窗口的无限高度提议下把自己折叠成 0。
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                })
            }
            .onPreferenceChange(ContentHeightKey.self) { h in
                if h > 0, abs(h - contentHeight) > 0.5 { contentHeight = h }
            }
            // 内容少 → 窗口收短、框里不留空白；日志页 30 条 dmesg 超过 530 时仍可滚动。
            // 首帧测量值还没回来时给一个合理高度，避免面板闪一下只有页签。
            .frame(height: min(max(contentHeight > 0 ? contentHeight + 4 : 480, 1), 530))

            // 趋势条与鲜活度提示都放在内容区之外、状态条之上：不占 ScrollView 的实测高度，
            // 插盘 / 加服务导致内容变高、进入滚动时，这两条仍常驻可见。
            // （离屏预览实测：放在 ScrollView 内会被裁掉半行甚至整行。）
            if tab == .overview { trendStrip }
            if tab == .overview { freshnessBanner }

            // 状态 / 异常提示从最上面挪到内容区最下面，作为底部状态条常驻可见
            header

            Divider()
            toolbar
        }
        .padding(12)
        .frame(width: 372)
        // 所有数据点用这个命名坐标系上报 frame；唯一一张浮窗画在根视图 overlay 上，
        // 位于 ScrollView 之外，既不会被裁切，也不计入 contentHeight。
        .coordinateSpace(name: HoverLayout.space)
        .overlay(alignment: .topLeading) { hoverOverlay }
        .environment(\.hoverSelection, $hover)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showHelp) { HelpView() }
        // 电源二次确认画成面板内卡片，而不是 .sheet / .alert：
        // MenuBarExtra 的弹出窗口随时可能被系统收起，独立 sheet 会连带消失；
        // 卡片留在同一视图树里，既能被离屏渲染验收，也不会误触后立即下发。
        .overlay {
            if let action = displayedPowerConfirm {
                PowerConfirmCard(action: action) { confirmed in
                    pendingPower = nil
                    if confirmed { Task { await runPower(action) } }
                }
            }
        }
        .alert(powerResultTitle.isEmpty ? "电源操作结果" : powerResultTitle,
               isPresented: $showPowerResult) {
            Button("好", role: .cancel) { showPowerResult = false }
        } message: { Text(powerResultText) }
        .alert("排障报告", isPresented: $showReportResult) {
            Button("好", role: .cancel) { showReportResult = false }
        } message: { Text(reportResultText) }
    }

    /// 离屏预览用 --power-confirm 强制注入一张确认卡片，便于截图验收。
    private var displayedPowerConfirm: PowerAction? {
        pendingPower ?? (UIPreview.showPowerConfirm ? .reboot : nil)
    }

    // MARK: - 数据悬停浮窗（11-08 第 13 轮）

    /// 离屏渲染没有真实鼠标，--hover-preview 会把一张浮窗直接注入这里。
    private var displayedHover: HoverState? {
        hover ?? UIPreview.hoverPreviewState
    }

    private func hoverOrigin(_ h: HoverState, panel: CGSize, cardWidth: CGFloat) -> CGPoint {
        // 对当前内容优先使用 PreferenceKey 实测尺寸；切换到新数据点时，先按文字换行规则估高，
        // 防止上一张浮窗的缓存尺寸影响新卡片的定位。
        let measured = hoverCardMeasurement.id == h.info.id
            ? min(hoverCardMeasurement.size.height, panel.height - 16) : 0
        let height = measured > 1
            ? measured
            : HoverLayout.estimatedHeight(h.info, width: cardWidth)
        let card = CGSize(width: cardWidth, height: height)
        return HoverLayout.origin(anchor: h.frame, panel: panel, card: card)
    }

    /// 整个面板只有这一张浮窗。根视图 overlay 里的 GeometryReader 只负责量面板尺寸，
    /// 卡片自身高度通过 PreferenceKey 回传，用于「下方放不下就翻到上方」。
    private var hoverOverlay: some View {
        GeometryReader { panel in
            // 用一个铺满的透明底 + 明确的 topLeading overlay：ZStack 的默认对齐会先把
            // 卡片居中，再叠加 offset 就会偏到面板中间（离屏渲染实测过）。
            Color.clear
                .overlay(alignment: .topLeading) {
                    if let h = displayedHover {
                        let w = HoverLayout.cardWidth(for: h.info, panelWidth: panel.size.width)
                        let o = hoverOrigin(h, panel: panel.size, cardWidth: w)
                        HoverCardView(info: h.info)
                            .frame(width: w, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(
                                GeometryReader { c in
                                    Color.clear.preference(
                                        key: HoverCardSizeKey.self,
                                        value: HoverCardMeasurement(id: h.info.id, size: c.size))
                                }
                            )
                            .onPreferenceChange(HoverCardSizeKey.self) { measurement in
                                if measurement.id == h.info.id,
                                   measurement != hoverCardMeasurement {
                                    hoverCardMeasurement = measurement
                                }
                            }
                            .offset(x: o.x, y: o.y)
                    }
                }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 顶部快捷操作（11-07 第 10 轮）

    /// 一行放下 4 个控件：左侧页签固定宽度，右侧三个按钮按内容宽度紧凑排布。
    /// 隐藏电源按钮时页签恢复占满整行（与旧版一致）。
    private var topBar: some View {
        HStack(spacing: 6) {
            tabPicker
                .frame(width: cfg.showPowerActions ? 116 : nil,
                       height: Self.topBarHeight)
            if cfg.showPowerActions {
                Spacer(minLength: 0)
                powerButton(.shutdown, tint: .red)
                powerButton(.reboot, tint: .orange)
                dsmButton
            }
        }
    }

    /// 顶部按钮专用样式。系统 `.bordered` 的背景边框只按自身 ideal size 绘制，
    /// 外层 `.frame(height:)` 只会撑大容器、按钮看起来仍比分段控件矮一截；
    /// 这里让背景填满父级给定的高度，和左侧 Picker 真正等高。
    private struct TopBarButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            TopBarButtonSurface(label: configuration.label,
                                isPressed: configuration.isPressed)
        }
    }

    /// 浅色下 `.controlColor` + 0.5pt 淡描边会和白色窗口背景糊在一起，
    /// 只剩文字颜色能认出来。这里给按钮一层明确底色、1pt 边界和轻微投影，
    /// 让「关机 / 重启 / 打开 DSM」一眼看出是可点区域，仍是 macOS 原生按钮观感。
    private struct TopBarButtonSurface<Label: View>: View {
        let label: Label
        let isPressed: Bool
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let dark = scheme == .dark
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
            let fill: Color = isPressed
                ? Color(nsColor: .selectedControlColor).opacity(0.85)
                : (dark ? Color.white.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            let stroke: Color = dark ? Color.white.opacity(0.26) : Color.black.opacity(0.22)
            let shade: Color = dark ? Color.clear : Color.black.opacity(0.07)
            return label
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .background(shape.fill(fill).shadow(color: shade, radius: 1, y: 0.5))
                .overlay(shape.stroke(stroke, lineWidth: 1))
                .contentShape(Rectangle())
        }
    }

    private var dsmButton: some View {
        Button {
            if !PowerControl.openDSM() {
                powerResultTitle = "DSM 地址无效"
                powerResultText = "当前地址：\(cfg.dsmURL.isEmpty ? "自动拼接失败" : cfg.dsmURL)。请到「设置 → 常规 → 电源操作」填写完整地址，例如 http://\(cfg.effectiveHost):5000/。"
                showPowerResult = true
            }
        } label: {
            Label("打开 DSM", systemImage: "safari").font(.system(size: 9.5))
        }
        .buttonStyle(TopBarButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: Self.topBarHeight)
        .help("在浏览器中打开 \(PowerControl.dsmURL()?.absoluteString ?? "DSM")")
    }

    private func powerButton(_ action: PowerAction, tint: Color) -> some View {
        Button { pendingPower = action } label: {
            Label(action.title, systemImage: action.symbol)
                .font(.system(size: 9.5))
                .foregroundStyle(tint)
        }
        .buttonStyle(TopBarButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: Self.topBarHeight)
        .disabled(powerBusy)
        .help("\(action.title) \(cfg.effectiveHost)（需二次确认，通过 SSH + sudo 下发）")
    }

    @MainActor
    private func runPower(_ action: PowerAction) async {
        guard !powerBusy else { return }
        powerBusy = true
        let outcome = await PowerControl.perform(action)
        powerBusy = false
        powerResultTitle = outcome.title
        powerResultText = outcome.detail
        showPowerResult = true
        if outcome.ok { monitor.notePowerAction(action) }
    }

    // MARK: - 状态 / 异常提示条（11-07 按用户要求从最上面移到内容区最下面）

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            ZStack {
                Circle().fill(monitor.health.color.opacity(0.14)).frame(width: 28, height: 28)
                Image(systemName: monitor.health.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(monitor.health.color)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(monitor.health.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    if monitor.checking {
                        ProgressView().controlSize(.mini).scaleEffect(0.65)
                    }
                    if monitor.paused {
                        Text("已暂停").font(.system(size: 8.5))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.orange.opacity(0.18)))
                    }
                }
                Text(monitor.latest?.summary ?? "正在执行首次检查…")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .hoverData(HoverInfo.summary(
                        health: monitor.health,
                        summary: monitor.latest?.summary ?? "",
                        date: monitor.lastCheck,
                        host: Config.shared.effectiveHost,
                        throttle: monitor.throttleNote,
                        power: monitor.powerNote))
                // 只在熔断时出现，正常节奏不占面板高度
                if !monitor.throttleNote.isEmpty {
                    Text(monitor.throttleNote)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("检测到阻塞后，探测间隔已自动拉长，性能采样与磁盘体检暂停；连续 2 轮无超时后回落")
                }
                // 只在刚执行过关机 / 重启时出现，说明为什么状态没有马上刷新
                if !monitor.powerNote.isEmpty {
                    Text(monitor.powerNote)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("电源操作后的静默窗口，避免 NAS 正常关机/重启被误报成离线告警")
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Config.shared.effectiveHost)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    if Transport.shared.usesExternal {
                        Text("兼容模式").font(.system(size: 8)).foregroundStyle(.orange)
                    }
                    freshnessDot
                    if let d = monitor.lastCheck {
                        Text(d, style: .time)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        // 上下留白单独收短，底部状态条不再占掉一整块高度
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(monitor.health.color.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(monitor.health.color.opacity(0.28), lineWidth: 0.8)
        )
    }

    // MARK: - 数据鲜活度（11-08 第 16 轮）

    /// 只在「熔断退避 + 数据确实变旧」时出现。正常节奏不占面板高度，
    /// 用淡黄而非红色，强调这是自动保护，不是故障告警。
    private var freshnessBanner: some View {
        Group {
            if monitor.freshness.isStale {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitor.freshness.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(monitor.freshness.detail)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.yellow.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.yellow.opacity(0.48), lineWidth: 0.8))
                .help("数据鲜活度：\(monitor.freshness.reportLine)")
            }
        }
    }

    /// 底部状态条右侧常驻的小圆点：新鲜绿 / 退避黄 / 预期内抑制灰。
    /// 两页都可见，日志页也能一眼看出曲线为什么停住了。
    private var freshnessDot: some View {
        let f = monitor.freshness
        let color: Color = f.isStale
            ? Color(red: 0.88, green: 0.66, blue: 0.10)
            : (f.level == .suppressed ? Color.secondary.opacity(0.55) : Color.green.opacity(0.85))
        return Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .help("数据鲜活度：\(f.reportLine)"
                  + (f.suppressedReason.isEmpty ? "" : "（\(f.suppressedReason)）"))
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(PanelTab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - 各个服务状态（两列单行，分层明细改由悬停提示承载）

    private var servicesSection: some View {
        let results = monitor.latest?.results ?? []
        let dsmCustom = cfg.dsmURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows: [ServiceStatus] = catalog.services.map { svc in
            var spec = svc
            // 顶部「打开 DSM」若配了自定义地址（QuickConnect / 5001 / 域名），
            // 服务行的 DSM 按钮沿用同一地址，避免两个入口指向不同地方；
            // 用户在服务页给 DSM 单独填过地址时，以服务页的配置为准。
            if svc.key == "dsm", (svc.urlString ?? "").isEmpty, !dsmCustom.isEmpty {
                spec.urlString = dsmCustom
            }
            return ServiceStatus(spec: spec,
                          results: results.filter { ServiceCatalog.probeBelongs($0.id, to: svc.key) },
                          missing: catalog.missingKeys.contains(svc.key),
                          discovered: svc.origin == .discovered)
        }
        let normal = rows.filter { $0.ok && !$0.missing }.count
        let missingCount = rows.filter(\.missing).count
        // 两列布局「手排」而不是 LazyVGrid：MenuBarExtra 弹出窗口里的 ScrollView
        // 给的是无限高度提议，LazyVGrid 在真机上可能一个行都不实例化。
        // 行数随服务数量动态变化，新增 / 删除服务后界面立刻跟着增减。
        let pairs = stride(from: 0, to: rows.count, by: 2).map { $0 }
        return VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "服务状态",
                          trailing: rows.isEmpty ? "未配置服务"
                            : (results.isEmpty ? "未检测" : "\(normal)/\(rows.count) 正常")
                              + (missingCount > 0 ? " · \(missingCount) 未监听" : ""))
            if !catalog.discovered.isEmpty { discoveryHint }
            if rows.isEmpty {
                smallHint("尚未配置服务，可在「设置 → 服务」里添加")
            } else if results.isEmpty {
                smallHint("等待首次检查")
            } else {
                VStack(spacing: 2) {
                    ForEach(pairs, id: \.self) { i in
                        HStack(spacing: 8) {
                            ServiceStatusRow(status: rows[i], host: cfg.effectiveHost)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if i + 1 < rows.count {
                                ServiceStatusRow(status: rows[i + 1], host: cfg.effectiveHost)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Spacer(minLength: 0).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .card(verticalInset: 7)
    }

    /// 体检发现新监听端口：只提示、不擅自灌进服务列表，避免系统临时端口刷屏。
    private var discoveryHint: some View {
        let ports = catalog.discovered.map { String($0) }.joined(separator: ", ")
        return HStack(spacing: 4) {
            Image(systemName: "plus.magnifyingglass").font(.system(size: 8.5))
            Text("发现 \(catalog.discovered.count) 个新端口 · 设置 → 服务可加入监测")
                .font(.system(size: 8.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 3)
        .help("新端口：\(ports)")
    }

    private var storageWarning: String? {
        let storage = monitor.latest?.results.filter { $0.layer == .storage } ?? []
        let timeouts = storage.filter { $0.timedOut }.count
        if monitor.health == .stalled {
            // .stalled 也可能来自 L4 磁盘体检（D 状态 / 阵列降级），此时读库全绿。
            // 只有真的有读库超时才能提示「读库卡住」和冷启动，否则会误导用户去断电。
            if timeouts > 0 {
                return "ⓘ 端口与静态页正常但读库请求卡住 = 存储层阻塞。热重启常卡在 docker.service；先核对日志页内核 ATA / CRC 与阵列状态，确认后再决定是否冷启动。"
            }
            let diskBad = monitor.latest?.results.filter { $0.layer == .disk && !$0.ok } ?? []
            if !diskBad.isEmpty {
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                let when = monitor.disk.map { f.string(from: $0.date) } ?? "最近"
                return "ⓘ 读库探针本轮全部正常；\(when) 磁盘体检发现 "
                    + diskBad.map { $0.detail }.joined(separator: " · ")
                    + "。属磁盘 I/O 快照告警，先看日志页 SATA / I/O 明细，勿据此断电。"
            }
            return "ⓘ 存储层异常，但本轮无读库超时；请查看日志页明细。"
        }
        let bad = storage.filter { !$0.ok }
        if !bad.isEmpty {
            return "读库探针异常：" + bad.map { "\($0.name) \($0.latency)" }
                .joined(separator: " · ")
        }
        return nil
    }

    // MARK: - 趋势条

    private var trendStrip: some View {
        let items = Array(monitor.history.suffix(64))
        return VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "最近 \(items.count) 次检查",
                          trailing: items.isEmpty ? "" : items.last!.timeString)
            HStack(spacing: 1.5) {
                if items.isEmpty {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.15))
                        .frame(height: 8)
                } else {
                    ForEach(items) { s in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(s.health == .unknown ? Color.gray.opacity(0.3) : s.health.color)
                            .frame(height: 8)
                            .hoverData(HoverInfo.check(s, id: "trend.\(s.id.uuidString)"))
                    }
                }
            }
        }
    }

    // MARK: - 磁盘（性能 + 健康，压缩进总览）

    private var diskOverviewSection: some View {
        let vals = Array(monitor.visibleMetrics.suffix(48))
        let io = vals.last
        // 曲线按整段历史判断（与 CPU / 网络面板一致），数值只认最新样本；
        // 新版本刚升级时旧历史没有磁盘字段，会正确显示「—」而不是演示数据。
        let hasIO = vals.contains { $0.diskRead != nil || $0.diskWrite != nil }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("磁盘").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let d = monitor.disk {
                    Text("体检 \(d.date, style: .time)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .hoverData(HoverInfo.disk(d))
                }
                Spacer(minLength: 0)
                if cfg.showDemoMetrics {
                    Text("演示").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.orange.opacity(0.16)))
                }
                Button {
                    Task { await monitor.runDiskCheck() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help("重新体检磁盘")
            }
            .padding(.horizontal, 2)

            // 整机物理磁盘读写吞吐：只来自 SSH /proc/diskstats，缺失显示「—」
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("整机磁盘读写").font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 2)
                Text("↓ \(MetricFormat.rate(io?.diskRead))")
                    .foregroundStyle(Self.diskReadColor)
                Text("↑ \(MetricFormat.rate(io?.diskWrite))")
                    .foregroundStyle(Self.diskWriteColor)
            }
            .font(.system(size: 9.5, design: .monospaced))
            .hoverData(HoverInfo.diskIO(vals))
            if hasIO {
                LineChart(series: [
                    .init(vals.map(\.diskRead), Self.diskReadColor, fill: true),
                    .init(vals.map(\.diskWrite), Self.diskWriteColor, fill: false),
                ], height: 20, showLatestDot: false,
                         samples: vals, hoverID: "disk",
                         hoverContext: "整机磁盘吞吐 · 采样点")
            } else {
                Text("等待整机磁盘吞吐（SSH /proc/diskstats）")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(height: 20)
            }

            if let d = monitor.disk {
                // 盘很多时只列前三块 + 计数，完整清单在体检浮窗里，避免文字被省略号截断。
                let diskNames = d.physicalDisks.map(\.name)
                let diskLabel = diskNames.count <= 3
                    ? diskNames.joined(separator: " / ")
                    : diskNames.prefix(3).joined(separator: " / ") + " +\(diskNames.count - 3)"
                // 阵列与卷都直接按 report 里的实际条数渲染：新增盘建出新阵列 / 新卷
                // 就多一行，拔盘后旧卷消失就少一行，界面没有任何数量假设。
                HStack(spacing: 8) {
                    ForEach(d.arrays) { a in
                        HStack(spacing: 3) {
                            Circle().fill(a.healthy ? Color.green : Color.red)
                                .frame(width: 5, height: 5)
                            Text("\(a.name) \(a.healthy ? "正常" : "降级")")
                                .font(.system(size: 9, design: .monospaced))
                        }
                        .fixedSize()
                        .hoverData(HoverInfo.array(a, report: d))
                    }
                    if d.arrays.isEmpty {
                        Text("阵列 —").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text(d.physicalDisks.isEmpty
                         ? "物理盘 —"
                         : "物理盘 \(d.physicalDisks.count) 块 · \(diskLabel)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("D 状态 \(d.dStateCount) · SATA \(d.sataErrors.count) 条")
                        .font(.system(size: 8.5))
                        .foregroundStyle(d.dStateCount > 0 || !d.sataErrors.isEmpty
                                         ? Color.orange : Color.secondary)
                        .hoverData(HoverInfo.disk(d))
                }
                ForEach(d.volumes) { v in
                    HStack(spacing: 5) {
                        Text(v.mount).font(.system(size: 9, design: .monospaced))
                            .frame(width: 62, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.gray.opacity(0.18))
                                Capsule().fill(v.percent >= 90 ? Color.red : Color.accentColor)
                                    .frame(width: geo.size.width
                                           * CGFloat(min(100, v.percent)) / 100)
                            }
                        }
                        .frame(height: 3)
                        Text("\(v.percent)%").font(.system(size: 8.5, design: .monospaced))
                            .frame(width: 27, alignment: .trailing)
                        Text("剩 \(v.free)").font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                    }
                    .hoverData(HoverInfo.volume(v))
                }
                if d.hasWarning {
                    Text(d.warningText).font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .hoverData(HoverInfo.disk(d))
                } else if !d.sufficient {
                    Text("体检数据不足，未参与状态判定")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .hoverData(HoverInfo.disk(d))
                }
            } else {
                smallHint("尚未完成磁盘体检")
            }
        }
        .card(verticalInset: 7)
    }

    // MARK: - 日志（状态变化 + SATA / I/O 告警）

    private var sataLines: [String] { monitor.disk?.sataErrors ?? [] }

    private var logsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader(title: "状态变化记录", trailing: "\(monitor.events.count) 条")
                if monitor.events.isEmpty { smallHint("暂无状态变化记录") }
                ForEach(monitor.events) { e in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(e.level.color).frame(width: 5, height: 5)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.text).font(.system(size: 10))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(e.timeString).font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .hoverData(HoverInfo.event(e))
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 5) {
                SectionHeader(title: "SATA / I/O 告警",
                              trailing: sataLines.isEmpty ? "无" : "\(sataLines.count) 条")
                HStack(spacing: 6) {
                    if let d = monitor.disk {
                        Text("体检 \(d.date, style: .time) · \(d.reachable ? "运行 \(d.uptime)" : "不可用")")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .hoverData(HoverInfo.disk(d))
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await monitor.runDiskCheck() }
                    } label: {
                        Label("重新体检", systemImage: "arrow.clockwise")
                            .font(.system(size: 9.5))
                    }
                    .buttonStyle(.borderless)
                    .help("重新读取 dmesg 的 SATA / I/O 告警")
                }
                .padding(.horizontal, 2)
                if sataLines.isEmpty {
                    smallHint(monitor.disk == nil
                              ? "尚未完成磁盘体检"
                              : "暂无 SATA / I/O 告警（需在设置中启用 sudo 读取 dmesg）")
                } else {
                    ForEach(Array(sataLines.suffix(30).enumerated()), id: \.offset) { pair in
                        HStack(alignment: .top, spacing: 5) {
                            Text("!").font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.orange)
                                .frame(width: 6)
                            Text(pair.element.trimmingCharacters(in: .whitespaces))
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .hoverData(HoverInfo.sata(pair.element,
                                                  index: pair.offset,
                                                  report: monitor.disk))
                    }
                }
            }
            .card()
        }
    }

    private func smallHint(_ s: String) -> some View {
        HStack { Spacer(); Text(s).font(.system(size: 9.5)).foregroundStyle(.tertiary); Spacer() }
            .padding(.vertical, 10)
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                monitor.checkNow()
                Task { await monitor.runDiskCheck() }
            } label: {
                Label("立即检查", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(monitor.checking)

            Button(monitor.paused ? "继续" : "暂停") {
                // 关机后是应用主动暂停的，点「继续」时要把电源静默提示一并清掉
                if monitor.paused { monitor.resumeFromPowerPause() }
                else { monitor.paused = true }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 10.5))

            Spacer()

            Button {
                let r = Diagnostics.copyToPasteboard(monitor: monitor, cfg: cfg)
                reportResultText = r.ok
                    ? "已复制 \(r.text.count) 字符的 Markdown 报告到剪贴板。报告汇总最近探测结果、整机性能采样与磁盘错误，已脱敏、不含任何凭据，可直接粘贴到工单或另一台设备。"
                    : "剪贴板不可用，复制失败。请改用命令行 NASMonitor --report 导出。"
                showReportResult = true
            } label: { Image(systemName: "doc.on.clipboard") }
            .buttonStyle(.borderless)
            .help("一键复制排障报告（Markdown，已脱敏）")

            Button {
                showHelp = true
            } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.borderless)
            .help("使用说明")

            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Image(systemName: "gearshape") }
            .buttonStyle(.borderless)
            .help("设置")

            Button {
                NSApp.terminate(nil)
            } label: { Image(systemName: "power") }
            .buttonStyle(.borderless)
            .help("退出 NASMonitor")
        }
    }
}

// MARK: - ScrollView 内容高度测量

/// 把 ScrollView 内容的实测高度传回父视图，用于给 MenuBarExtra 弹出窗口一个确定高度。
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 单个服务的聚合状态

private struct ServiceStatusRow: View {
    let status: ContentView.ServiceStatus
    /// 当前 NAS 主机，由 ContentView 的 @ObservedObject cfg 传入；
    /// 改 IP 后父视图重建，按钮目标会立刻跟着变，不会残留旧地址。
    let host: String

    private var linkURL: URL? {
        ServiceLinks.resolve(spec: status.spec, host: host)
    }

    private var dot: Color {
        // 服务已停（端口不再监听）与「探测失败」是两回事，灰色标出，不误报成故障。
        if status.missing { return .secondary }
        if status.results.isEmpty { return .secondary }
        if status.hasTimeout { return .red }
        return status.ok ? .green : .orange
    }

    private var text: String {
        if status.missing { return "未监听" }
        if status.results.isEmpty { return "未检测" }
        if status.hasTimeout { return "超时" }
        return status.ok ? "正常" : "异常"
    }

    private var slowest: String {
        status.results.max { $0.ms < $1.ms }?.latency ?? "—"
    }

    /// 分层明细折进悬停浮窗，一行放完，服务区从 6 行 × 2 行压成 3 行 × 2 列
    private var hoverInfo: HoverInfo {
        HoverInfo.service(name: status.spec.name,
                          port: status.spec.port,
                          results: status.results)
    }

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(dot).frame(width: 5, height: 5)
            Text(status.spec.name).font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
            if status.discovered {
                Text("新").font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 3).padding(.vertical, 0.5)
                    .background(Capsule().fill(Color.orange.opacity(0.16)))
            }
            Spacer(minLength: 2)
            Text(text).font(.system(size: 9)).foregroundStyle(dot)
            Text(slowest)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
                .lineLimit(1)
            // 每个服务右侧的「打开网页」按钮：点击直接交给默认浏览器。
            // SSH / BT 等没有网页的端口不生成按钮；地址可在「设置 → 服务」逐项改。
            if let url = linkURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.borderless)
                .help("打开 \(status.spec.name) 网页 · \(url.absoluteString)")
                .accessibilityLabel("打开 \(status.spec.name) 网页")
            }
        }
        .padding(.vertical, 2)
        .opacity(status.missing ? 0.6 : 1)
        .hoverData(hoverInfo)
    }
}

// MARK: - 内置使用说明

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NASMonitor 如何判断 NAS 状态")
                .font(.system(size: 15, weight: .semibold))
            Group {
                Text("分四层探测，重点不是「ping 通没通」，而是区分网络活着和存储卡死：")
                bullet("网络层", "TCP 握手 6 个服务端口")
                bullet("静态层", "DSM Static / CGI、Amane Health、Jellyfin Public —— 只读系统分区或内存，存储挂起时仍秒回")
                bullet("存储层", "用必然失败的假凭据发认证请求。正常时秒回 401/400，存储挂起时读库卡死超时。零配置、不需要真实密码")
                bullet("磁盘层", "通过免密 SSH 读 /proc/mdstat、df、D 状态进程；可选 sudo 读 dmesg 的 SATA 链路错误")
                Text("当「端口通 + 静态页秒回 + 多项读库超时」同时出现，即判定为存储层阻塞并红色告警。这是 2026-11-06 存储链路故障的特征；该故障的背板与 SATA 线已于 11-07 整体更换。单个瞬时 D 状态进程不算阻塞证据。")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("提示")
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("· 面板只有「总览 / 日志」两页：总览依次是整机性能、磁盘读写与阵列卷状态、压缩后的服务状态与趋势条；日志页放状态变化记录和 SATA / I/O 告警明细。菜单栏只显示图标与状态色点，不显示文字。")
                Text("· 鼠标停在任意数据上会即时弹出浮窗：CPU / 内存 / 网络 / 磁盘吞吐显示当前值、峰值、均值、采样时间与数据源；曲线上移动可逐点查看那一次的完整采样；服务名显示各层探针的耗时与原始结论；阵列 / 卷 / 趋势色块 / 日志行 / SATA 明细显示各自的完整数据（面板里被截断的摘要在浮窗中展开）。浮窗只是叠加显示，不抢焦点、不拦截点击，也不改变面板高度。")
                Text("· 本机开了代理会被应用自动绕过，内网探测不会走代理。")
                Text("· 离开内网时自动暂停，不会在外出时反复告警。")
                Text("· 连续 2 轮一致才切换状态，避免网络抖动误报；次数可在设置中调整。")
                Text("· 探测间隔默认 2 分钟，同一时刻只允许一个网络作业（分层探测 / 性能采样 / 磁盘体检）。出现 2 个以上超时或读库阻塞时立即停止后续建连，间隔自动翻倍（最长 ×4），并暂停采样与体检；连续 2 轮无超时后逐级回落。状态条会显示橙色「阻塞熔断」。")
                Text("· 顶部「关机 / 重启」是不可逆操作，必须二次确认；指令经免密 SSH + sudo 下发，sudo 密码从本地 0600 凭据文件经 stdin 送入，不出现在命令行或日志中。确认框里会写明目标主机和实际命令。关机后监测会主动暂停，重启后静默 10 分钟，避免把预期内的断电误报成离线告警。「打开 DSM」只是用浏览器打开 DSM 页面，可在设置里改地址；不想要这些按钮可在「设置 → 常规 → 电源操作」整行隐藏。")
                Text("· 服务状态每行右侧的方框箭头小按钮会在默认浏览器打开该服务网页，默认按 http://主机:端口；可在「设置 → 服务」逐项改成完整 https 地址、/路径或含 {host} / {port} 的模板。SSH / BT 等没有网页的端口不显示按钮，DSM 行会沿用顶部「打开 DSM」配置的自定义地址。点击后面板自动收起，属正常行为。")
                Text("· DSM 的认证正常就要约 5 秒，应用为它单独使用更长超时；若前两个读库探针都已超时，本轮不会再发这个重请求。")
                Text("· 若 macOS 的「本地网络」权限未授予，直连会被系统拒绝（No route to host）。应用会自动切换到系统自带的 nc / curl / ssh 通道，面板右上角显示「兼容模式」，功能不受影响。也可到「系统设置 → 隐私与安全性 → 本地网络」手动允许。")
                Text("· CPU / 内存 / 网络上下行全部是整台 NAS 的数据，只来自 SSH 读 /proc 与 DSM Utilization 两条整机通道；某条不可用会显示「—」并说明原因。")
                Text("· 网络速率只累加物理网卡（本机实测仅 eth0），排除 docker 网桥、veth、sit、lo 等虚拟接口；存在 bond 时只取 bond，避免与成员口重复计数。**不会**用 qBittorrent 等任何单个服务的速率代替整机数据。")
                Text("· 磁盘读写吞吐只取 SSH 读 /proc/diskstats 的**物理整盘**（按 /sys/class/block 动态识别，盘符随冷启动重排，不写死字母），排除分区、md 阵列、dm、loop、ram 与 synoboot 启动盘；旧历史没有该字段或 SSH 不可用时显示「—」，不会用推算值补位。SATA / I/O 告警明细在日志页。")
                Text("· 2026-11-06 复核：sshd 已恢复，SSH /proc 能给出整机读数；DSM 登录仍返回 407（验证码/自动封锁），解除后自动启用。两条通道都不可用时一律显示「—」。")
                Text("· 想先看清图表样式，可在「设置 → 探针与凭据 → 整机性能采样」打开示例数据；该开关会用橙色「演示数据」标记，且不会写入真实历史。")
                Text("· 所有可选凭据保存在 ~/Library/Application Support/NASMonitor/credentials.json（权限 0600），不使用系统钥匙串，因此不会出现「想要使用钥匙串中的机密信息」并要求输入 Mac 登录密码的弹窗。")
                Text("· Amane Token 已配置时，Amane DB 探针会真实读库（/api/tasks）；存储挂起时该请求会超时，是判别半死状态的关键信号之一。")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("好") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 430)
    }

    private func bullet(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .frame(width: 42, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 电源操作二次验证卡片
//
// 只有输入「当前 NAS 地址」或「管理员密码后四位」后，destructive 按钮才可用。
// 密码本身不显示、不进日志/报告/argv，只由 PowerControl.verify 做一次等值比较。

private struct PowerConfirmCard: View {
    let action: PowerAction
    let onDone: (Bool) -> Void
    @ObservedObject private var cfg = Config.shared
    @State private var input = ""

    private var matched: Bool { PowerControl.verify(input, cfg: cfg) }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.86)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("确认 NAS 电源操作 · \(action.title)")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("目标：\(cfg.effectiveHost)")
                    Text("命令：sudo \(PowerControl.command(for: action, cfg: cfg))")
                    Text(action.consequence)
                    Text("不可撤销，请确认没有正在进行的备份或传输。")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Divider()
                Text("二次验证：\(PowerControl.confirmationHint(cfg))")
                    .font(.system(size: 10.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                TextField("输入确认信息", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                if !input.isEmpty && !matched {
                    Text("输入不匹配，电源指令不会下发。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button("取消", role: .cancel) { onDone(false) }
                        .buttonStyle(.bordered).controlSize(.small)
                    Spacer()
                    Button(action.title, role: .destructive) { onDone(true) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .foregroundStyle(matched ? Color.red : Color.secondary)
                        .disabled(!matched)
                }
            }
            .padding(14)
            .frame(width: 336)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
