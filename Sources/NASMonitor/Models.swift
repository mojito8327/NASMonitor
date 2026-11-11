import Foundation
import SwiftUI

// MARK: - 状态

enum Health: String, Codable, CaseIterable {
    case unknown    // 尚未完成首次检查
    case online     // 全部正常
    case degraded   // 部分服务异常
    case stalled    // 存储层阻塞（网络与静态页正常，读库请求超时）
    case offline    // 主机不可达
    case away       // 不在内网，暂停监测

    var title: String {
        switch self {
        case .unknown:  return "正在检查"
        case .online:   return "一切正常"
        case .degraded: return "部分服务异常"
        case .stalled:  return "存储层阻塞"
        case .offline:  return "NAS 离线"
        case .away:     return "不在内网"
        }
    }

    var short: String {
        switch self {
        case .unknown:  return "…"
        case .online:   return "正常"
        case .degraded: return "异常"
        case .stalled:  return "存储挂起"
        case .offline:  return "离线"
        case .away:     return "离开"
        }
    }

    var color: Color {
        switch self {
        case .unknown:  return .secondary
        case .online:   return Color(red: 0.18, green: 0.72, blue: 0.38)
        case .degraded: return Color(red: 0.95, green: 0.68, blue: 0.12)
        case .stalled:  return Color(red: 0.93, green: 0.28, blue: 0.24)
        case .offline:  return Color(red: 0.48, green: 0.50, blue: 0.55)
        case .away:     return Color(red: 0.55, green: 0.58, blue: 0.66)
        }
    }

    /// 菜单栏模板图标名（SF Symbol）
    var symbol: String {
        switch self {
        case .unknown:  return "questionmark.circle"
        case .online:   return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .stalled:  return "xmark.octagon.fill"
        case .offline:  return "moon.zzz.fill"
        case .away:     return "airplane"
        }
    }

    var isProblem: Bool {
        self == .degraded || self == .stalled || self == .offline
    }
}

// MARK: - 探测层

enum Layer: String, Codable {
    case tcp     = "网络"
    case stat    = "静态"
    case storage = "存储"
    case disk    = "磁盘"

    var order: Int {
        switch self {
        case .tcp: return 0
        case .stat: return 1
        case .storage: return 2
        case .disk: return 3
        }
    }
}

struct ProbeResult: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var layer: Layer
    var ok: Bool
    var detail: String
    var ms: Int
    var timedOut: Bool = false

    var latency: String {
        if timedOut { return "超时" }
        if ms < 0 { return "—" }
        if ms < 1000 { return "\(ms) ms" }
        return String(format: "%.1f s", Double(ms) / 1000)
    }
}

struct Snapshot: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = Date()
    var health: Health
    var summary: String
    var results: [ProbeResult]

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - 服务定义

/// 一条被监测的服务。已改为可持久化配置：新增 / 删除 / 改端口后，
/// 探针与面板都按这份列表动态生成，不再有「写死 6 个服务」的假设。
struct ServiceSpec: Identifiable, Hashable, Codable {
    var id: String { key }
    var key: String
    var name: String
    var port: UInt16
    /// 该端口异常时是否计入「服务异常」告警
    var critical: Bool = true
    /// 来源：内置默认 / 用户手工添加 / 自动纳入的发现端口
    var origin: Origin = .builtIn
    /// 服务网页地址模板，供总览页的「打开网页」按钮使用。
    /// nil / 空串 = 按 `http://{host}:{port}` 自动生成；SSH 等非网页端口不生成。
    /// 可填完整 URL（含 https）、以 / 开头的路径，或含 {host} / {port} 的模板。
    /// 只影响跳转，不参与任何探测与告警判定。
    var urlString: String? = nil

    enum Origin: String, Codable {
        case builtIn
        case user
        case discovered
    }

    enum CodingKeys: String, CodingKey {
        case key, name, port, critical, origin, urlString
    }

