import Foundation
import Darwin

// MARK: - 传输模式
//
// macOS 15+ 的「本地网络」权限会拦截第三方进程直连局域网，
// 表现为 connect() 立刻返回 EHOSTUNREACH (65)，而系统自带的 nc / curl / ssh 不受限。
// 因此检测到这类拦截时自动切换到系统工具通道（兼容模式），保证开箱即用。

final class Transport {
    static let shared = Transport()
    private let state = Locked<Bool>(false)
    private init() {}

    var usesExternal: Bool { state.get() }
    func switchToExternal() { state.set(true) }
    func reset() { state.set(false) }
}

final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

enum ProbeQueues {
    /// 只用于把「必然阻塞的 BSD socket / 外部进程等待」隔离出 Swift 协作线程池。
    /// Swift Concurrency 的协作线程不能被同步阻塞，所以这些操作走 GCD，
    /// 上层通过 continuation / Task 取消与之衔接。
    static let work = DispatchQueue(label: "com.github.mojito8327.nasmon.work", qos: .utility, attributes: .concurrent)
}

// MARK: - 一次性 continuation 门闩
//
// withTaskCancellationHandler 的 onCancel 与 GCD 完成回调可能竞态到达，
// 也可能在 continuation 安装之前就取消。这个门闩保证只 resume 一次，并缓存早期结果。

private final class OnceResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    private var settled = false
    private var pending: T?

    func install(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        if settled, let v = pending {
            lock.unlock()
            c.resume(returning: v)
            return
        }
        cont = c
        lock.unlock()
    }

    func resume(_ v: T) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        if let c = cont {
            cont = nil
            lock.unlock()
            c.resume(returning: v)
        } else {
            pending = v
            lock.unlock()
        }
    }
}

// MARK: - 通用子进程执行（async + Task 取消联动）
//
// 用临时文件代替 Pipe，规避管道满 / EOF 死锁。
// 2026-11-08 并发重构：
//   - 等待外部进程放在 GCD 队列，不占用 Swift 协作线程池；
//   - withTaskCancellationHandler 在 Task 被取消时立即 p.terminate()，
//     杜绝「上层已放弃、ssh/curl 仍在后台跑」的孤儿进程；
//   - 临时文件在 gate 中清理，取消路径也一样清理。

struct ProcResult {
    var stdout: String = ""
    var stderr: String = ""
    var exitCode: Int32 = -1
    var timedOut: Bool = false
}

