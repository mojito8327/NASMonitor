import Foundation
import AppKit
import Darwin.Mach

// MARK: - 一键排障报告（脱敏 Markdown）
//
// 用户发现 NAS 异常时，需要把「最近探测结果 + 整机采样 + 磁盘错误」一次性带走，
// 而不是手动截图几张浮窗。这里生成纯 Markdown 并复制到剪贴板，可直接粘到
// 另一台设备、工单或笔记里。
//
// 安全约定：
//   - 报告**绝不读取** CredentialStore，不输出任何 token / 密码 / DSM 账号；
//   - redact() 再做一层兜底，清掉意外混入的 Bearer / token= / passwd= 片段；
//   - 主机 IP 属内网地址，保留以便核对目标，其他机器名不动。

enum Diagnostics {

    struct Context {
        var host: String = ""
        var generatedAt: Date = Date()
        var health: Health = .unknown
        var summary: String = ""
        var latest: Snapshot?
        var history: [Snapshot] = []
        var metrics: [MetricsSample] = []
        var disk: DiskReport?
        var events: [Event] = []
        var throttleNote: String = ""
        var powerNote: String = ""
        var transportExternal: Bool = false
        var appearance: String = ""
        var interval: Double = 0
        var timeout: Double = 0
        var multiplier: Int = 1
        var source: String = "运行中应用"
        /// 运行中应用才有完整的闸门状态；命令行读盘模式留 nil，只输出采样年龄
        var freshness: Freshness.Status?
    }

    // MARK: - 生成

    static func markdown(_ c: Context) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = f.string(from: c.generatedAt)
        var out: [String] = []
        out.append("# NASMonitor 排障报告")
        out.append("")
        out.append("- 生成时间：\(now)")
        out.append("- 目标主机：`\(c.host)`")
        out.append("- 数据来源：\(c.source)")
        out.append("- 当前状态：**\(c.health.title)**（\(c.health.rawValue)）")
        if !c.summary.isEmpty { out.append("- 状态摘要：\(redact(c.summary))") }
        out.append("- 探测节奏：\(Int(c.interval))s · 超时 \(Int(c.timeout))s · 闸门倍率 ×\(c.multiplier)")
        out.append("- 传输通道：\(c.transportExternal ? "系统工具兼容模式" : "原生直连") · 界面外观：\(c.appearance)")
        if !c.throttleNote.isEmpty { out.append("- 熔断：\(redact(c.throttleNote))") }
        if !c.powerNote.isEmpty { out.append("- 电源操作：\(redact(c.powerNote))") }
        if let f = c.freshness { out.append("- 数据鲜活度：\(redact(f.reportLine))") }

        out.append("")
        out.append("## 最近一轮探测")
        if let s = c.latest {
            out.append("时间 `\(s.timeString)` · 共 \(s.results.count) 项")
            out.append("")
            out.append("| 层 | 探针 | 结果 | 详情 | 耗时 |")
            out.append("|---|---|---|---|---|")
            for r in s.results {
                let mark = r.timedOut ? "超时" : (r.ok ? "正常" : "异常")
                let detail = redact(r.detail).replacingOccurrences(of: "|", with: "\\|")
                out.append("| \(r.layer.rawValue) | \(r.name) | \(mark) | \(detail) | \(r.latency) |")
            }
            let timeouts = s.results.filter(\.timedOut).count
            let storageTimeouts = s.results.filter { $0.layer == .storage && $0.timedOut }.count
            out.append("")
            out.append("> 超时 \(timeouts) 项，其中读库层 \(storageTimeouts) 项。"
                       + (storageTimeouts > 0
                          ? "**存在真实读库阻塞证据**，需核对内核 ATA / CRC 与阵列状态。"
                          : "读库层无超时；若此时状态为存储层阻塞，证据应来自磁盘体检（D 状态 / 阵列降级），不要直接断电重启。"))
        } else {
            out.append("（尚无探测结果）")
        }

        out.append("")
        out.append("## 近期状态变化（最近 \(min(12, c.history.count)) 轮）")
        if c.history.isEmpty {
            out.append("（无历史）")
        } else {
            out.append("")
            out.append("| 时间 | 状态 | 摘要 |")
            out.append("|---|---|---|")
            for s in c.history.suffix(12).reversed() {
                out.append("| \(s.timeString) | \(s.health.short) | \(redact(s.summary).replacingOccurrences(of: "|", with: "\\|")) |")
            }
        }

