import Foundation

// MARK: - 探测节流与阻塞熔断
//
// 背景：一轮分层探测最多同时打开 6 个 TCP + 5 个静态 HTTP + 3 个读库 HTTP，
// 性能采样还会再开 SSH / DSM 连接，磁盘体检再开一条 SSH。NAS 处于
// 「端口通、静态页秒回、读库卡死」的半死状态时，这些请求会一直挂到超时；
// 旧的 30 秒节奏 + 三条互不相让的重复定时器，会让未释放的连接层层堆积，
// 反过来把 NAS 的连接表 / 服务线程压死 —— 监控本身成了压垮 NAS 的最后一根稻草。
//
// 现行策略（2026-11-07）：
//   1) 全局闸门：主探测 / 性能采样 / 磁盘体检，任意时刻只允许一个网络作业在跑；
//   2) 一次一定时器：每个作业结束后按「当前倍率」重排下一次，阻塞退避立刻生效，
//      不用等旧周期走完，也不会出现 timer 叠 timer；
//   3) 熔断退避：只认「网络层证据」——≥2 个请求超时，或 ≥1 个读库探针超时，
//      倍率 ×2（上限 ×4，默认 120s → 最长 480s），并暂停附加作业（采样 / 体检）；
//      连续 2 轮干净后回落一级，直到恢复 ×1。
//      注意：Engine 在磁盘 D 状态进程 / 阵列降级时也会把 health 判成 .stalled
//      （为了立即告警），但这不是 TCP 阻塞，不能据此限流，否则一次磁盘告警
//      就会让性能采样被无限期暂停（11-07 真机踩到）；
//   4) 卡死自愈：某个作业占用闸门超过 90s 视为异常，强制释放，避免整条链饿死。
//
// 只管调度与连接预算，不参与健康判定；所有状态用 NSLock 保护，主线程与后台都能查。

enum ProbeJob: String {
    case probe
    case metrics
    case disk

    var label: String {
        switch self {
        case .probe:   return "分层探测"
        case .metrics: return "性能采样"
        case .disk:    return "磁盘体检"
        }
    }
}

final class ProbeGovernor: @unchecked Sendable {
    static let shared = ProbeGovernor()

    private let lock = NSLock()
    private var busy = false
    private var busyJob: ProbeJob?
    private var busySince: Date = .distantPast
    private var blockedRounds = 0
    private var cleanRounds = 0
    private var lastBlockReason = ""
    private var lastChange = Date()

    /// 作业占用闸门超过这个时长视为卡死（最长一轮：DSM 登录 12s + 静态 6s + TCP 3s，留足余量）
    private static let staleAfter: TimeInterval = 90

    private init() {}

    // MARK: - 状态查询

    /// 当前间隔倍率：1 / 2 / 4
    var multiplier: Int {
        lock.lock(); defer { lock.unlock() }
        return 1 << min(blockedRounds, 2)
    }

    /// 是否处于熔断冷却（此时附加作业全部暂停）
    var cooling: Bool { multiplier > 1 }

    var blockReason: String {
        lock.lock(); defer { lock.unlock() }
        return lastBlockReason
    }