    /// 旧配置 / 自检里可能出现的没有 origin 的条目，按内置处理，不让解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = try c.decode(String.self, forKey: .name)
        port = try c.decode(UInt16.self, forKey: .port)
        critical = try c.decodeIfPresent(Bool.self, forKey: .critical) ?? true
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .builtIn
        // 旧版 UserDefaults 里没有这个字段：按「自动推断」处理，绝不让解码失败。
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
    }

    init(key: String, name: String, port: UInt16,
         critical: Bool = true, origin: Origin = .builtIn,
         urlString: String? = nil) {
        self.key = key
        self.name = name
        self.port = port
        self.critical = critical
        self.origin = origin
        self.urlString = urlString
    }
}

enum Services {
    /// 仅作为「首次启动播种」与「恢复默认」的模板；运行时一律读 ServiceCatalog.shared.services。
    static let defaults: [ServiceSpec] = [
        .init(key: "ssh",    name: "SSH",         port: 22),
        .init(key: "dsm",    name: "DSM",         port: 5000),
        .init(key: "amane",  name: "Amane",       port: 8000),
        .init(key: "qb",     name: "qBittorrent", port: 8080),
        .init(key: "jf",     name: "Jellyfin",    port: 8096),
        .init(key: "mihomo", name: "mihomo",      port: 9090, critical: false),
    ]

    static func critical(_ list: [ServiceSpec]) -> [ServiceSpec] {
        list.filter(\.critical)
    }

    /// 内置服务深度探针的 key。删除某服务后，对应的 L2 / L3 探针会自动不再生成。
    static let deepProbeKeys: Set<String> = ["dsm", "amane", "qb", "jf"]
}

// MARK: - 磁盘体检结果

struct DiskReport: Codable {
    var date: Date = Date()
    var reachable: Bool = false
    var arrays: [ArrayInfo] = []
    var volumes: [VolumeInfo] = []
    /// 运行时枚举到的物理整盘（/sys/block，排除 loop / zram / dm / md / 启动 U 盘）。
    /// 插拔物理盘或新建存储空间时，这个列表会自己增减。
    var physicalDisks: [PhysicalDisk] = []
    /// 随同一次低频 SSH 体检带回的对外 TCP 监听端口，供服务发现使用。
    /// 不额外建连接、不额外开一轮探测，遵守串行闸门与防 TCP 堆积约束。
    var listeningPorts: [Int] = []
    var dStateCount: Int = 0
    var sataErrors: [String] = []
    var uptime: String = ""
    var rawHint: String = ""

    struct ArrayInfo: Codable, Identifiable, Hashable {
        var id: String { name }
        var name: String
        var healthy: Bool
        var detail: String
    }

    struct VolumeInfo: Codable, Identifiable, Hashable {
        var id: String { mount }
        var mount: String
        var total: String
        var used: String
        var free: String
        var percent: Int
    }

    struct PhysicalDisk: Codable, Identifiable, Hashable {
        var id: String { name }
        var name: String
        /// 已格式化的人类可读容量，如 "3.0 T"
        var size: String
        var model: String
    }

    enum CodingKeys: String, CodingKey {
        case date, reachable, arrays, volumes, physicalDisks, listeningPorts
        case dStateCount, sataErrors, uptime, rawHint
    }