        out.append("")
        out.append("## 整机性能采样")
        let samples = c.metrics.suffix(12)
        if let last = c.metrics.last {
            out.append("最新 `\(last.timeString)`（来源 \(last.cpuSource.isEmpty ? "无" : last.cpuSource)）："
                       + "CPU \(MetricFormat.cpu(last.cpu)) · 内存 \(MetricFormat.bytes(last.memUsed)) / \(MetricFormat.bytes(last.memTotal))"
                       + " · 下行 \(MetricFormat.rate(last.rx)) · 上行 \(MetricFormat.rate(last.tx))"
                       + " · 磁盘读 \(MetricFormat.rate(last.diskRead)) · 磁盘写 \(MetricFormat.rate(last.diskWrite))")
            if !last.note.isEmpty { out.append("采集说明：\(redact(last.note))") }
        }
        if !samples.isEmpty {
            func avg(_ pick: (MetricsSample) -> Double?) -> String {
                let v = samples.compactMap(pick)
                guard !v.isEmpty else { return "—" }
                return String(format: "%.2f MB/s", v.reduce(0, +) / Double(v.count) / 1024 / 1024)
            }
            let cpu = samples.compactMap(\.cpu)
            out.append("近 \(samples.count) 点均值：CPU "
                       + (cpu.isEmpty ? "—" : String(format: "%.1f%%", cpu.reduce(0, +) / Double(cpu.count)))
                       + " · 网络下行 \(avg(\.rx)) · 上行 \(avg(\.tx))"
                       + " · 磁盘读 \(avg(\.diskRead)) · 写 \(avg(\.diskWrite))")
        } else {
            out.append("（无采样数据）")
        }

        out.append("")
        out.append("## 磁盘体检")
        if let d = c.disk {
            out.append("- SSH 可达：\(d.reachable ? "是" : "否") · 运行：\(d.uptime.isEmpty ? "—" : d.uptime) · 持续 D 状态进程：\(d.dStateCount)")
            out.append("- 数据足以判定：\(d.sufficient ? "是" : "否（SSH 无阵列信息，不参与告警判定）")")
            if d.arrays.isEmpty {
                out.append("- 阵列：无数据")
            } else {
                for a in d.arrays {
                    out.append("- 阵列 `\(a.name)`：\(a.healthy ? "正常" : "**降级**") · \(redact(a.detail))")
                }
            }
            for v in d.volumes {
                out.append("- 卷 `\(v.mount)`：\(v.used)/\(v.total) · 已用 \(v.percent)% · 剩 \(v.free)")
            }
            if d.physicalDisks.isEmpty {
                out.append("- 物理盘：无数据")
            } else {
                out.append("- 物理盘 **\(d.physicalDisks.count) 块**：")
                for p in d.physicalDisks {
                    out.append("  - `\(p.name)`：\(p.size) · \(redact(p.model))")
                }
            }
            out.append("- 对外监听端口："
                       + (d.listeningPorts.isEmpty ? "无数据"
                          : "\(d.listeningPorts.count) 个 · "
                            + d.listeningPorts.map(String.init).joined(separator: ", ")))
            if d.sataErrors.isEmpty {
                out.append("- SATA / I/O 告警行：无（未启用 sudo 时 dmesg 段不采集）")
            } else {
                out.append("- SATA / I/O 告警行 **\(d.sataErrors.count) 条**：")
                for l in d.sataErrors.suffix(20) { out.append("  - `\(redact(l.trimmingCharacters(in: .whitespaces)))`") }
            }
            if !d.rawHint.isEmpty { out.append("- 体检备注：\(redact(d.rawHint))") }
        } else {
            out.append("（尚未执行磁盘体检，或本进程为命令行模式）")
        }

        let cat = ServiceCatalog.shared
        out.append("")
        out.append("## 服务目录（运行时配置）")
        out.append("- 已配置 \(cat.snapshot.count) 个服务 · 自动纳入\(cat.autoAdopt ? "开启" : "关闭")")
        for s in cat.snapshot {
            out.append("- `\(redact(s.name))` :\(s.port) · \(s.critical ? "关键" : "非关键")"
                       + " · \(s.origin.rawValue)"
                       + (cat.missingKeys.contains(s.key) ? " · **未监听**" : ""))
        }
        if !cat.discovered.isEmpty {
            out.append("- 待确认新端口：\(cat.discovered.map(String.init).joined(separator: ", "))")
        }

        if !c.events.isEmpty {
            out.append("")
            out.append("## 事件日志（最近 \(min(15, c.events.count)) 条）")
            for e in c.events.prefix(15) {
                out.append("- `\(e.timeString)` [\(e.level.short)] \(redact(e.text))")
            }
        }

