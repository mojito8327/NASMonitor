import Foundation

// MARK: - 主机清单只读命令

/// NASMonitor --inventory
/// 只跑一次低频只读 SSH 体检，把卷 / 阵列 / 物理盘 / 监听端口原样打印出来。
/// 不发起分层探测、不写 UserDefaults、不修改任何服务配置。
enum InventoryCLI {
    static func run() async {
        let cfg = RunConfig(Config.shared)
        let pw = CredentialStore.get(CredentialStore.Key.sudoPassword)
        print("NASMonitor 主机清单（只读）· 目标 \(cfg.host) · \(Date())")
        print(String(repeating: "-", count: 74))
        let r = await Engine.diskCheck(cfg,
                                       useSudo: Config.shared.useSudo && !pw.isEmpty,
                                       sudoPassword: pw)
        guard r.reachable else {
            print("SSH 不可用：\(r.rawHint)")
            return
        }
        print("运行: \(r.uptime) · 持续 D 状态进程: \(r.dStateCount)")
        print("\n▸ 数据阵列（/proc/mdstat，动态枚举）")
        for a in r.arrays {
            print("  \(a.name): \(a.healthy ? "正常" : "降级")  \(a.detail)")
        }
        if r.arrays.isEmpty { print("  （无）") }
        print("\n▸ 卷（df -kP，动态枚举）")
        for v in r.volumes {
            print("  \(v.mount): \(v.used)/\(v.total) 已用 \(v.percent)%  剩 \(v.free)")
        }
        if r.volumes.isEmpty { print("  （无）") }
        print("\n▸ 物理整盘（/sys/block，动态枚举）")
        for d in r.physicalDisks { print("  \(d.name): \(d.size)  \(d.model)") }
        if r.physicalDisks.isEmpty { print("  （无）") }
        print("\n▸ 对外 TCP 监听端口（只读，供服务发现）")
        print("  \(r.listeningPorts.map(String.init).joined(separator: ", "))")
        let cat = ServiceCatalog.shared
        let outcome = ServiceCatalog.evaluate(services: cat.snapshot,
                                              observed: r.listeningPorts,
                                              ignored: cat.ignoredPorts,
                                              autoAdopt: cat.autoAdopt)
        print("\n▸ 与当前服务目录比对（不写入配置）")
        print("  已配置 \(cat.snapshot.count) 个服务 · 未监听 \(outcome.missingKeys.count) 个"
              + " · 新端口候选 \(outcome.candidates.count) 个")
        if !outcome.candidates.isEmpty {
            print("  候选: \(outcome.candidates.map(String.init).joined(separator: ", "))")
        }
        print("\n  \(r.rawHint)")
    }
}

/// NASMonitor --services
enum ServicesCLI {
    static func run() {
        let c = ServiceCatalog.shared
        print("NASMonitor 服务目录 · \(Date())")
        print(String(repeating: "-", count: 74))
        for s in c.snapshot {
            let flag = c.missingKeys.contains(s.key) ? "  [未监听]" : ""
            print("  \(s.name)(\(s.key))  :\(s.port)  "
                  + "\(s.critical ? "关键" : "非关键")  \(s.origin.rawValue)\(flag)")
            print("       网页: \(ServiceLinks.display(spec: s, host: Config.shared.effectiveHost))")
        }
        print("自动纳入新端口: \(c.autoAdopt ? "开启" : "关闭")")
        print("候选新端口: \(c.discovered.isEmpty ? "无" : c.discovered.map(String.init).joined(separator: ", "))")
        print("忽略端口: \(c.ignoredPorts.sorted().isEmpty ? "无" : c.ignoredPorts.sorted().map(String.init).joined(separator: ", "))")
        if let t = c.lastObserved { print("最近清单采集: \(t)") }
        print("共 \(ServiceCatalog.systemPorts.count) 个系统端口不进候选清单。")
    }
}

// MARK: - 纯内存自检

