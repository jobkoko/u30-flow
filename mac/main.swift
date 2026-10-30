import AppKit
import Foundation
import ServiceManagement

let appID = "local.u30flow.menubar"
let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/U30 Flow")
struct Configuration: Codable {
    let routerHost: String
    let sshUser: String
    let sshPort: Int
    func validated() throws -> Configuration {
        guard routerHost.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$", options: .regularExpression) != nil,
              sshUser.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil,
              (1...65535).contains(sshPort) else {
            throw NSError(domain: "U30FlowConfiguration", code: 1, userInfo: [NSLocalizedDescriptionKey: "请填写有效的主机名/IPv4地址、SSH用户名和端口。"])
        }
        return self
    }
    static func load() -> Configuration? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("config.json")),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return try? value.validated()
    }
}
var configuration = Configuration.load()
var router: String { configuration?.routerHost ?? "router.local" }
var billingOffset = 28800

struct Subscription: Codable {
    let date: String
    let first, updated, used, today, total, expire, remaining: Double
    let partial, reset: Int
}
struct Snapshot: Codable {
    let uptime, rx, tx: Double
    let vpn, metadata_error: Int
    let subscription: Subscription?
    let utc_offset: Int?
}
func bytes(_ n: Double, short: Bool = false) -> String {
    let units = short ? ["B", "K", "M", "G", "T"] : ["B", "KB", "MB", "GB", "TB"]
    var v = max(0, n), u = 0
    while v >= 1000 && u < units.count - 1 { v /= 1000; u += 1 }
    let digits = v >= 100 || u == 0 ? 0 : (v >= 10 ? 1 : 2)
    return String(format: "%.*f%@%@", digits, v, short ? "" : " ", units[u])
}
func timeText(_ n: Double, date: Bool = false) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
    f.timeZone = TimeZone(secondsFromGMT: billingOffset)
    f.dateFormat = date ? "yyyy-MM-dd HH:mm" : "HH:mm:ss"
    return f.string(from: Date(timeIntervalSince1970: n))
}
struct CommandResult { let code: Int32; let text: String }
func run(_ executable: String, _ args: [String], timeout: Double = 10) -> CommandResult {
    let p = Process(), output = Pipe()
    p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
    p.standardOutput = output; p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return CommandResult(code: -1, text: "") }
    let ended = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async { p.waitUntilExit(); ended.signal() }
    if ended.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        if ended.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return CommandResult(code: p.isRunning ? -2 : p.terminationStatus, text: String(data: data, encoding: .utf8) ?? "")
}
func sshArguments(_ command: String) -> [String] {
    return ["-T", "-n", "-p", String(configuration?.sshPort ?? 22), "-i", support.appendingPathComponent("monitor_ed25519").path,
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
            "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\"\(support.appendingPathComponent("known_hosts").path)\"",
            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "\(configuration?.sshUser ?? "root")@\(router)", command]
}

