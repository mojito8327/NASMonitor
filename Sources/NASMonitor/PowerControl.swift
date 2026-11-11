import Foundation
import AppKit

// MARK: - NAS 电源操作 / DSM 快捷入口
//
// 11-07 第 10 轮：面板顶部新增「关机 / 重启 / 打开 DSM」三个按钮。
// 关机与重启是不可逆操作，这里刻意做得比普通探测「难触发」：
//   1) UI 必须弹 destructive 确认，弹窗里写清目标主机与实际命令；
//   2) 只走已有的免密 SSH 通道，sudo 密码从 CredentialStore 读出、经 stdin 送入，
//      绝不出现在 argv / ps / 日志 / 命令行历史里；
//   3) 命令按空白拆词执行，**不用 eval**，配置里带了 shell 元字符也不会被解释；
//   4) 先验证 sudo 可用（sudo -v）再回传 ###POWER_ACCEPTED，
//      避免把「密码错 / 没配免密」误报成「已关机」；
//   5) 真正执行延后 2 秒并忽略 HUP，SSH 会话随 NAS 断电被掐断时指令仍会落地；
//   6) 本机 DSM 7 实测：/usr/sbin/shutdown 与 /usr/sbin/reboot 都是 systemd 软链，
//      sudo -n 需要密码，sudo -S 配合 CredentialStore 里的 sudo.password 可拿到 uid 0。
//
// 安全边界：本文件不提供「无确认直接执行」的入口；--power-script 只打印脚本，
// 不建连接、不执行任何关机/重启。真机验收绝不能对着生产 NAS 点这两个按钮。

enum PowerAction: String, CaseIterable, Identifiable {
    case shutdown
    case reboot

    var id: String { rawValue }
    var title: String { self == .shutdown ? "关机" : "重启" }
    var symbol: String { self == .shutdown ? "power" : "arrow.triangle.2.circlepath" }
    var doneText: String { self == .shutdown ? "关机指令已下发" : "重启指令已下发" }
    var consequence: String {
        self == .shutdown
            ? "NAS 会停止所有服务并断电，之后只能到机器旁物理开机。"
            : "NAS 会立即重启，全部服务与传输中断数分钟。"
    }
}

struct PowerOutcome {
    let ok: Bool
    let title: String
    let detail: String
}

enum PowerControl {

    // MARK: - 打开 DSM

    /// 留空时按本机 DSM 端口自动拼 http://<host>:5000/；也可填 https://...:5001/ 或自定义域名。
    static func dsmURL(_ cfg: Config = .shared) -> URL? {
        let raw = cfg.dsmURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if raw.isEmpty {
            candidate = "http://\(cfg.effectiveHost):5000/"
        } else {
            candidate = raw.contains("://") ? raw : "http://" + raw
        }
        guard let u = URL(string: candidate),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              u.host != nil else { return nil }
        return u
    }

    @discardableResult
    static func openDSM(_ cfg: Config = .shared) -> Bool {
        guard let u = dsmURL(cfg) else { return false }
        return NSWorkspace.shared.open(u)
    }

    // MARK: - 命令

    static func defaultCommand(_ action: PowerAction) -> String {
        action == .shutdown ? "/usr/sbin/shutdown -h now" : "/usr/sbin/shutdown -r now"
    }

