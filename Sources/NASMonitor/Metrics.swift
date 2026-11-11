import Foundation
import AppKit

// MARK: - 整机性能指标采集
//
// 所有指标都只代表「整台 NAS」，不接受任何单个服务/容器的速率冒充整机数据。
// 没有免认证的 HTTP 接口，按「多通道、按字段补齐、失败退避」工作：
//
//   1) SSH /proc        一次连接内两次采样算出 CPU、网卡速率与**磁盘读写吞吐**。
//                       网卡只累加 /sys/class/net 下带 device 链接的物理接口；
//                       磁盘只累加 /proc/diskstats 里的物理整盘，排除分区、md、dm、
//                       loop 等，避免与阵列/分区重复计数。
//                       事故后 sshd 一度只 accept 不发 banner，现已恢复；再挂掉会自动退避。
//   2) DSM SID          SYNO.API.Auth -> SYNO.Core.System.Utilization，官方整机指标。
//                       同样过滤虚拟接口。当前登录返回 407（验证码/自动封锁），解除后自动启用。
//
// 两个通道都不可用时，CPU / 内存 / 网络一律显示「—」并说明原因，绝不回退到
// qBittorrent 等单服务速率，也不用示例值或推算值写进真实历史。

struct MetricsConfig: Sendable {
    var host: String
    var timeout: Double
    var sshEnabled: Bool
    var sshUser: String
    var dsmUser: String
    var dsmPassword: String

    init(_ c: Config) {
        host = c.effectiveHost
        timeout = max(2, min(20, c.timeout))
        sshEnabled = c.sshEnabled
        sshUser = c.sshUser
        dsmUser = CredentialStore.get(CredentialStore.Key.dsmUser)
        dsmPassword = CredentialStore.get(CredentialStore.Key.dsmPassword)
    }
}

// MARK: - 失败退避

final class Backoff {
    static let shared = Backoff()
    private let lock = NSLock()
    private var until: [String: Date] = [:]
    private var fails: [String: Int] = [:]

    func blocked(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = until[key] else { return false }
        return Date() < t
    }

    func remaining(_ key: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return max(0, (until[key] ?? Date()).timeIntervalSinceNow)
    }

    func succeeded(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        until.removeValue(forKey: key)
        fails.removeValue(forKey: key)
    }

    func failed(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        let n = min((fails[key] ?? 0) + 1, 6)
        fails[key] = n
        // 60s -> 102s -> 173s -> 295s -> 上限 5 分钟
        until[key] = Date().addingTimeInterval(min(60 * pow(1.7, Double(n - 1)), 300))
    }
}

// MARK: - curl 通道（支持 cookie jar，密码走 stdin 不进 argv）

struct CurlResp {
    var status: Int = 0
    var body: String = ""
}

enum Curl {
    private static let marker = "__NM__"

