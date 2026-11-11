import Foundation

// MARK: - 凭据存储（本地 0600 文件，不使用系统钥匙串）
//
// 为什么不用 Keychain：
//   这个应用是 ad-hoc 签名，每次 `codesign --force --sign -` 重建后 cdhash 都会变。
//   macOS 把每个新构建当成「另一个应用」，于是 SecItemCopyMatching 读取旧条目时
//   会反复弹出「想要使用钥匙串中的机密信息」并要求输入 Mac 登录密码。
//   这里存的只是内网只读接口的凭据，放到仅当前用户可读（0600）的文件里更合适，
//   也完全不写进 UserDefaults / 命令行参数 / 日志。
//
// 文件位置：~/Library/Application Support/NASMonitor/credentials.json
// 文件名沿用 Keychain.swift 只是历史原因，源码里已不含任何 Security 框架调用。

enum CredentialStore {

    enum Key {
        static let amaneToken = "amane.token"
        static let jellyfinToken = "jellyfin.token"
        static let sudoPassword = "sudo.password"
        static let dsmUser = "dsm.user"
        static let dsmPassword = "dsm.password"

        static let all: [String] = [
            amaneToken, jellyfinToken, sudoPassword, dsmUser, dsmPassword,
        ]
    }

    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let d = base.appendingPathComponent("NASMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static var fileURL: URL { dir.appendingPathComponent("credentials.json") }

    private static func read() -> [String: String] {
        guard let d = try? Data(contentsOf: fileURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else {
            return [:]
        }
        return o
    }

    private static func write(_ all: [String: String]) {
        guard let d = try? JSONSerialization.data(withJSONObject: all,
                                                  options: [.prettyPrinted, .sortedKeys]) else { return }
        // 凭据文件从创建那一刻就是 0600，不再有「先 0644 落地再改权限」的窗口
        _ = AtomicFileWriter.write(d, to: fileURL)
    }

    static func get(_ key: String) -> String { read()[key] ?? "" }
    static func has(_ key: String) -> Bool { !get(key).isEmpty }

    static func set(_ key: String, _ value: String) {
        var all = read()
        all[key] = value
        write(all)
    }

    static func delete(_ key: String) {
        var all = read()
        all.removeValue(forKey: key)
        write(all)
    }

    /// 供命令行自检使用：只列「已配置的键名」，绝不输出值。
    static func configuredKeys() -> [String] {
        Key.all.filter { has($0) }
    }
}