/// NASMonitor --services-selftest
/// 全部在内存里跑：不建连接、不读 UserDefaults、不改 GUI 的真实服务配置。
/// 用 2026-11-08 真机采集到的 df / mdstat / ss 输出做回归样本。
enum ServiceCatalogSelfTest {
    static func run() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "✓" : "✗") \(name)")
            if ok { pass += 1 } else { fail += 1 }
        }

        print("NASMonitor 动态清单 / 服务目录自检 · 纯内存 · \(Date())")
        print(String(repeating: "-", count: 74))

        // ---------- 1. 卷：真实 df -kP 输出（含 /volume3 的重复 bind 挂载） ----------
        let df = """
        Filesystem             1024-blocks       Used  Available Capacity Mounted on
        /dev/md0                   2384568    1506384     759400      67% /
        devtmpfs                   1841768          0    1841768       0% /dev
        tmpfs                      1951188          4    1951184       1% /dev/shm
        /dev/mapper/cachedev_1  3746108684   95039408 3651069276       3% /volume2
        /dev/mapper/cachedev_0 11245500828 3079125368 8166375460      28% /volume3
        /dev/mapper/cachedev_0 11245500828 3079125368 8166375460      28% /volume3/@appdata/ContainerManager/all_shares/docker
        /dev/mapper/cachedev_2  2808426764 2125840840  682585924      76% /volume1
        /dev/mapper/cachedev_2  2808426764 2125840840  682585924      76% /volume3/@appdata/ContainerManager/all_shares/media
        """
        let vols = Engine.parseDF(df)
        check("全量 df 解析出 3 个卷（原来是写死的 2 个）", vols.count == 3)
        check("新插入盘建出的 /volume1 被识别", vols.contains { $0.mount == "/volume1" })
        check("卷按自然序排列", vols.map(\.mount) == ["/volume1", "/volume2", "/volume3"])
        check("bind 挂载 / @appdata 子卷被排除",
              !vols.contains { $0.mount.contains("@appdata") })
        check("同一卷的重复行只保留一条", Set(vols.map(\.mount)).count == 3)
        check("/volume1 使用率读成 76%", vols.first?.percent == 76)
        check("根分区与 tmpfs 不进卷列表", !vols.contains { $0.mount == "/" })
        check("挂载点判定排除根分区", !Engine.isVolumeMount("/"))
        check("挂载点判定排除子目录", !Engine.isVolumeMount("/volume3/@appdata/x"))
        check("挂载点判定接受外置盘", Engine.isVolumeMount("/volumeUSB1"))
        check("挂载点判定拒绝裸 /volume", !Engine.isVolumeMount("/volume"))
        check("空 df 输出不产生卷", Engine.parseDF("").isEmpty)

        // ---------- 2. 阵列：真实 /proc/mdstat ----------
        let md = """
        Personalities : [raid1]
        md3 : active raid1 sdc3[0]
              2925444544 blocks super 1.2 [1/1] [U]
        md6 : active raid1 sde3[0]
              11714063360 blocks super 1.2 [1/1] [U]
        md4 : active raid1 sdd3[0]
              3902196544 blocks super 1.2 [1/1] [U]
        md1 : active raid1 sdc2[14] sde2[12] sdd2[13]
              2096128 blocks super 1.2 [12/3] [UUU_________]
        md0 : active raid1 sdc1[14] sde1[12] sdd1[13]
              2489216 blocks super 1.2 [12/3] [UUU_________]
        unused devices: <none>
        """
        let arrays = Engine.parseMDStat(md)
        check("动态解析出 3 个数据阵列", arrays.count == 3)
        check("新增盘的 md3 被识别", arrays.contains { $0.name == "md3" })
        check("md0 / md1 系统分区仍跳过",
              !arrays.contains { $0.name == "md0" || $0.name == "md1" })
        check("单盘 raid1 [1/1] [U] 判为正常", arrays.allSatisfy(\.healthy))

        // ---------- 3. 物理盘：/sys/block ----------
        let block = """
        sdc|5860533168|DT01ACA300
        sdd|7814037168|DT02ABA400
        sde|23437770752|HUH721212ALE601
        nvme0n1|1953525168|SN850X

        ||
        """
        let disks = Engine.parseBlock(block)
        check("物理盘解析出 4 块", disks.count == 4)
        check("NVMe 盘不会被 /dev/sd[a-z] 漏掉", disks.contains { $0.name == "nvme0n1" })
        check("容量按 512 字节扇区换算",
              disks.first { $0.name == "sde" }?.size.hasSuffix("T") == true)
        check("型号原样保留", disks.first { $0.name == "sdc" }?.model == "DT01ACA300")
        check("空行 / 无名字行被丢弃", Engine.parseBlock(block + "\nsdf||\n").count == 5)
        check("无容量时显示 — 而非推算值",
              Engine.parseBlock("sdx|0|UNKNOWN").first?.size == "—")

        // ---------- 4. 监听端口 ----------
        let ports = Engine.parseListeningPorts("22\n9090\n9090\n70000\n-1\nabc\n65535\n")
        check("端口去重并排序", ports == [22, 9090, 65535])
        check("越界与非法端口被丢弃", !ports.contains(70000) && !ports.contains(-1))

        // ---------- 5. 服务目录纯函数 ----------
        let base = Services.defaults
        let observed = [22, 80, 139, 443, 445, 5000, 5001, 5357, 7890,
                        8000, 8080, 8091, 8096, 9090, 51413]
        let o1 = ServiceCatalog.evaluate(services: base, observed: observed,
                                         ignored: [], autoAdopt: false)
        check("候选不含系统端口 5001 / 5357",
              !o1.candidates.contains(5001) && !o1.candidates.contains(5357))
        check("候选不含已配置端口 8096", !o1.candidates.contains(8096))
        check("候选含新出现的端口 7890", o1.candidates.contains(7890))
        check("候选全部 ≥1024", o1.candidates.allSatisfy { $0 >= 1024 })
        check("未开启自动纳入时不生成服务", o1.adopted.isEmpty)
        check("默认服务全部在监听时无失效项", o1.missingKeys.isEmpty)
        check("候选按端口号升序", o1.candidates == o1.candidates.sorted())

        let o2 = ServiceCatalog.evaluate(services: base,
                                         observed: observed.filter { $0 != 9090 },
                                         ignored: [], autoAdopt: false)
        check("停掉 mihomo 被标记失效", o2.missingKeys == ["mihomo"])
        check("手工确认的服务不会被自动移除", o2.removedKeys.isEmpty)

        let o3 = ServiceCatalog.evaluate(services: base, observed: observed,
                                         ignored: [], autoAdopt: true)
        check("自动纳入会生成服务", !o3.adopted.isEmpty)
        check("自动纳入的服务不计关键告警", o3.adopted.allSatisfy { !$0.critical })
        check("自动纳入的服务 origin=discovered",
              o3.adopted.allSatisfy { $0.origin == .discovered })
        check("自动纳入的 key / port 一一对应",
              o3.adopted.allSatisfy { $0.key == "port\($0.port)" })

        let autoSpecs = base + o3.adopted
        let o4 = ServiceCatalog.evaluate(services: autoSpecs,
                                         observed: observed.filter { $0 != 51413 },
                                         ignored: [], autoAdopt: true)
        check("自动纳入的服务端口消失后自动移除", o4.removedKeys.contains("port51413"))
        check("移除判定不波及内置服务", !o4.removedKeys.contains("mihomo"))

        let o5 = ServiceCatalog.evaluate(services: base, observed: observed,
                                         ignored: [7890, 8091], autoAdopt: false)
        check("忽略端口不再进入候选",
              !o5.candidates.contains(7890) && !o5.candidates.contains(8091))

        // ---------- 6. 探针 → 服务动态归属 ----------
        let belongs = ServiceCatalog.probeBelongs
        check("tcp.ssh 属于 ssh", belongs("tcp.ssh", "ssh"))
        check("stat.dsm-icon 属于 dsm", belongs("stat.dsm-icon", "dsm"))
        check("stat.dsm-cgi 属于 dsm", belongs("stat.dsm-cgi", "dsm"))
        check("sto.dsm 属于 dsm", belongs("sto.dsm", "dsm"))
        check("stat.amane 属于 amane", belongs("stat.amane", "amane"))
        check("stat.qb 属于 qb", belongs("stat.qb", "qb"))
        check("sto.jf 属于 jf", belongs("sto.jf", "jf"))
        check("tcp.mihomo 属于 mihomo", belongs("tcp.mihomo", "mihomo"))
        check("新服务 tcp.port9443 自动归属", belongs("tcp.port9443", "port9443"))
        check("stat.dsm-icon 不串到 dsm2", !belongs("stat.dsm-icon", "dsm2"))
        check("tcp.dsm 不串到 dsm2", !belongs("tcp.dsm", "dsm2"))
        check("disk 不属于任何服务", !belongs("disk", "dsm"))

        // ---------- 7. 旧数据解码兼容 ----------
        var rep = DiskReport()
        rep.reachable = true
        if let data = try? JSONEncoder().encode(rep),
           var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj.removeValue(forKey: "physicalDisks")
            obj.removeValue(forKey: "listeningPorts")
            if let legacy = try? JSONSerialization.data(withJSONObject: obj),
               let decoded = try? JSONDecoder().decode(DiskReport.self, from: legacy) {
                check("旧体检报告缺新字段仍可解码",
                      decoded.reachable && decoded.physicalDisks.isEmpty
                      && decoded.listeningPorts.isEmpty)
            } else { check("旧体检报告缺新字段仍可解码", false) }
        } else { check("旧体检报告缺新字段仍可解码", false) }

        let legacyService = #"[{"key":"ssh","name":"SSH","port":22,"critical":true}]"#
        if let data = legacyService.data(using: .utf8),
           let arr = try? JSONDecoder().decode([ServiceSpec].self, from: data),
           let s = arr.first {
            check("旧服务条目缺 origin 仍可解码", s.origin == .builtIn && s.port == 22)
        } else { check("旧服务条目缺 origin 仍可解码", false) }

        // ---------- 8. 服务列表本身可配置 ----------
        check("默认服务 6 个", base.count == 6)
        check("关键服务 5 个", Services.critical(base).count == 5)
        check("删掉一个服务后关键服务数跟着变",
              Services.critical(base.filter { $0.key != "ssh" }).count == 4)
        check("深探针 key 集合只覆盖内置四项", Services.deepProbeKeys.count == 4)

        // ---------- 9. 服务名称自定义（纯函数，不读写 UserDefaults） ----------
        let port8091 = ServiceSpec(key: "port8091", name: "Web 8091", port: 8091,
                                   critical: false, origin: .discovered)
        let renamed = ServiceCatalog.renamed(port8091, to: "  我的影音库  ")
        check("改名去掉首尾空白", renamed?.name == "我的影音库")
        check("改名保留服务 key（探针 ID 不失效）", renamed?.key == "port8091")
        check("改名保留端口", renamed?.port == 8091)
        check("改名不重置关键标记", renamed?.critical == false)
        check("改名不改变来源 / 自动移除规则", renamed?.origin == .discovered)
        check("改名后 tcp.port8091 仍归属该服务",
              belongs("tcp.port8091", renamed?.key ?? ""))
        check("空名称与全空白名称被拒绝",
              ServiceCatalog.renamed(port8091, to: "   ") == nil)
        check("超过 40 字的名称被拒绝",
              ServiceCatalog.renamed(port8091,
                                     to: String(repeating: "名", count: 41)) == nil)
        check("恰好 40 字的名称可用",
              ServiceCatalog.renamed(port8091,
                                     to: String(repeating: "名", count: 40))?.name.count == 40)
        check("名称清洗后不改动原条目", port8091.name == "Web 8091")
        check("默认候选名称未丢失", ServiceCatalog.wellKnown[8096] == "Jellyfin")

        print(String(repeating: "-", count: 74))
        print("结果: \(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}
