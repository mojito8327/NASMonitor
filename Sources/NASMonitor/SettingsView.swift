import SwiftUI
import AppKit

struct SettingsView: View {
    /// 仅 --render-settings 离屏验收用：放大窗口高度以便一次截到靠下的分组。
    /// 真机窗口仍固定 460×430，内部 ScrollView 正常滚动。
    static var previewHeight: CGFloat?
    /// 仅 --render-settings 离屏验收用：指定初始页签（--settings-tab services）
    static var previewTab: SettingsTab = .general

    @EnvironmentObject private var monitor: Monitor
    @ObservedObject private var cfg = Config.shared
    @ObservedObject private var appearance = AppearanceObserver.shared
    @ObservedObject private var catalog = ServiceCatalog.shared
    @State private var tab = SettingsView.previewTab
    @State private var amaneToken = ""
    @State private var jellyfinToken = ""
    @State private var sudoPassword = ""
    @State private var dsmUser = ""
    @State private var dsmPassword = ""
    @State private var newServiceName = ""
    @State private var newServicePort = ""
    @State private var newServiceURL = ""
    /// 行内改名草稿：输入中先不写目录，回车 / 失焦才提交，避免打断中文输入法组合。
    @State private var nameDrafts: [String: String] = [:]
    /// 行内网页地址草稿：同样延迟提交，避免每敲一个字符就写 UserDefaults。
    @State private var urlDrafts: [String: String] = [:]
    /// 候选端口加入前可先填自定义名称；留空则用 wellKnown 自动名称。
    @State private var candidateNames: [Int: String] = [:]
    @FocusState private var focusedNameKey: String?
    @State private var lastFocusedNameKey: String?
    @FocusState private var focusedURLKey: String?
    @State private var lastFocusedURLKey: String?
    @State private var savedHint = ""
    @State private var alertText = ""

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "常规"
        case services = "服务"
        case probes = "探针与凭据"
        case about = "关于"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case .general: general
                    case .services: servicesConfig
                    case .probes: probes
                    case .about: about
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: SettingsView.previewHeight ?? 430)
        .onAppear(perform: loadSecrets)
        // 光标离开名称框（点别处 / 切换焦点）即保存草稿；回车由 onSubmit 单独处理。
        .onChange(of: focusedNameKey) { newFocus in
            if let old = lastFocusedNameKey, old != newFocus {
                commitServiceName(old)
            }
            lastFocusedNameKey = newFocus
        }
        // 光标离开网页地址框同样即保存；回车由 onSubmit 单独处理。
        .onChange(of: focusedURLKey) { newFocus in
            if let old = lastFocusedURLKey, old != newFocus {
                commitServiceURL(old)
            }
            lastFocusedURLKey = newFocus
        }
        .onChange(of: catalog.services) { list in
            let keys = Set(list.map(\.key))
            nameDrafts = nameDrafts.filter { keys.contains($0.key) }
            urlDrafts = urlDrafts.filter { keys.contains($0.key) }
        }
        .onDisappear {
            if let key = lastFocusedNameKey { commitServiceName(key) }
            if let key = lastFocusedURLKey { commitServiceURL(key) }
        }
        .alert("提示", isPresented: Binding(
            get: { !alertText.isEmpty },
            set: { if !$0 { alertText = "" } }
        )) {
            Button("好") { alertText = "" }
        } message: { Text(alertText) }
    }

    // MARK: - 常规

    private var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text("界面外观 · 自动 / 手动切换").font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("外观", selection: Binding(
                        get: { appearance.mode },
                        set: { appearance.setMode($0) }
                    )) {
                        ForEach(AppearanceObserver.Mode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(appearance.isDark ? Color.white : Color.black)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.8))
                        Text("当前软件界面 \(appearance.isDark ? "深色" : "浅色")")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    Text("信号源：\(appearance.source)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(appearance.mode == .auto
                         ? "自动模式：软件面板随系统浅色 / 深色同步切换。这里不影响菜单栏图标，图标由 macOS 原生 template 机制自动染色。"
                         : "手动模式：软件面板锁定为「\(appearance.mode.title)」，不再跟随系统；菜单栏图标仍由 macOS 按菜单栏底色自动染色。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            GroupBox(label: Text("菜单栏图标 · macOS 原生自适应").font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        iconSwatch(dark: false, label: "浅色菜单栏")
                        iconSwatch(dark: true, label: "深色菜单栏")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("NSImage.isTemplate = true")
                                .font(.system(size: 10, design: .monospaced))
                            Text("同一张剪影，黑 / 白由 macOS 决定")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Text("换壁纸、动态桌面推进、切换浅色 / 深色时，系统按菜单栏底色自动重绘图标，与 Wi-Fi、电池等系统图标走同一条渲染通路。应用不读取壁纸文件、不计算亮度、不轮询，也不需要屏幕录制或辅助功能权限。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("右下角彩色状态点由独立 NSView 叠加在状态项上绘制，保留绿 / 橙 / 红 / 灰告警色（template 会把颜色单色化）。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            GroupBox(label: Text("目标主机").font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("IP / 域名").font(.system(size: 11)).frame(width: 78, alignment: .leading)
                        TextField("192.168.1.10", text: $cfg.host)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    Toggle("仅在内网时监测（外出自动静默）", isOn: $cfg.onlyLAN)
                        .font(.system(size: 11))
                    HStack {
                        Text("内网网段").font(.system(size: 11)).frame(width: 78, alignment: .leading)
                        TextField("192.168.1.", text: $cfg.lanPrefix)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .disabled(!cfg.onlyLAN)
                        Text("x").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("当前本机 IPv4：\(LANCheck.localIPv4s().joined(separator: ", "))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
            }

            GroupBox(label: Text("电源操作 · 顶部快捷按钮").font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("在面板顶部显示「关机 / 重启 / 打开 DSM」", isOn: $cfg.showPowerActions)
                        .font(.system(size: 11))
                    HStack {
                        Text("DSM 地址").font(.system(size: 11)).frame(width: 78, alignment: .leading)
                        TextField("留空自动使用 http://\(cfg.effectiveHost):5000/", text: $cfg.dsmURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                    Text("当前打开：\(PowerControl.dsmURL()?.absoluteString ?? "地址无效")")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Divider()
                    Text("关机 / 重启经免密 SSH + sudo 下发，需先在「探针与凭据」保存 sudo 密码（或给该用户配置 NOPASSWD）。命令只按空白拆词执行、不用 eval；确认弹窗会写明目标主机与实际命令。")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("关机命令").font(.system(size: 11)).frame(width: 78, alignment: .leading)
                        TextField(PowerControl.defaultCommand(.shutdown), text: $cfg.powerShutdownCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                    HStack {
                        Text("重启命令").font(.system(size: 11)).frame(width: 78, alignment: .leading)
                        TextField(PowerControl.defaultCommand(.reboot), text: $cfg.powerRebootCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                    Text("本机 DSM 7 实测 /usr/sbin/shutdown 是 systemd 软链，sudo -S 可提权；其它 NAS 请改成实际存在的绝对路径。关机后监测主动暂停，重启后静默 10 分钟，避免预期内断电被误报成离线告警。")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            GroupBox(label: Text("检查节奏 · 防 TCP 阻塞").font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 10) {
                    sliderRow("检查间隔", value: $cfg.interval, range: 30...600, step: 30, unit: "秒")
                    sliderRow("单次超时", value: $cfg.timeout, range: 2...20, step: 1, unit: "秒")
                    HStack {
                        Text("状态确认轮数").font(.system(size: 11)).frame(width: 78, alignment: .leading)
                        Stepper(value: $cfg.confirmations, in: 1...5) {
                            Text("\(cfg.confirmations) 轮一致后才切换状态")
                                .font(.system(size: 11))
                        }
                        Spacer()
                    }
                    Toggle("阻塞时自动拉长间隔（自适应节流）", isOn: $cfg.adaptiveThrottle)
                        .font(.system(size: 11))
                    HStack(spacing: 6) {
                        Text("当前倍率 ×\(monitor.throttleMultiplier)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(monitor.throttleMultiplier > 1 ? .orange : .secondary)
                        if !monitor.throttleNote.isEmpty {
                            Text(monitor.throttleNote)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    Text("三种网络作业（分层探测 / 性能采样 / 磁盘体检）由同一闸门串行执行，不会同时开多组连接。一轮出现 ≥2 个超时或读库阻塞时立即收手：未发出的读库请求取消、已挂住的 dataTask 立刻断开、超时不再补发 curl；下一轮间隔 ×2 → 最多 ×4，同时暂停采样与体检。连续 2 轮无超时后逐级回落，面板状态条会显示橙色「阻塞熔断」。")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("存储层阻塞会跳过确认轮数立即告警；恢复正常需要满足轮数。")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                .padding(8)
            }

            GroupBox(label: Text("告警").font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("发送系统通知", isOn: $cfg.notifyEnabled).font(.system(size: 11))
                    Toggle("异常时播放提示音", isOn: $cfg.soundEnabled).font(.system(size: 11))
                    Toggle("开机自动启动", isOn: $cfg.launchAtLogin)
                        .font(.system(size: 11))
                        .onChange(of: cfg.launchAtLogin, perform: { on in
                            do { try monitor.setLaunchAtLogin(on) }
                            catch {
                                alertText = "设置开机自启失败：\(error.localizedDescription)。也可以到「系统设置 → 通用 → 登录项」手动添加。"
                                cfg.launchAtLogin = false
                            }
                        })
                }
                .padding(8)
            }
        }
    }

    /// 设置页示意图：模拟系统把同一张 template 图在两种菜单栏底色下染成黑 / 白。
    private func iconSwatch(dark: Bool, label: String) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(dark ? Color(white: 0.13) : Color(white: 0.94))
                if let icon = MenuBarIcon.preview(isDark: dark, health: monitor.health) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 21, height: 20)
                }
            }
            .frame(width: 62, height: 24)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.4), lineWidth: 0.8))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, unit: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).frame(width: 78, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text("\(Int(value.wrappedValue)) \(unit)")
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 48, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 探针与凭据

    // MARK: - 服务目录与端口发现

    private var servicesConfig: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("服务列表直接决定总览页的行数与每轮 TCP 探针，增删后下一轮立即生效。磁盘的卷 / 阵列 / 物理盘由每次体检自动枚举，无需在这里配置。")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox(label: Text("当前监测的服务 · \(catalog.services.count) 个")
                .font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 5) {
                    if catalog.services.isEmpty {
                        Text("尚未配置服务").font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(catalog.services) { s in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(catalog.missingKeys.contains(s.key)
                                          ? Color.secondary : Color.green)
                                    .frame(width: 6, height: 6)
                                TextField("名称", text: nameBinding(key: s.key, current: s.name))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 10.5))
                                    .frame(width: 104)
                                    .focused($focusedNameKey, equals: s.key)
                                    .onSubmit { commitServiceName(s.key) }
                                // 用 String 拼接而不是 Text 的数字插值，否则会显示成 :5,000
                                Text(":" + String(s.port))
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(width: 56, alignment: .leading)
                                Text(s.origin == .builtIn ? "内置"
                                     : (s.origin == .discovered ? "自动" : "自定"))
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                                    .frame(width: 30, alignment: .leading)
                                Toggle("关键", isOn: Binding(
                                    get: { s.critical },
                                    set: { catalog.setCritical(key: s.key, on: $0) }
                                ))
                                .toggleStyle(.checkbox).font(.system(size: 9.5))
                                Spacer(minLength: 2)
                                if catalog.missingKeys.contains(s.key) {
                                    Text("未监听").font(.system(size: 9)).foregroundStyle(.orange)
                                }
                                Button("删除") { catalog.remove(key: s.key) }
                                    .controlSize(.small)
                            }
                            // 第二行：网页地址。留空即按 http://主机:端口 自动推断，
                            // 总览页服务行右侧的 ⤴ 按钮用的就是这里解析出来的地址。
                            HStack(spacing: 6) {
                                Text("网页")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28, alignment: .leading)
                                TextField("留空 = http://主机:端口",
                                          text: urlBinding(key: s.key, current: s.urlString ?? ""))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 9.5))
                                    .focused($focusedURLKey, equals: s.key)
                                    .onSubmit { commitServiceURL(s.key) }
                                Button {
                                    if let url = ServiceLinks.resolve(spec: s, host: cfg.effectiveHost) {
                                        NSWorkspace.shared.open(url)
                                    }
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .disabled(ServiceLinks.resolve(spec: s, host: cfg.effectiveHost) == nil)
                                .help("在浏览器打开该服务；SSH 等非网页端口需先填写地址")
                            }
                            .padding(.leading, 12)
                        }
                    }
                    Text("名称框可直接修改，回车或点击别处保存；改名只换显示文字，服务标识、端口、「关键」标记与探针结果都保持连续。网页地址可填完整 https 地址、/路径或含 {host} / {port} 的模板；留空则按 主机:端口 自动推断，SSH / BT 等无网页端口不显示跳转按钮。")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    HStack(spacing: 8) {
                        if !catalog.missingKeys.isEmpty {
                            Button("移除所有未监听服务 (\(catalog.missingKeys.count))") {
                                catalog.removeMissing()
                            }.controlSize(.small)
                        }
                        Button("恢复默认服务列表") {
                            catalog.reset()
                            nameDrafts.removeAll()
                            urlDrafts.removeAll()
                            candidateNames.removeAll()
                            alertText = "已恢复内置服务，网页地址、端口候选与忽略表已清空。"
                        }.controlSize(.small)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("手动添加服务").font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("名称", text: $newServiceName)
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                        TextField("端口", text: $newServicePort)
                            .textFieldStyle(.roundedBorder).frame(width: 68)
                        Button("添加") {
                            let p = Int(newServicePort.trimmingCharacters(in: .whitespaces)) ?? 0
                            let raw = newServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            let clean = ServiceLinks.normalizedTemplate(raw)
                            if !raw.isEmpty, clean == nil {
                                alertText = "网页地址不合法：只支持 http / https，且不超过 \(ServiceLinks.maxTemplateLength) 个字符。"
                                return
                            }
                            if catalog.add(name: newServiceName, port: p,
                                           urlString: raw.isEmpty ? nil : clean) {
                                newServiceName = ""
                                newServicePort = ""
                                newServiceURL = ""
                            } else {
                                alertText = "请填写 1–\(ServiceCatalog.maxNameLength) 字的名称与 1–65535 之间的端口。"
                            }
                        }.controlSize(.small)
                    }
                    TextField("网页地址（可选，留空 = 自动按 主机:端口 打开）", text: $newServiceURL)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10))
                    Text("名称随时可在上方列表里直接改；同一端口再次添加只更新名称，不会重置「关键」标记。删除过的端口会记入忽略表，不会反复被当成新服务提示。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("端口发现 · 随低频磁盘体检带回")
                .font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("自动把新端口纳入监测（默认关闭，建议先确认）",
                           isOn: Binding(get: { catalog.autoAdopt },
                                         set: { catalog.setAutoAdopt($0) }))
                        .font(.system(size: 10.5))
                    Text(catalog.lastObserved == nil
                         ? "尚未完成一次磁盘体检。"
                         : "最近一次体检看到 \(catalog.observedPorts.count) 个对外监听端口。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if catalog.discovered.isEmpty {
                        Text("当前没有待确认的新端口。")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    } else {
                        Text("待确认的新端口 · \(catalog.discovered.count) 个")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("名称框里可以直接写自定义名称，再点「加入」；留空则使用自动识别名。")
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(catalog.discovered, id: \.self) { p in
                            HStack(spacing: 6) {
                                Text(":" + String(p))
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(width: 58, alignment: .leading)
                                TextField(catalog.name(forPort: p), text: candidateNameBinding(p))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 10.5))
                                    .frame(width: 118)
                                Spacer(minLength: 2)
                                Button("加入") { adoptCandidate(p) }.controlSize(.small)
                                Button("忽略") {
                                    catalog.ignore(port: p)
                                    candidateNames.removeValue(forKey: p)
                                }.controlSize(.small)
                            }
                        }
                        HStack(spacing: 8) {
                            Button("全部加入") {
                                catalog.adoptAll()
                                candidateNames.removeAll()
                            }.controlSize(.small)
                            Button("全部忽略") {
                                for p in catalog.discovered { catalog.ignore(port: p) }
                                candidateNames.removeAll()
                            }.controlSize(.small)
                        }
                        .padding(.top, 2)
                    }
                    Text("系统端口（22 / 80 / 443 / 5000 / 5001 / 5357 / 326x 等）不进候选；端口发现只复用磁盘体检那一次只读 SSH，不额外发起 TCP 连接，也不会加重 NAS 阻塞。自动纳入的服务一旦端口消失会自动移除；手工确认的服务只标灰，由你决定是否删除。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 名称编辑辅助

    /// 草稿只在内存里，提交前不会碰 UserDefaults；`current` 是目录里的当前名称。
    private func nameBinding(key: String, current: String) -> Binding<String> {
        Binding(get: { nameDrafts[key] ?? current },
                set: { nameDrafts[key] = $0 })
    }

    private func candidateNameBinding(_ port: Int) -> Binding<String> {
        Binding(get: { candidateNames[port] ?? "" },
                set: { candidateNames[port] = $0 })
    }

    /// 回车 / 失焦 / 页面消失时提交。空名或超长名不入库，保留原名称并提示。
    private func commitServiceName(_ key: String) {
        guard let draft = nameDrafts.removeValue(forKey: key) else { return }
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            alertText = "名称不能为空，已保留原来的名称。"
            return
        }
        if !catalog.rename(key: key, name: clean) {
            alertText = "名称需为 1–\(ServiceCatalog.maxNameLength) 个字符，已保留原来的名称。"
        }
    }

    private func urlBinding(key: String, current: String) -> Binding<String> {
        Binding(get: { urlDrafts[key] ?? current },
                set: { urlDrafts[key] = $0 })
    }

    /// 回车 / 失焦 / 页面消失时提交网页地址。非法输入保留草稿并提示，
    /// 不让用户敲了半天的地址被静默丢掉。
    private func commitServiceURL(_ key: String) {
        guard let draft = urlDrafts[key] else { return }
        if catalog.setURL(key: key, raw: draft) {
            urlDrafts.removeValue(forKey: key)
        } else {
            alertText = "网页地址不合法：只支持 http / https，且不超过 \(ServiceLinks.maxTemplateLength) 个字符。"
        }
    }

    private func adoptCandidate(_ port: Int) {
        guard catalog.adopt(port: port, name: candidateNames[port]) else {
            alertText = "名称需为 1–\(ServiceCatalog.maxNameLength) 个字符，请修改后再加入。"
            return
        }
        candidateNames.removeValue(forKey: port)
    }

    private var probes: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("常规监测不需要任何密码，每轮只做轻量 TCP / HTTP 探测，不建立 SSH 连接。以下凭据只用于低频磁盘体检（默认 15 分钟一次，阻塞熔断期间暂停）与面板顶部的关机 / 重启指令，保存在仅当前用户可读的本地文件（权限 0600），不会触发 macOS 钥匙串授权弹窗。")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("凭据文件：~/Library/Application Support/NASMonitor/credentials.json")
                .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)

            GroupBox(label: Text("SSH 深度探测").font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("启用磁盘体检所需的 SSH（需已配置免密公钥）", isOn: $cfg.sshEnabled)
                        .font(.system(size: 11))
                    HStack {
                        Text("用户名").font(.system(size: 11)).frame(width: 78, alignment: .leading)
                        TextField("admin", text: $cfg.sshUser)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .disabled(!cfg.sshEnabled)
                    }
                    Toggle("定期磁盘体检（阵列 / 空间 / D 状态进程）", isOn: $cfg.diskCheckEnabled)
                        .font(.system(size: 11))
                        .disabled(!cfg.sshEnabled)
                }
                .padding(8)
            }

            GroupBox(label: Text("可选：sudo 读取 dmesg 与 SMART").font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("启用 SATA 链路错误检查", isOn: $cfg.useSudo).font(.system(size: 11))
                    HStack {
                        Text("sudo 密码").font(.system(size: 11)).frame(width: 78, alignment: .leading)
                        SecureField("留空则不修改", text: $sudoPassword)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Button("保存") {
                            CredentialStore.set(CredentialStore.Key.sudoPassword, sudoPassword)
                            sudoPassword = ""
                            savedHint = "sudo 密码已保存"
                        }
                        .disabled(sudoPassword.isEmpty)
                    }
                    Text("通过 stdin 注入，不会出现在命令行或日志里。用于抓 SError / WRITE DMA / qc timeout 等掉盘前兆。")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            GroupBox(label: Text("可选：API Token").font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Amane 携带 Token 探测 /api/tasks", isOn: $cfg.useAmaneToken)
                        .font(.system(size: 11))
                    HStack {
                        Text("Amane").font(.system(size: 11)).frame(width: 78, alignment: .leading)
                        SecureField("Bearer Token", text: $amaneToken)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        Button("保存") {
                            CredentialStore.set(CredentialStore.Key.amaneToken, amaneToken)
                            amaneToken = ""; savedHint = "Amane Token 已保存"
                        }.disabled(amaneToken.isEmpty)
                    }
                    Toggle("Jellyfin 携带 Token 探测 /Users", isOn: $cfg.useJellyfinToken)
                        .font(.system(size: 11))
                    HStack {
                        Text("Jellyfin").font(.system(size: 11)).frame(width: 78, alignment: .leading)
                        SecureField("Access Token", text: $jellyfinToken)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        Button("保存") {
                            CredentialStore.set(CredentialStore.Key.jellyfinToken, jellyfinToken)
                            jellyfinToken = ""; savedHint = "Jellyfin Token 已保存"
                        }.disabled(jellyfinToken.isEmpty)
                    }
                    Text("不配 Token 时，Amane 请求会在鉴权层返回 401，只能验证通道而不能验证数据库；Jellyfin 的假凭据认证已能穿透用户库，是默认的主力探针。")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            GroupBox(label: Text("整机性能采样（CPU / 内存 / 网络上下行）").font(.system(size: 11, weight: .semibold))) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("启用性能采样", isOn: $cfg.metricsEnabled).font(.system(size: 11))
                    sliderRow("采样间隔", value: $cfg.metricsInterval, range: 30...600, step: 30, unit: "秒")
                    Toggle("用示例数据预览图表（不写入真实历史）", isOn: $cfg.showDemoMetrics)
                        .font(.system(size: 11))
                    Text("打开后总览页会显示橙色「演示数据」标记，仅用于查看图表样式。")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()
                    Text("网络上下行只统计整台 NAS 的物理网卡（本机实测仅 eth0），docker 网桥 / veth / sit / lo 一律排除；bond 不与成员口重复计数。不会用 qBittorrent 等任何单个服务的速率代替整机数据。")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("DSM 凭据 · 存本地 0600 文件，不使用钥匙串；密码经 stdin 传给 curl，不出现在命令行或日志")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    credentialRow("DSM 账号", text: $dsmUser, secure: false)
                    credentialRow("DSM 密码", text: $dsmPassword, secure: true)
                    HStack {
                        Spacer()
                        Button("保存 DSM") {
                            if !dsmUser.isEmpty { CredentialStore.set(CredentialStore.Key.dsmUser, dsmUser) }
                            if !dsmPassword.isEmpty { CredentialStore.set(CredentialStore.Key.dsmPassword, dsmPassword) }
                            dsmUser = ""; dsmPassword = ""
                            savedHint = "DSM 凭据已保存"
                        }
                        .controlSize(.small)
                        .disabled(dsmUser.isEmpty && dsmPassword.isEmpty)
                    }

                    Text("数据来源只有两条整机通道：SSH 读 /proc（当前可用）→ DSM Utilization（当前登录返回 407）。某条通道失败会自动退避，恢复后无需改配置；两条都不可用时 CPU / 内存 / 网络一律显示「—」，不填推算值。")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            if !savedHint.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(savedHint).font(.system(size: 10))
                }
            }
        }
    }

    private func credentialRow(_ label: String, text: Binding<String>, secure: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).frame(width: 78, alignment: .leading)
            Group {
                if secure {
                    SecureField("留空则不修改", text: text)
                } else {
                    TextField("留空则不修改", text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: secure ? .default : .monospaced))
        }
    }

    // MARK: - 关于

    /// 不再写死「6 个服务 / 2 个阵列」：按当前服务目录与最近一次体检清单生成。
    private var monitorObjectText: String {
        let svc = catalog.services.isEmpty ? "未配置服务"
            : catalog.services.map { "\($0.name) \($0.port)" }.joined(separator: " · ")
        let disk: String
        if let d = monitor.disk {
            disk = "阵列 \(d.arrays.count) 组（\(d.arrays.map(\.name).joined(separator: "/"))）"
                + " · 卷 \(d.volumes.count) 个（\(d.volumes.map(\.mount).joined(separator: "/"))）"
                + " · 物理盘 \(d.physicalDisks.count) 块"
        } else {
            disk = "阵列 / 卷 / 物理盘按每次体检动态枚举"
        }
        return "当前服务：\(svc)。磁盘：\(disk)。增删服务或插拔盘后，下一轮自动更新，无需改代码。"
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Group {
                    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                       let icon = NSImage(contentsOf: url) {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NASMonitor").font(.system(size: 16, weight: .semibold))
                    // 版本号只从 AppVersion 读（由 VERSION 生成），不再写死在界面里。
                    Text("\(AppVersion.display) (build \(AppVersion.build)) · 为 192.168.1.10 的 DSM 7 定制")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("判据来源")
                .font(.system(size: 11, weight: .semibold))
            Text("依据 2026-11-06 的存储链路故障实测：TCP 端口仍 accept、favicon 与 SYNO.Core.System 秒回，但所有读数据库的操作超时。普通 ping / 端口监控完全发现不了这种半死状态，因此本应用把「静态层正常 + 存储层超时」作为独立告警级别。涉事硬盘已拔除，背板与 SATA 线已于 11-07 整体更换；磁盘体检的 D 状态计数改为连续 3 次快照，瞬时内核线程不再触发红色告警。")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("监测对象")
                .font(.system(size: 11, weight: .semibold))
            Text(monitorObjectText)
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 8) {
                Button("清空历史记录") { monitor.clearHistory() }
                    .controlSize(.small)
                Button("恢复默认设置") {
                    cfg.reset()
                    catalog.reset()
                    nameDrafts.removeAll()
                    candidateNames.removeAll()
                    appearance.setMode(.auto)
                    alertText = "已恢复默认值（外观回到自动、服务列表回到内置 6 个），重启应用后完全生效。"
                }
                .controlSize(.small)
                Spacer()
            }
        }
    }

    private func loadSecrets() {
        // 只显示是否已配置，不把密钥读回文本框
        amaneToken = ""
        jellyfinToken = ""
        sudoPassword = ""
        dsmUser = ""; dsmPassword = ""
        let hasAmane = CredentialStore.has(CredentialStore.Key.amaneToken)
        let hasJf = CredentialStore.has(CredentialStore.Key.jellyfinToken)
        let hasSudo = CredentialStore.has(CredentialStore.Key.sudoPassword)
        let hasDSM = CredentialStore.has(CredentialStore.Key.dsmPassword)
        var names: [String] = []
        if hasAmane { names.append("Amane") }
        if hasJf { names.append("Jellyfin") }
        if hasSudo { names.append("sudo") }
        if hasDSM { names.append("DSM") }
        savedHint = names.isEmpty
            ? "尚未配置任何凭据（常规监测不需要）"
            : names.joined(separator: " / ") + " 凭据已配置"
    }
}
