import Foundation
import Combine
import Darwin

final class Config: ObservableObject {
    static let shared = Config()

    private let d = UserDefaults.standard
    private func str(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }
    private func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
    private func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
    private func bol(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    @Published var host: String           { didSet { d.set(host, forKey: "host") } }
    @Published var interval: Double       { didSet { d.set(interval, forKey: "interval") } }
    @Published var timeout: Double        { didSet { d.set(timeout, forKey: "timeout") } }
    @Published var confirmations: Int     { didSet { d.set(confirmations, forKey: "confirmations") } }
    @Published var notifyEnabled: Bool    { didSet { d.set(notifyEnabled, forKey: "notifyEnabled") } }
    @Published var soundEnabled: Bool     { didSet { d.set(soundEnabled, forKey: "soundEnabled") } }
    @Published var onlyLAN: Bool          { didSet { d.set(onlyLAN, forKey: "onlyLAN") } }
    @Published var lanPrefix: String      { didSet { d.set(lanPrefix, forKey: "lanPrefix") } }
    @Published var sshEnabled: Bool       { didSet { d.set(sshEnabled, forKey: "sshEnabled") } }
    @Published var sshUser: String        { didSet { d.set(sshUser, forKey: "sshUser") } }
    @Published var diskCheckEnabled: Bool { didSet { d.set(diskCheckEnabled, forKey: "diskCheckEnabled") } }
    @Published var useAmaneToken: Bool    { didSet { d.set(useAmaneToken, forKey: "useAmaneToken") } }
    @Published var useJellyfinToken: Bool { didSet { d.set(useJellyfinToken, forKey: "useJellyfinToken") } }
    @Published var useSudo: Bool          { didSet { d.set(useSudo, forKey: "useSudo") } }
    @Published var launchAtLogin: Bool    { didSet { d.set(launchAtLogin, forKey: "launchAtLogin") } }
    @Published var metricsEnabled: Bool   { didSet { d.set(metricsEnabled, forKey: "metricsEnabled") } }
    @Published var metricsInterval: Double { didSet { d.set(metricsInterval, forKey: "metricsInterval") } }
    @Published var showDemoMetrics: Bool  { didSet { d.set(showDemoMetrics, forKey: "showDemoMetrics") } }
    /// 阻塞熔断：检测到读库阻塞 / 大量超时时自动拉长间隔并暂停附加作业。
    /// 关掉后仍保留「同时只允许一个网络作业」的串行闸门与请求级超时取消。
    @Published var adaptiveThrottle: Bool { didSet { d.set(adaptiveThrottle, forKey: "adaptiveThrottle") } }

    // MARK: 面板顶部快捷操作（11-07 第 10 轮）
    /// 是否显示「关机 / 重启 / 打开 DSM」三个按钮。关掉后电源指令完全无从触发。
    @Published var showPowerActions: Bool { didSet { d.set(showPowerActions, forKey: "showPowerActions") } }
    /// 打开 DSM 的地址。留空 = 自动拼 http://<host>:5000/；可填 https://host:5001/ 或 QuickConnect 地址。
    @Published var dsmURL: String { didSet { d.set(dsmURL, forKey: "dsmURL") } }
    /// 通过 SSH + sudo 下发的关机 / 重启命令。只按空白拆词执行，不用 eval。
    @Published var powerShutdownCommand: String { didSet { d.set(powerShutdownCommand, forKey: "powerShutdownCommand") } }
    @Published var powerRebootCommand: String { didSet { d.set(powerRebootCommand, forKey: "powerRebootCommand") } }

    /// 仅用于命令行诊断（--host）：内存覆盖目标主机，不写 UserDefaults，
    /// 不影响正在运行的 GUI 与用户真实配置。
    var hostOverride: String?
    var effectiveHost: String {
        let h = hostOverride ?? host
        return h.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private init() {
        host = d.string(forKey: "host") ?? "192.168.1.10"
        // 30s 曾是默认值，但在 NAS 半死时会让未释放的 TCP 连接层层堆积。
        // 现默认 120s；对历史遗留的极小值做下限保护（老配置最低抬到 30s）。
        interval = max(30, d.object(forKey: "interval") == nil ? 120 : d.double(forKey: "interval"))
        timeout = d.object(forKey: "timeout") == nil ? 6 : d.double(forKey: "timeout")
        confirmations = d.object(forKey: "confirmations") == nil ? 2 : d.integer(forKey: "confirmations")
        notifyEnabled = d.object(forKey: "notifyEnabled") == nil ? true : d.bool(forKey: "notifyEnabled")
        soundEnabled = d.object(forKey: "soundEnabled") == nil ? true : d.bool(forKey: "soundEnabled")
        onlyLAN = d.object(forKey: "onlyLAN") == nil ? true : d.bool(forKey: "onlyLAN")
        lanPrefix = d.string(forKey: "lanPrefix") ?? "192.168.1."
        sshEnabled = d.object(forKey: "sshEnabled") == nil ? true : d.bool(forKey: "sshEnabled")
        sshUser = d.string(forKey: "sshUser") ?? "admin"
        diskCheckEnabled = d.object(forKey: "diskCheckEnabled") == nil ? true : d.bool(forKey: "diskCheckEnabled")
        // 已迁移 Amane Token 到 CredentialStore，默认启用真实读库探针；
        // 未配置 Token 时会自动退回 401 通道探测，不会误报。
        useAmaneToken = d.object(forKey: "useAmaneToken") == nil ? true : d.bool(forKey: "useAmaneToken")
        useJellyfinToken = d.bool(forKey: "useJellyfinToken")
        useSudo = d.bool(forKey: "useSudo")
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        metricsEnabled = d.object(forKey: "metricsEnabled") == nil ? true : d.bool(forKey: "metricsEnabled")
        metricsInterval = max(30, d.object(forKey: "metricsInterval") == nil ? 120 : d.double(forKey: "metricsInterval"))
        showDemoMetrics = d.bool(forKey: "showDemoMetrics")
        adaptiveThrottle = d.object(forKey: "adaptiveThrottle") == nil ? true : d.bool(forKey: "adaptiveThrottle")
        showPowerActions = d.object(forKey: "showPowerActions") == nil ? true : d.bool(forKey: "showPowerActions")
        dsmURL = d.string(forKey: "dsmURL") ?? ""
        // DSM 7 上 /usr/sbin/shutdown 是 systemd 软链，sudo 后 -h / -r now 都能正常收尾服务。
        powerShutdownCommand = d.string(forKey: "powerShutdownCommand") ?? "/usr/sbin/shutdown -h now"
        powerRebootCommand = d.string(forKey: "powerRebootCommand") ?? "/usr/sbin/shutdown -r now"
    }

    var base: String { "http://\(effectiveHost)" }

    func reset() {
        for k in ["host", "interval", "timeout", "confirmations", "notifyEnabled", "soundEnabled",
                  "onlyLAN", "lanPrefix", "sshEnabled", "sshUser", "diskCheckEnabled",
                  "useAmaneToken", "useJellyfinToken", "useSudo", "launchAtLogin",
                  "metricsEnabled", "metricsInterval", "showDemoMetrics",
                  "adaptiveThrottle", "appearanceMode",
                  "showPowerActions", "dsmURL", "powerShutdownCommand", "powerRebootCommand"] {
            d.removeObject(forKey: k)
        }
    }
}

// MARK: - 内网判定

enum LANCheck {
    /// 读取本机所有 IPv4，判断是否与 NAS 处于同一网段。
    /// 用于「不在家」时自动静默，避免外出时反复告警。
    static func isOnSameLAN(as host: String, prefix: String) -> Bool {
        // prefix 形如 "192.168.1."；若 NAS 是域名则无法判断，保守认为在内网
        guard !prefix.isEmpty else { return true }
        if host.hasPrefix(prefix) == false, isIPv4(host) { return false }
        for addr in localIPv4s() {
            if addr.hasPrefix(prefix) { return true }
        }
        return false
    }

    private static func isIPv4(_ s: String) -> Bool {
        var sin = sockaddr_in()
        return s.withCString { inet_pton(AF_INET, $0, &sin.sin_addr) == 1 }
    }

    static func localIPv4s() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
               let sa = p.pointee.ifa_addr, sa.pointee.sa_family == AF_INET {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = sockaddr_in()
                memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                result.append(String(cString: buf))
            }
            ptr = p.pointee.ifa_next
        }
        return result
    }
}