final class BarView: NSView {
    var first = "U30 Flow · 连接中"
    var second = "正在读取订阅用量"
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    var textWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font]
        return max((first as NSString).size(withAttributes: attributes).width,
                   (second as NSString).size(withAttributes: attributes).width)
    }
    var fittedWidth: CGFloat { ceil(textWidth) + 4 }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.black.withAlphaComponent(0.75) : NSColor.white.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 1.2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        // Both rows are primary menu bar content; translucency needs equal contrast.
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: p, .shadow: shadow]
        (first as NSString).draw(in: NSRect(x: 2, y: bounds.midY + 0.5, width: bounds.width - 4, height: 12), withAttributes: attrs)
        (second as NSString).draw(in: NSRect(x: 2, y: bounds.midY - 11.5, width: bounds.width - 4, height: 12), withAttributes: attrs)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!, bar: BarView!, menu = NSMenu()
    var process: Process?, buffer = Data(), timer: Timer?
    var snapshot: Snapshot?, previous: Snapshot?, lastMessage = Date.distantPast
    var down = 0.0, up = 0.0, lanMS: Double?, webMS: Double?
    var webState = "等待检测", checking = false, online = false, stopping = false
    var lastProbe = Date.distantPast, nextReconnect = Date.distantPast
    var menuFields: [String: NSMenuItem] = [:]
    var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: appID).filter({ $0.processIdentifier != getpid() }).count > 0 {
            NSApp.terminate(nil); return
        }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: support.appendingPathComponent("last-snapshot.json")) {
            snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
            if let offset = snapshot?.utc_offset, (-50400...50400).contains(offset) { billingOffset = offset }
        }
        item = NSStatusBar.system.statusItem(withLength: 160)
        if let button = item.button {
            bar = BarView(frame: button.bounds); bar.autoresizingMask = [.width, .height]
            button.addSubview(bar); button.toolTip = "U30 Flow：订阅余量、今日订阅增量和 U30 实时网络状态"
            button.setAccessibilityLabel("U30 Flow 订阅与网络状态")
        }
        menu.delegate = self; item.menu = menu; makeMenu()
        connect()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func field(_ id: String, _ title: String) {
        let x = NSMenuItem(title: title, action: nil, keyEquivalent: ""); x.isEnabled = false
        menu.addItem(x); menuFields[id] = x
    }
    func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let x = NSMenuItem(title: title, action: selector, keyEquivalent: ""); x.target = self; menu.addItem(x); return x
    }
    func makeMenu() {
        field("state", "U30 Flow · 正在连接")
        menu.addItem(.separator())
        field("remaining", "订阅剩余：读取中")
        field("today", "今日订阅用量：读取中")
        field("coverage", "")
        field("updated", "")
        field("expire", "")
        menu.addItem(.separator())
        field("down", "U30 下行：—")
        field("up", "U30 上行：—")
        field("lan", "路由器响应：—")
        field("web", "外网响应（HTTPS）：—")
        field("vpn", "路由器代理：—")
        field("scope", "实时速率包括连接 U30 的全部设备")
        menu.addItem(.separator())
        _ = action("连接设置…", #selector(settings))
        _ = action("立即检测网络", #selector(refresh))
        _ = action("打开路由器后台", #selector(openRouter))
        _ = action("统计口径与隐私说明…", #selector(explain))
        loginItem = action("登录 Mac 时自动启动", #selector(toggleLogin))
        menu.addItem(.separator())
        _ = action("退出 U30 Flow", #selector(quit))
        updateDisplay()
    }
    func menuWillOpen(_ menu: NSMenu) { updateDisplay() }
    func connect() {
        guard !stopping, process == nil, configuration != nil else { return }
        let p = Process(), pipe = Pipe()
        // Bound the SSH child's lifetime to this app, including a crash or SIGKILL.
        // Pass arguments separately so paths with spaces never become shell code.
        let supervisedSSH = """
        owner=$1
        shift
        /usr/bin/ssh "$@" &
        connection=$!
        guard_pid=
        cleanup() {
            kill "$connection" 2>/dev/null || :
            [ -z "$guard_pid" ] || kill "$guard_pid" 2>/dev/null || :
        }
        trap 'cleanup; exit 143' TERM HUP INT
        (
            while kill -0 "$owner" 2>/dev/null; do sleep 2; done
            kill "$connection" 2>/dev/null || :
        ) &
        guard_pid=$!
        wait "$connection"
        result=$?
        cleanup
        exit "$result"
        """
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", supervisedSSH, "u30-flow-connection", String(getpid())] + sshArguments("u30-stream")
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        buffer.removeAll(keepingCapacity: true)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        p.terminationHandler = { [weak self] dead in
            DispatchQueue.main.async {
                guard let self, self.process === dead else { return }
                self.process = nil; self.online = false; self.previous = nil; self.down = 0; self.up = 0
                self.lanMS = nil; self.webMS = nil; self.webState = "等待检测"; self.lastProbe = .distantPast
                self.nextReconnect = Date().addingTimeInterval(5); self.updateDisplay()
            }
        }
        do { try p.run(); process = p } catch { nextReconnect = Date().addingTimeInterval(10) }
    }
    func receive(_ data: Data) {
        buffer.append(data)
        if buffer.count > 65536 { buffer.removeAll(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
            guard let s = try? JSONDecoder().decode(Snapshot.self, from: Data(line)) else { continue }
            if let old = previous, s.uptime > old.uptime, s.uptime - old.uptime < 20, s.rx >= old.rx, s.tx >= old.tx {
                down = (s.rx - old.rx) / (s.uptime - old.uptime)
                up = (s.tx - old.tx) / (s.uptime - old.uptime)
            } else { down = 0; up = 0 }
            previous = s; snapshot = s; online = true; lastMessage = Date()
            if let offset = s.utc_offset, (-50400...50400).contains(offset) { billingOffset = offset }
            if let encoded = try? JSONEncoder().encode(s) {
                let path = support.appendingPathComponent("last-snapshot.json")
                try? encoded.write(to: path, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
            updateDisplay()
            if Date().timeIntervalSince(lastProbe) >= 30 { probe() }
        }
    }
    func tick() {
        if process == nil && Date() >= nextReconnect { connect() }
        if online && Date().timeIntervalSince(lastMessage) > 12 {
            online = false; previous = nil; down = 0; up = 0; process?.terminate(); updateDisplay()
        }
        if online && Date().timeIntervalSince(lastProbe) >= 30 { probe() }
    }
    func probe() {
        guard online, !checking else { return }
        checking = true; lastProbe = Date()
        let probedRouter = router
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let route = run("/sbin/route", ["-n", "get", probedRouter], timeout: 3)
            let iface = route.text.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") })?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
            let ping = run("/sbin/ping", ["-n", "-c", "1", "-W", "1000", probedRouter], timeout: 3)
            let regex = try? NSRegularExpression(pattern: "time[=<]([0-9.]+) ms")
            var lan: Double?
            if let match = regex?.firstMatch(in: ping.text, range: NSRange(ping.text.startIndex..., in: ping.text)), let range = Range(match.range(at: 1), in: ping.text) { lan = Double(ping.text[range]) }
            // Resolve through U30 and bind the HTTPS probe to the interface that reaches U30.
            // Another Wi-Fi/hotspot on this Mac must not be mistaken for U30's Internet path.
            let dns = run("/usr/bin/dig", ["@\(probedRouter)", "www.gstatic.com", "A", "+short", "+time=2", "+tries=1"], timeout: 4)
            let ip = dns.text.split(separator: "\n").map(String.init).first(where: {
                let parts = $0.split(separator: "."); return parts.count == 4 && parts.allSatisfy { Int($0).map { 0...255 ~= $0 } ?? false }
            })
            var ms: Double?, state = "DNS 无响应"
            if let ip, !iface.isEmpty {
                let r = run("/usr/bin/curl", ["--noproxy", "*", "--interface", iface, "-4", "-sS", "--connect-timeout", "5", "--max-time", "8", "--resolve", "www.gstatic.com:443:\(ip)", "-o", "/dev/null", "-w", "%{http_code} %{time_total}", "https://www.gstatic.com/generate_204"], timeout: 9)
                let fields = r.text.split(separator: " ")
                if r.code == 0, fields.count == 2, fields[0] == "204", let seconds = Double(fields[1]) { ms = seconds * 1000; state = "正常" }
                else { state = r.code == 28 ? "请求超时" : "暂不可用" }
            }
            DispatchQueue.main.async {
                guard let self, router == probedRouter else { return }
                self.lanMS = lan; self.webMS = ms; self.webState = state; self.checking = false; self.updateDisplay()
            }
        }
    }
    func updateDisplay() {
        guard bar != nil else { return }
        let s = snapshot?.subscription
        let df = DateFormatter(); df.timeZone = TimeZone(secondsFromGMT: billingOffset); df.dateFormat = "yyyy-MM-dd"
        let isToday = s.map { $0.date == df.string(from: Date()) } ?? false
        let stale = s.map { Date().timeIntervalSince1970 - $0.updated > 900 || !isToday || snapshot?.metadata_error == 1 } ?? true
        var usageLine = "今 — · 余 —"
        if let s {
            usageLine = "今 \(bytes(s.today, short: true)) · 余 \(bytes(s.remaining, short: true))"
            menuFields["remaining"]?.title = "订阅剩余：\(bytes(s.remaining)) / \(bytes(s.total))"
            menuFields["today"]?.title = "\(s.partial == 1 ? "今日已记录" : "今日订阅用量（约）")：\(bytes(s.today))"
            menuFields["coverage"]?.title = s.partial == 1 ? "从 \(timeText(s.first, date: true)) 起记录，之前用量未知" : "配置时区零点起记账；以订阅后台更新为准"
            if s.reset == 1 { menuFields["coverage"]?.title = "检测到订阅计数重置，本日记录不完整" }
            menuFields["updated"]?.title = "订阅更新：\(timeText(s.updated))\(stale ? "（获取失败或过期，显示缓存）" : " · 周期读取")"
            menuFields["expire"]?.title = s.expire > 0 ? "订阅到期：\(timeText(s.expire, date: true))" : "订阅到期：未提供"
            if !isToday {
                usageLine = "今 — · 余 \(bytes(s.remaining, short: true))"
                menuFields["today"]?.title = "今日订阅用量：今天的数据尚未更新"
                menuFields["coverage"]?.title = "上次记账日期 \(s.date)，不计入今天"
            }
        } else {
            menuFields["remaining"]?.title = "订阅剩余：暂未取得"
            menuFields["today"]?.title = "今日订阅用量：暂未取得"
            menuFields["coverage"]?.title = "不会用路由器总流量代替订阅用量"
        }
        if online {
            let delay = webMS.map { String(format: "%.0fms", $0) } ?? (checking ? "检测中" : webState)
            bar.first = "↓\(bytes(down, short: true))/s ↑\(bytes(up, short: true))/s"
            bar.second = "\(usageLine) · \(delay)"
        } else {
            bar.first = configuration == nil ? "U30 Flow · 请先配置" : "U30 未连接 · 缓存"
            bar.second = "\(usageLine) · —"
        }
        menuFields["state"]?.title = "U30 Flow · \(configuration == nil ? "请先打开连接设置" : (online ? "已连接路由器" : "未连接路由器"))"
        menuFields["down"]?.title = "U30 实时下行：\(online ? bytes(down) + "/s" : "—")"
        menuFields["up"]?.title = "U30 实时上行：\(online ? bytes(up) + "/s" : "—")"
        menuFields["lan"]?.title = "路由器响应：\(lanMS.map { String(format: "%.1f ms", $0) } ?? "—")"
        menuFields["web"]?.title = "外网响应（HTTPS）：\(webMS.map { String(format: "%.0f ms", $0) } ?? webState)"
        menuFields["vpn"]?.title = "路由器代理：\(snapshot.map { $0.vpn == 1 ? "已开启" : "已关闭" } ?? "—")"
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item.length = bar.fittedWidth
        if let button = item.button { bar.frame = button.bounds }
        bar.needsDisplay = true
        let state: [String: Any] = ["running": true, "routerConnected": online, "statusLine1": bar.first, "statusLine2": bar.second, "statusWidthPoints": item.length, "measuredTextWidthPoints": bar.textWidth, "downBytesPerSecond": down, "upBytesPerSecond": up, "externalMilliseconds": webMS as Any? ?? NSNull(), "metadataStale": stale, "updated": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            let path = support.appendingPathComponent("latest-state.json")
            try? data.write(to: path, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }
    @objc func refresh() { lastProbe = .distantPast; probe() }
    @objc func openRouter() {
        guard configuration != nil, let url = URL(string: "http://\(router)") else { return }
        NSWorkspace.shared.open(url)
    }
    @objc func settings() {
        let alert = NSAlert(); alert.messageText = "连接已配对的路由器"
        alert.informativeText = "先按 README 配置专用只读密钥和已核验的主机公钥。这里不接收管理员密码或订阅链接。"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        let host = NSTextField(string: configuration?.routerHost ?? "")
        let user = NSTextField(string: configuration?.sshUser ?? "root")
        let port = NSTextField(string: String(configuration?.sshPort ?? 22))
        for (label, field) in [("路由器主机名或IPv4地址", host), ("SSH用户名", user), ("SSH端口", port)] {
            stack.addArrangedSubview(NSTextField(labelWithString: label))
            field.frame.size = NSSize(width: 300, height: 24); stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 158)
        alert.accessoryView = stack; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let value = try Configuration(routerHost: host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), sshUser: user.stringValue, sshPort: Int(port.stringValue) ?? 0).validated()
            let path = support.appendingPathComponent("config.json")
            try JSONEncoder().encode(value).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            let old = process; process = nil; old?.terminate()
            configuration = value; snapshot = nil; previous = nil; online = false; down = 0; up = 0
            lanMS = nil; webMS = nil; checking = false; lastProbe = .distantPast
            try? FileManager.default.removeItem(at: support.appendingPathComponent("last-snapshot.json"))
            connect(); updateDisplay()
        } catch {
            let failed = NSAlert(); failed.messageText = "未能保存设置"; failed.informativeText = "请检查主机名、用户名、端口及本机文件权限。"; failed.runModal()
        }
    }
    @objc func explain() {
        let a = NSAlert(); a.messageText = "统计口径与隐私"
        a.informativeText = "剩余与今日用量来自订阅服务器的累计账单，包含其他设备使用同一订阅的流量；不是 U30 的蜂窝总流量。服务器可能延迟记账或按倍率扣费。\n\n第一天和中断后无法补算此前用量，会标为‘今日已记录’。U30 每 5 分钟采样，Mac 休眠时仍记账。跨日和计数重置会标明记录不完整。\n\n上下行是 U30 全部设备的蜂窝接口速率，每 3 秒刷新。外网响应是经 U30 的小型 HTTPS 请求耗时，每 30 秒检测，包含建连和 TLS，不等同于纯节点 Ping。单位 GB=10亿字节。\n\n应用仅持有专用的只读 SSH 密钥，不保存路由器管理员密码或订阅链接，不上传统计数据。"
        a.addButton(withTitle: "知道了"); NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            if SMAppService.mainApp.status == .requiresApproval {
                let a = NSAlert(); a.messageText = "需要允许登录项"; a.informativeText = "请到系统设置 → 通用 → 登录项，允许 U30 Flow。"; a.runModal()
            }
        } catch {
            let a = NSAlert(); a.messageText = "未能修改登录启动"; a.informativeText = "可以在系统设置 → 通用 → 登录项中手动添加 U30 Flow。"; a.runModal()
        }
        updateDisplay()
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { stopping = true; timer?.invalidate(); process?.terminate() }
}

if CommandLine.arguments.contains("--diagnose") {
    guard configuration != nil else { print("{\"configured\":false}"); exit(1) }
    let result = run("/usr/bin/ssh", sshArguments("u30-status"), timeout: 8)
    if result.code == 0, let data = result.text.data(using: .utf8), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
        let obj: [String: Any] = ["routerConnected": true, "remainingBytes": snap.subscription?.remaining as Any? ?? NSNull(), "observedTodayBytes": snap.subscription?.today as Any? ?? NSNull(), "partialDay": snap.subscription?.partial == 1, "routerVPNEnabled": snap.vpn == 1]
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]); print(String(decoding: out, as: UTF8.self)); exit(0)
    }
    print("{\"routerConnected\":false}"); exit(1)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(); app.delegate = delegate
app.run()
