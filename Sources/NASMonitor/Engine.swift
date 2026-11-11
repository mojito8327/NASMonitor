import Foundation

/// 一次探测所需的配置快照（值拷贝，避免跨线程读 ObservableObject）
struct RunConfig {
    let host: String
    let timeout: Double
    let sshEnabled: Bool
    let sshUser: String
    let useAmaneToken: Bool
    let amaneToken: String
    let useJellyfinToken: Bool
    let jellyfinToken: String
    /// 本轮要探测的服务快照：来自可持久化的 ServiceCatalog，增删服务后下一轮立即生效。
    let services: [ServiceSpec]

    init(_ c: Config) {
        host = c.effectiveHost
        timeout = max(2, min(30, c.timeout))
        sshEnabled = c.sshEnabled
        sshUser = c.sshUser
        useAmaneToken = c.useAmaneToken
        amaneToken = CredentialStore.get(CredentialStore.Key.amaneToken)
        useJellyfinToken = c.useJellyfinToken
        jellyfinToken = CredentialStore.get(CredentialStore.Key.jellyfinToken)
        services = ServiceCatalog.shared.snapshot
    }

    var base: String { "http://\(host)" }

    /// 内置深度探针按 key 找端口：服务被删掉或端口被改，探针自动跟着变。
    func port(of key: String) -> UInt16? {
        services.first { $0.key == key }?.port
    }
}

enum Engine {

    static let jellyfinAuthHeader =
        "MediaBrowser Client=\"NASMonitor\", Device=\"Mac\", DeviceId=\"nasmon-mac\", Version=\"1.0.0\""