private final class ProcGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<ProcResult, Never>?
    private var settled = false
    private var pending: ProcResult?
    private var cleaned = false
    /// 取消标记必须在锁内先于 terminate/settle 置位：GCD 等待线程看到子进程
    /// 被 terminate 后会立刻走 finish()，若不先标记，两条路径会并发争抢 settle，
    /// 取消结果偶尔会被「正常结束」的空结果覆盖（--cancel-selftest 偶发失败的根因）。
    private var cancelled = false

    let process: Process
    let urls: [URL]

    init(process: Process, urls: [URL]) {
        self.process = process
        self.urls = urls
    }

    func install(_ c: CheckedContinuation<ProcResult, Never>) {
        lock.lock()
        if settled, let v = pending {
            lock.unlock()
            c.resume(returning: v)
            return
        }
        cont = c
        lock.unlock()
    }

    private func settle(_ v: ProcResult) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        if let c = cont {
            cont = nil
            lock.unlock()
            c.resume(returning: v)
        } else {
            pending = v
            lock.unlock()
        }
    }

    private func cleanup() {
        // cancel() 与 finish() 可能从不同线程几乎同时到达，closeFile / removeItem
        // 必须幂等，否则会对同一个 fd 重复关闭。
        lock.lock()
        if cleaned { lock.unlock(); return }
        cleaned = true
        lock.unlock()
        (process.standardOutput as? FileHandle)?.closeFile()
        (process.standardError as? FileHandle)?.closeFile()
        (process.standardInput as? FileHandle)?.closeFile()
        for u in urls { try? FileManager.default.removeItem(at: u) }
    }

    /// Task 取消：立即终止子进程并回收资源。
    func cancel() {
        lock.lock()
        if settled || cancelled { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
        cleanup()
        settle(ProcResult(stderr: "Task 已取消，子进程已终止", timedOut: true))
    }

    /// 正常结束 / 超时：读回三个临时文件再交付。
    func finish(timedOut: Bool) {
        // 取消结果一律优先。terminate() 会让另一个线程的 waitUntilExit 立即返回，
        // 若这里继续 settle，就会和 cancel() 竞态；直接交给 cancel() 结算即可，
        // 也避免在 cleanup() 之后再去读可能已被删除的临时文件。
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { return }
        let out = (try? Data(contentsOf: urls[0])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let err = (try? Data(contentsOf: urls[1])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let r = ProcResult(stdout: out, stderr: err,
                           exitCode: process.isRunning ? -1 : process.terminationStatus,
                           timedOut: timedOut)
        cleanup()
        settle(r)
    }
}

enum Proc {
    static func run(path: String, args: [String], stdin: String? = nil,
                    timeout: TimeInterval) async -> ProcResult {
        let tag = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory
        let outURL = dir.appendingPathComponent("nm-\(tag).out")
        let errURL = dir.appendingPathComponent("nm-\(tag).err")
        let inURL  = dir.appendingPathComponent("nm-\(tag).in")
        let urls = [outURL, errURL, inURL]
        let fm = FileManager.default
        for u in urls { fm.createFile(atPath: u.path, contents: nil) }
        if let s = stdin { try? Data(s.utf8).write(to: inURL) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do {
            p.standardOutput = try FileHandle(forWritingTo: outURL)
            p.standardError = try FileHandle(forWritingTo: errURL)
            p.standardInput = try FileHandle(forReadingFrom: inURL)
        } catch {
            for u in urls { try? fm.removeItem(at: u) }
            return ProcResult(stderr: "文件句柄创建失败: \(error.localizedDescription)")
        }
        do { try p.run() } catch {
            for u in urls { try? fm.removeItem(at: u) }
            return ProcResult(stderr: "进程启动失败: \(error.localizedDescription)")
        }

        let gate = ProcGate(process: p, urls: urls)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<ProcResult, Never>) in
                gate.install(c)
                ProbeQueues.work.async {
                    // 这里的 semaphore 只阻塞 GCD 线程，不占用 Swift 协作线程池。
                    // 与外部进程的等待无法用 Task.sleep 表达，仍需要一次真正的 wait。
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.global(qos: .utility).async {
                        p.waitUntilExit()
                        done.signal()
                    }
                    var timedOut = false
                    if done.wait(timeout: .now() + timeout) == .timedOut {
                        timedOut = true
                        if p.isRunning { p.terminate() }
                        _ = done.wait(timeout: .now() + 1.5)
                    }
                    gate.finish(timedOut: timedOut)
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    /// 进程被强杀时 defer 来不及清理。启动时只回收「超过 1 小时」且严格匹配
    /// nm-<UUID>.(out|err|in) 的本应用残留，不碰其它进程正在写的临时文件，
    /// 也让 --footprint 的 temp_leftovers 长期判据（恒为 0）真正可用。
    @discardableResult
    static func sweepStaleTempFiles(olderThan: TimeInterval = 3600) -> Int {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        let cutoff = Date().addingTimeInterval(-max(600, olderThan))
        var removed = 0
        for name in names {
            let ns = name as NSString
            guard name.hasPrefix("nm-"),
                  ["out", "err", "in"].contains(ns.pathExtension),
                  UUID(uuidString: String(ns.deletingPathExtension.dropFirst(3))) != nil else { continue }
            let u = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: u.path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            if (try? fm.removeItem(at: u)) != nil { removed += 1 }
        }
        return removed
    }
}

// MARK: - 系统工具通道（兼容模式）

enum External {
    static func tcp(host: String, port: UInt16, timeout: TimeInterval) async -> (Bool, Int) {
        let start = Date()
        let t = max(1, Int(timeout.rounded(.up)))
        let r = await Proc.run(path: "/usr/bin/nc",
                               args: ["-z", "-G", "\(t)", "-w", "\(t)", host, "\(port)"],
                               timeout: timeout + 0.6)
        return (!r.timedOut && r.exitCode == 0, Int(Date().timeIntervalSince(start) * 1000))
    }

    /// 用 curl 发请求。--noproxy '*' 强制绕过系统代理；状态与耗时由 -w 附在输出末尾。
    static func http(_ urlString: String, method: String, headers: [String: String],
                     body: Data?, timeout: TimeInterval) async -> HTTPResp {
        let marker = "__NM__"
        let t = max(1, Int(timeout.rounded(.up)))
        var args = ["-s", "--noproxy", "*",
                    "--max-time", "\(t)", "--connect-timeout", "\(t)",
                    "-A", "NASMonitor/1.0",
                    "-w", "\n\(marker)%{http_code}\(marker)%{time_total}"]
        if method != "GET" { args += ["-X", method] }
        for (k, v) in headers { args += ["-H", "\(k): \(v)"] }
        if let b = body, !b.isEmpty { args += ["--data-binary", "@-"] }
        args.append(urlString)

        let stdin = body.flatMap { String(data: $0, encoding: .utf8) }
        let p = await Proc.run(path: "/usr/bin/curl", args: args, stdin: stdin, timeout: timeout + 1.2)

        var resp = HTTPResp()
        resp.timedOut = p.timedOut || p.exitCode == 28
        guard let range = p.stdout.range(of: marker) else {
            resp.connectionFailed = !resp.timedOut
            resp.ms = resp.timedOut ? Int(timeout * 1000) : 0
            return resp
        }
        let tail = String(p.stdout[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = tail.components(separatedBy: marker)
        resp.status = Int(parts.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        if parts.count > 1, let secs = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
            resp.ms = Int(secs * 1000)
        }
        resp.body = String(p.stdout[..<range.lowerBound])
            .trimmingCharacters(in: .newlines)
        if resp.status == 0 && !resp.timedOut { resp.connectionFailed = true }
        return resp
    }
}

// MARK: - TCP 连通性

enum Net {
    static var debug = false

    static func tcp(host: String, port: UInt16, timeout: TimeInterval) async -> (Bool, Int) {
        if Transport.shared.usesExternal {
            return await External.tcp(host: host, port: port, timeout: timeout)
        }
        let gate = OnceResume<(Bool, Int, Int32)>()
        let triple = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<(Bool, Int, Int32), Never>) in
                gate.install(c)
                // BSD socket 的 select 无法被 Task 取消打断，放到 GCD 上执行；
                // 取消时门闩立即返回失败，底层最多再跑完 ≤3s 的 select 后结果被丢弃。
                ProbeQueues.work.async {
                    gate.resume(direct(host: host, port: port, timeout: timeout))
                }
            }
        } onCancel: {
            gate.resume((false, -1, ECANCELED))
        }
        let (ok, ms, err) = triple
        if debug { print("[tcp] \(host):\(port) ok=\(ok) ms=\(ms) errno=\(err)") }
        if ok { return (true, ms) }
        // 65 EHOSTUNREACH / 51 ENETUNREACH / 1 EPERM / 13 EACCES —— 本地网络权限拦截特征
        if [65, 51, 1, 13].contains(err) {
            Transport.shared.switchToExternal()
            return await External.tcp(host: host, port: port, timeout: timeout)
        }
        return (false, ms)
    }

    private static func direct(host: String, port: UInt16, timeout: TimeInterval) -> (Bool, Int, Int32) {
        let start = Date()
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        let gai = host.withCString { getaddrinfo($0, nil, &hints, &res) }
        guard gai == 0, let info = res else { return (false, -1, Int32(gai)) }
        defer { freeaddrinfo(res) }

        var addr = sockaddr_in()
        memcpy(&addr, info.pointee.ai_addr,
               min(MemoryLayout<sockaddr_in>.size, Int(info.pointee.ai_addrlen)))
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_port = port.bigEndian

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (false, -1, errno) }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var connected = false
        var savedErrno: Int32 = 0
        let rc: Int32 = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        savedErrno = errno
        if rc == 0 {
            connected = true
        } else if savedErrno == EINPROGRESS {
            var wf = fd_set()
            _ = withUnsafeMutableBytes(of: &wf) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            setFD(fd, in: &wf)
            var tv = timeval()
            tv.tv_sec = Int(timeout)
            tv.tv_usec = __darwin_suseconds_t((timeout - Double(Int(timeout))) * 1_000_000)
            if select(fd + 1, nil, &wf, nil, &tv) > 0 {
                var e: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &len)
                connected = (e == 0)
                savedErrno = e
            }
        }
        return (connected, Int(Date().timeIntervalSince(start) * 1000), savedErrno)
    }

    private static func setFD(_ fd: Int32, in set: inout fd_set) {
        let idx = Int(fd) / 32
        let bit = Int32(1 << (Int(fd) % 32))
        withUnsafeMutablePointer(to: &set) { p in
            p.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
                bits[idx] |= bit
            }
        }
    }
}

