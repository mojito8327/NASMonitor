import SwiftUI
import AppKit
import Foundation

// MARK: - 悬停浮窗（2026-11-08 第 13 轮）
//
// 设计约束（MenuBarExtra 弹出窗口的既有踩坑 + 本轮实测，勿回退）：
// 1. 不用 NSPopover / 自建 NSWindow：会抢焦点，且离屏渲染无法验收。
// 2. 不用 .help(...)：macOS 原生 tooltip 延迟长、样式不可控、只能塞一段字符串。
// 3. 浮窗画在 ContentView 根视图的 overlay 上，位于 ScrollView 之外，
//    因此不会被裁切，也不参与 GeometryReader + PreferenceKey 的 contentHeight 测量，
//    面板高度仍由真实内容决定（不会平白多出一块空白）。
// 4. 整个面板只保留一个浮窗实例：用 Environment 里的 Binding 共享当前 hover 目标，
//    每个数据点只上报自己的 HoverInfo 与在根坐标系中的 frame。
// 5. 浮窗 allowsHitTesting(false)：不拦截点击、不改变鼠标进出、不获取焦点。

// MARK: - 数据模型

enum HoverTint: String, Hashable {
    case plain, secondary, good, warn, bad, accent

    var color: Color {
        switch self {
        case .plain:     return .primary
        case .secondary: return .secondary
        case .good:      return Color(red: 0.18, green: 0.72, blue: 0.38)
        case .warn:      return .orange
        case .bad:       return .red
        case .accent:    return .accentColor
        }
    }
}

struct HoverField: Identifiable, Hashable {
    var id: String { "\(label)#\(value)#\(tint.rawValue)" }
    let label: String
    let value: String
    let tint: HoverTint

    init(_ label: String, _ value: String, _ tint: HoverTint = .plain) {
        self.label = label
        self.value = value
        self.tint = tint
    }
}

struct HoverInfo: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let fields: [HoverField]
    let note: String

    init(_ id: String, _ title: String,
         subtitle: String = "", fields: [HoverField] = [], note: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.fields = fields
        self.note = note
    }
}

struct HoverState {
    var info: HoverInfo
    var frame: CGRect
}

enum HoverFormat {
    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }

    static func mean(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "—" }
        return String(format: "%.1f", values.reduce(0, +) / Double(values.count))
    }
}

// MARK: - 浮窗定位

enum HoverLayout {
    /// 所有可悬停数据点用这个命名坐标系上报 frame；浮窗 overlay 用同一坐标系定位。
    static let space = "nm.hover.root"
    static let maxCardWidth: CGFloat = 286
    static let minCardWidth: CGFloat = 148
    static let horizontalPadding: CGFloat = 18
    static let labelColumnWidth: CGFloat = 60

    /// 内容优先按自然宽度排版，只有超出上限时才换行；不再让每种浮窗一律占满 286pt。
    static func cardWidth(_ panelWidth: CGFloat) -> CGFloat {
        min(maxCardWidth, max(1, panelWidth - 16))
    }

    static func cardWidth(for info: HoverInfo, panelWidth: CGFloat) -> CGFloat {
        let cap = cardWidth(panelWidth)
        let title = textWidth(info.title, font: .systemFont(ofSize: 10.5, weight: .semibold))
        let subtitle = textWidth(info.subtitle, font: .monospacedSystemFont(ofSize: 8.5, weight: .regular))
        let note = textWidth(info.note, font: .systemFont(ofSize: 8.5))
        let rows = info.fields.map { field in
            labelColumnWidth + 6 + textWidth(field.value,
                font: .monospacedSystemFont(ofSize: 9, weight: .regular))
        }.max() ?? 0
        let natural = max(title, subtitle, note, rows) + horizontalPadding
        return min(cap, max(minCardWidth, ceil(natural)))
    }

