import Foundation
import Combine

/// 服务目录 + 主机清单发现。
///
/// 以前 `Services.all` 是编译期写死的 6 条，装新服务 / 停掉旧服务后界面和探针都不会变。
/// 现在服务列表持久化在 UserDefaults，可被设置页增删改；同时搭「低频磁盘体检」那一次
/// 只读 SSH 的便车带回对外监听端口，用来发现新服务、把已停掉的服务标记为失效。
/// 端口发现**不额外发起任何 TCP 连接**，因此不会增加 NAS 的连接表压力。
final class ServiceCatalog: ObservableObject {
    static let shared = ServiceCatalog()

    @Published private(set) var services: [ServiceSpec] = []
    @Published private(set) var ignoredPorts: Set<Int> = []
    @Published private(set) var autoAdopt = false
    /// 最近一次体检看到、但尚未纳入监测的新端口（已过滤系统端口与忽略项）
    @Published private(set) var discovered: [Int] = []
    /// 配置中但当前没有对外监听的服务 key
    @Published private(set) var missingKeys: Set<String> = []
    /// 最近一次体检看到的全部对外监听端口（含系统端口，供排障报告使用）
    @Published private(set) var observedPorts: [Int] = []
    @Published private(set) var lastObserved: Date?

    private let d = UserDefaults.standard
    private static let kServices = "serviceCatalog.services.v1"
    private static let kIgnored = "serviceCatalog.ignoredPorts.v1"
    private static let kAutoAdopt = "serviceCatalog.autoAdopt.v1"

    /// 显示名称上限：面板服务行是定宽单行的，太长会挤掉端口 / 关键 / 删除按钮。
    static let maxNameLength = 40

    /// DSM / Linux 自身的监听端口。它们不是「用户装的新服务」，不进候选清单。
    /// 用户仍可在设置页手动把其中任何一个加进监测。
    static let systemPorts: Set<Int> = [
        22, 80, 111, 123, 139, 161, 443, 445, 512, 631, 873,
        2049, 3260, 3261, 3262, 3263, 3264, 3265, 3266,
        5000, 5001, 5357,
    ]

    /// 常见自托管服务端口 → 友好名称。只是给候选端口起名字，不影响判定。
    static let wellKnown: [Int: String] = [
        3000: "Grafana", 3001: "Web 3001", 5055: "Overseerr",
        6789: "Deluge", 6880: "Cloud Torrent", 7878: "Radarr",
        7983: "OpenList", 8000: "Amane", 8080: "qBittorrent",
        8081: "Web 8081", 8082: "Web 8082", 8085: "Web 8085",
        8090: "Web 8090", 8091: "Web 8091", 8096: "Jellyfin",
        8123: "Home Assistant", 8443: "Web 8443", 8686: "Lidarr",
        8888: "Web 8888", 8989: "Sonarr", 9000: "Portainer",
        9090: "mihomo", 9091: "Transmission", 9443: "Portainer TLS",
        9696: "Prowlarr", 32400: "Plex", 51413: "BT 传入",
    ]

    private init() { load() }

    // MARK: - 持久化

    private func load() {
        if let data = d.data(forKey: Self.kServices),
           let arr = try? JSONDecoder().decode([ServiceSpec].self, from: data),
           !arr.isEmpty {
            services = arr
        } else {
            services = Services.defaults
        }
        ignoredPorts = Set(d.array(forKey: Self.kIgnored) as? [Int] ?? [])
        autoAdopt = d.bool(forKey: Self.kAutoAdopt)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(services) {
            d.set(data, forKey: Self.kServices)
        }
        d.set(Array(ignoredPorts).sorted(), forKey: Self.kIgnored)
        d.set(autoAdopt, forKey: Self.kAutoAdopt)
    }

    /// 给 RunConfig 用的值拷贝快照：一轮探测期间列表不会被设置页改动影响。
    var snapshot: [ServiceSpec] { services }

    /// 仅离屏预览：注入一份服务清单 / 候选端口 / 失效标记，**不写 UserDefaults**，
    /// 所以 --render 进程不会污染正在运行的 GUI 的真实服务配置。
    func installPreview(services list: [ServiceSpec],
                        discovered ports: [Int] = [],
                        missing: Set<String> = []) {
        services = list
        discovered = ports
        missingKeys = missing
    }

    // MARK: - 纯函数：发现结果与名称校验（自检可直接覆盖，无 IO）

