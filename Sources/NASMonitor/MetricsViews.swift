import SwiftUI
import AppKit

// MARK: - 轻量折线图（自绘 Path，零依赖，明暗模式通用）

struct LineChart: View {
    struct Series {
        let values: [Double?]
        let color: Color
        let fill: Bool
        init(_ values: [Double?], _ color: Color, fill: Bool = true) {
            self.values = values
            self.color = color
            self.fill = fill
        }
    }

    let series: [Series]
    /// 固定上限（CPU 用 100）；nil 时按当前数据自动缩放
    var ceiling: Double? = nil
    var height: CGFloat = 60
    var showLatestDot = true
    /// 曲线逐点悬停：samples 与 series[0].values 来自同一个 data 数组，一一对应。
    /// 不传 samples 时曲线保持纯展示（例如菜单栏小图）。
    var samples: [MetricsSample]? = nil
    var hoverID = "chart"
    var hoverContext = "整机性能采样点"

    @Environment(\.hoverSelection) private var hoverSelection
    @State private var rootFrame: CGRect = .zero

    private struct Segment { let points: [CGPoint] }

    /// 把 x 坐标反查成第几个采样点，浮窗锚在鼠标位置上。
    private func setChartHover(_ point: CGPoint?, width: CGFloat) {
        let key = "chart.\(hoverID)"
        guard let samples, !samples.isEmpty, let p = point else {
            if hoverSelection.wrappedValue?.info.id == key {
                hoverSelection.wrappedValue = nil
            }
            return
        }
        let n = samples.count
        let i = n == 1 ? 0
            : min(n - 1, max(0, Int(round(p.x / max(1, width) * CGFloat(n - 1)))))
        hoverSelection.wrappedValue = HoverState(
            info: HoverInfo.chartPoint(samples[i], id: key, context: hoverContext),
            frame: CGRect(x: rootFrame.minX + p.x,
                          y: rootFrame.minY + p.y,
                          width: 1, height: 1))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let count = max(2, series.map(\.values.count).max() ?? 2)
            let peak = series.flatMap(\.values).compactMap { $0 }.max() ?? 0
            let top = max(1, ceiling ?? max(peak * 1.18, 1))

            ZStack(alignment: .topLeading) {
                // 三条水平网格
                ForEach(0..<3, id: \.self) { i in
                    Path { p in
                        let y = h * CGFloat(i) / 2
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                }

                ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                    let segments = Self.segments(s.values, count: count, w: w, h: h, top: top)
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        if seg.points.count >= 2 {
                            if s.fill {
                                Path { p in
                                    p.move(to: CGPoint(x: seg.points[0].x, y: h))
                                    for pt in seg.points { p.addLine(to: pt) }
                                    p.addLine(to: CGPoint(x: seg.points[seg.points.count - 1].x, y: h))
                                    p.closeSubpath()
                                }
                                .fill(LinearGradient(
                                    colors: [s.color.opacity(0.30), s.color.opacity(0.015)],
                                    startPoint: .top, endPoint: .bottom))
                            }
                            Path { p in
                                p.addLines(seg.points)
                            }
                            .stroke(s.color, style: StrokeStyle(lineWidth: 1.6,
                                                                lineCap: .round,
                                                                lineJoin: .round))
                        }
                    }
                    if showLatestDot, let last = segments.last?.points.last {
                        Circle().fill(s.color).frame(width: 4.5, height: 4.5)
                            .position(last)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): setChartHover(p, width: w)
                case .ended:         setChartHover(nil, width: w)
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .background(
            GeometryReader { g in
                Color.clear.preference(
                    key: HoverAnchorKey.self,
                    value: ["chart.\(hoverID)": g.frame(in: .named(HoverLayout.space))])
            }
        )
        .onPreferenceChange(HoverAnchorKey.self) { dict in
            if let f = dict["chart.\(hoverID)"], f != rootFrame { rootFrame = f }
        }
    }

    /// nil 值断开线段，绝不把缺失数据当成 0 画出来
    private static func segments(_ values: [Double?], count: Int,
                                 w: CGFloat, h: CGFloat, top: Double) -> [Segment] {
        var result: [Segment] = []
        var current: [CGPoint] = []
        for i in 0..<count {
            let v = i < values.count ? values[i] : nil
            guard let v else {
                if current.count >= 2 { result.append(Segment(points: current)) }
                current = []
                continue
            }
            let x = count > 1 ? w * CGFloat(i) / CGFloat(count - 1) : 0
            let y = h - h * CGFloat(min(1, max(0, v / top)))
            current.append(CGPoint(x: x, y: y))
        }
        if current.count >= 2 { result.append(Segment(points: current)) }
        else if current.count == 1 { result.append(Segment(points: current)) }
        return result
    }
}

// MARK: - 整机性能区（总览页顶部，不自带 ScrollView）

struct MetricsPanel: View {
    @EnvironmentObject private var monitor: Monitor
    @ObservedObject private var cfg = Config.shared