    private static func textWidth(_ string: String, font: NSFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    /// 首帧还没拿到 PreferenceKey 实测尺寸时，按同一宽度约束估算实际换行后的高度。
    /// 实测值到达后始终以实测高度定位，避免固定/过大的估算制造空白。
    static func estimatedHeight(_ info: HoverInfo, width: CGFloat? = nil) -> CGFloat {
        let cardWidth = width ?? cardWidth(for: info, panelWidth: 372)
        let contentWidth = max(32, cardWidth - horizontalPadding)
        let valueWidth = max(24, contentWidth - labelColumnWidth - 6)
        let titleFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let subtitleFont = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
        let valueFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let labelFont = NSFont.systemFont(ofSize: 8.5)
        let noteFont = NSFont.systemFont(ofSize: 8.5)
        var heights: [CGFloat] = [textHeight(info.title, font: titleFont, width: contentWidth)]
        if !info.subtitle.isEmpty {
            heights.append(textHeight(info.subtitle, font: subtitleFont, width: contentWidth))
        }
        if !info.fields.isEmpty {
            heights.append(2.5) // 分隔线及上下留白
            for field in info.fields {
                heights.append(max(textHeight(field.label, font: labelFont, width: labelColumnWidth),
                                   textHeight(field.value, font: valueFont, width: valueWidth)))
            }
        }
        if !info.note.isEmpty {
            heights.append(textHeight(info.note, font: noteFont, width: contentWidth) + 2)
        }
        let gaps = CGFloat(max(0, heights.count - 1)) * 4
        return ceil(14 + heights.reduce(0, +) + gaps + 2)
    }

    private static func textHeight(_ string: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let rect = (string as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return max(font.ascender - font.descender + font.leading, ceil(rect.height))
    }

    /// 优先放在数据下方；下方放不下就翻到上方；都不够时贴着面板底部夹住。
    /// 纯函数，便于 --hover-selftest 做边界回归。
    static func origin(anchor: CGRect, panel: CGSize, card: CGSize) -> CGPoint {
        let w = min(max(1, card.width > 1 ? card.width : cardWidth(panel.width)),
                    max(1, panel.width - 16))
        let h = card.height > 1 ? card.height : 96
        let x = min(max(anchor.minX - 6, 8), max(8, panel.width - w - 8))
        let below = anchor.maxY + 6
        let above = anchor.minY - h - 6
        let y: CGFloat
        if below + h <= panel.height - 8 {
            y = below
        } else if above >= 8 {
            y = above
        } else {
            y = max(8, min(below, panel.height - h - 8))
        }
        return CGPoint(x: max(8, x), y: max(8, y))
    }
}

// MARK: - 各类数据点的浮窗内容（纯函数，可自检）

extension HoverInfo {
    /// 一条性能采样：把整机 CPU / 内存 / 网络 / 磁盘 / 来源 / 时间一次列全。
    /// 曲线上悬停具体采样点、以及顶部数据卡片都复用这个口径。
    static func sample(_ s: MetricsSample, id: String,
                       context: String = "整机性能采样") -> HoverInfo {
        let pct = s.memPercent.map { String(format: "%.1f%%", $0) } ?? "—"
        let fields: [HoverField] = [
            .init("CPU", MetricFormat.cpu(s.cpu), .accent),
            .init("内存", "\(MetricFormat.bytes(s.memUsed)) / \(MetricFormat.bytes(s.memTotal)) (\(pct))"),
            .init("下行", MetricFormat.rate(s.rx)),
            .init("上行", MetricFormat.rate(s.tx)),
            .init("磁盘读", MetricFormat.rate(s.diskRead)),
            .init("磁盘写", MetricFormat.rate(s.diskWrite)),
            .init("CPU 源", s.cpuSource.isEmpty ? "—" : s.cpuSource, .secondary),
            .init("网络源", s.netSource.isEmpty ? "—" : s.netSource, .secondary),
            .init("磁盘源", s.diskSource.isEmpty ? "—" : s.diskSource, .secondary),
        ]
        let note = s.note.isEmpty
            ? "全部为整台 NAS 的读数；缺失显示「—」，不用推算值或演示数据补位。"
            : s.note + " · 缺失显示「—」"
        return HoverInfo(id, context, subtitle: "采样时间 \(HoverFormat.time(s.date))",
                         fields: fields, note: note)
    }

    /// 曲线逐点悬停：只列该采样点的核心数值，避免全量 9 字段卡片盖住半个面板。
    /// 想看来源 / 峰值 / 均值，悬停上方数据卡片即可。
    static func chartPoint(_ s: MetricsSample, id: String, context: String) -> HoverInfo {
        let pct = s.memPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        return HoverInfo(id, context,
            subtitle: "采样时间 \(HoverFormat.time(s.date))",
            fields: [
                .init("CPU", MetricFormat.cpu(s.cpu), .accent),
                .init("内存", "\(MetricFormat.bytes(s.memUsed)) · \(pct)"),
                .init("下行", MetricFormat.rate(s.rx)),
                .init("上行", MetricFormat.rate(s.tx)),
                .init("磁盘读", MetricFormat.rate(s.diskRead)),
                .init("磁盘写", MetricFormat.rate(s.diskWrite)),
            ],
            note: "整机读数；悬停上方数值可看峰值 / 均值 / 数据源。")
    }

    /// 顶部性能卡片：当前 / 峰值 / 均值 / 数据源 / 采样时间 / 样本数。
    static func performance(id: String, title: String,
                            current: String, peak: String, average: String,
                            source: String, date: Date?, count: Int,
                            note: String) -> HoverInfo {
        HoverInfo(id, title,
                  subtitle: "最近 \(count) 个采样点 · 整机读数",
                  fields: [
                      .init("当前", current, .accent),
                      .init("峰值", peak),
                      .init("均值", average),
                      .init("数据源", source.isEmpty ? "—" : source, .secondary),
                      .init("采样时间", date.map(HoverFormat.time) ?? "—", .secondary),
                      .init("样本数", "\(count)", .secondary),
                  ], note: note)
    }

    /// 整机磁盘读写吞吐：数值 + 曲线峰值 + 来源 + 口径说明。
    static func diskIO(_ vals: [MetricsSample]) -> HoverInfo {
        let io = vals.last
        let reads = vals.compactMap(\.diskRead)
        let writes = vals.compactMap(\.diskWrite)
        return HoverInfo("disk.io", "整机物理磁盘吞吐",
            subtitle: "SSH /proc/diskstats · 最近 \(vals.count) 个采样点",
            fields: [
                .init("当前读", MetricFormat.rate(io?.diskRead)),
                .init("当前写", MetricFormat.rate(io?.diskWrite)),
                .init("读峰值", MetricFormat.rate(reads.max())),
                .init("写峰值", MetricFormat.rate(writes.max())),
                .init("数据源", io?.diskSource.isEmpty == false ? (io?.diskSource ?? "—") : "—", .secondary),
                .init("采样时间", io.map { HoverFormat.time($0.date) } ?? "—", .secondary),
            ],
            note: "只累加物理整盘，排除分区 / md / dm / loop / ram 等虚拟层；读长期为 0 是页缓存命中或确实无物理读，不是采集失败。")
    }

    /// 服务状态行：列出每一层探针的耗时与原始结论。
    static func service(name: String, port: UInt16,
                        results: [ProbeResult]) -> HoverInfo {
        var fields: [HoverField] = [
            .init("端口", "\(port)", .secondary),
            .init("探针数", "\(results.count)", .secondary),
        ]
        if results.isEmpty {
            fields.append(.init("结论", "端口未通，未做进一步探测", .warn))
        } else {
            for r in results {
                let tint: HoverTint = r.timedOut ? .bad : (r.ok ? .good : .warn)
                fields.append(.init("\(r.layer.rawValue) · \(r.name)",
                                    "\(r.latency) · \(r.detail)", tint))
            }
        }
        return HoverInfo("service.\(name)", "\(name) · 分层探测明细",
                         subtitle: "结果数 \(results.count) · 悬停即时显示",
                         fields: fields,
                         note: "TCP 通只代表端口在监听；假凭据读库正常返回 401 / 400 / 200 才说明用户库可读，超时才是存储层阻塞。")
    }

    /// 趋势条上的某一次检查：完整状态、分层统计、完整摘要（面板里只显示一行）。
    static func check(_ s: Snapshot, id: String) -> HoverInfo {
        let tcp = s.results.filter { $0.layer == .tcp }
        let stat = s.results.filter { $0.layer == .stat }
        let storage = s.results.filter { $0.layer == .storage }
        let disk = s.results.filter { $0.layer == .disk }
        let timeouts = s.results.filter { $0.timedOut }.count
        let storageTimeouts = storage.filter { $0.timedOut }.count
        var fields: [HoverField] = [
            .init("判定", s.health.title, s.health.isProblem ? .bad : .good),
            .init("网络", "\(tcp.filter(\.ok).count)/\(tcp.count) 正常"),
            .init("静态", "\(stat.filter(\.ok).count)/\(stat.count) 正常"),
            .init("存储", "\(storage.filter(\.ok).count)/\(storage.count) 正常",
                  storageTimeouts > 0 ? .bad : .plain),
            .init("磁盘", "\(disk.filter(\.ok).count)/\(disk.count) 正常"),
            .init("超时", "\(timeouts) 个（读库 \(storageTimeouts) 个）",
                  timeouts > 0 ? .warn : .secondary),
        ]
        for r in s.results.filter({ !$0.ok || $0.timedOut }) {
            fields.append(.init("异常 · \(r.name)", "\(r.latency) · \(r.detail)", .warn))
        }
        return HoverInfo(id, "检查快照 · \(s.timeString)",
                         subtitle: HoverFormat.time(s.date),
                         fields: fields, note: s.summary)
    }

    /// 磁盘阵列
    static func array(_ a: DiskReport.ArrayInfo, report d: DiskReport) -> HoverInfo {
        HoverInfo("array.\(a.name)", "阵列 \(a.name)",
            subtitle: "体检 \(HoverFormat.time(d.date))",
            fields: [
                .init("状态", a.healthy ? "正常" : "降级", a.healthy ? .good : .bad),
                .init("详情", a.detail.isEmpty ? "—" : a.detail),
                .init("D 状态", "\(d.dStateCount) 个进程", d.dStateCount > 0 ? .warn : .plain),
                .init("SATA", "\(d.sataErrors.count) 条", d.sataErrors.isEmpty ? .plain : .warn),
            ], note: "阵列状态来自 /proc/mdstat；降级与读库超时是两类独立证据。")
    }

    /// 卷使用率
    static func volume(_ v: DiskReport.VolumeInfo) -> HoverInfo {
        HoverInfo("volume.\(v.mount)", "卷 \(v.mount)",
            subtitle: "df 容量快照",
            fields: [
                .init("使用率", "\(v.percent)%", v.percent >= 90 ? .bad : .accent),
                .init("总容量", v.total.isEmpty ? "—" : v.total),
                .init("已用", v.used.isEmpty ? "—" : v.used),
                .init("可用", v.free.isEmpty ? "—" : v.free),
                .init("判定", v.percent >= 90 ? "空间紧张" : "正常",
                      v.percent >= 90 ? .warn : .good),
            ], note: "≥90% 会计入磁盘告警，但不会判成读库卡死。")
    }

    /// 完整磁盘体检报告
    static func disk(_ d: DiskReport) -> HoverInfo {
        HoverInfo("disk.report", "磁盘体检报告",
            subtitle: HoverFormat.time(d.date),
            fields: [
                .init("SSH", d.reachable ? "可达" : "不可用", d.reachable ? .good : .bad),
                .init("运行", d.uptime.isEmpty ? "—" : d.uptime),
                .init("阵列", "\(d.arrays.count) 组 · 降级 \(d.arrays.filter { !$0.healthy }.count) 组",
                      d.arrays.contains { !$0.healthy } ? .bad : .plain),
                .init("卷", "\(d.volumes.count) 个 · "
                      + (d.volumes.isEmpty ? "—" : d.volumes.map(\.mount).joined(separator: " "))),
                .init("物理盘", d.physicalDisks.isEmpty ? "—" : "\(d.physicalDisks.count) 块"),
                .init("盘清单", d.physicalDisks.isEmpty ? "—"
                      : d.physicalDisks.map { "\($0.name) \($0.size) \($0.model)" }
                          .joined(separator: " · ")),
                .init("监听端口", d.listeningPorts.isEmpty ? "—" : "\(d.listeningPorts.count) 个"),
                .init("D 状态", "\(d.dStateCount) 个进程", d.dStateCount > 0 ? .warn : .plain),
                .init("SATA", "\(d.sataErrors.count) 条", d.sataErrors.isEmpty ? .plain : .warn),
                .init("判定", d.warningText, d.hasWarning ? .warn : .good),
                .init("原始提示", d.rawHint.isEmpty ? "—" : d.rawHint, .secondary),
            ], note: "阵列 / 卷 / 物理盘 / 监听端口每次体检按实际枚举，插拔盘与增删服务后自动更新；D 状态 / 阵列降级会判 .stalled，但不等于读库超时，勿据此断电。")
    }

    /// 底部状态条：把 lineLimit(1) 截掉的完整摘要展开
    static func summary(health: Health, summary: String, date: Date?,
                        host: String, throttle: String, power: String) -> HoverInfo {
        HoverInfo("header.summary", "当前状态 · 完整判定摘要",
            subtitle: "面板底部状态条（悬停展开）",
            fields: [
                .init("状态", health.title, health.isProblem ? .bad : .good),
                .init("本机目标", host, .secondary),
                .init("上次检查", date.map(HoverFormat.time) ?? "—", .secondary),
                .init("节流", throttle.isEmpty ? "基础节奏" : throttle,
                      throttle.isEmpty ? .plain : .warn),
                .init("电源静默", power.isEmpty ? "无" : power, .secondary),
            ], note: summary.isEmpty ? "等待首次检查完成" : summary)
    }

    /// 日志页状态变化记录
    static func event(_ e: Event) -> HoverInfo {
        HoverInfo("event.\(e.id.uuidString)", "状态变化记录",
            subtitle: e.timeString,
            fields: [
                .init("级别", e.level.title, e.level.isProblem ? .warn : .good),
                .init("发生时间", HoverFormat.time(e.date), .secondary),
                .init("内容", e.text),
            ], note: "只记录 health 变化与关键告警，不写凭据或 cookie。")
    }

    /// 日志页 SATA / I/O 告警明细（面板里 lineLimit(2) 会被截断）
    static func sata(_ raw: String, index: Int, report d: DiskReport?) -> HoverInfo {
        HoverInfo("sata.\(index)", "SATA / I/O 告警 · 第 \(index + 1) 条",
            subtitle: d.map { "体检 \(HoverFormat.time($0.date))" } ?? "尚未完成磁盘体检",
            fields: [
                .init("内核日志", raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                .init("条数", d.map { "\($0.sataErrors.count) 条" } ?? "—", .secondary),
                .init("D 状态", d.map { "\($0.dStateCount) 个进程" } ?? "—", .warn),
            ], note: "来自 dmesg（需 sudo 读取）。与读库超时是独立证据：SATA 链路错误提示查线缆 / 盘位，不代表必须物理断电冷启动。")
    }
}

// MARK: - Environment 共享 hover 状态

private struct HoverSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<HoverState?> = Binding<HoverState?>.constant(nil)
}

extension EnvironmentValues {
    var hoverSelection: Binding<HoverState?> {
        get { self[HoverSelectionKey.self] }
        set { self[HoverSelectionKey.self] = newValue }
    }
}

/// 每个数据点上报自己的 frame。用字典而不是单值，避免嵌套视图互相覆盖。
struct HoverAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct HoverCardMeasurement: Equatable {
    let id: String
    let size: CGSize
}

struct HoverCardSizeKey: PreferenceKey {
    static var defaultValue = HoverCardMeasurement(id: "", size: .zero)
    static func reduce(value: inout HoverCardMeasurement, nextValue: () -> HoverCardMeasurement) {
        value = nextValue()
    }
}

/// 把一个普通数据显示包装成可悬停目标。
/// 只上报 info + frame，浮窗本体由 ContentView 根视图统一绘制。
struct HoverData<Content: View>: View {
    let info: HoverInfo
    let content: Content

    @Environment(\.hoverSelection) private var selection
    @State private var frame: CGRect = .zero

    var body: some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: HoverAnchorKey.self,
                        value: [info.id: geo.frame(in: .named(HoverLayout.space))])
                }
            )
            .onPreferenceChange(HoverAnchorKey.self) { dict in
                if let f = dict[info.id], f != frame { frame = f }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    selection.wrappedValue = HoverState(info: info, frame: frame)
                } else if selection.wrappedValue?.info.id == info.id {
                    // 相邻数据点之间移动时，旧的「离开」可能比新的「进入」晚到；
                    // 只清自己，避免把新浮窗一起清掉。
                    selection.wrappedValue = nil
                }
            }
    }
}