    /// 名称清洗：去首尾空白、拒绝空串与超长串。新增 / 改名 / 采纳端口共用一条规则。
    static func normalizedName(_ raw: String) -> String? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= maxNameLength else { return nil }
        return clean
    }

    /// 只改显示名称，服务标识（key）/ 端口 / 关键标记 / 来源原样保留。
    /// key 是 `tcp.<key>` 探针 ID 与面板结果聚合的稳定依据，改名绝不能换 key，
    /// 否则已经采到的历史结果会突然对不上；改名也不能悄悄改变告警级别或自动移除规则。
    static func renamed(_ spec: ServiceSpec, to raw: String) -> ServiceSpec? {
        guard let clean = normalizedName(raw) else { return nil }
        var out = spec
        out.name = clean
        return out
    }

    struct Outcome: Equatable {
        var missingKeys: Set<String> = []
        var removedKeys: Set<String> = []
        var candidates: [Int] = []
        var adopted: [ServiceSpec] = []
    }

    /// - `observed` 为空 / SSH 不可达时由调用方直接跳过，绝不把全部服务误标成失效。
    /// - 自动纳入（origin == .discovered）的服务一旦端口消失就自动移除，
    ///   这样「删掉现有服务」无需手工清理；用户确认过的服务只标灰，不擅自删除。
    static func evaluate(services: [ServiceSpec], observed: [Int],
                         ignored: Set<Int>, autoAdopt: Bool) -> Outcome {
        let ports = Set(observed.filter { $0 > 0 && $0 <= 65535 })
        var out = Outcome()
        out.missingKeys = Set(services.filter { !ports.contains(Int($0.port)) }.map(\.key))
        out.removedKeys = Set(services
            .filter { $0.origin == .discovered && out.missingKeys.contains($0.key) }
            .map(\.key))
        let configured = Set(services.map { Int($0.port) })
        out.candidates = ports.subtracting(configured)
            .subtracting(ignored)
            .subtracting(systemPorts)
            .filter { $0 >= 1024 }
            .sorted()
        if autoAdopt {
            out.adopted = out.candidates.map { p in
                ServiceSpec(key: "port\(p)", name: wellKnown[p] ?? "端口 \(p)",
                            port: UInt16(p), critical: false, origin: .discovered)
            }
        }
        return out
    }

    /// 探针 ID → 服务 key 的归属判定。以前是 ContentView 里那张写死的字典，
    /// 现在按命名约定动态聚合，新增服务只要生成 `tcp.<key>` 就能被面板收进来。
    static func probeBelongs(_ id: String, to key: String) -> Bool {
        if id == "tcp.\(key)" { return true }
        for layer in ["stat.", "sto."] {
            let base = layer + key
            if id == base { return true }
            if id.hasPrefix(base + "-") || id.hasPrefix(base + ".") { return true }
        }
        return false
    }

    // MARK: - 体检结果应用（只在 SSH 成功、确实拿到端口清单时才调用）

    /// 返回本次发生的变化描述，供 Monitor 写事件日志；无变化返回 nil。
    @discardableResult
    func apply(observed: [Int], reachable: Bool) -> String? {
        guard reachable, !observed.isEmpty else { return nil }
        let previousCandidates = Set(discovered)
        let outcome = Self.evaluate(services: services, observed: observed,
                                    ignored: ignoredPorts, autoAdopt: autoAdopt)
        observedPorts = observed.sorted()
        lastObserved = Date()
        missingKeys = outcome.missingKeys

        var changed = false
        if !outcome.removedKeys.isEmpty {
            services.removeAll { outcome.removedKeys.contains($0.key) }
            changed = true
        }
        if !outcome.adopted.isEmpty {
            services.append(contentsOf: outcome.adopted)
            services.sort { $0.port < $1.port }
            changed = true
        }
        discovered = autoAdopt ? [] : outcome.candidates
        if changed { persist() }

        // 只报「本轮真正新增/移除」的动作；候选与失效状态常驻不变时不重复写事件日志。
        let fresh = Set(outcome.candidates).subtracting(previousCandidates)
        var parts: [String] = []
        if !outcome.adopted.isEmpty { parts.append("自动纳入 \(outcome.adopted.count) 个新服务") }
        else if !fresh.isEmpty { parts.append("发现 \(fresh.count) 个新端口待确认") }
        if !outcome.removedKeys.isEmpty { parts.append("移除 \(outcome.removedKeys.count) 个已停服务") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 设置页操作

    func setAutoAdopt(_ on: Bool) {
        autoAdopt = on
        persist()
        if on { adoptAll() }
    }

    /// 手工新增 / 改名同端口的已有条目。返回 false 表示参数非法或端口越界。
    /// 同端口重复添加只更新名称，不再把「关键」标记悄悄重置为 false；
    /// `urlString` 传 nil 时不覆盖已有网页地址，传值（含空串）才更新。
    @discardableResult
    func add(name: String, port: Int, critical: Bool = false,
             urlString: String? = nil) -> Bool {
        guard let clean = Self.normalizedName(name), (1...65535).contains(port) else {
            return false
        }
        if let i = services.firstIndex(where: { Int($0.port) == port }) {
            services[i].name = clean
            if let u = urlString {
                services[i].urlString = u.isEmpty ? nil : u
            }
        } else {
            let base = clean.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            var key = base.isEmpty ? "port\(port)" : base
            var n = 2
            while services.contains(where: { $0.key == key }) {
                key = "\(base.isEmpty ? "port\(port)" : base)\(n)"
                n += 1
            }
            services.append(ServiceSpec(key: key, name: clean, port: UInt16(port),
                                        critical: critical, origin: .user,
                                        urlString: (urlString?.isEmpty ?? true) ? nil : urlString))
        }
        ignoredPorts.remove(port)
        discovered.removeAll { $0 == port }
        missingKeys = missingKeys.filter { key in
            services.contains { $0.key == key && Int($0.port) == port }
        }
        persist()
        return true
    }

    /// 只改显示名称：key / port / critical / origin 全都不动，探针与历史结果保持连续。
    @discardableResult
    func rename(key: String, name: String) -> Bool {
        guard let i = services.firstIndex(where: { $0.key == key }),
              let updated = Self.renamed(services[i], to: name) else { return false }
        guard updated.name != services[i].name else { return true }
        services[i] = updated
        persist()
        return true
    }

    /// 设置某个服务的网页地址模板。传空串 = 恢复「按 主机:端口 自动推断」。
    /// 返回 false 表示 key 不存在或模板非法，此时不改动目录、不写 UserDefaults。
    /// 只影响总览页的跳转按钮，不改 key / 端口 / 关键标记 / 来源，探针与历史结果保持连续。
    @discardableResult
    func setURL(key: String, raw: String) -> Bool {
        guard let i = services.firstIndex(where: { $0.key == key }),
              let clean = ServiceLinks.normalizedTemplate(raw) else { return false }
        services[i].urlString = clean.isEmpty ? nil : clean
        persist()
        return true
    }

    /// 采纳一个发现端口（视为用户确认，端口消失后只标灰、不自动移除）。
    /// `name` 为空时使用 wellKnown 的自动名称；非空则按用户填的自定义名称入库。
    /// 返回 false 表示名称非法（如超过 40 字），此时不改动目录。
    @discardableResult
    func adopt(port: Int, name: String? = nil) -> Bool {
        let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chosen: String
        if raw.isEmpty {
            chosen = Self.wellKnown[port] ?? "端口 \(port)"
        } else {
            guard let clean = Self.normalizedName(raw) else { return false }
            chosen = clean
        }
        return add(name: chosen, port: port)
    }

    func adoptAll() {
        for p in discovered { _ = adopt(port: p) }
        discovered = []
    }

    /// 忽略后不会再出现在候选清单里；恢复默认可清空忽略表。
    func ignore(port: Int) {
        ignoredPorts.insert(port)
        discovered.removeAll { $0 == port }
        persist()
    }

    func setCritical(key: String, on: Bool) {
        guard let i = services.firstIndex(where: { $0.key == key }) else { return }
        services[i].critical = on
        persist()
    }

    func remove(key: String) {
        guard let s = services.first(where: { $0.key == key }) else { return }
        // 删掉的端口记入忽略表，否则下一轮体检又会把它当「新服务」推回来。
        ignoredPorts.insert(Int(s.port))
        services.removeAll { $0.key == key }
        missingKeys.remove(key)
        discovered.removeAll { $0 == Int(s.port) }
        persist()
    }

    /// 一键清理所有「已配置但未监听」的服务。
    func removeMissing() {
        for key in Array(missingKeys) { remove(key: key) }
    }

    func reset() {
        services = Services.defaults
        ignoredPorts = []
        autoAdopt = false
        discovered = []
        missingKeys = []
        observedPorts = []
        lastObserved = nil
        persist()
    }

    func name(forPort p: Int) -> String { Self.wellKnown[p] ?? "端口 \(p)" }
}