    static func command(for action: PowerAction, cfg: Config = .shared) -> String {
        let raw = (action == .shutdown ? cfg.powerShutdownCommand : cfg.powerRebootCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? defaultCommand(action) : raw
    }

    /// 单引号转义：配置值只作为数据进入脚本，不会被当成 shell 代码。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 发给远端 `bash -s` 的脚本正文。PW 由 stdinPayload 在脚本最前面注入。
    /// 抽成独立函数是为了让 --power-script 能干跑验收：只打印、不建连接。
    static func script(for action: PowerAction, cfg: Config = .shared) -> String {
        let quoted = shellQuote(command(for: action, cfg: cfg))
        return """
        POWER_CMD=\(quoted)
        run_sudo() {
          if [ -n "${PW:-}" ]; then
            printf '%s\\n' "$PW" | sudo -S -p '' "$@"
          else
            sudo -n "$@"
          fi
        }
        # 只按空白拆词，不用 eval；配置里即使含 shell 元字符也只是普通参数
        read -r -a ARGS <<< "$POWER_CMD"
        BIN="${ARGS[0]:-}"
        if [ -z "$BIN" ]; then echo '###POWER_NO_COMMAND'; exit 42; fi
        if [ -x "$BIN" ] || command -v "$BIN" >/dev/null 2>&1; then :
        else echo "###POWER_NO_BINARY $BIN"; exit 42; fi
        # 先验证 sudo 可用，避免把「密码错」当成「已关机」
        if [ -n "${PW:-}" ]; then
          printf '%s\\n' "$PW" | sudo -S -p '' -v >/dev/null 2>&1 \\
            || { echo '###POWER_SUDO_FAIL'; exit 43; }
        else
          sudo -n -v >/dev/null 2>&1 || { echo '###POWER_SUDO_FAIL'; exit 43; }
        fi
        echo '###POWER_ACCEPTED'
        # 延后 2s 且忽略 HUP：SSH 会话被 NAS 断电掐断，也不会带走待执行的指令
        ( trap '' HUP; sleep 2; run_sudo "${ARGS[@]}" ) >/dev/null 2>&1 </dev/null &
        echo '###POWER_DONE'
        """
    }

    /// sudo 密码以 base64 形式从 stdin 送入（与磁盘体检同一条通路），不进 argv。
    static func stdinPayload(sudoPassword: String) -> String? {
        sudoPassword.isEmpty ? nil : SSH.stdin(for: sudoPassword)
    }

    // MARK: - 二次确认（防误触）
    //
    // 纯粹的 destructive 点击在菜单栏里有手滑风险。下发前必须再输入一次
    // 「当前 NAS 地址」或「管理员密码后四位」，两者都只做等值比较：
    //   - 密码本身绝不进入日志 / 排障报告 / argv / 脚本正文；
    //   - matchesConfirmation 是纯函数，便于 --power-selftest 覆盖。

    static func matchesConfirmation(_ input: String, host: String,
                                    passwordSuffix: String?) -> Bool {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.isEmpty, t == h { return true }
        if let sfx = passwordSuffix, !sfx.isEmpty, t == sfx { return true }
        return false
    }

    static func verify(_ input: String, cfg: Config = .shared) -> Bool {
        let pw = CredentialStore.get(CredentialStore.Key.sudoPassword)
        let suffix = pw.count >= 4 ? String(pw.suffix(4)) : nil
        return matchesConfirmation(input, host: cfg.effectiveHost, passwordSuffix: suffix)
    }

    /// 只描述「要输入什么」，不回显任何密码内容。
    static func confirmationHint(_ cfg: Config = .shared) -> String {
        let pw = CredentialStore.get(CredentialStore.Key.sudoPassword)
        return pw.count >= 4
            ? "请输入当前 NAS 地址 \(cfg.effectiveHost)，或管理员密码后四位。"
            : "请输入当前 NAS 地址 \(cfg.effectiveHost)。"
    }

    // MARK: - 执行

    static func perform(_ action: PowerAction, cfg: Config = .shared) async -> PowerOutcome {
        guard cfg.sshEnabled else {
            return PowerOutcome(ok: false, title: "未启用 SSH",
                                detail: "电源指令通过免密 SSH + sudo 下发。请先到「设置 → 探针与凭据 → SSH 深度探测」启用 SSH。")
        }
        let user = cfg.sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else {
            return PowerOutcome(ok: false, title: "SSH 用户为空",
                                detail: "请在「设置 → 探针与凭据」填写 SSH 用户名。")
        }
        let host = cfg.effectiveHost
        guard !host.isEmpty else {
            return PowerOutcome(ok: false, title: "目标主机为空",
                                detail: "请先在「设置 → 常规 → 目标主机」填写 NAS 地址。")
        }
        guard !cfg.onlyLAN || LANCheck.isOnSameLAN(as: host, prefix: cfg.lanPrefix) else {
            return PowerOutcome(ok: false, title: "当前不在内网",
                                detail: "已阻止下发电源指令。请回到 \(cfg.lanPrefix)x 网段后重试。")
        }

        let pw = CredentialStore.get(CredentialStore.Key.sudoPassword)
        let body = script(for: action, cfg: cfg)
        let payload = stdinPayload(sudoPassword: pw)
        // SSH.run 本身是 async 且非 actor 隔离：直接 await 即可离开主线程，
        // 不再套 Task.detached；上层 Task 取消时底层 ssh 子进程会被 terminate。
        let out = await SSH.run(user: user, host: host, script: body,
                                stdin: payload, timeout: 12)
        return interpret(out, action: action, host: host, hasPassword: !pw.isEmpty)
    }

    /// 只读前置检查：确认 SSH 通、命令存在、sudo 可提权。**绝不执行关机/重启**。
    /// 供 --power-check 与排障使用，避免用户点了按钮才发现密码没配好。
    static func check(_ cfg: Config = .shared) async -> String {
        let user = cfg.sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = cfg.effectiveHost
        let pw = CredentialStore.get(CredentialStore.Key.sudoPassword)
        let payload = stdinPayload(sudoPassword: pw)
        let shutdownCmd = command(for: .shutdown, cfg: cfg)
        let rebootCmd = command(for: .reboot, cfg: cfg)
        let body = """
        CHECK_CMDS=(\(shellQuote(shutdownCmd)) \(shellQuote(rebootCmd)))
        echo "###WHOAMI $(id -un)"
        for C in "${CHECK_CMDS[@]}"; do
          read -r -a A <<< "$C"
          B="${A[0]:-}"
          if [ -n "$B" ] && { [ -x "$B" ] || command -v "$B" >/dev/null 2>&1; }; then
            echo "###BIN_OK $B"
          else
            echo "###BIN_MISSING $B"
          fi
        done
        if [ -n "${PW:-}" ]; then
          printf '%s\\n' "$PW" | sudo -S -p '' -v >/dev/null 2>&1 \\
            && echo '###SUDO_OK' || echo '###SUDO_FAIL'
        else
          sudo -n -v >/dev/null 2>&1 && echo '###SUDO_OK' || echo '###SUDO_FAIL'
        fi
        echo '###CHECK_END'
        """
        let out = await SSH.run(user: user, host: host, script: body,
                                stdin: payload, timeout: 12)
        var lines = ["目标: \(user)@\(host)",
                     "SSH: \(out.text.contains("###CHECK_END") ? "可达" : "不可达")",
                     "sudo 密码: \(pw.isEmpty ? "未配置（依赖 NOPASSWD）" : "已配置（stdin 注入）")",
                     "关机命令: \(shutdownCmd)",
                     "重启命令: \(rebootCmd)"]
        for line in out.text.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("###WHOAMI") { lines.append("远端用户: " + s.replacingOccurrences(of: "###WHOAMI ", with: "")) }
            if s.hasPrefix("###BIN_OK") { lines.append("✓ 命令存在: " + s.replacingOccurrences(of: "###BIN_OK ", with: "")) }
            if s.hasPrefix("###BIN_MISSING") { lines.append("✗ 命令缺失: " + s.replacingOccurrences(of: "###BIN_MISSING ", with: "")) }
        }
        if out.text.contains("###SUDO_OK") { lines.append("✓ sudo 可提权") }
        else if out.text.contains("###SUDO_FAIL") { lines.append("✗ sudo 提权失败：请检查 sudo 密码 / NOPASSWD") }
        else { lines.append("? sudo 状态未知") }
        if !out.stderr.isEmpty {
            lines.append("SSH stderr: " + String(out.stderr.prefix(160)))
        }
        let ready = out.text.contains("###CHECK_END")
            && out.text.contains("###SUDO_OK")
            && !out.text.contains("###BIN_MISSING")
        lines.append(ready ? "结论: 电源操作前置条件就绪（本检查未执行任何关机/重启）"
                           : "结论: 前置条件未就绪，按钮会返回失败回执，不会误报成功")
        return lines.joined(separator: "\n")
    }