extension View {
    func hoverData(_ info: HoverInfo) -> some View {
        HoverData(info: info, content: self)
    }
}

// MARK: - 浮窗外观

struct HoverCardView: View {
    let info: HoverInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !info.subtitle.isEmpty {
                Text(info.subtitle)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !info.fields.isEmpty {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.8))
                    .frame(height: 0.5)
                    .padding(.vertical, 1)
                ForEach(info.fields) { f in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(f.label)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(f.value)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(f.tint.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            if !info.note.isEmpty {
                Text(info.note)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                // 用系统薄材质轻微透出并柔化下层图表，避免底下文字直接穿透干扰阅读。
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.18))
                }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.78), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 6, x: 0, y: 2)
        // 关键：浮窗不参与命中测试，不抢焦点、不影响底下数据点的鼠标进出
        .allowsHitTesting(false)
    }
}

// MARK: - 离屏预览用的浮窗样本

extension UIPreview {
    /// --render --hover-preview 时强制显示一个浮窗，供离屏截图验收。
    /// kind: sample（曲线采样点）/ full（完整采样）/ check（检查快照）/ disk（磁盘）
    ///       / service（服务）/ sata（告警）/ summary（底部状态条）
    static var hoverPreviewKind = "sample"
    /// --hover-anchor-y 可把预览锚点挪到面板底部，验收「下方放不下就翻到上方」。
    static var hoverPreviewAnchorY: CGFloat = 76