    var cleanRoundCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cleanRounds
    }

    /// 给面板状态条用的一句话；正常节奏返回空串，不占界面空间
    var statusText: String {
        let m = multiplier
        guard m > 1 else { return "" }
        return "阻塞熔断 ×\(m) · \(lastBlockReason)"
    }

    /// 下一次作业的延迟。冷却时附加作业也一起拉长，减少空转。
    func delay(for job: ProbeJob, base: Double) -> Double {
        let b: Double
        switch job {
        case .probe:   b = max(30, base)
        case .metrics: b = max(30, base)
        case .disk:    b = max(900, base)
        }
        return max(1, b * Double(multiplier))
    }

    // MARK: - 闸门

    /// 尝试占用闸门。返回 false 表示本次直接跳过（不建任何连接）。
    /// - manual: 用户点「立即检查」，允许绕过冷却，但仍受「同时只有一个作业」约束。
    func begin(_ job: ProbeJob, manual: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy {
            if Date().timeIntervalSince(busySince) > Self.staleAfter {
                busy = false
                busyJob = nil
            } else {
                return false
            }
        }
        // 注意：此处已持有 lock，不能再调用会加锁的 cooling / multiplier，
        // 否则 NSLock（非递归）会自锁死。直接读 blockedRounds。
        if job != .probe && !manual && blockedRounds > 0 { return false }
        busy = true
        busyJob = job
        busySince = Date()
        return true
    }

    /// 释放闸门并（仅主探测）根据结果更新熔断状态。
    func end(_ job: ProbeJob, snapshot: Snapshot? = nil) {
        lock.lock(); defer { lock.unlock() }
        if busyJob == job || busy {
            busy = false
            busyJob = nil
        }
        guard job == .probe, let s = snapshot else { return }

        let timeouts = s.results.filter { $0.timedOut }.count
        let storageTimeouts = s.results.filter { $0.layer == .storage && $0.timedOut }.count
        // 只看网络层证据：health == .stalled 也可能来自磁盘 D 状态 / 阵列降级，
        // 那种情况要照常采样，不能把性能曲线一起冻住。
        let blocked = timeouts >= 2 || storageTimeouts >= 1
        if blocked {
            blockedRounds = min(blockedRounds + 1, 2)
            cleanRounds = 0
            lastBlockReason = storageTimeouts >= 1
                ? "读库阻塞，已停止后续连接"
                : "\(timeouts) 个请求超时"
        } else if timeouts == 0 {
            cleanRounds += 1
            // 连续两轮无超时才回落一级，避免在临界状态反复横跳
            if cleanRounds >= 2, blockedRounds > 0 {
                blockedRounds -= 1
                cleanRounds = 0
            }
        } else {
            cleanRounds = 0
        }
        lastChange = Date()
    }

    /// 上层主动取消某个在飞作业：立即释放它占用的闸门，让新一轮可以开始。
    /// 与 Monitor.cancelInFlight 成对使用，避免「闸门还被已放弃的作业占着」。
    func abandon(_ job: ProbeJob) {
        lock.lock(); defer { lock.unlock() }
        if busyJob == job {
            busy = false
            busyJob = nil
            lastChange = Date()
        }
    }

    /// 用户主动「立即检查」：允许这一次不受冷却限制。
    func forceProbe() {
        lock.lock(); defer { lock.unlock() }
        lastChange = Date()
    }

    /// 设置页关掉「自适应节流」时，立刻清掉熔断状态，回到基础节奏。
    func setEnabled(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !on else { return }
        blockedRounds = 0
        cleanRounds = 0
        lastBlockReason = ""
        lastChange = Date()
    }

    func describe(probe: Double, metrics: Double, disk: Double) -> String {
        lock.lock(); defer { lock.unlock() }
        let m = 1 << min(blockedRounds, 2)
        var lines: [String] = []
        lines.append("当前倍率: ×\(m)  （1 / 2 / 4，阻塞时递增，连续 2 轮干净回落）")
        lines.append("闸门状态: \(busy ? "占用中（\(busyJob?.label ?? "未知作业")，已 \(Int(Date().timeIntervalSince(busySince)))s）" : "空闲")")
        lines.append("熔断原因: \(lastBlockReason.isEmpty ? "无" : lastBlockReason)")
        lines.append("干净轮数: \(cleanRounds) / 2")
        lines.append("基础节奏: 分层探测 \(Int(probe))s · 性能采样 \(Int(metrics))s · 磁盘体检 \(Int(disk))s")
        lines.append("实际节奏: 分层探测 \(Int(probe * Double(m)))s · 附加作业 \(m > 1 ? "暂停" : "正常")")
        lines.append("单轮连接上限: 6 TCP + 5 静态 + 最多 3 读库；静态层大面积超时时立即跳过读库层")
        lines.append("超时处置: dataTask.cancel() 立即释放，直连超时不再补发 curl；全局同时只允许一个网络作业")
        return lines.joined(separator: "\n")
    }
}