    /// 手写解码：旧版体检结果 / 自检固件里没有 physicalDisks / listeningPorts，
    /// 必须走默认值，否则整份报告解码失败、磁盘区会静默变空。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        reachable = try c.decodeIfPresent(Bool.self, forKey: .reachable) ?? false
        arrays = try c.decodeIfPresent([ArrayInfo].self, forKey: .arrays) ?? []
        volumes = try c.decodeIfPresent([VolumeInfo].self, forKey: .volumes) ?? []
        physicalDisks = try c.decodeIfPresent([PhysicalDisk].self, forKey: .physicalDisks) ?? []
        listeningPorts = try c.decodeIfPresent([Int].self, forKey: .listeningPorts) ?? []
        dStateCount = try c.decodeIfPresent(Int.self, forKey: .dStateCount) ?? 0
        sataErrors = try c.decodeIfPresent([String].self, forKey: .sataErrors) ?? []
        uptime = try c.decodeIfPresent(String.self, forKey: .uptime) ?? ""
        rawHint = try c.decodeIfPresent(String.self, forKey: .rawHint) ?? ""
    }

    /// 自定义 init(from:) 会抑制成员式构造器，这里显式保留（新字段带默认值，旧调用点不用改）。
    init(date: Date = Date(), reachable: Bool = false,
         arrays: [ArrayInfo] = [], volumes: [VolumeInfo] = [],
         physicalDisks: [PhysicalDisk] = [], listeningPorts: [Int] = [],
         dStateCount: Int = 0, sataErrors: [String] = [],
         uptime: String = "", rawHint: String = "") {
        self.date = date
        self.reachable = reachable
        self.arrays = arrays
        self.volumes = volumes
        self.physicalDisks = physicalDisks
        self.listeningPorts = listeningPorts
        self.dStateCount = dStateCount
        self.sataErrors = sataErrors
        self.uptime = uptime
        self.rawHint = rawHint
    }

    /// 体检数据是否足够用于判定（SSH 失败 / 无输出时绝不能据此报警）
    var sufficient: Bool { reachable && !arrays.isEmpty }

    var hasWarning: Bool {
        // 数据不足 ≠ 异常，否则开机首轮会产生「存储层阻塞」假告警
        guard sufficient else { return false }
        return arrays.contains { !$0.healthy } || dStateCount > 0 || !sataErrors.isEmpty
            || volumes.contains { $0.percent >= 90 }
    }

    var warningText: String {
        var parts: [String] = []
        if !reachable { parts.append("SSH 不可用") }
        let bad = arrays.filter { !$0.healthy }.map { $0.name }
        if !bad.isEmpty { parts.append("阵列降级 \(bad.joined(separator: ", "))") }
        if dStateCount > 0 { parts.append("\(dStateCount) 个进程持续卡在 I/O") }
        if !sataErrors.isEmpty { parts.append("\(sataErrors.count) 条 SATA 链路错误") }
        let full = volumes.filter { $0.percent >= 90 }.map { "\($0.mount) \($0.percent)%" }
        if !full.isEmpty { parts.append("空间紧张 \(full.joined(separator: ", "))") }
        return parts.isEmpty ? "无异常" : parts.joined(separator: " · ")
    }
}

// MARK: - 性能采样
//
// 一条样本里各字段允许缺失，但**所有字段都只代表整台 NAS**：
// CPU / 内存 / 网络只来自 SSH /proc 或 DSM Utilization 的整机读数。
// 网络速率只统计物理网卡，磁盘吞吐只统计物理整盘（/proc/diskstats），
// 不采用任何单个服务/容器（如 qBittorrent）的速率，也不把分区 / md / dm 重复计数。
// 缺失就留 nil，UI 显示「—」并说明原因，绝不用推算值或示例值冒充真实监测数据。

