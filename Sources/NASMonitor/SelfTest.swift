import Foundation

/// 命令行自检：NASMonitor --selftest
/// 不启动 GUI，跑完整一轮分层探测 + 磁盘体检，把结果打到 stdout。
enum SelfTest {
    static func run() async {
        let cfg = RunConfig(Config.shared)
        let args = CommandLine.arguments
        let withDisk = !args.contains("--no-disk")
        Net.debug = args.contains("--debug-tcp")

        print("NASMonitor 自检 · 目标 \(cfg.host) · \(Date())")
        if Config.shared.onlyLAN {
            let same = LANCheck.isOnSameLAN(as: cfg.host, prefix: Config.shared.lanPrefix)
            print("内网判定: \(same ? "在内网" : "不在内网（GUI 会自动静默）")  本机: \(LANCheck.localIPv4s().joined(separator: ", "))")
        }
        print(String(repeating: "-", count: 74))

        let pw = CredentialStore.get(CredentialStore.Key.sudoPassword)
        let disk: DiskReport? = withDisk
            ? await Engine.diskCheck(cfg, useSudo: Config.shared.useSudo && !pw.isEmpty,
                                     sudoPassword: pw)
            : nil
        let snap = await Engine.run(cfg, disk: disk)
        for r in snap.results {
            let mark = r.timedOut ? "超时" : (r.ok ? "正常" : "异常")
            print("[\(r.layer.rawValue)] \(mark)  \(r.name)  —  \(r.detail)  (\(r.latency))")
        }
        print(String(repeating: "-", count: 74))
        print("结论: \(snap.health.title) — \(snap.summary)")

        if let r = disk {
            print("\n▸ 磁盘体检")
            print("  SSH 可达: \(r.reachable)  运行: \(r.uptime)  D 状态进程: \(r.dStateCount)")
            for a in r.arrays { print("  阵列 \(a.name): \(a.healthy ? "正常" : "降级")  \(a.detail)") }
            for v in r.volumes { print("  卷 \(v.mount): \(v.used)/\(v.total) 已用 \(v.percent)%  剩 \(v.free)") }
            if !r.sataErrors.isEmpty {
                print("  ⚠ SATA / I/O 告警 \(r.sataErrors.count) 条:")
                for l in r.sataErrors.suffix(8) { print("    \(l.trimmingCharacters(in: .whitespaces))") }
            } else {
                print("  SATA / I/O 告警: 无（或需启用 sudo 才能读取 dmesg）")
            }
            print("  \(r.rawHint)")
        }

        if args.contains("--json") {
            print("\n---JSON---")
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(snap), let s = String(data: d, encoding: .utf8) { print(s) }
        }
    }
}

