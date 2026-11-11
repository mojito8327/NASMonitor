# NASMonitor

macOS 菜单栏常驻应用，监测局域网内 NAS 的**真实健康状态**——尤其是「端口还通、静态页还能秒回，但读数据库已经卡死」这种 ping / 端口监控发现不了的半死状态。原生 SwiftUI + SwiftPM，无第三方依赖，macOS 13+ / Swift 5.9+。

## 为什么需要它

NAS 的存储链路（掉盘、背板、阵列挂起）出问题时机器往往没有死机：SSH 端口仍 accept、静态页仍秒回，只有真正读数据库的请求一直超时。此时 ping 通、端口通，媒体库却已刷不出来，重启还可能卡在停 Docker 上。

NASMonitor 把「静态层正常 + 存储层超时」单独建模为 `stalled` 级别，并用一次**假凭据登录**穿透到认证 / 用户库验证磁盘是否真的可读。

## 功能

- **四层探测**：TCP 端口 → 免认证静态路径 → 读库探针 → 低频 SSH 磁盘体检（阵列、容量、D 状态进程，可选 sudo 查 SATA 错误）。
- **不会把 NAS 问死**：默认 120 秒一轮、磁盘体检 15 分钟，全局串行闸门保证任意时刻只有一个网络作业；发现阻塞迹象立刻停止后续建连、`cancel()` 释放 socket，并自动 ×2 / ×4 拉长间隔。
- **动态清单**：卷 / 阵列 / 物理盘按 `df -kP`、`/proc/mdstat`、`/sys/block` 全量枚举，插拔后自动跟随；服务目录可在「设置 → 服务」运行时增删、改名、配网页地址。
- **状态机**：`online / degraded / stalled / offline / away`，连续 N 轮确认后切换，`stalled` 立即告警，离开内网自动静默。
- **整机性能**：CPU、内存、物理网卡上下行、物理整盘读写吞吐；数据缺失显示 `—`，不填推算值。
- **两页面板**：总览（性能 + 磁盘 + 服务 + 趋势）与日志（状态变化 + SATA / I/O 明细）。
- **安全**：凭据只存本机 `0600` 文件（`~/Library/Application Support/NASMonitor/credentials.json`）；关机 / 重启需手动输入 NAS IP 或密码后四位二次确认，自动监测永不下发电源指令。
- **排障报告**：一键把最近一轮结果汇总为 Markdown（自动脱敏，不含凭据）。

## 安装

### 方式 A：预编译包（Apple Silicon）

到 [Releases](https://github.com/mojito8327/NASMonitor/releases/latest) 下载 `NASMonitor-1.3.zip`：

```bash
curl -fL -O https://github.com/mojito8327/NASMonitor/releases/download/v1.3/NASMonitor-1.3.zip
shasum -a 256 -c SHA256SUMS      # 可选校验
unzip -q NASMonitor-1.3.zip
/usr/bin/xattr -cr NASMonitor.app   # 首次打开被 Gatekeeper 拦截时
open NASMonitor.app
```

包为 arm64；Intel Mac 请用方式 B。应用为 ad-hoc 签名、未公证，也可在「系统设置 → 隐私与安全性」点「仍要打开」。

### 方式 B：从源码构建（任意 Mac）

```bash
git clone https://github.com/mojito8327/NASMonitor.git
cd NASMonitor
./build.sh
open NASMonitor.app
```

`build.sh` 会还原图标、`swift build -c release`、组装并签名 `.app`，结尾跑版本一致性门禁。

## 首次使用

打开后在菜单栏图标 → 设置：

1. **常规**：把目标主机改成你的 NAS 地址（默认值是示例 `192.168.1.30`）。
2. **探针与凭据**：SSH 用户名与免密公钥（磁盘体检用）；DSM / 媒体库 Token 可选，缺失时对应字段显示 `—`，不会误报。
3. **电源**：如需面板上的关机 / 重启，需配置 `sudo.password` 或给该用户 NOPASSWD；可先用 `--power-check` 只读验证。

常规四层探测不需要任何密码。

## 命令行

```bash
BIN="NASMonitor.app/Contents/MacOS/NASMonitor"

"$BIN" --selftest --no-disk   # 跑一轮只读探测
"$BIN" --inventory            # 列卷 / 阵列 / 物理盘 / 监听端口
"$BIN" --services             # 服务目录与网页地址
"$BIN" --throttle             # 当前节流倍率与节奏
"$BIN" --power-check          # 只读检查电源前置条件
"$BIN" --report               # 打印排障报告（脱敏）
"$BIN" --version              # 版本与包内 plist 核对
```

其余 `--*-selftest` 为纯内存自检，不建连接；`--store-cred <key>` 从 stdin 读值，不写进 shell 历史。

## 隐私与网络行为

- 只访问设置页配置的主机；强制清空代理字典，避免系统代理劫持内网地址。
- 不上传遥测 / 崩溃报告 / 监测数据，无需联网账号。
- 凭据、历史、性能样本均在本机 `0600` 文件，原子写入。
- 不读壁纸、不截图、不需要屏幕录制或辅助功能权限。
- 仅在内网时监测（可关闭），外出自动静默。

## 版本与发布

根目录 `VERSION` 是唯一版本源（`MARKETING=1.3` / `BUILD=4`）；`scripts/version.sh` 负责 `print / sync / stamp / bump / check`，`build.sh` 每次构建自动同步并在结尾跑 11 项一致性门禁。发布流程：`./scripts/version.sh bump <新版本>` → `./build.sh` → 重新打包 → `check` → `git tag`。

## 已知限制

- 仅 macOS 13+；预编译包 arm64，Intel 需自建。
- ad-hoc 签名、未公证，首次打开需手动放行。
- 磁盘吞吐只来自 SSH `/proc/diskstats`；SSH 不可用或数据在 LVM / 硬件 RAID 虚拟盘上时显示 `—`。

## License

[MIT](LICENSE) © 2026 mojito8327
