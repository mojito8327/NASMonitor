import Foundation

// MARK: - 数据鲜活度（Stale Indicator）
//
// 背景：阻塞熔断会把探测间隔拉到 ×2 / ×4，并**暂停**性能采样与磁盘体检这两条
// 附加作业。于是面板上的 CPU / 内存 / 网络曲线会长时间停在原地，用户很容易
// 误以为「程序卡死了」。这里给一个温和的黄色说明，把「数据在变旧」解释成
// 「监控正在主动保护 NAS」，而不是让界面沉默。
//
// 关键判据（宁可不报，绝不误报）：
//   1) 只在 `cooling == true`（闸门确实处于熔断退避）时提示；
//   2) 主时钟取「最近一次成功性能采样」；退避暂停的正是这条链，探测本身
//      仍会按拉长后的间隔跑完，所以不能拿探测时间当主时钟；
//   3) 没开性能采样时退回「最近一次有效探测」，阈值随基础间隔一起放大，
//      避免用户把间隔设成 900s 却被 600s 阈值误报；
//   4) 用户暂停 / 电源静默 / 不在内网 / 冷启动 / 尚无历史数据一律抑制；
//   5) 阈值下限 600s（10 分钟），并与实际采样节奏取较大值，防止配置差异误报。
//
// 纯函数、不读 UserDefaults、不读磁盘、不建连接，便于 --freshness-selftest 覆盖。

enum Freshness {

    enum Level: String {
        case fresh       // 数据新鲜，或虽旧但不在退避（不占界面空间）
        case stale       // 退避导致数据变旧，需要温和提示
        case suppressed  // 预期内的不更新，明确抑制
    }

    struct Input {
        var now: Date = Date()
        /// 本进程启动时间，用于冷启动预热抑制
        var startedAt: Date = Date().addingTimeInterval(-3600)
        /// 最近一次写入 history 的有效探测（away / 已取消的轮次不计）
        var lastProbe: Date?
        /// 最近一次成功落地的性能采样
        var lastMetrics: Date?
        var hasMetrics = false
        var metricsEnabled = true
        var metricsInterval: TimeInterval = 120
        var cooling = false
        var multiplier = 1
        /// 未启用性能采样时，探测兜底用的基础间隔
        var baseInterval: TimeInterval = 120
        var paused = false
        var away = false
        var powerGrace = false
        var checking = false
    }

    struct Status: Equatable {
        var level: Level = .fresh
        var title = ""
        var detail = ""
        /// 主时钟的年龄（秒）
        var age: TimeInterval = 0
        /// 本次采用的阈值（秒）
        var threshold: TimeInterval = baseThreshold
        /// 主时钟来源，报告与浮窗共用
        var source = "性能采样"
        var multiplier = 1
        var suppressedReason = ""

        var isStale: Bool { level == .stale }

        /// 排障报告用的一行结论，不含任何凭据
        var reportLine: String {
            let minutes = Int(age / 60)
            switch level {
            case .stale:
                return "**已过期（自动退避）**：\(source) \(minutes) 分钟未更新 · 阈值 \(Int(threshold / 60)) 分钟 · 闸门倍率 ×\(multiplier)"
            case .suppressed:
                return "未提示（\(suppressedReason.isEmpty ? "预期内" : suppressedReason)）· \(source) \(minutes) 分钟前更新 · 闸门倍率 ×\(multiplier)"
            case .fresh:
                return "新鲜：\(source) \(minutes) 分钟前更新 · 阈值 \(Int(threshold / 60)) 分钟 · 闸门倍率 ×\(multiplier)"
            }
        }
    }

    /// 10 分钟：用户能明显察觉「曲线不动了」，又远长于 ×4 下的探测周期。
    static let baseThreshold: TimeInterval = 600
    /// 启动初期不提示，等首轮作业跑完再说
    static let warmup: TimeInterval = 180

    static func evaluate(_ i: Input) -> Status {
        let m = max(1, i.multiplier)
        let useMetrics = i.metricsEnabled && i.hasMetrics && i.lastMetrics != nil
        let source = useMetrics ? "性能采样" : "探测数据"
        let reference = useMetrics ? i.lastMetrics : i.lastProbe
        let age = reference.map { max(0, i.now.timeIntervalSince($0)) } ?? 0
        // 采样节奏本来就很慢时不按 600s 硬判；探测兜底还要把熔断倍率算进去。
        let threshold = useMetrics
            ? max(baseThreshold, i.metricsInterval * 1.2)
            : max(baseThreshold, i.baseInterval * Double(m) * 1.2)

        func base(_ level: Level) -> Status {
            Status(level: level, title: "", detail: "", age: age,
                   threshold: threshold, source: source, multiplier: m)
        }
        func suppressed(_ why: String) -> Status {
            var s = base(.suppressed)
            s.suppressedReason = why
            return s
        }

        // 预期内的不更新，逐一抑制，避免把「用户的主动选择」说成 NAS 故障
        if i.paused { return suppressed("用户已暂停监测") }
        if i.powerGrace { return suppressed("电源操作静默窗口") }
        if i.away { return suppressed("不在内网，已暂停探测") }
        if reference == nil { return suppressed("等待首次检查") }
        if i.now.timeIntervalSince(i.startedAt) < warmup { return suppressed("启动预热") }
        // 不在退避时，数据再旧也不归咎于自动保护（可能只是采样通道故障）
        guard i.cooling else { return base(.fresh) }
        guard age >= threshold else { return base(.fresh) }

        var s = base(.stale)
        s.title = "NAS 响应变慢，监控已进入自动退避状态"
        let minutes = Int(age / 60)
        s.detail = "\(source)已 \(minutes) 分钟未更新（熔断 ×\(m) 暂停了附加采样）；"
            + "这是自动保护而非程序卡死，连续 2 轮无超时后会自动恢复。"
        return s
    }
}