    /// 总览页里与「磁盘 / 服务状态」同屏，用更矮的曲线保证三者一屏放得下
    var compact = false

    private static let cpuColor = Color(red: 0.26, green: 0.55, blue: 0.95)
    private static let downColor = Color(red: 0.16, green: 0.72, blue: 0.68)
    private static let upColor = Color(red: 0.98, green: 0.58, blue: 0.22)
    private static let memColor = Color(red: 0.60, green: 0.45, blue: 0.92)

    private var chartHeight: CGFloat { compact ? 28 : 56 }
    private var gap: CGFloat { compact ? 5 : 9 }

    var body: some View {
        let data = Array(monitor.visibleMetrics.suffix(48))
        let latest = data.last
        let cpuValues: [Double?] = data.map { $0.cpu }
        let rxValues: [Double?] = data.map { $0.rx }
        let txValues: [Double?] = data.map { $0.tx }
        let cpuVals = data.compactMap(\.cpu)
        let memPercents = data.compactMap(\.memPercent)
        let netVals = data.flatMap { [$0.rx, $0.tx] }.compactMap { $0 }
        let netPeak = netVals.max() ?? 0

        return VStack(alignment: .leading, spacing: gap) {
                statusRow(data, latest)

                // CPU 曲线
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("CPU 使用率").font(.system(size: 10, weight: .semibold))
                        Spacer()
                        Text(MetricFormat.cpu(latest?.cpu))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Self.cpuColor)
                        Text("峰值 \(MetricFormat.cpu(cpuVals.max()))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .hoverData(HoverInfo.performance(
                        id: "metric.cpu", title: "CPU 使用率 · 整机",
                        current: MetricFormat.cpu(latest?.cpu),
                        peak: MetricFormat.cpu(cpuVals.max()),
                        average: cpuVals.isEmpty ? "—" : HoverFormat.mean(cpuVals) + "%",
                        source: latest?.cpuSource ?? "",
                        date: latest?.date, count: data.count,
                        note: "CPU 只来自 SSH /proc 或 DSM Utilization 两条整机通道；不是任何单个服务/容器的占用率。"))
                    if cpuVals.isEmpty {
                        chartPlaceholder("等待整机 CPU（SSH / DSM）")
                    } else {
                        LineChart(series: [.init(cpuValues, Self.cpuColor)],
                                  ceiling: 100, height: chartHeight,
                                  samples: data, hoverID: "cpu",
                                  hoverContext: "CPU 使用率 · 采样点")
                    }
                }
                .card(inset: compact ? 7 : 10, verticalInset: compact ? 5 : 10)

