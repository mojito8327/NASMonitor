import Foundation

/// 服务「打开网页」按钮的目标地址解析。
///
/// 刻意做成纯函数：不读 UserDefaults、不建连接、不碰 AppKit、不打开浏览器，
/// 因此 `--links-selftest` 能完整覆盖所有分支，GUI 侧只需 `NSWorkspace.shared.open(url)`。
/// 地址只影响跳转，**不参与任何 TCP / HTTP 探测与告警判定**，也不会被写进排障报告。
enum ServiceLinks {
    /// 只有 TCP 探测意义、没有可打开网页的端口。显式填了网页地址时以用户为准。
    static let nonWebPorts: Set<Int> = [
        22, 23, 25, 53, 110, 139, 143, 445, 993, 995, 2049,
        3260, 3261, 3262, 3263, 3264, 3265, 3266,
        6881, 6888, 51413,
    ]

    static let maxTemplateLength = 300

    /// 用户输入清洗：去首尾空白；空串表示「恢复自动推断」。
    /// 返回 nil = 非法（超长 / 控制字符 / 危险 scheme），此时不应写回目录。
    static func normalizedTemplate(_ raw: String) -> String? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= maxTemplateLength else { return nil }
        if clean.isEmpty { return "" }
        guard clean.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let lower = clean.lowercased()
        // 带 :// 的只允许 http / https；不带 :// 的 javascript: / file: 之类也拒绝。
        if lower.contains("://") {
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        }
        for bad in ["javascript:", "file:", "data:", "vbscript:"] {
            if lower.hasPrefix(bad) { return nil }
        }
        return clean
    }

    /// 把配置里的主机写成 URL 里合法的主机名：IPv6 字面量补方括号。
    static func hostLiteral(_ host: String) -> String? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        if h.hasPrefix("[") && h.hasSuffix("]") { return h }
        if h.contains(":") { return "[\(h)]" }
        return h
    }

    /// 生成最终 URL 字符串；返回 nil 表示该服务没有可打开的网页（按钮不显示）。
    static func urlString(spec: ServiceSpec, host: String) -> String? {
        guard let hostPart = hostLiteral(host) else { return nil }
        let port = Int(spec.port)
        let template = (spec.urlString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if template.isEmpty {
            guard !nonWebPorts.contains(port) else { return nil }
            return "http://\(hostPart):\(port)"
        }
        // 设置页写入前已用 normalizedTemplate 拦过一次；这里再挡一道，覆盖
        // 手工改 UserDefaults / 旧数据里混入的危险 scheme，确保解析出的地址
        // 始终是可交给浏览器的 http/https URL。
        guard normalizedTemplate(template) != nil else { return nil }

        var text = template
            .replacingOccurrences(of: "{host}", with: hostPart)
            .replacingOccurrences(of: "{port}", with: String(port))
        if !text.contains("://") {
            // 以 / 开头 = 只覆盖路径，主机与端口仍用当前配置；
            // 否则视作用户自己写的完整主机名（如 nas.local:5001）。
            text = text.hasPrefix("/") ? "http://\(hostPart):\(port)" + text : "http://" + text
        }
        guard let u = URL(string: text),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let h = u.host, !h.isEmpty else { return nil }
        return u.absoluteString
    }

    static func resolve(spec: ServiceSpec, host: String) -> URL? {
        guard let s = urlString(spec: spec, host: host) else { return nil }
        return URL(string: s)
    }

    /// 命令行 / 悬停提示用的展示串。
    static func display(spec: ServiceSpec, host: String) -> String {
        urlString(spec: spec, host: host) ?? "（无网页）"
    }
}