        out.append("")
        out.append("## 排障提示")
        out.append("1. 先看「最近一轮探测」里读库层是否真的超时；背板与 SATA 线已于 2026-11-07 整体更换，")
        out.append("   单个内核线程的瞬时 D 状态不构成硬件复发，不要据此物理断电。")
        out.append("2. 真读库阻塞时，对照 NAS 侧 `nas-health.log` 的 ATA / CRC / hung task / 链路降速计数与 md 阵列状态。")
        out.append("3. 观察期内不要跑批量 `ffmpeg -c copy` 无损合并或写 IO 压测。")
        out.append("")
        out.append("---")
        out.append("本报告由 NASMonitor 1.0 生成，**不包含任何凭据**（token / 密码 / DSM 账号均未读取）。")
        return out.joined(separator: "\n")
    }

    /// 兜底脱敏：即便某个 detail 意外带入敏感串，也不会被复制到剪贴板。
    static func redact(_ s: String) -> String {
        var t = s
        let patterns = [
            #"Bearer\s+[A-Za-z0-9._\-]+"#,
            #"(?i)(token|passwd|password|apikey|api_key|secret)\s*[=:]\s*["']?[A-Za-z0-9._\-+/]{6,}["']?"#,
            #"\"(sid|token|passwd|password)\"\s*:\s*\"[^\"]+\""#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: []) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                                withTemplate: "[已脱敏]")
            }
        }
        return t
    }

    // MARK: - 运行中应用

    @MainActor
    static func context(monitor: Monitor, cfg: Config) -> Context {
        var c = Context()
        c.host = cfg.effectiveHost
        c.health = monitor.health
        c.summary = monitor.latest?.summary ?? ""
        c.latest = monitor.latest
        c.history = monitor.history
        c.metrics = monitor.visibleMetrics
        c.disk = monitor.disk
        c.events = monitor.events
        c.throttleNote = monitor.throttleNote
        c.powerNote = monitor.powerNote
        c.transportExternal = Transport.shared.usesExternal
        c.appearance = AppearanceObserver.shared.mode.title
        c.interval = cfg.interval
        c.timeout = cfg.timeout
        c.multiplier = monitor.throttleMultiplier
        c.freshness = monitor.freshness
        return c
    }

    /// 复制到系统剪贴板；返回是否成功与报告全文（供 UI 回执展示字数）。
    @MainActor
    static func copyToPasteboard(monitor: Monitor, cfg: Config) -> (ok: Bool, text: String) {
        let text = markdown(context(monitor: monitor, cfg: cfg))
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        return (ok, text)
    }

    // MARK: - 命令行（读取本地持久化文件，不需要 GUI）

    @MainActor
    static func fromDisk(cfg: Config) -> Context {
        var c = Context()
        c.host = cfg.effectiveHost
        c.source = "本地 history.json / metrics.json"
        c.interval = cfg.interval
        c.timeout = cfg.timeout
        c.appearance = AppearanceObserver.shared.mode.title
        c.transportExternal = Transport.shared.usesExternal
        let dir = MetricsCollector.storeDir()
        if let d = try? Data(contentsOf: dir.appendingPathComponent("history.json")),
           let arr = try? JSONDecoder().decode([Snapshot].self, from: d) {
            let (fixed, _) = Engine.normalizeLegacySummaries(arr)
            c.history = fixed
            c.latest = fixed.last
            c.health = fixed.last?.health ?? .unknown
            c.summary = fixed.last?.summary ?? ""
        }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("metrics.json")),
           let arr = try? JSONDecoder().decode([MetricsSample].self, from: d) {
            c.metrics = arr
        }
        return c
    }
}

// MARK: - 命令行入口

enum DiagnosticsCLI {
    @MainActor
    static func run() {
        let c = Diagnostics.fromDisk(cfg: .shared)
        print(Diagnostics.markdown(c))
    }

    @MainActor
    static func copy() {
        let c = Diagnostics.fromDisk(cfg: .shared)
        let text = Diagnostics.markdown(c)
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        print(ok ? "已复制排障报告到剪贴板（\(text.count) 字符）" : "复制失败：剪贴板不可用")
        print("自检：报告不含凭据字段 -> \(!text.contains("sudo.password") && !text.contains("amane.token") ? "通过" : "失败")")
    }
}

// MARK: - 资源足迹（供 24 小时 Instruments 对照）
//
// 不是 Instruments 的替代品，而是一个可脚本化的采样点：每 4 小时由巡检任务
// 调一次 `--footprint`，把 resident_size / fd 数 / 临时文件残留写成一行 JSON，
// 长期对比即可看出 Process / URLSession 句柄有没有随时间单调增长。
// 代码侧的约束：HTTP.session 是单例、Proc.run 的临时文件 defer 清理、
// 所有 async 子任务在 withTaskGroup 退出时被取消（见并发重构说明）。

enum Footprint {
    static func snapshotJSON() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        var rss: UInt64 = 0, vss: UInt64 = 0
        let kerr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { q in
                // mach_task_self() 是 C 函数式宏，Swift 不导入；直接用同名全局变量。
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), q, &count)
            }
        }
        if kerr == KERN_SUCCESS { rss = info.resident_size; vss = info.virtual_size }

        let fds = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: temp.path))?
            .filter { $0.hasPrefix("nm-") }.count ?? -1

        let f = ISO8601DateFormatter()
        return """
        {"ts":"\(f.string(from: Date()))","rss_bytes":\(rss),"virtual_bytes":\(vss),\
        "open_fds":\(fds),"temp_leftovers":\(leftovers),\
        "rss_mb":\(String(format: "%.2f", Double(rss) / 1048576.0))}
        """
    }

    static func printReport() {
        print(snapshotJSON())
        print("说明: rss_bytes 常驻内存 / open_fds 当前进程 fd 数 / temp_leftovers 为 Proc.run 残留的 nm-* 临时文件")
        print("长期平稳判据: rss_mb 不随时间单调增长，temp_leftovers 恒为 0，open_fds 在每轮探测后回落")
    }
}