                // 内存
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("内存占用").font(.system(size: 10, weight: .semibold))
                        Spacer()
                        Text("\(MetricFormat.bytes(latest?.memUsed)) / \(MetricFormat.bytes(latest?.memTotal))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let p = latest?.memPercent {
                            Text(String(format: "%.0f%%", p))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Self.memColor)
                        }
                    }
                    .hoverData(HoverInfo.performance(
                        id: "metric.mem", title: "内存占用 · 整机",
                        current: "\(MetricFormat.bytes(latest?.memUsed)) / \(MetricFormat.bytes(latest?.memTotal))",
                        peak: memPercents.isEmpty ? "—" : String(format: "%.1f%%", memPercents.max() ?? 0),
                        average: memPercents.isEmpty ? "—" : HoverFormat.mean(memPercents) + "%",
                        source: latest?.cpuSource.isEmpty == false ? (latest?.cpuSource ?? "") : "SSH /proc",
                        date: latest?.date, count: data.count,
                        note: "整机物理内存：已用 / 总量与占用百分比。缺失时显示「—」，不会拿演示数据补真实历史。"))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.16))
                            Capsule().fill(Self.memColor.opacity(0.9))
                                .frame(width: geo.size.width *
                                       CGFloat((latest?.memPercent ?? 0) / 100))
                        }
                    }
                    .frame(height: 5)
                    .hoverData(HoverInfo.sample(
                        latest ?? MetricsSample.empty,
                        id: "metric.mem.bar", context: "内存占用 · 同一采样点"))
                    if latest?.memPercent == nil {
                        Text("整机内存需 SSH / DSM 通道").font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .card(inset: compact ? 7 : 10, verticalInset: compact ? 5 : 10)

                // 网络上下行
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("整机网络上下行").font(.system(size: 10, weight: .semibold))
                        Spacer()
                        HStack(spacing: 8) {
                            Text("↓ \(MetricFormat.rate(latest?.rx))")
                                .foregroundStyle(Self.downColor)
                            Text("↑ \(MetricFormat.rate(latest?.tx))")
                                .foregroundStyle(Self.upColor)
                        }
                        .font(.system(size: 10, design: .monospaced))
                    }
                    .hoverData(HoverInfo.performance(
                        id: "metric.net", title: "整机网络上下行",
                        current: "↓ \(MetricFormat.rate(latest?.rx)) / ↑ \(MetricFormat.rate(latest?.tx))",
                        peak: MetricFormat.rate(netVals.max()),
                        average: MetricFormat.rate(netVals.isEmpty ? nil : netVals.reduce(0, +) / Double(netVals.count)),
                        source: latest?.netSource ?? "",
                        date: latest?.date, count: data.count,
                        note: "只累加整机物理网卡（有 bond 时只取 bond），排除 docker 网桥 / veth / lo；绝不用 qBittorrent 等单服务速率代替。"))
                    if netPeak <= 0 && data.compactMap(\.rx).isEmpty {
                        chartPlaceholder("等待整机网络速率（SSH / DSM）")
                    } else {
                        LineChart(series: [
                            .init(rxValues, Self.downColor, fill: true),
                            .init(txValues, Self.upColor, fill: false),
                        ], ceiling: max(netPeak * 1.18, 64 * 1024), height: chartHeight,
                                 samples: data, hoverID: "net",
                                 hoverContext: "整机网络速率 · 采样点")
                    }
                    HStack(spacing: 10) {
                        legend(Self.downColor, "下行")
                        legend(Self.upColor, "上行")
                        Spacer()
                        if let src = latest?.netSource, !src.isEmpty {
                            Text(src).font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .hoverData(HoverInfo(
                                    "metric.net.source", "网络速率数据源",
                                    subtitle: "整机物理网卡累计",
                                    fields: [
                                        .init("当前来源", src, .accent),
                                        .init("CPU 来源", latest?.cpuSource.isEmpty == false
                                              ? (latest?.cpuSource ?? "—") : "—", .secondary),
                                        .init("磁盘来源", latest?.diskSource.isEmpty == false
                                              ? (latest?.diskSource ?? "—") : "—", .secondary),
                                        .init("采样时间", latest.map { HoverFormat.time($0.date) } ?? "—", .secondary),
                                    ],
                                    note: "来源为空说明该通道本轮不可用，对应数值显示「—」；不会用推算值补位。"))
                        }
                    }
                    .padding(.top, 1)
                }
                .card(inset: compact ? 7 : 10, verticalInset: compact ? 5 : 10)

                if !monitor.metricsNote.isEmpty {
                    Text(monitor.metricsNote)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(2)
    }

    private func statusRow(_ data: [MetricsSample], _ latest: MetricsSample?) -> some View {
        HStack(spacing: 6) {
            if cfg.showDemoMetrics {
                Text("演示数据 · 非真实")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.orange.opacity(0.16)))
            } else {
                Circle().fill(latest?.hasAny == true ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                Text(data.isEmpty ? "整机性能 · 等待首次采样" : "整机性能 · 最近 \(data.count) 个采样点")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .hoverData(HoverInfo(
                        "metric.status", "整机性能采样状态",
                        subtitle: data.isEmpty ? "尚无采样" : "最新 \(HoverFormat.time(latest?.date ?? Date()))",
                        fields: [
                            .init("可见点数", "\(data.count)", .accent),
                            .init("上次落盘", monitor.metricsLast.map(HoverFormat.time) ?? "—", .secondary),
                            .init("采样中", monitor.metricsSampling ? "是" : "否",
                                  monitor.metricsSampling ? .warn : .good),
                            .init("演示数据", cfg.showDemoMetrics ? "开（不写历史）" : "关",
                                  cfg.showDemoMetrics ? .warn : .secondary),
                        ],
                        note: monitor.metricsNote.isEmpty
                            ? "采样与分层探测、磁盘体检共用同一条串行闸门，默认 2 分钟一次；熔断时暂停附加作业。"
                            : monitor.metricsNote))
            }
            Spacer()
            if let d = monitor.metricsLast, !cfg.showDemoMetrics {
                Text(d, style: .time)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if monitor.metricsSampling {
                ProgressView().controlSize(.mini).scaleEffect(0.65)
            }
            Button {
                Task { await monitor.sampleMetrics() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("立即采样")
            .disabled(monitor.metricsSampling)
        }
    }

    private func legend(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(c).frame(width: 8, height: 2.5)
            Text(text).font(.system(size: 8.5)).foregroundStyle(.tertiary)
        }
    }

    private func chartPlaceholder(_ text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.secondary.opacity(0.22),
                              style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            Text(text).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
        .frame(height: chartHeight)
    }
}