    /// 结果判定：只有拿到 ###POWER_ACCEPTED 才算「已下发」。
    /// 注意「已下发」不等于「NAS 已经断电」——关机过程中 SSH 可能先被掐断。
    static func interpret(_ o: SSH.Output, action: PowerAction, host: String,
                          hasPassword: Bool) -> PowerOutcome {
        let text = o.text
        if text.contains("###POWER_ACCEPTED") {
            let tail = text.contains("###POWER_DONE") ? "指令已进入执行队列" : "指令已进入执行队列（SSH 随后断开）"
            return PowerOutcome(ok: true, title: action.doneText,
                                detail: "目标 \(host) · \(tail)。\(action.consequence)")
        }
        if text.contains("###POWER_SUDO_FAIL") || o.stderr.contains("sudo:") && o.stderr.contains("password") {
            return PowerOutcome(
                ok: false, title: "sudo 验证未通过",
                detail: hasPassword
                    ? "已配置的 sudo 密码未能提权，请在「设置 → 探针与凭据」重新填写；NAS 未执行任何电源操作。"
                    : "NAS 要求 sudo 密码，但本机未配置。请在「设置 → 探针与凭据」保存 sudo 密码，或在 NAS 上为该用户配置 NOPASSWD；NAS 未执行任何电源操作。")
        }
        if text.contains("###POWER_NO_BINARY") || text.contains("###POWER_NO_COMMAND") {
            let line = text.split(separator: "\n").first(where: { $0.contains("###POWER_NO_") }) ?? ""
            return PowerOutcome(ok: false, title: "命令不可用",
                                detail: "远端找不到 \(String(line).replacingOccurrences(of: "###POWER_NO_", with: ""))。可到「设置 → 常规 → 电源操作」改成这台 NAS 上实际存在的命令；NAS 未执行任何电源操作。")
        }
        if o.timedOut {
            return PowerOutcome(ok: false, title: "SSH 超时",
                                detail: "12 秒内没有拿到确认标记，无法判断是否已下发。请先确认 NAS 状态，不要重复点击。")
        }
        let err = o.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = err.isEmpty ? "（SSH 无输出，exit \(o.exitCode)）" : String(err.prefix(180))
        return PowerOutcome(ok: false, title: "指令未下发",
                            detail: "\(hint)。NAS 未执行任何电源操作。")
    }
}