// MARK: - HTTP

struct HTTPResp {
    var status: Int = 0
    var ms: Int = -1
    var timedOut: Bool = true
    var connectionFailed: Bool = false
    var body: String = ""
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]      // 关键：绕过系统代理，避免内网请求被劫持成 502
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 40
        c.timeoutIntervalForResource = 40
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    static func request(_ urlString: String, method: String = "GET",
                        headers: [String: String] = [:], body: Data? = nil,
                        timeout: TimeInterval) async -> HTTPResp {
        guard !Task.isCancelled else {
            return HTTPResp(status: 0, ms: 0, timedOut: false, connectionFailed: true)
        }
        if Transport.shared.usesExternal {
            return await External.http(urlString, method: method, headers: headers,
                                       body: body, timeout: timeout)
        }
        let r = await direct(urlString, method: method, headers: headers, body: body, timeout: timeout)
        // 上层 Task 已取消时不要「补发」curl 兼容通道：那会为了一个已经被放弃的
        // 请求再拉起一个子进程，正好是这次重构要消除的孤儿作业。
        guard !Task.isCancelled else { return r }
        // 明确超时说明 NAS 已经不响应了；此时再补发一条 curl 只会给堵住的连接表加负担。
        // 兼容通道只用于「直连拿不到任何响应」的网络权限 / 代理类故障。
        if r.timedOut { return r }
        if r.status > 0 { return r }
        let e = await External.http(urlString, method: method, headers: headers,
                                    body: body, timeout: timeout)
        if e.status > 0 {
            Transport.shared.switchToExternal()
            return e
        }
        return r
    }

    /// 用 withTaskGroup 让「真实请求」与「超时哨兵」竞速：
    /// 先返回者胜出，group 退出时 cancelAll() 会取消另一个子任务。
    /// 超时胜出 → URLSession.data(for:) 被取消 → 底层 URLSessionTask 立即终止；
    /// 上层 Task 被取消 → 两个子任务一起取消，同样不会留下半开连接。
    private static func direct(_ urlString: String, method: String, headers: [String: String],
                               body: Data?, timeout: TimeInterval) async -> HTTPResp {
        guard let url = URL(string: urlString) else {
            return HTTPResp(status: -1, ms: 0, timedOut: false, connectionFailed: true)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("NASMonitor/1.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body

        return await withTaskGroup(of: HTTPResp?.self) { group in
            group.addTask {
                let start = Date()
                do {
                    let (data, response) = try await session.data(for: req)
                    guard !Task.isCancelled else { return nil }
                    var r = HTTPResp()
                    r.ms = Int(Date().timeIntervalSince(start) * 1000)
                    r.status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    r.body = data.isEmpty ? "" : (String(data: data.prefix(8192), encoding: .utf8) ?? "")
                    r.timedOut = false
                    r.connectionFailed = r.status <= 0
                    return r
                } catch let e as URLError {
                    if Task.isCancelled || e.code == .cancelled { return nil }
                    var r = HTTPResp()
                    r.ms = Int(Date().timeIntervalSince(start) * 1000)
                    r.timedOut = (e.code == .timedOut)
                    r.connectionFailed = !r.timedOut
                    return r
                } catch {
                    return Task.isCancelled ? nil
                        : HTTPResp(status: -1, ms: 0, timedOut: false, connectionFailed: true)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000))
                    return HTTPResp(status: 0, ms: Int(timeout * 1000), timedOut: true)
                } catch { return nil }   // sleep 被取消 = 请求先返回了
            }

            defer { group.cancelAll() }
            for await r in group {
                if let r { return r }
            }
            return HTTPResp(status: -1, ms: 0, timedOut: false, connectionFailed: true)
        }
    }
}

