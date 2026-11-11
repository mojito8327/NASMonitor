import Foundation
import Darwin

// MARK: - 全程 0600 的原子写入
//
// 旧实现是 `Data.write(to: options: .atomic)` 然后 `setAttributes([.posixPermissions: 0o600])`。
// 问题有两层：
//   1) .atomic 内部先按进程 umask（通常 0644）建临时文件，rename 落地后才被改成 0600 ——
//      中间存在一个「其他进程可读」的窗口，凭据文件恰好落在这个窗口里最危险；
//   2) 如果进程在 write 与 setAttributes 之间被杀，文件会永久停留在 0644。
//
// 这里用 POSIX 原语把权限在**创建那一刻**就定死：
//   open(O_WRONLY|O_CREAT|O_EXCL, 0600) → write → fsync → rename(2) 原子覆盖 → fsync 目录。
// 临时文件与目标同目录，rename 保证原子且不会跨卷；O_EXCL 避免并发写互相覆盖。
// rename 之后目标 inode 就是那个 0600 临时文件，全程不存在权限宽松的瞬间。
//
// 约定：调用方保证父目录已存在（Monitor / CredentialStore 都会在 storeDir() 里创建）。

enum AtomicFileWriter {

    /// 用 0600 权限创建同目录临时文件并原子替换目标。
    /// - Returns: 是否成功；失败时目标文件保持原样（未被破坏），临时文件会被清理。
    @discardableResult
    static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) -> Bool {
        let dir = url.deletingLastPathComponent().path
        let target = url.path
        let tmp = dir + "/." + url.lastPathComponent
            + ".tmp-\(UUID().uuidString.prefix(8))"

        // O_EXCL：并发写入各自用唯一临时名，不会互相截断。
        let fd = tmp.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode) }
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        // 显式 chmod 兜底：open 的 mode 会被 umask 掩掉，0600 & ~umask 通常仍是 0600，
        // 但遇到异常 umask（如 0777 之外的组合）时这里把它钉死。
        _ = tmp.withCString { Darwin.chmod($0, mode) }

        guard writeAll(fd, data), Darwin.fsync(fd) == 0 else {
            _ = tmp.withCString { Darwin.unlink($0) }
            return false
        }

        // rename 是原子的；目标若已存在会被整体替换，且新 inode 权限就是 0600。
        let renamed = tmp.withCString { t in
            target.withCString { d in Darwin.rename(t, d) }
        }
        guard renamed == 0 else {
            _ = tmp.withCString { Darwin.unlink($0) }
            return false
        }

        // 目录项落盘，断电后不会退回旧 inode。失败不影响本次写入结果。
        let dfd = dir.withCString { Darwin.open($0, O_RDONLY) }
        if dfd >= 0 {
            _ = Darwin.fsync(dfd)
            Darwin.close(dfd)
        }

        // 再次收紧，防御目标原本被外部改成宽松权限的极端情况（rename 已覆盖，这里只是双保险）。
        _ = target.withCString { Darwin.chmod($0, mode) }
        return true
    }

    /// 处理 write(2) 的部分写入与 EINTR。
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// 生成一个已按 0600 创建的空文件（cookie jar 等场景），不存在则不重复创建。
    static func ensureFile(_ url: URL, mode: mode_t = 0o600) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = write(Data(), to: url, mode: mode)
    }

    /// 只读自检：验证临时文件创建时的权限位确实是 0600，且 rename 后目标权限不漂移。
    /// 不碰任何真实数据文件，只在临时目录里做一次完整写入。
    static func selfTest() -> (pass: Int, fail: Int, log: String) {
        var pass = 0, fail = 0, lines: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1; lines.append("  [OK] \(name)") }
            else { fail += 1; lines.append("  [FAIL] \(name)") }
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nm-atomic-selftest-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("secret.json")
        let payload = Data("{\"token\":\"sentinel\"}".utf8)
        check("首次写入成功", write(payload, to: target))
        check("内容正确", (try? Data(contentsOf: target)) == payload)

        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        let perm = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check("落地即 0600（无权限窗口）", perm == 0o600)

        check("覆盖写入成功", write(Data("{\"token\":\"new\"}".utf8), to: target))
        let perm2 = ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check("覆盖后权限仍为 0600", perm2 == 0o600)
        check("覆盖后内容已更新", (try? String(contentsOf: target, encoding: .utf8)) == "{\"token\":\"new\"}")

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.contains(".tmp-") } ?? []
        check("无临时文件残留", leftovers.isEmpty)
        return (pass, fail, lines.joined(separator: "\n"))
    }
}