    /// 纯函数：按「本轮真实证据」生成 .stalled 的摘要，便于自检回归。
    ///
    /// .stalled 有两个完全不同的来源：
    ///   1) L3 读库探针真的超时（11-06 掉盘事故的特征，需要冷启动）；
    ///   2) L4 磁盘体检某次快照看到 D 状态进程 / 阵列降级，而读库其实全绿。
    /// 早期版本无论哪种都写「N 个读库请求超时 —— 典型存储层阻塞」，
    /// 于是出现「0 个读库请求超时 —— 典型存储层阻塞」这种自相矛盾的提示，
    /// 还会把用户误导去物理断电。这里严格按证据分流。
    static func stalledSummary(storageTimeouts: Int,
                               storageCount: Int,
                               disk: DiskReport?,
                               diskCritical: Bool) -> String {
        let needStall = min(2, max(1, storageCount))
        var parts: [String] = []
        if storageTimeouts >= needStall {
            parts.append("TCP 端口正常、静态页秒回，但 \(storageTimeouts) 个读库请求超时 —— 典型存储层阻塞")
        } else if storageTimeouts > 0 {
            parts.append("\(storageTimeouts) 个读库请求超时")
        } else {
            parts.append("读库探针全部正常（本轮 0 个读库超时）")
        }
        if diskCritical, let d = disk {
            let bad = d.arrays.filter { !$0.healthy }.map { $0.name }
            if !bad.isEmpty {
                parts.append("磁盘体检发现阵列降级（\(bad.joined(separator: "、"))）")
            } else if d.dStateCount > 0 {
                parts.append("磁盘体检发现 \(d.dStateCount) 个进程持续卡在 I/O（连续 3 次快照）")
            } else {
                parts.append("磁盘体检发现 I/O 异常")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 历史数据迁移（旧版自相矛盾文案）

    /// 纯函数：按**一条快照自己的 results** 生成 .stalled 摘要。
    /// 与 `stalledSummary(storageTimeouts:...)` 的前缀口径保持一致，磁盘部分直接用
    /// 历史里已经落盘的 probe detail，不再需要 DiskReport（历史文件里没有它）。
    static func stalledSummary(from results: [ProbeResult]) -> String {
        let storage = results.filter { $0.layer == .storage }
        let timeouts = storage.filter { $0.timedOut }.count
        let needStall = min(2, max(1, storage.count))
        var parts: [String] = []
        if timeouts >= needStall {
            parts.append("TCP 端口正常、静态页秒回，但 \(timeouts) 个读库请求超时 —— 典型存储层阻塞")
        } else if timeouts > 0 {
            parts.append("\(timeouts) 个读库请求超时")
        } else {
            parts.append("读库探针全部正常（本轮 0 个读库超时）")
        }
        let diskBad = results.filter { $0.layer == .disk && !$0.ok }
        if !diskBad.isEmpty {
            parts.append("磁盘体检发现 " + diskBad.map { $0.detail }.joined(separator: " · "))
        }
        return parts.joined(separator: " · ")
    }

    /// 只纠正「读库 0 超时却写典型存储层阻塞」的旧快照，其余一律原样保留。
    /// health / results / date / id 全部不动；真的有读库超时的历史证据绝不改写。
    static func normalizeLegacySummary(_ s: Snapshot) -> Snapshot? {
        guard s.health == .stalled,
              s.summary.contains("典型存储层阻塞") else { return nil }
        let storage = s.results.filter { $0.layer == .storage }
        guard storage.filter({ $0.timedOut }).isEmpty else { return nil }
        var out = s
        out.summary = stalledSummary(from: s.results)
        return out
    }

    /// 返回纠正后的数组与改动条数；幂等，重复调用不会二次改写。
    static func normalizeLegacySummaries(_ arr: [Snapshot]) -> ([Snapshot], Int) {
        var out = arr
        var n = 0
        for i in out.indices {
            if let fixed = normalizeLegacySummary(out[i]) { out[i] = fixed; n += 1 }
        }
        return (out, n)
    }

    private struct TCPOutcome: @unchecked Sendable {
        let key: String
        let ok: Bool
        let result: ProbeResult
    }

    private struct StaticSpec: Sendable {
        let id: String, name: String, key: String, path: String, expect: String
    }

    /// 完整的一轮分层探测（Swift Concurrency 结构化并发）。
    ///
    /// 每层用 withTaskGroup：子任务只负责发起单个请求并返回 ProbeResult，
    /// `for await` 在**调用方 task** 里串行收集，所以不再需要 DispatchGroup、
    /// NSLock 或任何共享可变缓冲。上层 Task 被取消 / group 退出时，未完成的
    /// 子任务会被自动取消，取消信号一路传到 URLSessionTask 与 Proc.run 的子进程。
    static func run(_ cfg: RunConfig, disk: DiskReport? = nil) async -> Snapshot {
        var results: [ProbeResult] = []

        // ---------- L1：TCP 端口 ----------
        var tcpOK: [String: Bool] = [:]
        await withTaskGroup(of: TCPOutcome.self) { group in
            // 服务列表来自 ServiceCatalog：新增服务自动获得 tcp.<key> 探针，
            // 删除服务后本轮不再为它发包，面板也同步少一行。
            for svc in cfg.services {
                group.addTask {
                    let timeout = min(cfg.timeout, 3)
                    let (ok, ms) = await Net.tcp(host: cfg.host, port: svc.port, timeout: timeout)
                    let r = ProbeResult(id: "tcp.\(svc.key)", name: svc.name, layer: .tcp,
                                        ok: ok,
                                        detail: ok ? ":\(svc.port) 可连接" : ":\(svc.port) 无响应",
                                        ms: ms, timedOut: !ok && ms >= Int(timeout * 1000) - 60)
                    return TCPOutcome(key: svc.key, ok: ok, result: r)
                }
            }
            for await o in group {
                tcpOK[o.key] = o.ok
                results.append(o.result)
            }
        }

        let critical = Services.critical(cfg.services)
        let criticalTotal = critical.count
        let criticalAlive = critical.filter { tcpOK[$0.key] == true }.count

        if criticalAlive == 0 {
            let summary = "所有关键端口均无响应（\(criticalTotal) 个）"
            return Snapshot(health: .offline, summary: summary, results: sorted(results))
        }

        // 连握手都大面积挂住时，继续发 HTTP 只会继续堆 TCP 连接。
        // 立即收手，交给 Monitor 的熔断退避拉长下一轮。
        let tcpTimeouts = results.filter { $0.layer == .tcp && $0.timedOut }.count
        if tcpTimeouts >= 4 {
            return Snapshot(health: .degraded,
                            summary: "\(tcpTimeouts) 个端口握手超时 —— 已停止本轮 HTTP 探测，避免继续堆积 TCP 连接",
                            results: sorted(results))
        }

        // ---------- L2：静态 / 免认证路径 ----------
        // 这些请求只读系统分区或内存，存储挂起时依然秒回 —— 是判别「网络活着」的基准线。
        // 深度静态探针按服务目录里的实际端口拼 URL：删掉 DSM/Jellyfin 之类服务后，
        // 对应探针不再生成；用户改了端口也会自动跟着走，不会继续打旧端口。
        var staticSpecs: [StaticSpec] = []
        if let p = cfg.port(of: "dsm") {
            staticSpecs.append(.init(id: "stat.dsm-icon", name: "DSM Static", key: "dsm",
                                     path: "\(cfg.base):\(p)/favicon.ico", expect: "404"))
            staticSpecs.append(.init(id: "stat.dsm-cgi", name: "DSM CGI", key: "dsm",
                                     path: "\(cfg.base):\(p)/webapi/entry.cgi?api=SYNO.Core.System&version=1&method=info",
                                     expect: "code 119"))
        }
        if let p = cfg.port(of: "amane") {
            staticSpecs.append(.init(id: "stat.amane", name: "Amane Health", key: "amane",
                                     path: "\(cfg.base):\(p)/api/health", expect: "200"))
        }
        if let p = cfg.port(of: "jf") {
            staticSpecs.append(.init(id: "stat.jf", name: "Jellyfin Public", key: "jf",
                                     path: "\(cfg.base):\(p)/System/Info/Public", expect: "200"))
        }
        if let p = cfg.port(of: "qb") {
            staticSpecs.append(.init(id: "stat.qb", name: "qBittorrent API", key: "qb",
                                     path: "\(cfg.base):\(p)/api/v2/app/version", expect: "200/403"))
        }

        await withTaskGroup(of: ProbeResult.self) { group in
            for spec in staticSpecs where tcpOK[spec.key] == true {
                group.addTask {
                    let r = await HTTP.request(spec.path, timeout: cfg.timeout)
                    // 只要拿到 HTTP 响应就算通道正常，状态码仅作记录
                    let ok = !r.timedOut && !r.connectionFailed && r.status > 0
                    return ProbeResult(id: spec.id, name: spec.name, layer: .stat, ok: ok,
                                       detail: ok ? "HTTP \(r.status) · 期望 \(spec.expect)"
                                                 : (r.timedOut ? "无响应（超时）" : "连接失败"),
                                       ms: r.ms, timedOut: r.timedOut)
                }
            }
            for await r in group { results.append(r) }
        }

        // ---------- L3：存储层探针（分阶段，阻塞即停） ----------
        // 关键设计：用「必然失败的凭据」触发一次需要读用户库 / 数据卷的请求。
        // 存储正常 → 秒回 401/400；存储挂起 → 请求卡死超时。全程零配置、不触碰真实账号。
        //
        // 及时停止：先并行发 2 个轻量读库探针。只有它们没有同时超时，才再发 DSM 登录
        // 那个最长 12s 的重请求；静态层已大面积超时时整个 L3 直接跳过。NAS 半死时
        // 继续往堵住的连接表里塞新请求只会加重阻塞。
        var storage: [ProbeResult] = []
        var stoppedReason = ""
        func skipped(_ id: String, _ name: String, _ reason: String) -> ProbeResult {
            ProbeResult(id: id, name: name, layer: .storage, ok: false,
                        detail: "已跳过（\(reason)）", ms: -1)
        }

        // 三个读库探针也跟着服务目录走：删掉服务就不再生成它的探针与「已跳过」占位行。
        let jfPort = cfg.port(of: "jf")
        let amanePort = cfg.port(of: "amane")
        let dsmPort = cfg.port(of: "dsm")
        let storageSpecs: [(String, String)] = [
            jfPort.map { _ in ("sto.jf", "Jellyfin Auth") },
            amanePort.map { _ in ("sto.amane", "Amane DB") },
            dsmPort.map { _ in ("sto.dsm", "DSM Auth") },
        ].compactMap { $0 }

        let staticEarly = results.filter { $0.layer == .stat }
        let staticTimeoutsEarly = staticEarly.filter { $0.timedOut }.count
        let hasStaticProbes = !staticSpecs.isEmpty
        let skipAllStorage = staticTimeoutsEarly >= 2
            || (hasStaticProbes && staticEarly.filter { $0.ok }.isEmpty)

        if skipAllStorage {
            stoppedReason = staticTimeoutsEarly >= 2
                ? "静态层 \(staticTimeoutsEarly) 个请求超时"
                : (hasStaticProbes ? "静态层全部不可用" : "未配置深度静态探针")
            for (id, name) in storageSpecs { storage.append(skipped(id, name, stoppedReason)) }
        } else {
            // 阶段 A：Jellyfin 认证（主力探针，正常约 0.9s）+ Amane 任务列表
            await withTaskGroup(of: ProbeResult.self) { group in
                if let jfPort, tcpOK["jf"] == true {
                    group.addTask {
                        let body = "{\"Username\":\"__nasmon_probe__\",\"Pw\":\"__invalid__\"}"
                        let r = await HTTP.request("\(cfg.base):\(jfPort)/Users/AuthenticateByName",
                                                   method: "POST",
                                                   headers: ["Content-Type": "application/json",
                                                             "Authorization": jellyfinAuthHeader],
                                                   body: body.data(using: .utf8),
                                                   timeout: cfg.timeout)
                        let ok = !r.timedOut && r.status >= 400 && r.status < 500
                        return ProbeResult(id: "sto.jf", name: "Jellyfin Auth", layer: .storage,
                                           ok: ok,
                                           detail: r.timedOut ? "读库超时（认证请求无返回）"
                                                             : "HTTP \(r.status) · 用户库可读",
                                           ms: r.ms, timedOut: r.timedOut)
                    }
                }
                if let amanePort, tcpOK["amane"] == true {
                    group.addTask {
                        var headers: [String: String] = [:]
                        if cfg.useAmaneToken && !cfg.amaneToken.isEmpty {
                            headers["Authorization"] = "Bearer \(cfg.amaneToken)"
                        }
                        let r = await HTTP.request("\(cfg.base):\(amanePort)/api/tasks?limit=1",
                                                   headers: headers, timeout: cfg.timeout)
                        let authenticated = cfg.useAmaneToken && !cfg.amaneToken.isEmpty
                        let ok: Bool
                        let detail: String
                        if r.timedOut {
                            ok = false; detail = "读库超时"
                        } else if authenticated {
                            ok = r.status == 200
                            detail = ok ? "HTTP 200 · 数据库可读" : "HTTP \(r.status) · Token 可能失效"
                        } else {
                            ok = r.status == 401 || r.status == 403
                            detail = "HTTP \(r.status) · 仅通道探测"
                        }
                        return ProbeResult(id: "sto.amane", name: "Amane DB", layer: .storage,
                                           ok: ok, detail: detail, ms: r.ms, timedOut: r.timedOut)
                    }
                }
                for await r in group { storage.append(r) }
            }

            // 阶段 B：DSM 登录（DSM 的 PAM 正常就要 ~5s，单独给长超时，避免误报）
            if storage.filter({ $0.timedOut }).count >= 2 {
                stoppedReason = "2 个读库请求已超时"
                if dsmPort != nil { storage.append(skipped("sto.dsm", "DSM Auth", stoppedReason)) }
            } else if let dsmPort, tcpOK["dsm"] == true {
                await withTaskGroup(of: ProbeResult.self) { group in
                    group.addTask {
                        let longTimeout = max(cfg.timeout * 2.5, 12)
                        let body = "api=SYNO.API.Auth&version=6&method=login&account=__nasmon_probe__&passwd=__invalid__&session=Core&format=sid"
                        let r = await HTTP.request("\(cfg.base):\(dsmPort)/webapi/entry.cgi", method: "POST",
                                                   headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                                   body: body.data(using: .utf8), timeout: longTimeout)
                        let ok = !r.timedOut && r.status > 0
                        return ProbeResult(id: "sto.dsm", name: "DSM Auth", layer: .storage,
                                           ok: ok,
                                           detail: r.timedOut ? "认证超时（长超时 \(Int(longTimeout))s）"
                                                             : (r.body.contains("\"code\":400") || r.body.contains("\"code\": 400")
                                                                ? "code 400 · 认证库可读" : "HTTP \(r.status) · 已响应"),
                                           ms: r.ms, timedOut: r.timedOut)
                    }
                    for await r in group { storage.append(r) }
                }
            } else if dsmPort != nil {
                storage.append(skipped("sto.dsm", "DSM Auth", "DSM 端口未通"))
            }
        }
        results.append(contentsOf: storage)

        // 说明：不再为「SSH 读 /proc/mdstat」单独建连接。
        // sshd 连接建立后不发 banner 就重置是 NAS 上常见故障，高频 SSH 探测反而会加重它。
        // SSH 健康由低频磁盘体检（默认 15 分钟一次）在 L4 体现，正常轮次只做轻量 TCP/HTTP。

        // ---------- L4：磁盘体检（低频，由 Monitor 缓存传入） ----------
        if let d = disk {
            let degraded = !d.arrays.isEmpty && d.arrays.contains { !$0.healthy }
            // dStateCount 现在只统计「连续 3 次快照都命中」的持续卡住进程，瞬时内核线程已过滤。
            // 单个持续 D 仍让磁盘体检显示异常（黄色），但不单独上升为「存储层阻塞」。
            let criticalDisk = d.sufficient && (degraded || d.dStateCount > 0)
            let detail: String
            if !d.sufficient { detail = "体检数据不足（SSH 未返回阵列信息），不参与判定" }
            else if degraded { detail = "阵列降级：\(d.arrays.filter { !$0.healthy }.map { $0.name }.joined(separator: ", "))" }
            else if d.dStateCount > 0 { detail = "\(d.dStateCount) 个进程持续卡在 I/O（连续 3 次快照）" }
            else if !d.sataErrors.isEmpty { detail = "\(d.sataErrors.count) 条 SATA 链路错误（检查背板与线材）" }
            else { detail = "\(d.arrays.count) 个阵列正常 · \(d.volumes.count) 个卷" }
            results.append(ProbeResult(id: "disk", name: "Disk / RAID", layer: .disk,
                                       ok: d.sufficient ? (!criticalDisk && d.sataErrors.isEmpty) : true,
                                       detail: detail, ms: -1))
        }

        // ---------- 判定 ----------
        let staticResults = results.filter { $0.layer == .stat }
        let staticOK = staticResults.filter { $0.ok }.count
        let staticTimeouts = staticResults.filter { $0.timedOut }.count
        let storageTimeouts = storage.filter { $0.timedOut }.count
        let failedTCP = critical.filter { tcpOK[$0.key] != true }.map { $0.name }
        let diskBad = results.filter { $0.layer == .disk && !$0.ok }
        // 存储阻塞必须由强证据支撑：阵列降级、≥2 个进程持续卡在 I/O，或多项读库探针超时。
        // 单次 ps 快照里的 1 个瞬时 D 状态（kworker/btrfs 线程正常 IO 等待）在 2026-11-08
        // 造成了持续数十分钟的「存储层阻塞」误报；体检脚本已改为三次快照过滤，这里再收一道门槛。
        let diskCritical = disk.map { d in
            d.sufficient && ((!d.arrays.isEmpty && d.arrays.contains { !$0.healthy }) || d.dStateCount >= 2)
        } ?? false

        var health: Health
        var summary: String

        let needStall = min(2, max(1, storage.count))
        if staticOK >= 2 && (storageTimeouts >= needStall || diskCritical) {
            health = .stalled
            // 只有本轮确有读库超时才说「读库卡住」；单靠磁盘体检命中时如实写磁盘证据。
            summary = stalledSummary(storageTimeouts: storageTimeouts,
                                     storageCount: storage.count,
                                     disk: disk,
                                     diskCritical: diskCritical)
        } else if storageTimeouts >= 1 {
            health = .degraded
            summary = "\(storageTimeouts) 个读库请求超时，静态层正常，疑似存储响应变慢"
        } else if staticTimeouts >= 1 || !failedTCP.isEmpty
                    || (hasStaticProbes && staticOK < 2) {
            health = .degraded
            var parts: [String] = []
            if !failedTCP.isEmpty { parts.append("端口不通: \(failedTCP.joined(separator: "、"))") }
            if staticTimeouts > 0 { parts.append("\(staticTimeouts) 个静态请求超时") }
            // 用户把所有内置深度服务都删掉时，静态层为空不等于 NAS 异常，
            // 只按 TCP 结果判定，避免凭空冒出「静态服务仅 0 项可用」。
            if hasStaticProbes && staticOK < 2 { parts.append("静态服务仅 \(staticOK) 项可用") }
            if storage.filter({ !$0.ok }).count > 0 {
                parts.append("存储探针 \(storage.filter { !$0.ok }.count) 项异常")
            }
            summary = parts.joined(separator: " · ")
        } else if !diskBad.isEmpty {
            health = .degraded
            summary = diskBad.map { $0.detail }.joined(separator: " · ")
        } else if let disk = disk, disk.hasWarning {
            health = .degraded
            summary = "磁盘预警：\(disk.warningText)"
        } else {
            health = .online
            summary = "\(criticalAlive)/\(criticalTotal) 关键端口 · \(staticOK) 项静态服务 · \(storage.filter { $0.ok }.count) 项读库探针全部正常"
        }

        if !stoppedReason.isEmpty {
            summary += "；已停止后续探测（\(stoppedReason)），等待退避后重试"
        }
        return Snapshot(health: health, summary: summary, results: sorted(results))
    }

    private static func sorted(_ r: [ProbeResult]) -> [ProbeResult] {
        r.sorted { a, b in
            if a.layer.order != b.layer.order { return a.layer.order < b.layer.order }
            return a.id < b.id
        }
    }

    // MARK: - 磁盘体检

    static func diskCheck(_ cfg: RunConfig, useSudo: Bool, sudoPassword: String) async -> DiskReport {
        let script = SSH.diskScript(useSudo: useSudo)
        let stdin = useSudo ? SSH.stdin(for: sudoPassword) : nil
        // 磁盘体检走一次 SSH；上层 Task 取消时 Proc.run 会 terminate 掉 ssh 子进程，
        // 不会留下挂在 NAS 上的孤儿登录会话。
        let out = await SSH.run(user: cfg.sshUser, host: cfg.host, script: script,
                                stdin: stdin, timeout: useSudo ? 15 : 9)
        var report = DiskReport(date: Date())
        guard !out.timedOut, !out.text.isEmpty else {
            let err = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? ""
            report.rawHint = out.timedOut ? "SSH 超时"
                : ("SSH 无输出" + (err.isEmpty ? "" : " · \(String(err.prefix(110)))"))
            return report
        }

        var section = ""
        var buf: [String] = []
        func flush() {
            let text = buf.joined(separator: "\n")
            switch section {
            case "MDSTAT":  report.arrays = parseMDStat(text)
            case "DF":      report.volumes = parseDF(text)
            case "BLOCK":   report.physicalDisks = parseBlock(text)
            case "LISTEN":  report.listeningPorts = parseListeningPorts(text)
            case "DSTATE":  report.dStateCount = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            case "UPTIME":  report.uptime = formatUptime(text)
            case "DMESG":   report.sataErrors = text.split(separator: "\n")
                                    .map(String.init)
                                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            case "SMART":   break
            default: break
            }
            buf = []
        }

        for line in out.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.hasPrefix("###") {
                flush()
                section = String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            buf.append(l)
        }
        flush()

        report.reachable = report.uptime != "--" || !report.arrays.isEmpty || !report.volumes.isEmpty
        if report.rawHint.isEmpty {
            report.rawHint = "体检完成 · \(report.arrays.count) 阵列 / \(report.volumes.count) 卷"
                + " / \(report.physicalDisks.count) 物理盘 / \(report.listeningPorts.count) 监听端口"
                + " / \(report.sataErrors.count) 告警行"
        }
        return report
    }

    static func parseMDStat(_ text: String) -> [DiskReport.ArrayInfo] {
        var out: [DiskReport.ArrayInfo] = []
        let lines = text.split(separator: "\n").map(String.init)
        var i = 0
        while i < lines.count {
            let l = lines[i]
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("md") && t.contains(":") {
                let name = (t.components(separatedBy: ":").first ?? t)
                    .trimmingCharacters(in: .whitespaces)
                // md0 / md1 是系统分区与 swap，在 RR 引导上固定显示 [UU__________]（12 槽位仅 2 成员），
                // 属正常现象，不能按标准 mdadm 规则判降级，直接跳过。
                // 数据阵列不写死名字：新增盘建出 md3 / md7 等都会自动纳入这里。
                if name == "md0" || name == "md1" { i += 1; continue }
                var detail = t
                if i + 1 < lines.count { detail += " " + lines[i + 1].trimmingCharacters(in: .whitespaces) }
                let healthy = !detail.contains("[_") && !detail.contains("[U_") && !detail.contains("[_U")
                out.append(DiskReport.ArrayInfo(name: name, healthy: healthy, detail: detail))
            }
            i += 1
        }
        return out
    }

    /// 卷挂载点判定：只认严格的一级 /volumeN（含 /volumeUSB1 这类外置盘），
    /// 不认 /volume3/@appdata/... 之类的 bind 挂载 / btrfs 子卷。
    static func isVolumeMount(_ s: String) -> Bool {
        guard s.hasPrefix("/volume") else { return false }
        let rest = s.dropFirst("/volume".count)
        return !rest.isEmpty && !rest.contains("/")
            && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// df -kP 全量输出 → 卷列表。严格过滤 + 按挂载点去重 + 自然排序，
    /// 任意数量卷都能显示（真实环境已出现 /volume1 /volume2 /volume3 三个）。
    static func parseDF(_ text: String) -> [DiskReport.VolumeInfo] {
        var seen = Set<String>()
        var out: [DiskReport.VolumeInfo] = []
        for l in text.split(separator: "\n").map(String.init) {
            let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 6, f[0].hasPrefix("/dev/"),
                  isVolumeMount(f[5]), !seen.contains(f[5]) else { continue }
            seen.insert(f[5])
            // df -k 输出单位为 1K 块
            let total = (Int64(f[1]) ?? 0) * 1024
            let used  = (Int64(f[2]) ?? 0) * 1024
            let free  = (Int64(f[3]) ?? 0) * 1024
            let pct = (f[4].replacingOccurrences(of: "%", with: "") as NSString).integerValue
            out.append(DiskReport.VolumeInfo(mount: f[5], total: human(Double(total)),
                                             used: human(Double(used)),
                                             free: human(Double(free)), percent: pct))
        }
        return out.sorted { $0.mount.localizedStandardCompare($1.mount) == .orderedAscending }
    }

    /// ###BLOCK 段的 `name|sectors|model` → 物理整盘清单。
    static func parseBlock(_ text: String) -> [DiskReport.PhysicalDisk] {
        var seen = Set<String>()
        var out: [DiskReport.PhysicalDisk] = []
        for l in text.split(separator: "\n").map(String.init) {
            let f = l.split(separator: "|", maxSplits: 2,
                            omittingEmptySubsequences: false).map(String.init)
            let name = f[0].trimmingCharacters(in: .whitespaces)
            guard f.count >= 2, !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            let sectors = Int64(f[1].trimmingCharacters(in: .whitespaces)) ?? 0
            let model = (f.count >= 3 ? f[2] : "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(DiskReport.PhysicalDisk(
                name: name,
                size: sectors > 0 ? human(Double(sectors) * 512) : "—",
                model: model.isEmpty ? "—" : model))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// ###LISTEN 段每行一个端口数字；脚本已排掉回环地址与表头，这里再做一次范围校验。
    static func parseListeningPorts(_ text: String) -> [Int] {
        var out = Set<Int>()
        for l in text.split(separator: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard let p = Int(t), p > 0, p <= 65535 else { continue }
            out.insert(p)
        }
        return out.sorted()
    }

    static func human(_ b: Double) -> String {
        let gb = b / 1_073_741_824
        if gb >= 1024 { return String(format: "%.1f T", gb / 1024) }
        return String(format: "%.0f G", gb)
    }

    static func formatUptime(_ text: String) -> String {
        let secs = Double(text.split(separator: " ").first ?? "0") ?? 0
        if secs <= 0 { return "--" }
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        if h >= 24 { return "\(h / 24) 天 \(h % 24) 小时" }
        return "\(h) 小时 \(m) 分"
    }
}

/// 命令行一次性清洗：NASMonitor --history-migrate
/// 旧版写进 history.json 的「0 个读库请求超时 —— 典型存储层阻塞」不会随代码修复自动消失，
/// 会一直在日志页误导用户。这里按每条快照自己的 results 纠正，写回前先留时间戳备份。
/// 只读本地文件、不建任何网络连接；GUI 运行时请先退出，避免与 120s 落盘竞态。
enum HistoryMigration {
    static func run() {
        let url = MetricsCollector.storeDir().appendingPathComponent("history.json")
        print("历史摘要迁移 · \(Date())")
        print("文件: \(url.path)")
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([Snapshot].self, from: data) else {
            print("读取 / 解码失败，未改动任何文件")
            return
        }
        let (fixed, n) = Engine.normalizeLegacySummaries(arr)
        print("快照 \(arr.count) 条 · 自相矛盾需纠正 \(n) 条")
        guard n > 0 else {
            print("无需改动，文件保持原样（可重复执行）")
            return
        }
        let bak = url.deletingLastPathComponent()
            .appendingPathComponent("history.json.bak-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.copyItem(at: url, to: bak)
        } catch {
            print("备份失败，已中止（原文件未改动）: \(error.localizedDescription)")
            return
        }
        do {
            let out = try JSONEncoder().encode(fixed)
            guard AtomicFileWriter.write(out, to: url) else {
                throw NSError(domain: "NASMonitor", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "原子写入失败"])
            }
            print("已写回 \(fixed.count) 条 · 备份 \(bak.lastPathComponent)")
            var shown = 0
            for (a, b) in zip(arr, fixed) where a.summary != b.summary && shown < 3 {
                print("  - \(a.summary)")
                print("  + \(b.summary)")
                shown += 1
            }
        } catch {
            print("写回失败: \(error.localizedDescription)")
            print("原文件未损坏，备份仍在 \(bak.lastPathComponent)")
        }
    }
}