// MARK: - SSH

enum SSH {
    struct Output {
        var text: String = ""
        var stderr: String = ""
        var exitCode: Int32 = -1
        var timedOut: Bool = false
    }

    static func run(user: String, host: String, script: String,
                    stdin: String? = nil, timeout: TimeInterval) async -> Output {
        let args = [
            "-o", "BatchMode=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=\(max(2, Int(timeout)))",
            "-o", "ServerAliveInterval=3",
            "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR",
            "-T", "\(user)@\(host)", "bash -s"
        ]
        // 脚本与可选密码一起从 stdin 送入，密码不出现在命令行里
        let payload = (stdin ?? "") + script
        let r = await Proc.run(path: "/usr/bin/ssh", args: args, stdin: payload, timeout: timeout)
        return Output(text: r.stdout, stderr: r.stderr,
                      exitCode: r.exitCode, timedOut: r.timedOut)
    }

    static func diskScript(useSudo: Bool) -> String {
        var s = """
        echo '###MDSTAT'
        cat /proc/mdstat 2>/dev/null
        echo '###DF'
        # 全量 df，卷路径不再写死。Swift 侧按 /volumeN 精确匹配并去重：
        # 新建卷（如 /volume1）与拔盘后卷消失都会自动反映；
        # /volume3/@appdata/... 这类 bind 挂载与 /、tmpfs 一律排除。
        df -kP 2>/dev/null
        echo '###BLOCK'
        # 运行时枚举物理整盘：写死 /dev/sd[a-z] 会漏掉 NVMe / SAS，
        # /sys/block 才是内核的权威清单，插拔盘后立刻增减。
        for b in /sys/block/*; do
          n=$(basename "$b")
          case "$n" in loop*|ram*|zram*|dm-*|md*|synoboot*) continue;; esac
          sz=$(cat "$b/size" 2>/dev/null)
          model=$(cat "$b/device/model" 2>/dev/null | tr -s ' ' | head -1)
          echo "$n|$sz|$model"
        done
        echo '###LISTEN'
        # 只读的对外 TCP 监听端口清单，供服务发现；不主动连接任何端口，
        # 也不会额外开一轮探测。本地回环地址与表头由 awk 过滤掉。
        (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | awk '$4 ~ /:/ && $4 !~ /127\\.0\\.0\\.1/ && $4 !~ /::1/ { split($4,a,":"); p=a[length(a)]; if (p+0>0) print p }' | sort -n -u
        echo '###DSTATE'
        # 连续 3 次快照（间隔 1s），只统计三次都处于 D 状态的 PID。
        # 单次 ps 快照会抓到 kworker / btrfs 线程 <1s 的正常 uninterruptible IO 等待，
        # 2026-11-08 曾因此连续误报「存储层阻塞」；真正卡死会被内核 hung task 看门狗（120s）记录。
        for i in 1 2 3; do ps -eo pid=,stat= 2>/dev/null | awk '$2 ~ /^D/ {print $1}'; if [ $i -lt 3 ]; then sleep 1; fi; done | sort | uniq -c | awk '$1 >= 3 {n++} END {print n+0}'
        echo '###UPTIME'
        cat /proc/uptime 2>/dev/null
        """
        if useSudo {
            s += """
            \necho '###DMESG'
            echo "$PW" | sudo -S -p '' dmesg 2>/dev/null | grep -iE 'SError|I/O error|WRITE DMA|limiting SATA|qc timeout|unplugged|resetting link' | tail -30
            echo '###SMART'
            # 与 ###BLOCK 用同一套枚举规则，盘符随冷启动重新枚举时不会漏盘
            for b in /sys/block/*; do
              n=$(basename "$b")
              case "$n" in loop*|ram*|zram*|dm-*|md*|synoboot*) continue;; esac
              d="/dev/$n"; echo "--$d"
              echo "$PW" | sudo -S -p '' smartctl -H -A "$d" 2>/dev/null | grep -iE 'SMART overall-health|Reallocated_Sector|Current_Pending|UDMA_CRC_Error|Offline_Uncorrectable'
            done
            """
        }
        s += "\necho '###END'\n"
        return s
    }

    static func stdin(for password: String) -> String {
        let b64 = Data(password.utf8).base64EncodedString()
        return "PW=$(echo '\(b64)' | base64 -d 2>/dev/null)\n"
    }
}