    static var hoverPreviewState: HoverState? {
        guard showHoverPreview else { return nil }
        let s = MetricsSample(date: Date(), cpu: 3.95, memUsed: 1353187328,
                              memTotal: 3996033024, rx: 500, tx: 666.67,
                              diskRead: 0, diskWrite: 1765396.08,
                              cpuSource: "整机 · SSH /proc", netSource: "整机 · SSH /proc",
                              diskSource: "整机 · SSH /proc/diskstats", note: "")
        let info: HoverInfo
        switch hoverPreviewKind {
        case "check":
            info = HoverInfo.check(
                Snapshot(date: Date(), health: .online, summary: "全部 6 个端口正常，静态页秒回，读库探针 3/3 正常，磁盘体检无异常",
                         results: [
                            ProbeResult(id: "tcp.dsm", name: "DSM", layer: .tcp, ok: true, detail: "握手成功", ms: 4),
                            ProbeResult(id: "sto.dsm", name: "DSM Auth", layer: .storage, ok: true, detail: "code 400 · 认证库可读", ms: 5600),
                         ]),
                id: "preview.check")
        case "disk":
            info = HoverInfo.disk(DiskReport(
                date: Date(), reachable: true,
                arrays: [.init(name: "md2", healthy: true, detail: "2/2 设备在线")],
                volumes: [.init(mount: "/volume1", total: "3.6T", used: "1.2T", free: "2.4T", percent: 34)],
                dStateCount: 0, sataErrors: [], uptime: "12 天", rawHint: "数据充分"))
        case "service":
            info = HoverInfo.service(name: "DSM", port: 5000, results: [
                ProbeResult(id: "tcp.dsm", name: "DSM", layer: .tcp, ok: true, detail: "握手成功", ms: 4),
                ProbeResult(id: "stat.dsm-icon", name: "DSM Static", layer: .stat, ok: true, detail: "HTTP 200", ms: 12),
                ProbeResult(id: "sto.dsm", name: "DSM Auth", layer: .storage, ok: true, detail: "code 400 · 认证库可读", ms: 5600),
            ])
        case "sata":
            info = HoverInfo.sata("ata3: hard resetting link / SError { Handshk } / WRITE DMA EXT failed",
                                  index: 0,
                                  report: DiskReport(date: Date(), reachable: true,
                                                     arrays: [.init(name: "md2", healthy: true, detail: "2/2")],
                                                     volumes: [], dStateCount: 2,
                                                     sataErrors: ["ata3: hard resetting link"],
                                                     uptime: "12 天", rawHint: ""))
        case "full":
            info = HoverInfo.sample(s, id: "preview.full", context: "整机性能采样 · 全量字段")
        case "summary":
            info = HoverInfo.summary(health: .online,
                                     summary: "全部 6 个端口正常，静态页秒回，读库探针 3/3 正常，磁盘体检 2 阵列 / 2 卷无异常",
                                     date: Date(), host: "192.168.1.10",
                                     throttle: "", power: "")
        default:
            info = HoverInfo.chartPoint(s, id: "preview.sample",
                                        context: "CPU 曲线 · 采样点")
        }
        // 默认锚在总览页 CPU 卡片附近；根坐标系里浮窗按 HoverLayout.origin 自动摆放
        return HoverState(info: info,
                          frame: CGRect(x: 24, y: hoverPreviewAnchorY,
                                        width: 300, height: 18))
    }
}