/// NASMonitor --links-selftest
/// 全内存：不建连接、不读 UserDefaults、不改 GUI 的真实服务配置、不打开浏览器。
enum ServiceLinksSelfTest {
    static func run() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "✓" : "✗") \(name)")
            if ok { pass += 1 } else { fail += 1 }
        }
        func spec(_ port: UInt16, _ template: String? = nil) -> ServiceSpec {
            ServiceSpec(key: "t", name: "测试", port: port,
                        critical: true, origin: .builtIn, urlString: template)
        }
        let host = "192.168.1.10"
        func str(_ p: UInt16, _ t: String? = nil, host h: String = host) -> String? {
            ServiceLinks.urlString(spec: spec(p, t), host: h)
        }

        // 1. 默认推断
        check("默认 = http://主机:端口", str(8096) == "http://192.168.1.10:8096")
        check("边界端口 65535", str(65535) == "http://192.168.1.10:65535")
        check("边界端口 1", str(1) == "http://192.168.1.10:1")

        // 2. 非网页端口
        check("SSH 22 不生成网页", str(22) == nil)
        check("BT 6888 不生成网页", str(6888) == nil)
        check("BT 51413 不生成网页", str(51413) == nil)
        check("iSCSI 3260 不生成网页", str(3260) == nil)
        check("DSM 5000 仍生成网页", str(5000) == "http://192.168.1.10:5000")
        check("SSH 显式填地址后以用户为准",
              str(22, "https://ssh.example.com/") == "https://ssh.example.com/")

        // 3. 模板形态
        check("完整 https 地址", str(8080, "https://nas.example.com:5001/") == "https://nas.example.com:5001/")
        check("DSM 自定义域名 / 5001 与顶部按钮一致",
              str(5000, "https://nas.example.cn:5001/") == "https://nas.example.cn:5001/")
        check("仅路径", str(8096, "/web/") == "http://192.168.1.10:8096/web/")
        check("路径带片段", str(8096, "/web/index.html#!/home.html")?
            .contains("/web/index.html") == true)
        check("{host}/{port} 占位符",
              str(8080, "https://{host}:{port}/ui/") == "https://192.168.1.10:8080/ui/")
        check("自定义主机名（无 scheme）",
              str(8080, "nas.local:5001") == "http://nas.local:5001")

        // 4. 输入校验
        check("空串 = 恢复自动", ServiceLinks.normalizedTemplate("   ") == "")
        check("首尾空白被去掉", ServiceLinks.normalizedTemplate("  /docs  ") == "/docs")
        check("拒绝 javascript:", ServiceLinks.normalizedTemplate("javascript:alert(1)") == nil)
        check("拒绝 file:", ServiceLinks.normalizedTemplate("file:///etc/passwd") == nil)
        check("拒绝 data:", ServiceLinks.normalizedTemplate("data:text/html,x") == nil)
        check("拒绝 ftp://", ServiceLinks.normalizedTemplate("ftp://x/y") == nil)
        check("拒绝超长模板",
              ServiceLinks.normalizedTemplate(String(repeating: "a", count: 301)) == nil)
        check("拒绝换行控制字符",
              ServiceLinks.normalizedTemplate("http://x/\ninject") == nil)
        check("拒绝无主机 URL", str(8096, "http://") == nil)
        check("空 host 不生成", str(8096, host: "   ") == nil)
        check("非法模板解析不出来（空格）",
              ServiceLinks.urlString(spec: spec(8096, "http://a b/c"), host: host) == nil)

        // 5. 主机字面量
        check("IPv6 补方括号",
              ServiceLinks.hostLiteral("fe80::1") == "[fe80::1]")
        check("IPv6 已有方括号不重复",
              ServiceLinks.hostLiteral("[fe80::1]") == "[fe80::1]")
        check("IPv4 原样", ServiceLinks.hostLiteral("192.168.1.10") == "192.168.1.10")
        check("IPv6 默认地址可用",
              str(8096, host: "fe80::1") == "http://[fe80::1]:8096")

        // 6. URL 对象与展示
        let u = ServiceLinks.resolve(spec: spec(8096), host: host)
        check("URL 对象 scheme", u?.scheme == "http")
        check("URL 对象 port", u?.port == 8096)
        check("URL 对象 host", u?.host == host)
        check("展示串", ServiceLinks.display(spec: spec(22), host: host) == "（无网页）")

        // 7. 旧配置兼容与往返编码（urlString 为可选字段，旧数据必须能解码）
        let oldJSON = #"{"key":"jf","name":"Jellyfin","port":8096,"critical":true,"origin":"builtIn"}"#
        let old = try? JSONDecoder().decode(ServiceSpec.self,
                                            from: Data(oldJSON.utf8))
        check("旧配置无 urlString 可解码", old != nil && old?.urlString == nil)
        let oldURL = old.flatMap { ServiceLinks.urlString(spec: $0, host: host) }
        check("旧配置仍按默认生成网页", oldURL == "http://192.168.1.10:8096")
        let newer = spec(8096, "/web/")
        let data = try? JSONEncoder().encode(newer)
        let back = data.flatMap { try? JSONDecoder().decode(ServiceSpec.self, from: $0) }
        check("新配置带 urlString 往返", back?.urlString == "/web/")
        check("编码含 urlString 字段",
              data.flatMap { String(data: $0, encoding: .utf8) }?.contains("urlString") == true)

        // 8. 目录级操作：改名 / 恢复默认不丢地址
        let renamed = ServiceCatalog.renamed(newer, to: "影音")
        check("改名保留 urlString", renamed?.urlString == "/web/" && renamed?.name == "影音")
        check("改名保留 key 与端口", renamed?.key == "t" && renamed?.port == 8096)
        check("发现结果不受 urlString 影响",
              ServiceCatalog.evaluate(services: [spec(8096, "/web/")],
                                     observed: [8096], ignored: [], autoAdopt: false)
                .missingKeys.isEmpty)

        // 9. 地址安全兜底：手工改坏的 UserDefaults 也不能生成危险 URL
        check("危险模板不生成网页（手工改配置的兜底）",
              str(8096, "javascript:alert(1)") == nil)

        print("结果: \(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}
