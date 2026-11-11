import Foundation

// ⚠️ 本文件由 scripts/version.sh sync 从仓库根目录 VERSION 自动生成，请勿手改。
// 唯一版本源 = VERSION；改版本一律执行 ./scripts/version.sh bump <新版本>。
// 关于页、--version、发布门禁都读这里的常量，避免版本数字散落回源码。
enum AppVersion {
    static let marketing = "1.3"
    static let build = "4"
    static let tag = "v1.3"
    static let zipName = "NASMonitor-1.3.zip"

    static var display: String { "版本 \(marketing)" }
    static var full: String { "\(marketing) (\(build))" }

    /// 版本号格式：主版本.次版本[.修订]，每段必须是十进制整数，不接受前缀 / 后缀。
    static func isValid(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.unicodeScalars.allSatisfy { ch in ch.value >= 48 && ch.value <= 57 }
        }
    }

    /// 按数值比较（补齐到 3 段），非法输入返回 nil。用于 bump 的单调递增校验。
    static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        guard isValid(a), isValid(b) else { return nil }
        let x = components(a), y = components(b)
        for i in 0..<3 {
            if x[i] != y[i] { return x[i] > y[i] ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func isValidBuild(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ch in ch.value >= 48 && ch.value <= 57 }
    }

    private static func components(_ s: String) -> [Int] {
        var v = s.split(separator: ".").map { piece in Int(piece) ?? 0 }
        while v.count < 3 { v.append(0) }
        return v
    }

    /// 运行时核对 .app 包内 plist 是否被旧包 / 手工改动污染。
    /// 命令行裸二进制（.build/release）没有 bundle，返回 .noBundle，属正常。
    enum BundleCheck: Equatable, CustomStringConvertible {
        case match
        case noBundle
        case mismatch(short: String?, build: String?)

        var description: String {
            switch self {
            case .match: return "一致"
            case .noBundle: return "命令行裸二进制（无 .app 包），跳过 plist 核对"
            case .mismatch(let s, let b):
                return "不一致：包内 \(s ?? "缺失") / \(b ?? "缺失")"
            }
        }
    }

    static func bundleCheck() -> BundleCheck {
        guard let info = Bundle.main.infoDictionary,
              let short = info["CFBundleShortVersionString"] as? String else {
            return .noBundle
        }
        let b = info["CFBundleVersion"] as? String
        return (short == marketing && b == build)
            ? .match : .mismatch(short: short, build: b)
    }
}

/// 纯内存自检：不建连接、不读 UserDefaults、不打开浏览器。
/// --version-selftest 会顺带核对当前进程的包内 plist（若在 .app 内运行）。
enum VersionSelfTest {
    static func run() {
        var pass = 0, fail = 0
        func check(_ label: String, _ ok: Bool) {
            if ok { pass += 1 } else { fail += 1; print("  ✗ \(label)") }
        }

        check("MARKETING 格式合法", AppVersion.isValid(AppVersion.marketing))
        check("BUILD 是十进制整数", AppVersion.isValidBuild(AppVersion.build))
        check("tag = v + MARKETING", AppVersion.tag == "v" + AppVersion.marketing)
        check("zipName 与版本一致",
              AppVersion.zipName == "NASMonitor-\(AppVersion.marketing).zip")
        check("display 不带硬编码数字", AppVersion.display == "版本 " + AppVersion.marketing)
        check("full 同时含版本与构建号",
              AppVersion.full.contains(AppVersion.marketing) && AppVersion.full.contains(AppVersion.build))

        check("isValid 1.1", AppVersion.isValid("1.1"))
        check("isValid 1.1.0", AppVersion.isValid("1.1.0"))
        check("isValid 10.25.3", AppVersion.isValid("10.25.3"))
        check("拒绝单段 1", !AppVersion.isValid("1"))
        check("拒绝四段 1.1.1.1", !AppVersion.isValid("1.1.1.1"))
        check("拒绝空段 1..1", !AppVersion.isValid("1..1"))
        check("拒绝带 v 前缀", !AppVersion.isValid("v1.1"))
        check("拒绝非数字段", !AppVersion.isValid("1.a"))
        check("拒绝空串", !AppVersion.isValid(""))
        check("拒绝构建号非数字", !AppVersion.isValidBuild("2b"))

        check("compare 相等", AppVersion.compare("1.1", "1.1") == .orderedSame)
        check("compare 高位更大", AppVersion.compare("1.2", "1.1") == .orderedDescending)
        check("compare 补零后相等", AppVersion.compare("1.1", "1.1.0") == .orderedSame)
        check("compare 修订号更大", AppVersion.compare("1.1.1", "1.1") == .orderedDescending)
        check("compare 按数值而非字典序", AppVersion.compare("2.0", "10.0") == .orderedAscending)
        check("compare 非法输入返回 nil", AppVersion.compare("bad", "1.1") == nil)
        check("isNewer 递增成立", AppVersion.isNewer("1.2", than: "1.1"))
        check("isNewer 同版本不成立", !AppVersion.isNewer("1.1", than: "1.1"))
        check("isNewer 倒退不成立", !AppVersion.isNewer("0.9", than: "1.1"))

        let c = AppVersion.bundleCheck()
        if case .mismatch = c {
            check("包内 plist 与源码版本一致：\(c.description)", false)
        } else {
            check("包内 plist 核对通过（\(c.description)）", true)
        }

        print("结果: \(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}