/// 电源指令自检：NASMonitor --power-selftest
/// 纯内存，不建任何连接、不执行关机/重启，也不打印任何凭据明文。
enum PowerControlSelfTest {
    static func run() {
        var pass = 0
        var fail = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "✓" : "✗") \(name)")
            if ok { pass += 1 } else { fail += 1 }
        }

        print("NASMonitor 电源指令自检 · 纯内存（不连接、不执行）· \(Date())")
        print(String(repeating: "-", count: 74))

        // 1) 单引号转义：配置值只能当数据，不能被当成 shell 代码拼接
        check("shellQuote 单引号转义",
              PowerControl.shellQuote("a'b") == "'a'\\''b'")
        let hostile = "/usr/sbin/shutdown -h now; rm -rf / '$(id)'"
        let quoted = PowerControl.shellQuote(hostile)
        check("危险字符被完整引用", quoted.hasPrefix("'") && quoted.hasSuffix("'")
              && quoted.contains("'\\''"))

        // 2) 脚本安全不变量
        for a in PowerAction.allCases {
            let s = PowerControl.script(for: a)
            check("[\(a.title)] 含确认标记", s.contains("###POWER_ACCEPTED"))
            check("[\(a.title)] 含收尾标记", s.contains("###POWER_DONE"))
            check("[\(a.title)] 忽略 HUP + 延后执行", s.contains("trap '' HUP") && s.contains("sleep 2"))
            check("[\(a.title)] 按空白拆词、不用 eval",
                  s.contains("read -r -a ARGS") && !s.contains("eval "))
            check("[\(a.title)] 先校验 sudo", s.contains("sudo -S -p '' -v") || s.contains("sudo -n -v"))
            check("[\(a.title)] 脚本正文不含明文密码",
                  !s.contains("SUDO_PASSWORD_SENTINEL"))
        }

        // 3) stdin 注入不含明文，且未配置密码时返回 nil
        let payload = PowerControl.stdinPayload(sudoPassword: "SUDO_PASSWORD_SENTINEL") ?? ""
        check("密码经 stdin base64 注入", payload.contains("base64 -d") && !payload.contains("SUDO_PASSWORD_SENTINEL"))
        check("未配置密码时不注入 PW", PowerControl.stdinPayload(sudoPassword: "") == nil)

        // 4) DSM 地址：默认拼接 + 自定义 https 地址（临时改配置后立即还原）
        let original = Config.shared.dsmURL
        Config.shared.dsmURL = ""
        let auto = PowerControl.dsmURL()?.absoluteString ?? ""
        check("默认 DSM 地址含 :5000", auto.contains(":5000/") && auto.hasPrefix("http://"))
        Config.shared.dsmURL = "nas.example.com:5001"
        check("无 scheme 自动补 http", PowerControl.dsmURL()?.absoluteString == "http://nas.example.com:5001")
        Config.shared.dsmURL = "https://nas.example.com:5001/"
        check("https 地址原样保留", PowerControl.dsmURL()?.absoluteString == "https://nas.example.com:5001/")
        Config.shared.dsmURL = original

        // 5) 结果判定：只有拿到确认标记才算「已下发」
        func out(_ text: String, _ err: String = "", _ timedOut: Bool = false) -> SSH.Output {
            SSH.Output(text: text, stderr: err, exitCode: 0, timedOut: timedOut)
        }
        let accepted = PowerControl.interpret(out("###POWER_ACCEPTED\n###POWER_DONE"),
                                              action: .shutdown, host: "h", hasPassword: true)
        check("确认标记 → 成功", accepted.ok && accepted.title == "关机指令已下发")
        check("sudo 失败 → 不报成功",
              !PowerControl.interpret(out("###POWER_SUDO_FAIL"), action: .shutdown,
                                     host: "h", hasPassword: true).ok)
        check("命令不存在 → 不报成功",
              !PowerControl.interpret(out("###POWER_NO_BINARY /nope"), action: .reboot,
                                     host: "h", hasPassword: false).ok)
        check("SSH 超时 → 不报成功",
              !PowerControl.interpret(out("", "", true), action: .reboot,
                                     host: "h", hasPassword: true).ok)
        check("连接拒绝 → 不报成功",
              !PowerControl.interpret(out("", "ssh: connect to host h port 22: Connection refused"),
                                     action: .shutdown, host: "h", hasPassword: true).ok)

        // 6) 二次双向验证：纯函数，不读凭据文件、不建连接
        check("输入 NAS 地址可通过",
              PowerControl.matchesConfirmation("192.168.1.10", host: "192.168.1.10",
                                               passwordSuffix: "4321"))
        check("前后空格容错",
              PowerControl.matchesConfirmation("  192.168.1.10\n", host: "192.168.1.10",
                                               passwordSuffix: nil))
        check("管理员密码后四位可通过",
              PowerControl.matchesConfirmation("4321", host: "192.168.1.10",
                                               passwordSuffix: "4321"))
        check("空输入一律拒绝",
              !PowerControl.matchesConfirmation("", host: "192.168.1.10", passwordSuffix: "4321"))
        check("输错地址被拒绝",
              !PowerControl.matchesConfirmation("192.168.1.27", host: "192.168.1.10",
                                                passwordSuffix: "4321"))
        check("未配置密码时不接受任意四位",
              !PowerControl.matchesConfirmation("4321", host: "192.168.1.10",
                                                passwordSuffix: nil))
        check("不接受密码前四位",
              !PowerControl.matchesConfirmation("Ex12", host: "192.168.1.10",
                                                passwordSuffix: "4321"))

        print(String(repeating: "-", count: 74))
        print("结果: \(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}

/// 从 Finder / LaunchServices 启动的 bundle 进程不在命令行沙箱里。
/// --headless 不建 GUI、不申请通知权限，只跑一轮并把结果写成 JSON，便于自动化验收。
enum Headless {
    struct Output: Codable {
        let snapshot: Snapshot
        let disk: DiskReport
        let host: String
        let finishedAt: Date
    }

    static func run() async {
        let cfg = RunConfig(Config.shared)
        let pw = CredentialStore.get(CredentialStore.Key.sudoPassword)
        let disk = await Engine.diskCheck(cfg,
                                          useSudo: Config.shared.useSudo && !pw.isEmpty,
                                          sudoPassword: pw)
        let snap = await Engine.run(cfg, disk: disk)
        let output = Output(snapshot: snap, disk: disk, host: cfg.host, finishedAt: Date())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let args = CommandLine.arguments
        var path = NSHomeDirectory() + "/Library/Application Support/NASMonitor/headless.json"
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count { path = args[i + 1] }
        if let data = try? enc.encode(output) {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            _ = AtomicFileWriter.write(data, to: URL(fileURLWithPath: path))
        }
    }
}

/// 状态文案自检：NASMonitor --summary-selftest
/// 纯内存，不建任何连接。防止「磁盘 I/O 快照告警」又被写成「读库请求卡住」。
enum EngineSummarySelfTest {
    static func run() {
        var pass = 0
        var fail = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1; print("  [OK] \(name)") }
            else { fail += 1; print("  [FAIL] \(name)") }
        }
        print("状态文案自检（纯内存）· \(Date())")
        print(String(repeating: "-", count: 74))

        // 场景 1：真正的读库卡死（11-06 掉盘事故特征），文案不能退化
        let real = Engine.stalledSummary(storageTimeouts: 2, storageCount: 3,
                                         disk: nil, diskCritical: false)
        check("真读库超时仍报典型存储层阻塞", real.contains("典型存储层阻塞"))
        check("真读库超时写明超时个数", real.contains("2 个读库请求超时"))

        // 场景 2：磁盘 D 状态快照，读库全绿（本次用户看到的误报）
        var d = DiskReport()
        d.dStateCount = 2
        let diskOnly = Engine.stalledSummary(storageTimeouts: 0, storageCount: 3,
                                             disk: d, diskCritical: true)
        check("磁盘告警不再说读库请求超时", !diskOnly.contains("读库请求超时"))
        check("磁盘告警不再说典型存储层阻塞", !diskOnly.contains("典型存储层阻塞"))
        check("磁盘告警如实写读库全部正常", diskOnly.contains("读库探针全部正常"))
        // 11-08 起文案改为「持续卡在 I/O（连续 3 次快照）」：强调已过滤瞬时 D 状态，
        // 自检断言必须跟着改，否则会一直假红。
        check("磁盘告警如实写 D 状态进程数", diskOnly.contains("2 个进程持续卡在 I/O"))

        // 场景 3：阵列降级
        var d2 = DiskReport()
        d2.arrays = [DiskReport.ArrayInfo(name: "md4", healthy: false, detail: "[_U]")]
        let raid = Engine.stalledSummary(storageTimeouts: 0, storageCount: 3,
                                         disk: d2, diskCritical: true)
        check("阵列降级如实点名", raid.contains("阵列降级（md4）"))
        check("阵列降级不误报读库超时", !raid.contains("读库请求超时"))

        // 场景 4：两类故障同时存在，两边证据都要给
        let both = Engine.stalledSummary(storageTimeouts: 2, storageCount: 3,
                                         disk: d, diskCritical: true)
        check("双故障同时给出读库证据", both.contains("典型存储层阻塞"))
        check("双故障同时给出磁盘证据", both.contains("连续 3 次快照"))

        // 场景 5：防御——单个超时不该被夸大成「典型存储层阻塞」
        let one = Engine.stalledSummary(storageTimeouts: 1, storageCount: 3,
                                        disk: nil, diskCritical: false)
        check("单个读库超时不夸大为典型阻塞", !one.contains("典型存储层阻塞"))

        print(String(repeating: "-", count: 74))
        print("结果: \(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}

/// 历史摘要迁移自检：NASMonitor --history-selftest
/// 纯内存，不读不写 history.json、不建任何网络连接。
enum HistoryMigrationSelfTest {
    static func run() {
        var pass = 0
        var fail = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "✓" : "✗") \(name)")
            if ok { pass += 1 } else { fail += 1 }
        }

        print("NASMonitor 历史摘要迁移自检 · 纯内存 · \(Date())")
        print(String(repeating: "-", count: 74))

        let storageOK = [
            ProbeResult(id: "sto.jf", name: "Jellyfin Auth", layer: .storage,
                        ok: true, detail: "HTTP 401 · 用户库可读", ms: 12),
            ProbeResult(id: "sto.amane", name: "Amane DB", layer: .storage,
                        ok: true, detail: "HTTP 200 · 数据库可读", ms: 29),
            ProbeResult(id: "sto.dsm", name: "DSM Auth", layer: .storage,
                        ok: true, detail: "code 400 · 认证库可读", ms: 5500),
        ]
        let diskBad = ProbeResult(id: "disk", name: "Disk / RAID", layer: .disk,
                                  ok: false, detail: "2 个进程卡在 I/O", ms: -1)
        let legacy = "TCP 端口正常、静态页秒回，但 0 个读库请求超时 —— 典型存储层阻塞；磁盘体检发现阵列降级或 I/O 卡死"

        // 场景 1：旧版自相矛盾文案（磁盘告警但读库全绿）
        let dirty = Snapshot(health: .stalled, summary: legacy, results: storageOK + [diskBad])
        let fixed = Engine.normalizeLegacySummary(dirty)
        check("旧自相矛盾文案被纠正", fixed != nil)
        if let f = fixed {
            check("纠正后不再说典型存储层阻塞", !f.summary.contains("典型存储层阻塞"))
            check("纠正后不再说读库请求超时", !f.summary.contains("个读库请求超时"))
            check("纠正后如实写读库全部正常", f.summary.contains("读库探针全部正常"))
            check("纠正后带真实磁盘 detail", f.summary.contains("2 个进程卡在 I/O"))
            check("health 不变", f.health == .stalled)
            check("results 不变", f.results.count == dirty.results.count)
            check("id 不变", f.id == dirty.id)
            check("date 不变", f.date == dirty.date)
        }

        // 场景 2：真有读库超时 → 是有效历史证据，绝不改写
        let realStall = Snapshot(health: .stalled, summary: legacy, results: [
            ProbeResult(id: "a", name: "Jellyfin Auth", layer: .storage,
                        ok: false, detail: "读库超时", ms: 6000, timedOut: true),
            ProbeResult(id: "b", name: "Amane DB", layer: .storage,
                        ok: false, detail: "读库超时", ms: 6000, timedOut: true),
        ])
        check("真读库超时的历史证据不改写", Engine.normalizeLegacySummary(realStall) == nil)

        // 场景 3：online / 新格式文案一律不动
        check("online 快照不改写",
              Engine.normalizeLegacySummary(
                Snapshot(health: .online, summary: legacy, results: storageOK)) == nil)
        let modern = Snapshot(health: .stalled,
                              summary: "读库探针全部正常（本轮 0 个读库超时） · 磁盘体检发现 2 个进程卡在 I/O",
                              results: storageOK + [diskBad])
        check("新格式文案不改写", Engine.normalizeLegacySummary(modern) == nil)

        // 场景 4：批量计数、未命中项逐字不变、幂等
        let arr = [Snapshot(health: .online, summary: "正常", results: storageOK),
                   dirty, dirty, realStall, modern]
        let (out, n) = Engine.normalizeLegacySummaries(arr)
        check("批量纠正条数正确", n == 2)
        check("批量数组长度不变", out.count == arr.count)
        check("未命中条目逐字不变", out[0].summary == arr[0].summary
              && out[3].summary == arr[3].summary && out[4].summary == arr[4].summary)
        let (again, n2) = Engine.normalizeLegacySummaries(out)
        check("重复迁移幂等", n2 == 0 && again[1].summary == out[1].summary)
        check("空数组安全", Engine.normalizeLegacySummaries([]).1 == 0)

        // 场景 5：没有磁盘 probe 也不编造读库阻塞
        let noDisk = Snapshot(health: .stalled, summary: legacy, results: storageOK)
        let nd = Engine.normalizeLegacySummary(noDisk)
        check("无磁盘证据也不误报读库阻塞", nd != nil
              && !(nd?.summary.contains("典型存储层阻塞") ?? true))

        print(String(repeating: "-", count: 74))
        print("结果: \(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}

// MARK: - Task 取消联动自检：--cancel-selftest
//
// 不连接真实 NAS。用 /bin/sleep 与不可达地址验证「顶层 Task 取消 →
// Process / URLSessionTask 立即终止」，并检查没有孤儿进程和临时文件残留。
// 这是并发重构最容易回归的一环，所以做成可脚本化的命令行自检。

enum CancellationSelfTest {
    static func run() async {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "✓" : "✗") \(name)")
            if ok { pass += 1 } else { fail += 1 }
        }
        // 直接用 FileManager 数文件：若用 Proc.run 去 ls，计数进程自己创建的
        // nm-*.out 会被算进去，导致 before/after 偶发差 1 的假失败。
        func nmCount() -> Int {
            let fm = FileManager.default
            let names = (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []
            return names.filter {
                $0.hasPrefix("nm-") && ($0 as NSString).pathExtension == "out"
            }.count
        }

        print("NASMonitor Task 取消联动自检 · \(Date())")
        print(String(repeating: "-", count: 74))
        let before = nmCount()

        // 1) Proc.run：取消后必须立刻返回并 terminate 子进程
        let t0 = Date()
        let t = Task { await Proc.run(path: "/bin/sleep", args: ["30"], timeout: 60) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        t.cancel()
        let r = await t.value
        let dt = Date().timeIntervalSince(t0)
        check("取消后 3s 内返回（实测 \(String(format: "%.2f", dt))s）", dt < 3)
        check("返回标记为取消/超时", r.timedOut)
        check("stderr 说明子进程已终止", r.stderr.contains("取消"))

        // 2) 无孤儿 sleep 进程（grep 用 [s] 模式避免自匹配）
        let ps = await Proc.run(path: "/bin/bash",
                                args: ["-c", "ps -eo command= | grep -c '[s]leep 30' || true"],
                                timeout: 5)
        let orphans = Int(ps.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        check("无残留 sleep 子进程（计数 \(orphans)）", orphans == 0)

        // 3) HTTP.request：取消后不得补发 curl 兼容通道、不得挂住
        let h0 = Date()
        let h = Task {
            await HTTP.request("http://10.255.255.1:8096/System/Info/Public", timeout: 30)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        h.cancel()
        _ = await h.value
        let hdt = Date().timeIntervalSince(h0)
        check("HTTP 取消后 4s 内返回（实测 \(String(format: "%.2f", hdt))s）", hdt < 4)

        // 4) 临时文件不残留
        let after = nmCount()
        check("Proc.run 临时文件无新增（前 \(before) / 后 \(after)）", after == before)
        check("资源足迹 JSON 可读", Footprint.snapshotJSON().contains("rss_bytes"))

        print(String(repeating: "-", count: 74))
        print("结果: \(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}

// MARK: - 排障报告自检：--diagnostics-selftest
//
// 纯内存：不读 CredentialStore、不建连接、不碰剪贴板。

enum DiagnosticsSelfTest {
    static func run() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "✓" : "✗") \(name)")
            if ok { pass += 1 } else { fail += 1 }
        }

        print("NASMonitor 排障报告自检 · 纯内存 · \(Date())")
        print(String(repeating: "-", count: 74))

        let dirty = "Authorization: Bearer abc.def-ghi_123 token=abcdefgh passwd: 1234567890"
        let clean = Diagnostics.redact(dirty)
        check("Bearer token 被脱敏", !clean.contains("abc.def-ghi_123"))
        check("token= 被脱敏", !clean.contains("abcdefgh"))
        check("passwd: 被脱敏", !clean.contains("1234567890"))
        check("脱敏占位符存在", clean.contains("[已脱敏]"))

        var c = Diagnostics.Context()
        c.host = "192.168.1.10"
        c.health = .stalled
        c.summary = "读库探针全部正常（本轮 0 个读库超时） · 磁盘体检发现 2 个进程卡在 I/O"
        c.latest = Snapshot(health: .stalled, summary: c.summary, results: [
            ProbeResult(id: "sto.jf", name: "Jellyfin Auth", layer: .storage,
                        ok: true, detail: "HTTP 401 · 用户库可读", ms: 24),
            ProbeResult(id: "disk", name: "Disk / RAID", layer: .disk,
                        ok: false, detail: "2 个进程卡在 I/O", ms: -1),
        ])
        c.history = [c.latest!]
        c.metrics = [MetricsSample()]
        var d = DiskReport()
        d.sataErrors = ["ata3: SError: { Handshk }"]
        c.disk = d
        c.events = [Event(text: "磁盘预警：2 条 SATA 链路错误", level: .degraded)]

        c.freshness = Freshness.Status(level: .stale, title: "NAS 响应变慢", detail: "",
                                       age: 900, threshold: 600, source: "性能采样", multiplier: 4)
        let md = Diagnostics.markdown(c)
        check("含标题与目标主机", md.contains("# NASMonitor 排障报告") && md.contains("192.168.1.10"))
        check("含最近一轮探测表格", md.contains("## 最近一轮探测") && md.contains("| 层 | 探针 |"))
        check("含整机性能采样", md.contains("## 整机性能采样"))
        check("含磁盘体检与 SATA 明细", md.contains("## 磁盘体检") && md.contains("SError"))
        check("含事件日志", md.contains("## 事件日志"))
        check("含数据鲜活度结论", md.contains("数据鲜活度") && md.contains("自动退避"))
        check("读库 0 超时时不误写读库阻塞证据", md.contains("读库层无超时"))
        check("报告不含任何凭据字段", !md.contains("sudo.password")
              && !md.contains("amane.token") && !md.contains("ExamplePass123!"))
        check("报告含免责说明", md.contains("不包含任何凭据"))

        print(String(repeating: "-", count: 74))
        print("结果: \(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}

// MARK: - 数据鲜活度自检：--freshness-selftest
//
// 纯内存、固定时钟：只验「什么时候该亮黄条、什么时候必须闭嘴」。
// 误报比漏报更烦人，所以抑制条件的覆盖比阈值本身更多。

enum FreshnessSelfTest {
    static func run() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "✓" : "✗") \(name)")
            if ok { pass += 1 } else { fail += 1 }
        }
        let now = Date()
        func base() -> Freshness.Input {
            var i = Freshness.Input()
            i.now = now
            i.startedAt = now.addingTimeInterval(-3600)
            i.lastProbe = now.addingTimeInterval(-120)
            i.lastMetrics = now.addingTimeInterval(-60)
            i.hasMetrics = true
            i.metricsEnabled = true
            i.metricsInterval = 120
            i.baseInterval = 120
            return i
        }
        func cooling(_ tweak: (inout Freshness.Input) -> Void = { _ in }) -> Freshness.Status {
            var i = base()
            i.cooling = true
            i.multiplier = 4
            i.lastMetrics = now.addingTimeInterval(-12 * 60)
            tweak(&i)
            return Freshness.evaluate(i)
        }

        print("NASMonitor 数据鲜活度自检 · 纯内存 · \(Date())")
        print(String(repeating: "-", count: 74))

        // 1) 正常节奏
        let fresh = Freshness.evaluate(base())
        check("正常节奏不提示", !fresh.isStale && fresh.level == .fresh)
        check("正常时标题为空、不占界面", fresh.title.isEmpty)

        // 2) 退避 + 12 分钟无采样：核心场景
        let s = cooling()
        check("退避且数据变旧时提示", s.isStale)
        check("用用户指定的温和文案", s.title == "NAS 响应变慢，监控已进入自动退避状态")
        check("说明是自动保护而非程序卡死", s.detail.contains("自动保护而非程序卡死"))
        check("说明写明倍率与年龄", s.detail.contains("×4") && s.detail.contains("12 分钟"))
        check("不夸大成 NAS 故障 / 离线", !s.title.contains("离线") && !s.title.contains("故障"))
        check("阈值默认 10 分钟", s.threshold == 600)
        check("年龄按固定时钟计算", abs(s.age - 720) < 0.01)
        check("主时钟是性能采样", s.source == "性能采样")
        check("报告行含退避结论", s.reportLine.contains("已过期（自动退避）"))

        // 3) 阈值边界
        check("9 分 59 秒不提示",
              !cooling { $0.lastMetrics = now.addingTimeInterval(-599) }.isStale)
        check("10 分 01 秒提示",
              cooling { $0.lastMetrics = now.addingTimeInterval(-601) }.isStale)

        // 4) 抑制条件：预期内的不更新一律闭嘴
        check("用户暂停不误报", cooling { $0.paused = true }.level == .suppressed)
        check("电源静默不误报", cooling { $0.powerGrace = true }.level == .suppressed)
        check("不在内网不误报", cooling { $0.away = true }.level == .suppressed)
        check("冷启动预热不误报",
              cooling { $0.startedAt = now.addingTimeInterval(-30) }.level == .suppressed)
        check("无历史数据不误报",
              cooling { $0.lastProbe = nil; $0.lastMetrics = nil; $0.hasMetrics = false }
                .level == .suppressed)
        check("抑制时标题为空", cooling { $0.paused = true }.title.isEmpty)
        check("抑制原因可解释",
              cooling { $0.away = true }.suppressedReason.contains("不在内网"))

        // 5) 不在退避：数据再旧也不归咎于自动保护
        var notCooling = base()
        notCooling.lastMetrics = now.addingTimeInterval(-30 * 60)
        check("未退避不提示", !Freshness.evaluate(notCooling).isStale)
        check("熔断解除后提示立即消失",
              !cooling { $0.cooling = false; $0.multiplier = 1 }.isStale)
        check("关闭自适应节流不提示",
              !cooling { $0.cooling = false }.isStale)

        // 6) 采样节奏本来就很慢：阈值跟着放大
        check("900s 采样节奏下 12 分钟不误报",
              !cooling { $0.metricsInterval = 900 }.isStale)
        let slow = cooling { $0.metricsInterval = 900; $0.lastMetrics = now.addingTimeInterval(-20 * 60) }
        check("900s 节奏下 20 分钟提示", slow.isStale)
        check("慢节奏阈值随之放大", abs(slow.threshold - 1080) < 1)

        // 7) 未启用性能采样时用探测兜底
        let byProbe = cooling { $0.metricsEnabled = false; $0.lastProbe = now.addingTimeInterval(-12 * 60) }
        check("关闭采样改用探测时钟", byProbe.isStale && byProbe.source == "探测数据")
        check("探测兜底阈值含熔断倍率",
              !cooling { $0.metricsEnabled = false
                         $0.baseInterval = 900
                         $0.lastProbe = now.addingTimeInterval(-12 * 60) }.isStale)

        // 8) 确定性：同一输入两次求值完全一致（UI 不会因抖动闪屏）
        check("纯函数求值确定", cooling() == cooling())
        check("正在检查也不改变判定", cooling { $0.checking = true }.isStale)

        print(String(repeating: "-", count: 74))
        print("结果: \(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}