struct MetricsSample: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var cpu: Double?            // 0...100，百分比
    var memUsed: Double?        // bytes
    var memTotal: Double?       // bytes
    var rx: Double?             // bytes/s，下行
    var tx: Double?             // bytes/s，上行
    var diskRead: Double?       // bytes/s，整机物理磁盘读取吞吐
    var diskWrite: Double?      // bytes/s，整机物理磁盘写入吞吐
    var cpuSource: String = ""  // 整机 · SSH /proc / 整机 · DSM
    var netSource: String = ""  // 整机 · SSH /proc / 整机 · DSM
    var diskSource: String = "" // 整机 · SSH /proc/diskstats
    var note: String = ""

    enum CodingKeys: String, CodingKey {
        case id, date, cpu, memUsed, memTotal, rx, tx, diskRead, diskWrite
        case cpuSource, netSource, diskSource, note
    }

    /// 手工解码：新增字段（如 diskSource）在旧版 metrics.json 里不存在时走默认值。
    /// 若用编译器合成的 Decodable，非可选字段缺键会让整份真实历史解码失败，
    /// GUI 启动就再也读不回 CPU / 内存 / 网络曲线，且会静默回退到演示数据。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        cpu = try c.decodeIfPresent(Double.self, forKey: .cpu)
        memUsed = try c.decodeIfPresent(Double.self, forKey: .memUsed)
        memTotal = try c.decodeIfPresent(Double.self, forKey: .memTotal)
        rx = try c.decodeIfPresent(Double.self, forKey: .rx)
        tx = try c.decodeIfPresent(Double.self, forKey: .tx)
        diskRead = try c.decodeIfPresent(Double.self, forKey: .diskRead)
        diskWrite = try c.decodeIfPresent(Double.self, forKey: .diskWrite)
        cpuSource = try c.decodeIfPresent(String.self, forKey: .cpuSource) ?? ""
        netSource = try c.decodeIfPresent(String.self, forKey: .netSource) ?? ""
        diskSource = try c.decodeIfPresent(String.self, forKey: .diskSource) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    /// 自定义 init(from:) 会让编译器不再合成成员式构造器，这里显式保留
    init(id: UUID = UUID(), date: Date = Date(),
         cpu: Double? = nil, memUsed: Double? = nil, memTotal: Double? = nil,
         rx: Double? = nil, tx: Double? = nil,
         diskRead: Double? = nil, diskWrite: Double? = nil,
         cpuSource: String = "", netSource: String = "",
         diskSource: String = "", note: String = "") {
        self.id = id
        self.date = date
        self.cpu = cpu
        self.memUsed = memUsed
        self.memTotal = memTotal
        self.rx = rx
        self.tx = tx
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.cpuSource = cpuSource
        self.netSource = netSource
        self.diskSource = diskSource
        self.note = note
    }

    var memPercent: Double? {
        guard let u = memUsed, let t = memTotal, t > 0 else { return nil }
        return min(100, max(0, u / t * 100))
    }

    var hasAny: Bool {
        cpu != nil || memPercent != nil || rx != nil || tx != nil
            || diskRead != nil || diskWrite != nil
    }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    static var empty: MetricsSample { MetricsSample() }

    /// 确定性的示例序列，仅用于 --render 预览与设置里的「示例数据」开关。
    /// 永远不写入真实历史文件，UI 会打上「演示数据」标记。
    static func demoSeries(count: Int = 48) -> [MetricsSample] {
        let now = Date()
        return (0..<count).map { i in
            let t = Double(i)
            let cpu = max(2, min(96, 26 + 13 * sin(t / 5.1) + 7 * sin(t / 2.3)
                + (i % 13 == 0 ? 21 : 0)))
            let rx = max(0, 1_450_000 + 1_100_000 * sin(t / 4.2)
                + 460_000 * sin(t / 1.7) + (i % 17 == 0 ? 2_600_000 : 0))
            let tx = max(0, 280_000 + 190_000 * sin(t / 6.3) + 95_000 * sin(t / 2.1))
            let dRead = max(0, 1_900_000 + 1_500_000 * sin(t / 3.7)
                + (i % 11 == 0 ? 3_200_000 : 0))
            let dWrite = max(0, 420_000 + 300_000 * sin(t / 5.5)
                + (i % 19 == 0 ? 1_100_000 : 0))
            let total = 8.0 * 1024 * 1024 * 1024
            return MetricsSample(
                date: now.addingTimeInterval(-Double(count - 1 - i) * 30),
                cpu: cpu,
                memUsed: total * (0.38 + 0.05 * sin(t / 9)),
                memTotal: total,
                rx: rx, tx: tx,
                diskRead: dRead, diskWrite: dWrite,
                cpuSource: "演示", netSource: "演示", diskSource: "演示",
                note: "示例数据，非真实监测结果")
        }
    }
}

enum MetricFormat {
    static func rate(_ bps: Double?) -> String {
        guard let v = bps else { return "—" }
        if v < 1024 { return String(format: "%.0f B/s", v) }
        if v < 1024 * 1024 { return String(format: "%.1f KB/s", v / 1024) }
        return String(format: "%.2f MB/s", v / 1024 / 1024)
    }

    static func bytes(_ b: Double?) -> String {
        guard let v = b else { return "—" }
        let g = v / 1024 / 1024 / 1024
        if g >= 1 { return String(format: "%.1f GB", g) }
        return String(format: "%.0f MB", v / 1024 / 1024)
    }

    static func cpu(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f%%", v)
    }
}

// MARK: - 事件日志

struct Event: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = Date()
    var text: String
    var level: Health

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