// MARK: - 纯内存自检

enum HoverSelfTest {
    static func run() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1; print("  ✓ \(name)") }
            else { fail += 1; print("  ✗ \(name)") }
        }
        print("NASMonitor 悬停浮窗自检 · \(Date())")

        let s = MetricsSample(date: Date(timeIntervalSince1970: 1_700_000_000),
                              cpu: 3.95, memUsed: 1_353_187_328, memTotal: 3_996_033_024,
                              rx: 500, tx: 666.67, diskRead: 0, diskWrite: 1_765_396,
                              cpuSource: "整机 · SSH /proc", netSource: "整机 · SSH /proc",
                              diskSource: "整机 · SSH /proc/diskstats", note: "")
        let sample = HoverInfo.sample(s, id: "sample.x")
        check("采样浮窗含 9 个字段", sample.fields.count == 9)
        check("采样浮窗保留磁盘读 0 B/s（不填推算值）",
              sample.fields.contains { $0.label == "磁盘读" && $0.value == "0 B/s" })
        check("采样浮窗写明三条来源",
              sample.fields.filter { $0.label.hasSuffix("源") }.count == 3)
        check("采样浮窗带完整时间戳", sample.subtitle.contains("2023-"))

        let empty = HoverInfo.sample(MetricsSample(), id: "sample.empty")
        check("空样本不崩溃且全部显示 —",
              empty.fields.filter { $0.value.contains("—") }.count >= 6)

        let point = HoverInfo.chartPoint(s, id: "chart.cpu", context: "CPU 曲线 · 采样点")
        check("曲线逐点浮窗只列 6 个核心值", point.fields.count == 6)
        check("曲线逐点浮窗不塞来源字段",
              !point.fields.contains { $0.label.hasSuffix("源") })

        let snap = Snapshot(date: Date(), health: .online, summary: "完整摘要：读库 3/3 正常",
                            results: [
                                ProbeResult(id: "a", name: "DSM", layer: .tcp, ok: true, detail: "ok", ms: 4),
                                ProbeResult(id: "b", name: "DSM Auth", layer: .storage, ok: true, detail: "code 400", ms: 5600),
                            ])
        let checkInfo = HoverInfo.check(snap, id: "trend.1")
        check("检查浮窗展开完整摘要", checkInfo.note == snap.summary)
        check("检查浮窗读库超时计数为 0",
              checkInfo.fields.contains { $0.label == "超时" && $0.value == "0 个（读库 0 个）" })
        let stalled = Snapshot(date: Date(), health: .stalled, summary: "存储层阻塞",
                               results: [ProbeResult(id: "c", name: "Jellyfin Auth", layer: .storage,
                                                     ok: false, detail: "读库超时", ms: 6000, timedOut: true)])
        let stalledInfo = HoverInfo.check(stalled, id: "trend.2")
        check("真读库超时会列异常明细",
              stalledInfo.fields.contains { $0.label.hasPrefix("异常") && $0.value.contains("读库超时") })

        let svc = HoverInfo.service(name: "DSM", port: 5000, results: snap.results)
        check("服务浮窗列出每层探针", svc.fields.count == 4 && svc.id == "service.DSM")
        check("服务浮窗空结果给出明确结论",
              HoverInfo.service(name: "SSH", port: 22, results: []).fields
                .contains { $0.value == "端口未通，未做进一步探测" })

        let d = DiskReport(date: Date(), reachable: true,
                           arrays: [.init(name: "md2", healthy: false, detail: "1/2")],
                           volumes: [.init(mount: "/volume1", total: "3.6T", used: "3.3T",
                                           free: "0.3T", percent: 92)],
                           dStateCount: 2, sataErrors: ["ata3: hard resetting link"],
                           uptime: "12 天", rawHint: "")
        let disk = HoverInfo.disk(d)
        check("磁盘浮窗同时呈现 D 状态与 SATA",
              disk.fields.contains { $0.label == "D 状态" && $0.value == "2 个进程" }
                && disk.fields.contains { $0.label == "SATA" && $0.value == "1 条" })
        check("磁盘浮窗不把磁盘告警写成读库卡死",
              !disk.note.contains("存储层阻塞") && !disk.note.contains("物理断电")
                && disk.note.contains("不等于读库超时"))
        check("卷浮窗 92% 判为空间紧张",
              HoverInfo.volume(d.volumes[0]).fields.contains { $0.label == "判定" && $0.value == "空间紧张" })
        check("阵列浮窗降级标红",
              HoverInfo.array(d.arrays[0], report: d).fields
                .contains { $0.label == "状态" && $0.tint == .bad })

        let shortInfo = HoverInfo("short", "CPU", fields: [.init("当前", "4%")])
        let shortWidth = HoverLayout.cardWidth(for: shortInfo, panelWidth: 372)
        let fullWidth = HoverLayout.cardWidth(for: sample, panelWidth: 372)
        check("短内容浮窗按自然宽度收窄", shortWidth < HoverLayout.cardWidth(372))
        check("长内容浮窗宽度受面板上限约束", fullWidth <= HoverLayout.cardWidth(372))
        check("不同内容得到不同宽度", shortWidth < fullWidth)

        let panel = CGSize(width: 372, height: 620)
        let card = CGSize(width: 286, height: 180)
        let p1 = HoverLayout.origin(anchor: CGRect(x: 20, y: 60, width: 200, height: 16),
                                    panel: panel, card: card)
        check("浮窗优先落在数据下方", p1.y == 82 && p1.x >= 8)
        check("浮窗不超出右边界", p1.x + HoverLayout.cardWidth(panel.width) <= panel.width - 7)
        let p2 = HoverLayout.origin(anchor: CGRect(x: 20, y: 560, width: 200, height: 16),
                                    panel: panel, card: card)
        check("底部数据自动翻到上方", p2.y == 560 - 180 - 6)
        let p3 = HoverLayout.origin(anchor: CGRect(x: 360, y: 300, width: 10, height: 10),
                                    panel: panel, card: card)
        check("右侧数据向左夹住", p3.x + HoverLayout.cardWidth(panel.width) <= panel.width - 8)
        let tiny = HoverLayout.origin(anchor: CGRect(x: 0, y: 0, width: 1, height: 1),
                                      panel: CGSize(width: 200, height: 120), card: .zero)
        check("极小面板也不会出现负坐标", tiny.x >= 8 && tiny.y >= 8)

        let est = HoverLayout.estimatedHeight(point)
        check("紧凑浮窗估算高度为正且适合自动定位", est > 80 && est < 260)
        check("全量浮窗估算高度大于紧凑浮窗",
              HoverLayout.estimatedHeight(sample) > est)
        let bottom = HoverLayout.origin(
            anchor: CGRect(x: 24, y: 470, width: 300, height: 18),
            panel: panel,
            card: CGSize(width: HoverLayout.cardWidth(panel.width), height: est))
        check("底部锚点用估算高度也能翻到上方", bottom.y < 470)
        check("翻到上方后卡片不越出面板底部", bottom.y + est <= panel.height)

        let previousPreview = UIPreview.showHoverPreview
        UIPreview.showHoverPreview = true
        let previousKind = UIPreview.hoverPreviewKind
        check("每种预览浮窗都带字段",
              ["sample", "full", "check", "disk", "service", "sata", "summary"].allSatisfy { kind in
                  UIPreview.hoverPreviewKind = kind
                  return !(UIPreview.hoverPreviewState?.info.fields.isEmpty ?? true)
              })
        UIPreview.hoverPreviewKind = previousKind
        UIPreview.showHoverPreview = previousPreview

        print("结果: \(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}