    static func request(_ url: String, form: [String: String]? = nil,
                        headers: [String: String] = [:],
                        jar: URL? = nil, writeJar: Bool = false,
                        timeout: Double) async -> CurlResp {
        let t = max(2, Int(timeout.rounded(.up)))
        var args = ["-s", "--noproxy", "*", "-k",
                    "--max-time", "\(t)", "--connect-timeout", "\(t)",
                    "-A", "NASMonitor/1.0",
                    "-w", "\n\(marker)%{http_code}"]
        if let jar {
            ensureFile(jar)
            args += ["-b", jar.path]
            if writeJar { args += ["-c", jar.path] }
        }
        for (k, v) in headers { args += ["-H", "\(k): \(v)"] }
        var stdin: String?
        if let form {
            args += ["-X", "POST", "--data-binary", "@-"]
            stdin = encode(form)
        }
        args.append(url)

        // curl 走 Proc.run 的子进程通道：上层 Task 被取消时子进程会被 terminate，
        // 不会留下仍在连接 NAS 的孤儿 curl。
        let r = await Proc.run(path: "/usr/bin/curl", args: args,
                               stdin: stdin, timeout: timeout + 1.5)
        guard let range = r.stdout.range(of: marker, options: .backwards) else {
            return CurlResp()
        }
        let code = Int(String(r.stdout[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return CurlResp(status: code,
                        body: String(r.stdout[..<range.lowerBound])
                            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func encode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return form.map { k, v in
            let e = { (s: String) -> String in
                (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s)
                    .replacingOccurrences(of: "%20", with: "+")
            }
            return "\(e(k))=\(e(v))"
        }.joined(separator: "&")
    }

    private static func ensureFile(_ url: URL) {
        AtomicFileWriter.ensureFile(url)
    }
}

// MARK: - 采集器

enum MetricsCollector {

    static func storeDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NASMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 标准 async：SSH / DSM 两条通道各自等待外部进程，取消信号会一路传到子进程。
    /// 返回一条字段可能不全、但来源明确的样本。
    static func collect(_ c: MetricsConfig) async -> MetricsSample {
        var s = MetricsSample()
        var notes: [String] = []

        // 1) SSH：整机 CPU / 内存 / 物理网卡速率 / 物理整盘读写吞吐
        if c.sshEnabled, !Backoff.shared.blocked("ssh") {
            if let v = await ssh(c) {
                s.cpu = v.cpu
                s.memUsed = v.memUsed
                s.memTotal = v.memTotal
                s.rx = v.rx
                s.tx = v.tx
                s.diskRead = v.diskRead
                s.diskWrite = v.diskWrite
                s.cpuSource = "整机 · SSH /proc"
                s.netSource = "整机 · SSH /proc"
                if v.diskRead != nil { s.diskSource = "整机 · SSH /proc/diskstats" }
                Backoff.shared.succeeded("ssh")
            } else {
                Backoff.shared.failed("ssh")
                notes.append("SSH 不可达")
            }
        } else if c.sshEnabled {
            notes.append("SSH 冷却中")
        }

        // 2) DSM：补齐缺失的整机字段（同样只取整机接口）
        if (s.cpu == nil || s.memPercent == nil || s.rx == nil),
           !c.dsmUser.isEmpty, !c.dsmPassword.isEmpty,
           !Backoff.shared.blocked("dsm") {
            if let v = await dsm(c) {
                if s.cpu == nil, let cpu = v.cpu { s.cpu = cpu; s.cpuSource = "整机 · DSM" }
                if s.memPercent == nil, let u = v.memUsed, let t = v.memTotal {
                    s.memUsed = u; s.memTotal = t
                }
                if s.rx == nil, let rx = v.rx, let tx = v.tx {
                    s.rx = rx; s.tx = tx; s.netSource = "整机 · DSM"
                }
                Backoff.shared.succeeded("dsm")
            } else {
                Backoff.shared.failed("dsm")
                notes.append(dsmLastNote.isEmpty ? "DSM 登录失败" : dsmLastNote)
            }
        }

        // 绝不回退到 qBittorrent 等单服务速率：那不是整机数据。
        if s.cpu == nil || s.memPercent == nil {
            notes.append("整机 CPU/内存需 SSH 或 DSM 可用")
        }
        if s.rx == nil {
            notes.append("整机网络需 SSH 或 DSM 可用（不接受单服务速率）")
        }
        if s.diskRead == nil {
            notes.append("磁盘吞吐需 SSH /proc/diskstats 可用")
        }
        s.note = Array(NSOrderedSet(array: notes)).compactMap { $0 as? String }
            .joined(separator: " · ")
        return s
    }

    // MARK: DSM

    private static let sid = Locked<String>("")
    private static let sidExpiry = Locked<Date>(.distantPast)
    private static let dsmNote = Locked<String>("")
    private static var dsmLastNote: String { dsmNote.get() }

    private static func dsm(_ c: MetricsConfig) async -> (cpu: Double?, memUsed: Double?,
                                                          memTotal: Double?, rx: Double?, tx: Double?)? {
        var token = sid.get()
        if token.isEmpty || Date() > sidExpiry.get() {
            let entry = "http://\(c.host):5000/webapi/entry.cgi"
            let login = await Curl.request(entry, form: [
                "api": "SYNO.API.Auth", "version": "6", "method": "login",
                "account": c.dsmUser, "passwd": c.dsmPassword,
                "session": "Core", "format": "sid",
            ], timeout: max(c.timeout, 8))
            guard let root = json(login.body),
                  let data = root["data"] as? [String: Any],
                  let newSID = data["sid"] as? String, !newSID.isEmpty else {
                let err = (json(login.body)?["error"] as? [String: Any])
                    .flatMap { num($0["code"]) }.map { Int($0) } ?? 0
                dsmNote.set(err == 407
                    ? "DSM 要求验证码/自动封锁 (407)"
                    : "DSM 登录失败 (code \(err))")
                sid.set("")
                return nil
            }
            token = newSID
            sid.set(token)
            sidExpiry.set(Date().addingTimeInterval(20 * 60))  // SID 20 分钟后重登
        }

        let url = "http://\(c.host):5000/webapi/entry.cgi?api=SYNO.Core.System.Utilization"
            + "&version=1&method=get&_sid=\(token)"
        let r = await Curl.request(url, timeout: c.timeout)
        guard r.status == 200,
              let root = json(r.body),
              (root["success"] as? Bool) == true,
              let data = root["data"] as? [String: Any] else {
            sid.set("")   // SID 失效，下轮重登
            dsmNote.set("DSM Utilization 读取失败")
            return nil
        }

        var cpu: Double?
        if let cc = data["cpu"] as? [String: Any] {
            if let real = num(cc["real_usage"]) {
                cpu = real
            } else {
                let parts = ["user_load", "system_load", "other_load"]
                    .compactMap { num(cc[$0]) }
                if !parts.isEmpty { cpu = min(100, max(0, parts.reduce(0, +))) }
            }
        }

        var memUsed: Double?, memTotal: Double?
        if let mm = data["memory"] as? [String: Any] {
            if let total = num(mm["total_real"]), total > 0 {
                memTotal = total * 1024
                let avail = num(mm["avail_real"]) ?? 0
                memUsed = max(0, total - avail) * 1024
            } else if let size = num(mm["memory_size"]), let pct = num(mm["real_usage"]) {
                memTotal = size * 1024 * 1024
                memUsed = memTotal! * pct / 100
            }
        }

        // 只累加整机物理网卡：排除 docker 网桥 / veth / sit / lo 等虚拟接口，
        // 并且当存在 bond 时只取 bond，避免与 slave 成员重复计数。
        var rx: Double?, tx: Double?
        if let nets = data["network"] as? [[String: Any]] {
            let physical = nets.filter { isPhysicalInterface($0["device"] as? String ?? "") }
            let bonds = physical.filter { isBond($0["device"] as? String ?? "") }
            let chosen = bonds.isEmpty ? physical : bonds
            if !chosen.isEmpty {
                var sumRx = 0.0, sumTx = 0.0
                for n in chosen {
                    sumRx += num(n["rx"]) ?? 0
                    sumTx += num(n["tx"]) ?? 0
                }
                rx = sumRx; tx = sumTx
            }
        }

        // 通道通了但一个有效字段都没解析到，说明 DSM 版本返回结构不同，按失败退避
        guard cpu != nil || memTotal != nil || rx != nil else {
            sid.set("")
            dsmNote.set("DSM Utilization 字段未识别")
            return nil
        }
        dsmNote.set("")
        return (cpu, memUsed, memTotal, rx, tx)
    }

    /// 整机物理网卡判定：与 SSH 脚本里 /sys/class/net/*/device 的口径保持一致。
    private static func isPhysicalInterface(_ dev: String) -> Bool {
        let d = dev.lowercased()
        guard !d.isEmpty, d != "lo" else { return false }
        let virtual = ["veth", "docker", "br-", "virbr", "tun", "tap", "sit",
                       "dummy", "ifb", "vmnet", "vnet", "wg", "tailscale", "zt", "ovs-system"]
        if virtual.contains(where: { d.hasPrefix($0) }) { return false }
        return ["eth", "en", "bond", "ovs_", "wlan", "wl"].contains { d.hasPrefix($0) }
    }

    private static func isBond(_ dev: String) -> Bool {
        let d = dev.lowercased()
        return d.hasPrefix("bond") || d.hasPrefix("ovs_bond")
    }

    // MARK: SSH /proc

    private static func ssh(_ c: MetricsConfig) async -> (cpu: Double, memUsed: Double,
                                                          memTotal: Double, rx: Double, tx: Double,
                                                          diskRead: Double?, diskWrite: Double?)? {
        // PHY 只收集 /sys/class/net 下带 device 链接的物理网卡（本机实测仅 eth0）。
        // 旧版把 docker0 / docker* / sit0 一起累加，容器内部流量会严重污染整机读数。
        // 磁盘同理：只取物理整盘（sda / nvme0n1 / mmcblk0），跳过分区、md 阵列、
        // dm、loop 等，否则同一份 I/O 会被整盘 + 分区 + 阵列重复累计三次。
        let script = """
        PHY=""
        for d in /sys/class/net/*; do
          n=${d##*/}
          if [ -e "$d/device" ]; then PHY="$PHY $n:"; fi
        done
        probe() {
          awk '/^cpu /{for(i=2;i<=9;i++) printf "%s ", $i; print ""}' /proc/stat
          awk -v p="$PHY" 'BEGIN{n=split(p,a,/[[:space:]]+/);k=0;for(i=1;i<=n;i++)if(a[i]!=""){ok[a[i]]=1;k++};all=(k==0)} NR>2 {x=$1; if(x=="lo:") next; if(all || (x in ok)){rx+=$2;tx+=$10}} END{print rx+0, tx+0}' /proc/net/dev
          awk '{print $1}' /proc/uptime
          awk '{n=$3; if(n ~ /^(loop|ram|zram|dm-|md|nbd|drbd|zd)/) next; if(n ~ /^nvme[0-9]+n[0-9]+p[0-9]+$/) next; if(n ~ /^mmcblk[0-9]+p[0-9]+$/) next; if(n ~ /^(sd|hd|vd|xvd)[a-z]+[0-9]+$/) next; if(n ~ /^(sd|hd|vd|xvd|nvme|mmcblk)/) {r+=$6; w+=$10}} END{print r+0, w+0}' /proc/diskstats
        }
        echo '###S1'
        probe
        sleep 1
        echo '###S2'
        probe
        echo '###MEM'
        grep -E '^(MemTotal|MemAvailable):' /proc/meminfo
        echo '###END'
        """
        let out = await SSH.run(user: c.sshUser, host: c.host, script: script,
                                timeout: c.timeout + 4)
        guard !out.timedOut, out.exitCode == 0,
              out.text.contains("###S1"), out.text.contains("###S2") else { return nil }

        let lines = out.text.split(separator: "\n").map(String.init)
        func section(_ tag: String) -> [String] {
            guard let i = lines.firstIndex(of: tag) else { return [] }
            var out: [String] = []
            for l in lines[(i + 1)...] {
                if l.hasPrefix("###") { break }
                if !l.trimmingCharacters(in: .whitespaces).isEmpty { out.append(l) }
            }
            return out
        }
        let s1 = section("###S1"), s2 = section("###S2"), mem = section("###MEM")
        guard s1.count >= 3, s2.count >= 3 else { return nil }

        func nums(_ s: String) -> [Double] {
            s.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .compactMap { Double($0) }
        }
        let c1 = nums(s1[0]), c2 = nums(s2[0])
        guard c1.count >= 5, c2.count >= 5 else { return nil }
        let t1 = c1.reduce(0, +), t2 = c2.reduce(0, +)
        let i1 = c1[3] + c1[4], i2 = c2[3] + c2[4]
        let dt = t2 - t1, di = i2 - i1
        guard dt > 0 else { return nil }
        let cpu = min(100, max(0, (1 - di / dt) * 100))

        let n1 = nums(s1[1]), n2 = nums(s2[1])
        let u1 = nums(s1[2]).first ?? 0, u2 = nums(s2[2]).first ?? 0
        let elapsed = max(0.1, u2 - u1)
        guard n1.count >= 2, n2.count >= 2 else { return nil }
        // 计数器回绕 / 主机重启时丢弃速率，避免出现负数或巨大尖峰
        let rx = n2[0] >= n1[0] ? (n2[0] - n1[0]) / elapsed : 0
        let tx = n2[1] >= n1[1] ? (n2[1] - n1[1]) / elapsed : 0

        // /proc/diskstats 的第 6 / 10 列是累计读 / 写扇区数，每扇区 512 字节。
        // 只在新旧两次都取到整盘计数、且计数器未回绕时才给出吞吐；否则留 nil 显示「—」。
        var diskRead: Double?, diskWrite: Double?
        let k1 = s1.count >= 4 ? nums(s1[3]) : []
        let k2 = s2.count >= 4 ? nums(s2[3]) : []
        if k1.count >= 2, k2.count >= 2, k2[0] >= k1[0], k2[1] >= k1[1] {
            diskRead = (k2[0] - k1[0]) * 512 / elapsed
            diskWrite = (k2[1] - k1[1]) * 512 / elapsed
        }

        var total = 0.0, avail = 0.0
        for line in mem {
            let parts = nums(line.replacingOccurrences(of: ":", with: " "))
            guard let v = parts.first else { continue }
            if line.hasPrefix("MemTotal") { total = v * 1024 }
            if line.hasPrefix("MemAvailable") { avail = v * 1024 }
        }
        guard total > 0 else { return nil }
        return (cpu, max(0, total - avail), total, rx, tx, diskRead, diskWrite)
    }

    // MARK: - JSON 小工具

    private static func json(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return o as? [String: Any]
    }

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - 命令行验证

enum MetricsCLI {
    static func run() async {
        let args = CommandLine.arguments
        var c = MetricsConfig(Config.shared)
        // 排障用：--no-ssh 可单独验证 DSM 整机通道；两者都关时应全部显示「—」
        if args.contains("--no-ssh") { c.sshEnabled = false }
        if args.contains("--no-dsm") { c.dsmUser = ""; c.dsmPassword = "" }
        print("整机性能采集 · 目标 \(c.host) · \(Date())")
        print("  通道  DSM=\(!c.dsmUser.isEmpty && !c.dsmPassword.isEmpty)"
              + "  SSH=\(c.sshEnabled ? c.sshUser : "关闭")")
        let s = await MetricsCollector.collect(c)
        print("  CPU      \(MetricFormat.cpu(s.cpu))  [\(s.cpuSource.isEmpty ? "无数据" : s.cpuSource)]")
        print("  内存     \(MetricFormat.bytes(s.memUsed)) / \(MetricFormat.bytes(s.memTotal))"
              + "  (\(s.memPercent.map { String(format: "%.0f%%", $0) } ?? "—"))")
        print("  下行     \(MetricFormat.rate(s.rx))  [\(s.netSource.isEmpty ? "无数据" : s.netSource)]")
        print("  上行     \(MetricFormat.rate(s.tx))")
        print("  磁盘读   \(MetricFormat.rate(s.diskRead))  [\(s.diskSource.isEmpty ? "无数据" : s.diskSource)]")
        print("  磁盘写   \(MetricFormat.rate(s.diskWrite))")
        print("  说明     \(s.note.isEmpty ? "全部通道正常" : s.note)")
    }
}
