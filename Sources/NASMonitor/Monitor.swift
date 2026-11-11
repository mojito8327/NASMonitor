import Foundation
import SwiftUI
import Combine
import ServiceManagement

@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published private(set) var health: Health = .unknown
    @Published private(set) var latest: Snapshot?
    @Published private(set) var history: [Snapshot] = []
    @Published private(set) var events: [Event] = []
    @Published private(set) var disk: DiskReport?
    @Published private(set) var checking = false
    @Published private(set) var lastCheck: Date?
    @Published var paused = false { didSet { refreshFreshness() } }

    // 数据鲜活度：退避时明确告诉用户「数据在变旧是自动保护」，而不是界面卡死
    @Published private(set) var freshness = Freshness.Status()
    /// 最近一次写入 history 的有效探测（away / 被取消的轮次不算「采到数据」）
    private var lastFreshProbe: Date?
    private let startedAt = Date()
    private var freshnessTimer: Timer?

    // 性能采样（CPU / 内存 / 网络上下行）
    @Published private(set) var metrics: [MetricsSample] = []
    @Published private(set) var metricsNote: String = ""
    @Published private(set) var metricsLast: Date?
    @Published private(set) var metricsSampling = false

    // 探测节流状态（面板状态条 / 设置页可见）
    @Published private(set) var throttleNote = ""
    @Published private(set) var throttleMultiplier = 1

    // 用户主动执行关机 / 重启后的静默窗口：别把预期内的断电报成离线告警
    @Published private(set) var powerNote = ""
    private var powerGraceUntil: Date?

    /// UI 实际展示的序列：开启示例开关时用确定性演示数据，不污染真实历史
    var visibleMetrics: [MetricsSample] {
        cfg.showDemoMetrics ? MetricsSample.demoSeries() : metrics
    }

    private var timer: Timer?
    private var diskTimer: Timer?
    private var metricsTimer: Timer?
    private var candidate: (health: Health, count: Int)?
    private var lastNotifiedDiskWarning = ""
    private let cfg = Config.shared
    private var cancellable: AnyCancellable?
    private let governor = ProbeGovernor.shared

    /// 三条链各自的顶层 Task。cancel() 会经 await 链一路传到 URLSessionTask
    /// 与 Proc.run 的子进程（见 Probes.swift 的 withTaskCancellationHandler）。
    /// token 用于避免「旧任务收尾时误清新任务的登记」。
    private var inFlight: [ProbeJob: (token: UUID, task: Task<Void, Never>)] = [:]

    /// 与 ProbeGovernor.staleAfter 对齐的硬看门狗：超时不只是释放闸门，
    /// 还要真正取消底层连接，杜绝孤儿 ssh / curl 进程。
    private static let jobWatchdog: TimeInterval = 90

    private static let maxHistory = 360
    private static let maxEvents = 200

    private init() {
        loadHistory()
        loadMetrics()
        // 配置变更后重建定时器
        cancellable = cfg.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.reschedule() }
        }
        // 鲜活度是个「随时间流逝」的状态：光靠探测/采样事件刷新不够，
        // 数据停在原地时也必须能自己变黄。30s 一次、只做内存计算，不建连接。
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFreshness() }
        }
        RunLoop.main.add(t, forMode: .common)
        freshnessTimer = t
        refreshFreshness()
    }

    // MARK: - 生命周期

    func start() {
        Notifier.requestAuthorization()
        reschedule()
    }

    /// 纯内存求值：所有抑制条件与阈值都在 Freshness.evaluate 里，可被自检覆盖。
    func refreshFreshness() {
        var i = Freshness.Input()
        i.now = Date()
        i.startedAt = startedAt
        i.lastProbe = lastFreshProbe
        i.lastMetrics = metricsLast
        i.hasMetrics = !metrics.isEmpty
        i.metricsEnabled = cfg.metricsEnabled
        i.metricsInterval = max(30, cfg.metricsInterval)
        i.cooling = cfg.adaptiveThrottle && governor.cooling
        i.multiplier = throttleMultiplier
        i.baseInterval = max(30, cfg.interval)
        i.paused = paused
        i.away = health == .away
        i.powerGrace = (powerGraceUntil ?? .distantPast) > Date()
        i.checking = checking
        let next = Freshness.evaluate(i)
        if next != freshness { freshness = next }
    }

    /// 三条链各用「一次性定时器 + 完成后重排」：任何时刻只有一个网络作业在跑。
    /// 阻塞熔断后下一次立刻按新倍率排，不会像 repeating timer 那样继续按旧周期硬发。
    func reschedule() {
        timer?.invalidate()
        diskTimer?.invalidate()
        metricsTimer?.invalidate()
        governor.setEnabled(cfg.adaptiveThrottle)
        // 启动 / 配置变更后错峰起步，避免三条链同一瞬间抢闸门
        schedule(.probe,   after: 2)
        schedule(.disk,    after: 12)
        schedule(.metrics, after: 25)
        refreshThrottle()
    }

    private func schedule(_ job: ProbeJob, after delay: TimeInterval) {
        let t = Timer.scheduledTimer(withTimeInterval: max(1, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.startJob(job)
            }
        }
        switch job {
        case .probe:   timer = t
        case .metrics: metricsTimer = t
        case .disk:    diskTimer = t
        }
    }

    /// 每条链只有一个可取消的顶层 Task；结构化并发负责把取消信号传到底层。
    private func startJob(_ job: ProbeJob, manual: Bool = false) {
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            if manual { _ = await self.probeCycle(manual: true) }
            else { await self.fire(job) }
            self.clearInFlight(job, token: token)
        }
        inFlight[job] = (token, task)

        // 闸门超时联动：到点先 cancel 顶层 Task，底层 URLSessionTask / Process 会立即终止。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.jobWatchdog * 1_000_000_000))
            guard let self, self.inFlight[job]?.token == token else { return }
            self.inFlight[job]?.task.cancel()
            self.addEvent("\(job.label) 超过 \(Int(Self.jobWatchdog))s 未完成，已取消底层连接",
                          level: .degraded)
        }
    }

    private func clearInFlight(_ job: ProbeJob, token: UUID) {
        if inFlight[job]?.token == token { inFlight.removeValue(forKey: job) }
    }

    /// 用户主动取消某条链（例如点「立即检查」时先撤掉上一轮）。
    func cancelInFlight(_ job: ProbeJob) { inFlight[job]?.task.cancel() }

    private func baseInterval(_ job: ProbeJob) -> Double {
        switch job {
        case .probe:   return max(30, cfg.interval)
        case .metrics: return max(30, cfg.metricsInterval)
        case .disk:    return max(900, cfg.interval * 6)
        }
    }

    private func fire(_ job: ProbeJob) async {
        var executed = true
        defer {
            let base = baseInterval(job)
            // 被闸门拦下（另一作业在跑 / 正在冷却）时短间隔重试，
            // 否则这次采样要白等一整个 120s 周期才补上。
            let next = executed ? governor.delay(for: job, base: base)
                                : min(20, max(5, base / 6))
            schedule(job, after: next)
            refreshThrottle()
        }
        guard !paused else { return }
        // 重启后的静默窗口：跳过自动轮次但仍按正常节奏重排，不占用闸门、不建连接
        if let until = powerGraceUntil {
            if Date() < until { return }
            powerGraceUntil = nil
            powerNote = ""
        }
        switch job {
        case .probe:   executed = await probeCycle()
        case .metrics: executed = await sampleMetrics()
        case .disk:    executed = await runDiskCheck()
        }
    }

    // MARK: - 电源操作联动

    /// 由 ContentView 在「已确认下发」后调用。关机 → 主动暂停，重启 → 静默 10 分钟。
    func notePowerAction(_ action: PowerAction) {
        addEvent("已下发\(action.title)指令（用户主动操作）", level: .degraded)
        switch action {
        case .shutdown:
            paused = true
            powerGraceUntil = nil
            powerNote = "已暂停监测（NAS 关机）· 开机后点「继续」恢复"
        case .reboot:
            powerGraceUntil = Date().addingTimeInterval(600)
            powerNote = "重启后 10 分钟内静默自动探测，避免误报离线"
        }
        refreshFreshness()
    }

    func resumeFromPowerPause() {
        paused = false
        powerGraceUntil = nil
        powerNote = ""
        refreshFreshness()
    }

    private func refreshThrottle() {
        governor.setEnabled(cfg.adaptiveThrottle)
        throttleNote = cfg.adaptiveThrottle ? governor.statusText : ""
        throttleMultiplier = cfg.adaptiveThrottle ? governor.multiplier : 1
        refreshFreshness()
    }

    // MARK: - 主循环

    /// 面板「立即检查」入口：用户主动触发，允许绕过冷却，但仍受串行闸门约束。
    func checkNow() {
        governor.forceProbe()
        // 用户主动刷新：先释放并取消上一轮仍在飞的连接，避免两轮探测叠加
        // 把半死 NAS 的连接表继续堆满。旧轮次被取消后不会写状态、不参与熔断统计。
        governor.abandon(.probe)
        cancelInFlight(.probe)
        startJob(.probe, manual: true)
    }

    private func probeCycle(manual: Bool = false) async -> Bool {
        guard governor.begin(.probe, manual: manual) else { return false }
        checking = true
        defer { checking = false }

        let runCfg = RunConfig(cfg)
        let onlyLAN = cfg.onlyLAN
        let prefix = cfg.lanPrefix
        let confirmations = max(1, cfg.confirmations)
        let diskSnapshot = disk
        let adaptive = cfg.adaptiveThrottle

        if onlyLAN && !LANCheck.isOnSameLAN(as: runCfg.host, prefix: prefix) {
            let away = Snapshot(health: .away,
                                summary: "本机不在 \(prefix)x 网段，已暂停监测",
                                results: [])
            apply(away, confirmations: confirmations)
            governor.end(.probe, snapshot: nil)
            refreshThrottle()
            return true
        }
        // Engine.run 是 async 且非 actor 隔离：直接 await 会离开主线程在协作线程池执行，
        // 不需要 Task.detached。取消信号沿 await 链传到 URLSessionTask / ssh 子进程。
        let snapshot = await Engine.run(runCfg, disk: diskSnapshot)

        // 被取消的轮次结果全是「连接已放弃」，绝不能写成一次离线/降级告警，
        // 也不能拿去更新熔断计数；闸门已由 governor.abandon 提前释放。
        guard !Task.isCancelled else { return true }

        apply(snapshot, confirmations: confirmations)
        governor.end(.probe, snapshot: adaptive ? snapshot : nil)
        refreshThrottle()
        return true
    }

    private func apply(_ s: Snapshot, confirmations: Int) {
        lastCheck = Date()
        // away 是「不在内网、主动静默」，不是一次真实采样；被 Task 取消的轮次
        // 根本不会走到这里（probeCycle 在 apply 前就 guard !Task.isCancelled）。
        if s.health != .away { lastFreshProbe = lastCheck }
        latest = s
        history.append(s)
        if history.count > Self.maxHistory { history.removeFirst(history.count - Self.maxHistory) }
        saveHistory()

        // 连续 N 轮一致才切换状态，避免单次网络抖动造成误报
        if var c = candidate, c.health == s.health {
            c.count += 1
            candidate = c
        } else {
            candidate = (s.health, 1)
        }
        guard let c = candidate else { return }

        if c.health == health { return }
        // 「不在内网」立即生效；异常状态也要尽快生效；恢复在线需满足确认次数
        let immediate = c.health == .away || (c.health == .stalled && c.count >= min(1, confirmations))
        guard c.count >= confirmations || immediate else { return }

        let previous = health
        health = c.health
        candidate = nil

        if previous != .unknown {
            let text: String
            let level = c.health
            if c.health == .online {
                text = "已恢复：\(s.summary)"
            } else if c.health == .away {
                text = "已暂停：不在内网"
            } else {
                text = "\(c.health.title)：\(s.summary)"
            }
            addEvent(text, level: level)

            if c.health != .away && previous != .away {
                let title = c.health == .online ? "NAS 已恢复正常" : "NAS 状态告警 · \(c.health.title)"
                var body = s.summary
                if c.health == .stalled {
                    body += "。请先核对日志页的读库超时数量、内核 ATA / CRC 与阵列状态；背板与 SATA 线已于 11-07 整体更换，勿据此直接断电重启。"
                }
                Notifier.send(title: title, body: body,
                              playSound: cfg.soundEnabled && c.health != .online,
                              notifyEnabled: cfg.notifyEnabled)
            }
        } else {
            addEvent("首次检查：\(c.health.title) · \(s.summary)", level: c.health)
        }
    }

    private func addEvent(_ text: String, level: Health) {
        events.insert(Event(text: text, level: level), at: 0)
        if events.count > Self.maxEvents { events = Array(events.prefix(Self.maxEvents)) }
    }

    // MARK: - 磁盘体检

    @discardableResult
    func runDiskCheck() async -> Bool {
        guard cfg.diskCheckEnabled, cfg.sshEnabled, !paused else { return true }
        guard governor.begin(.disk) else { return false }
        defer { governor.end(.disk) }
        let runCfg = RunConfig(cfg)
        let useSudo = cfg.useSudo
        let pw = CredentialStore.get(CredentialStore.Key.sudoPassword)
        let onlyLAN = cfg.onlyLAN
        let prefix = cfg.lanPrefix
        guard !onlyLAN || LANCheck.isOnSameLAN(as: runCfg.host, prefix: prefix) else { return true }

        let report = await Engine.diskCheck(runCfg, useSudo: useSudo, sudoPassword: pw)
        guard !Task.isCancelled else { return true }
        let previous = disk
        disk = report

        // 同一次只读体检带回主机清单：卷 / 阵列 / 物理盘与服务监听端口。
        // 只在 SSH 确实拿到有效数据时比较，避免 SSH 失败把「无数据」误记成「拔掉了所有盘」。
        if report.reachable && !report.volumes.isEmpty {
            if let p = previous {
                let oldV = Set(p.volumes.map(\.mount)), newV = Set(report.volumes.map(\.mount))
                let oldA = Set(p.arrays.map(\.name)), newA = Set(report.arrays.map(\.name))
                let oldD = Set(p.physicalDisks.map(\.name)), newD = Set(report.physicalDisks.map(\.name))
                var changes: [String] = []
                let addV = newV.subtracting(oldV).sorted(), delV = oldV.subtracting(newV).sorted()
                let addA = newA.subtracting(oldA).sorted(), delA = oldA.subtracting(newA).sorted()
                let addD = newD.subtracting(oldD).sorted(), delD = oldD.subtracting(newD).sorted()
                if !addV.isEmpty { changes.append("新增卷 \(addV.joined(separator: "、"))") }
                if !delV.isEmpty { changes.append("移除卷 \(delV.joined(separator: "、"))") }
                if !addA.isEmpty { changes.append("新增阵列 \(addA.joined(separator: "、"))") }
                if !delA.isEmpty { changes.append("移除阵列 \(delA.joined(separator: "、"))") }
                if !addD.isEmpty { changes.append("新增物理盘 \(addD.joined(separator: "、"))") }
                if !delD.isEmpty { changes.append("移除物理盘 \(delD.joined(separator: "、"))") }
                if !changes.isEmpty { addEvent("磁盘清单变化：\(changes.joined(separator: " · "))", level: .online) }
            }
            if let note = ServiceCatalog.shared.apply(observed: report.listeningPorts,
                                                      reachable: report.reachable) {
                addEvent("服务清单变化：\(note)", level: .online)
            }
        }
        if report.hasWarning {
            let w = report.warningText
            if w != lastNotifiedDiskWarning {
                lastNotifiedDiskWarning = w
                addEvent("磁盘预警：\(w)", level: .degraded)
                if report.arrays.contains(where: { !$0.healthy }) || report.dStateCount > 0 {
                    Notifier.send(title: "NAS 磁盘预警", body: w,
                                  playSound: cfg.soundEnabled, notifyEnabled: cfg.notifyEnabled)
                }
            }
        } else {
            lastNotifiedDiskWarning = ""
        }
        return true
    }

    // MARK: - 性能采样

    @discardableResult
    func sampleMetrics() async -> Bool {
        guard cfg.metricsEnabled, !paused, !metricsSampling else { return true }
        guard !cfg.onlyLAN || LANCheck.isOnSameLAN(as: cfg.effectiveHost, prefix: cfg.lanPrefix) else { return true }
        guard governor.begin(.metrics) else { return false }
        defer { governor.end(.metrics) }
        metricsSampling = true
        defer { metricsSampling = false }
        let c = MetricsConfig(cfg)
        let sample = await MetricsCollector.collect(c)
        guard !Task.isCancelled else { return true }

        metrics.append(sample)
        if metrics.count > 240 { metrics.removeFirst(metrics.count - 240) }
        metricsNote = sample.note
        metricsLast = sample.date
        saveMetrics()
        refreshFreshness()
        return true
    }

    private var metricsURL: URL {
        MetricsCollector.storeDir().appendingPathComponent("metrics.json")
    }

    private func saveMetrics() {
        let slim = Array(metrics.suffix(240))
        guard let data = try? JSONEncoder().encode(slim) else { return }
        _ = AtomicFileWriter.write(data, to: metricsURL)
    }

    private func loadMetrics() {
        guard let data = try? Data(contentsOf: metricsURL),
              let arr = try? JSONDecoder().decode([MetricsSample].self, from: data) else { return }
        metrics = arr
        metricsNote = arr.last?.note ?? ""
        metricsLast = arr.last?.date
    }

    func clearMetrics() {
        metrics = []
        metricsNote = ""
        metricsLast = nil
        saveMetrics()
        refreshFreshness()
    }

    // MARK: - 历史持久化

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NASMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private func saveHistory() {
        let slim = Array(history.suffix(120))
        guard let data = try? JSONEncoder().encode(slim) else { return }
        _ = AtomicFileWriter.write(data, to: storeURL)
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: storeURL),
              let arr = try? JSONDecoder().decode([Snapshot].self, from: data) else { return }
        // 旧版写进 history.json 的「0 个读库请求超时 —— 典型存储层阻塞」不会随代码
        // 修复自动消失。启动时按每条 results 纠正；下一轮 saveHistory() 会把纠正结果
        // 自然写回。纯内存、幂等，不改动 health / results / date / id。
        let (fixed, _) = Engine.normalizeLegacySummaries(arr)
        history = fixed
    }

    func clearHistory() {
        history = []
        events = []
        saveHistory()
        clearMetrics()
    }

    // MARK: - 离屏预览数据（仅 --render 使用）

    func installPreviewData(simulateDiskStall: Bool = false, simulateStale: Bool = false,
                            simulateExtraDisks: Bool = false,
                            simulateDiscovery: Bool = false) {
        // 预览也按服务目录动态造探针。--simulate-new-service 注入一个自动发现的新服务，
        // 用来验收面板行数随服务增减而变化；只改内存，绝不写 UserDefaults。
        var specs = ServiceCatalog.shared.snapshot
        if simulateDiscovery {
            specs.append(.init(key: "port9443", name: "Portainer TLS", port: 9443,
                               critical: false, origin: .discovered))
        }
        ServiceCatalog.shared.installPreview(
            services: specs,
            discovered: simulateDiscovery ? [32400, 9696] : [],
            missing: simulateDiscovery ? ["mihomo"] : [])

        var d = DiskReport()
        d.reachable = true
        d.uptime = "1 天 3 小时"
        // 默认对齐真实环境的三阵列 / 三卷 / 三块物理盘（含新插入的 sdc → /volume1）。
        // --simulate-extra-disks 再插两块盘，验收数量变化时界面不越界、不裁切。
        d.arrays = [.init(name: "md3", healthy: true, detail: ""),
                    .init(name: "md4", healthy: true, detail: ""),
                    .init(name: "md6", healthy: true, detail: "")]
        d.volumes = [
            .init(mount: "/volume1", total: "2.6 T", used: "2.0 T", free: "0.6 T", percent: 76),
            .init(mount: "/volume2", total: "3.5 T", used: "90 G", free: "3.4 T", percent: 3),
            .init(mount: "/volume3", total: "10.5 T", used: "2.9 T", free: "7.5 T", percent: 29),
        ]
        d.physicalDisks = [
            .init(name: "sdc", size: "3.0 T", model: "DT01ACA300"),
            .init(name: "sdd", size: "4.0 T", model: "DT02ABA400"),
            .init(name: "sde", size: "12.0 T", model: "HUH721212ALE601"),
        ]
        d.listeningPorts = [22, 80, 139, 443, 445, 5000, 5001, 5357, 7890,
                            8000, 8080, 8091, 8096, 9090, 51413]
        if simulateExtraDisks {
            d.arrays.append(.init(name: "md7", healthy: true, detail: ""))
            d.volumes.append(contentsOf: [
                .init(mount: "/volume4", total: "8.0 T", used: "1.1 T", free: "6.9 T", percent: 14),
                .init(mount: "/volumeUSB1", total: "1.8 T", used: "0.4 T", free: "1.4 T", percent: 22),
            ])
            d.physicalDisks.append(contentsOf: [
                .init(name: "nvme0n1", size: "1.0 T", model: "SN850X"),
                .init(name: "sdf", size: "8.0 T", model: "ST8000VN004"),
            ])
        }
        // 仅离屏预览：让日志页的 SATA / I/O 告警区有内容可验收，不写入真实历史
        d.sataErrors = [
            "[Mon Nov  6 03:14:22 2026] ata3: SError: { PHYRdyChg CommWake }",
            "[Mon Nov  6 03:14:22 2026] ata3.00: failed command: WRITE DMA EXT",
        ]
        d.rawHint = "预览数据"

        var r: [ProbeResult] = []
        for svc in specs {
            r.append(.init(id: "tcp.\(svc.key)", name: svc.name, layer: .tcp,
                           ok: true, detail: ":\(svc.port) 可连接", ms: 70))
        }
        let keys = Set(specs.map(\.key))
        if keys.contains("dsm") {
            r.append(.init(id: "stat.dsm-icon", name: "DSM Static", layer: .stat,
                           ok: true, detail: "HTTP 404 · 期望 404", ms: 12))
            r.append(.init(id: "stat.dsm-cgi", name: "DSM CGI", layer: .stat,
                           ok: true, detail: "HTTP 200 · 期望 code 119", ms: 41))
        }
        if keys.contains("amane") {
            r.append(.init(id: "stat.amane", name: "Amane Health", layer: .stat,
                           ok: true, detail: "HTTP 200 · 期望 200", ms: 15))
        }
        if keys.contains("jf") {
            r.append(.init(id: "stat.jf", name: "Jellyfin Public", layer: .stat,
                           ok: true, detail: "HTTP 200 · 期望 200", ms: 33))
        }
        if keys.contains("qb") {
            r.append(.init(id: "stat.qb", name: "qBittorrent API", layer: .stat,
                           ok: true, detail: "HTTP 403 · 期望 200/403", ms: 39))
        }
        if keys.contains("jf") {
            r.append(.init(id: "sto.jf", name: "Jellyfin Auth", layer: .storage,
                           ok: true, detail: "HTTP 401 · 用户库可读", ms: 24))
        }
        if keys.contains("amane") {
            r.append(.init(id: "sto.amane", name: "Amane DB", layer: .storage,
                           ok: true, detail: "HTTP 200 · 数据库可读", ms: 13))
        }
        if keys.contains("dsm") {
            r.append(.init(id: "sto.dsm", name: "DSM Auth", layer: .storage,
                           ok: true, detail: "code 400 · 认证库可读", ms: 5300))
        }
        r.append(.init(id: "disk", name: "Disk / RAID", layer: .disk, ok: true,
                       detail: "\(d.arrays.count) 个阵列正常 · \(d.volumes.count) 个卷", ms: -1))

        let criticalCount = specs.filter(\.critical).count
        let staticCount = r.filter { $0.layer == .stat }.count
        let storageCount = r.filter { $0.layer == .storage }.count
        let summary = "\(criticalCount)/\(criticalCount) 关键端口 · \(staticCount) 项静态服务"
            + " · \(storageCount) 项读库探针全部正常"
        let good = Snapshot(health: .online, summary: summary, results: r)
        var h: [Snapshot] = []
        for i in 0..<42 {
            let st: Health = (i % 17 == 5) ? .degraded : ((i % 23 == 9) ? .stalled : .online)
            h.append(Snapshot(health: st, summary: good.summary, results: r))
        }
        h.append(good)

        health = .online
        latest = good
        history = h
        disk = d
        lastCheck = Date()
        checking = false
        events = [
            Event(text: "首次检查：一切正常 · \(summary)", level: .online),
            Event(text: "磁盘预警：2 条 SATA 链路错误", level: .degraded),
            Event(text: "存储层阻塞：TCP 端口正常、静态页秒回，但 2 个读库请求超时", level: .stalled),
        ]

        metrics = MetricsSample.demoSeries()
        metricsNote = "示例数据，非真实监测结果"
        metricsLast = Date()
        metricsSampling = false

        // 仅离屏预览：复现「磁盘 D 状态快照 + 读库全绿」被判 .stalled 的场景，
        // 用来验收状态提示条不再误写成「读库请求卡住 / 需物理断电」。
        if simulateDiskStall {
            var dr = d
            dr.dStateCount = 2
            var rr = r
            if let i = rr.firstIndex(where: { $0.id == "disk" }) {
                rr[i] = .init(id: "disk", name: "Disk / RAID", layer: .disk,
                              ok: false, detail: "2 个进程卡在 I/O", ms: -1)
            }
            let stalled = Snapshot(
                health: .stalled,
                summary: Engine.stalledSummary(storageTimeouts: 0, storageCount: 3,
                                               disk: dr, diskCritical: true),
                results: rr)
            health = .stalled
            latest = stalled
            if !history.isEmpty { history[history.count - 1] = stalled }
            disk = dr
            // 演示事件也跟上场景，避免预览里出现「读库超时」与「读库全绿」自相矛盾
            events = [
                Event(text: "首次检查：一切正常 · \(summary)", level: .online),
                Event(text: "磁盘预警：2 条 SATA 链路错误", level: .degraded),
                Event(text: "磁盘体检：2 个进程卡在 I/O（读库探针本轮全部正常）", level: .stalled),
            ]
        }

        // 离屏预览不跑定时器，直接注入一份鲜活度结果。
        // startedAt 必须伪装成「已运行 1 小时」，否则冷启动预热会把演示的 stale 抑制掉。
        lastFreshProbe = lastCheck
        var fi = Freshness.Input()
        fi.startedAt = Date().addingTimeInterval(-3600)
        fi.lastProbe = lastFreshProbe
        fi.lastMetrics = metricsLast
        fi.hasMetrics = !metrics.isEmpty
        fi.metricsEnabled = cfg.metricsEnabled
        fi.metricsInterval = max(30, cfg.metricsInterval)
        fi.baseInterval = max(30, cfg.interval)
        if simulateStale {
            // 所有演示时间都以同一个基准钟为准，否则两次 Date() 的几毫秒差
            // 会把「15 分钟」显示成「14 分钟」。
            let clock = Date()
            fi.now = clock
            lastFreshProbe = clock.addingTimeInterval(-12 * 60)
            metricsLast = clock.addingTimeInterval(-15 * 60)
            fi.lastProbe = lastFreshProbe
            fi.lastMetrics = metricsLast
            fi.cooling = true
            fi.multiplier = 4
            throttleMultiplier = 4
            throttleNote = "阻塞熔断 ×4 · 读库阻塞，已停止后续连接"
        }
        freshness = Freshness.evaluate(fi)
    }

    /// 仅 --render --real-data 使用：用磁盘上的真实性能历史覆盖预览示例数据。
    func installRealMetrics() { loadMetrics() }

    // MARK: - 开机自启

    func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}
