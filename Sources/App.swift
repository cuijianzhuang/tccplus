import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 数据模型

struct TargetApp: Equatable {
    var name: String
    var bundleID: String
    var path: String
    var version: String

    static func load(from url: URL) -> TargetApp? {
        guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (info["CFBundleShortVersionString"] as? String) ?? ""
        return TargetApp(name: name, bundleID: bid, path: url.path, version: version)
    }
}

struct TCCService: Identifiable, Hashable {
    let id: String        // 传给 tccplus 的服务名
    let title: String
    let symbol: String
    let note: String
}

enum TCCAction: String, CaseIterable, Identifiable {
    case add, remove, reset
    var id: String { rawValue }
    var title: String {
        switch self {
        case .add: return "授权 (add)"
        case .remove: return "撤销 (remove)"
        case .reset: return "重置 (reset)"
        }
    }
    var hint: String {
        switch self {
        case .add: return "直接写入「已允许」，应用下次启动即拥有权限。"
        case .remove: return "写入「已拒绝」，应用不会再弹窗询问。"
        case .reset: return "清除记录，应用下次请求时会重新弹窗。"
        }
    }
}

/// 住在系统级 TCC.db 的服务，改它们需要 root；其余在用户级库，普通权限 + 完全磁盘访问即可
let systemScopedServices: Set<String> = [
    "ScreenCapture", "Accessibility", "ListenEvent", "SystemPolicyAllFiles",
]

let allServices: [TCCService] = [
    TCCService(id: "Microphone", title: "麦克风", symbol: "mic.fill", note: "kTCCServiceMicrophone"),
    TCCService(id: "Camera", title: "摄像头", symbol: "camera.fill", note: "kTCCServiceCamera"),
    TCCService(id: "ScreenCapture", title: "屏幕录制", symbol: "rectangle.dashed.badge.record", note: "kTCCServiceScreenCapture"),
    TCCService(id: "Accessibility", title: "辅助功能", symbol: "figure.wave", note: "kTCCServiceAccessibility"),
    TCCService(id: "ListenEvent", title: "输入监控", symbol: "keyboard", note: "kTCCServiceListenEvent"),
    TCCService(id: "SystemPolicyAllFiles", title: "完全磁盘访问", symbol: "externaldrive.fill", note: "kTCCServiceSystemPolicyAllFiles"),
    TCCService(id: "AppleEvents", title: "自动化 (AppleEvents)", symbol: "gearshape.2.fill", note: "kTCCServiceAppleEvents"),
    TCCService(id: "Photos", title: "照片", symbol: "photo.fill", note: "kTCCServicePhotos"),
]

// MARK: - tccplus 定位与执行

enum Runner {
    static let customPathKey = "tccplusCustomPath"

    /// App 内置的 tccplus 路径
    static var bundledPath: String? {
        Bundle.main.resourceURL?.appendingPathComponent("tccplus").path
    }

    static func locateTCCPlus() -> String? {
        var candidates: [String] = []
        if let custom = UserDefaults.standard.string(forKey: customPathKey) { candidates.append(custom) }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("tccplus").path { candidates.append(res) }
        candidates += [
            "/usr/local/bin/tccplus",
            "/opt/homebrew/bin/tccplus",
            (NSHomeDirectory() as NSString).appendingPathComponent("bin/tccplus"),
            (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/tccplus/tccplus"),
        ]
        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        // 最后再问一次 PATH
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-lc", "command -v tccplus"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    struct Result { let ok: Bool; let log: String }

    /// 普通权限执行：逐条跑 tccplus <action> <service> <bundleID>
    static func run(tool: String, action: TCCAction, services: [String], bundleID: String, appPath: String?) -> Result {
        var log = ""
        var ok = true
        for s in services {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            var argv = [action.rawValue, s, bundleID]
            if let appPath { argv.append(appPath) }
            p.arguments = argv
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            log += "$ \(tool) \(argv.joined(separator: " "))\n"
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                log += "启动失败：\(error.localizedDescription)\n"
                ok = false
                continue
            }
            let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !o.isEmpty { log += o.hasSuffix("\n") ? o : o + "\n" }
            if !e.isEmpty { log += e.hasSuffix("\n") ? e : e + "\n" }
            if p.terminationStatus != 0 {
                ok = false
                log += "↳ 退出码 \(p.terminationStatus)\n"
            }
            log += "\n"
        }
        return Result(ok: ok, log: log)
    }

    /// 管理员权限执行：拼成一条 shell 命令，交给 osascript 弹系统授权框
    static func runAsAdmin(tool: String, action: TCCAction, services: [String], bundleID: String, appPath: String?) -> Result {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let tail = appPath.map { " " + q($0) } ?? ""
        let cmds = services.map { "\(q(tool)) \(action.rawValue) \(q($0)) \(q(bundleID))\(tail)" }
        // 提权后 NSHomeDirectory() 会变成 /var/root，显式传真实用户家目录
        let shell = "export TCC_USER_HOME=\(q(NSHomeDirectory())); " + cmds.joined(separator: "; ")
        var log = "$ sudo sh -c \"\(shell)\"\n"

        let script = "do shell script \"" +
            shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") +
            "\" with administrator privileges"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return Result(ok: false, log: log + "启动 osascript 失败：\(error.localizedDescription)\n")
        }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !o.isEmpty { log += o }
        if !e.isEmpty { log += e }
        if !log.hasSuffix("\n") { log += "\n" }
        return Result(ok: p.terminationStatus == 0, log: log)
    }
}

// MARK: - 已安装应用扫描

struct InstalledApp: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
}

func scanInstalledApps() -> [InstalledApp] {
    let fm = FileManager.default
    var dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
    dirs.append((NSHomeDirectory() as NSString).appendingPathComponent("Applications"))
    var result: [InstalledApp] = []
    for d in dirs {
        guard let items = try? fm.contentsOfDirectory(atPath: d) else { continue }
        for i in items where i.hasSuffix(".app") {
            result.append(InstalledApp(name: (i as NSString).deletingPathExtension,
                                       path: (d as NSString).appendingPathComponent(i)))
        }
    }
    return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

// MARK: - 主界面

struct ContentView: View {
    @State private var target: TargetApp?
    @State private var selected: Set<String> = ["Microphone", "Camera"]
    @State private var action: TCCAction = .add
    @State private var useAdmin = false
    @State private var showAdvanced = false
    @State private var log = ""
    @State private var running = false
    @State private var toolPath: String? = Runner.locateTCCPlus()
    @State private var showPicker = false
    @State private var dropTargeted = false

    private var needsAdmin: Bool {
        !selected.isDisjoint(with: systemScopedServices)
    }

    private var canRun: Bool {
        target != nil && !selected.isEmpty && toolPath != nil && !running
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    appSection
                    serviceSection
                    actionSection
                    if !log.isEmpty { logSection }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 640)
        .onChange(of: selected) { _ in useAdmin = needsAdmin }
        .sheet(isPresented: $showPicker) {
            AppPickerSheet { url in
                setTarget(url)
                showPicker = false
            } onCancel: { showPicker = false }
        }
    }

    // 顶部
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("TCC 权限助手").font(.headline)
                Text("选择应用 → 勾选权限 → 后台调用 tccplus")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            toolStatus
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var toolStatus: some View {
        HStack(spacing: 6) {
            Circle().fill(toolPath == nil ? Color.red : Color.green).frame(width: 8, height: 8)
            Text(toolPath == nil ? "未找到 tccplus"
                                 : (toolPath == Runner.bundledPath ? "tccplus 已内置" : "tccplus 已就绪"))
                .font(.caption)
            Button("…") { chooseTool() }
                .buttonStyle(.borderless)
                .help(toolPath ?? "手动选择 tccplus 可执行文件")
        }
    }

    // 应用选择
    private var appSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. 目标应用").font(.subheadline).bold()
            HStack(spacing: 14) {
                Group {
                    if let t = target {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: t.path))
                            .resizable().frame(width: 56, height: 56)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 40)).foregroundStyle(.secondary)
                            .frame(width: 56, height: 56)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let t = target {
                        Text(t.name + (t.version.isEmpty ? "" : "  \(t.version)")).font(.body).bold()
                        HStack(spacing: 6) {
                            Text(t.bundleID)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(t.bundleID, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("复制 Bundle ID")
                        }
                        Text(t.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("尚未选择应用").foregroundStyle(.secondary)
                        Text("把 .app 拖到这里，或点右侧按钮").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(spacing: 6) {
                    Button("选择应用…") { browseApp() }
                    Button("已安装列表") { showPicker = true }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                                  style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: target == nil ? [5] : []))
            )
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension == "app" else { return }
                    DispatchQueue.main.async { setTarget(url) }
                }
                return true
            }
        }
    }

    // 权限勾选
    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("2. 权限项").font(.subheadline).bold()
                Spacer()
                Toggle("显示更多权限", isOn: $showAdvanced)
                    .toggleStyle(.checkbox).font(.caption)
            }
            let shown = showAdvanced ? allServices : Array(allServices.prefix(2))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(shown) { s in
                    Toggle(isOn: Binding(
                        get: { selected.contains(s.id) },
                        set: { on in if on { selected.insert(s.id) } else { selected.remove(s.id) } }
                    )) {
                        HStack(spacing: 6) {
                            Image(systemName: s.symbol).frame(width: 18)
                            Text(s.title)
                            Spacer()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .help(s.note)
                }
            }
        }
    }

    // 动作
    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("3. 操作").font(.subheadline).bold()
            Picker("", selection: $action) {
                ForEach(TCCAction.allCases) { a in Text(a.title).tag(a) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(action.hint).font(.caption).foregroundStyle(.secondary)
            Toggle("以管理员权限运行", isOn: $useAdmin)
                .toggleStyle(.checkbox).font(.caption)
            Text(needsAdmin
                 ? "已勾选的权限位于系统级数据库，必须提权。"
                 : "所选权限都在用户级数据库，通常无需提权，但本工具需要「完全磁盘访问」。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("输出").font(.subheadline).bold()
                Spacer()
                Button("清空") { log = "" }.buttonStyle(.borderless).font(.caption)
            }
            ScrollView {
                Text(log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        }
    }

    private var footer: some View {
        HStack {
            if toolPath == nil {
                Label("请先安装 tccplus 或手动指定路径", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if let t = target {
                Text("将执行 \(selected.count) 条命令 → \(t.bundleID)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if running { ProgressView().controlSize(.small) }
            Button(action: execute) {
                Text("执行").frame(width: 70)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRun)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: 行为

    private func setTarget(_ url: URL) {
        if let t = TargetApp.load(from: url) {
            target = t
        } else {
            log += "无法读取 \(url.path) 的 Bundle ID\n"
        }
    }

    private func browseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { setTarget(url) }
    }

    private func chooseTool() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "选择 tccplus 可执行文件"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: Runner.customPathKey)
            toolPath = Runner.locateTCCPlus()
        }
    }

    private func execute() {
        guard let t = target, let tool = toolPath else { return }
        let services = allServices.map(\.id).filter { selected.contains($0) }
        let act = action
        let admin = useAdmin
        running = true
        DispatchQueue.global().async {
            let extra = (tool == Runner.bundledPath) ? t.path : nil
            let r = admin
                ? Runner.runAsAdmin(tool: tool, action: act, services: services, bundleID: t.bundleID, appPath: extra)
                : Runner.run(tool: tool, action: act, services: services, bundleID: t.bundleID, appPath: extra)
            DispatchQueue.main.async {
                log += r.log
                log += r.ok ? "✅ 完成。请退出并重新启动 \(t.name) 使其生效。\n\n"
                            : "❌ 有命令失败。若提示无权限，需给本工具「完全磁盘访问」。\n\n"
                running = false
            }
        }
    }
}

// MARK: - 已安装应用选择表

struct AppPickerSheet: View {
    var onPick: (URL) -> Void
    var onCancel: () -> Void
    @State private var query = ""
    @State private var apps: [InstalledApp] = []
    @State private var selection: InstalledApp.ID?

    var filtered: [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用", text: $query).textFieldStyle(.plain)
            }
            .padding(10)
            Divider()
            List(filtered, selection: $selection) { app in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable().frame(width: 20, height: 20)
                    Text(app.name)
                }
                .tag(app.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onPick(URL(fileURLWithPath: app.path)) }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("选择") {
                    if let s = selection { onPick(URL(fileURLWithPath: s)) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(10)
        }
        .frame(width: 380, height: 460)
        .onAppear { apps = scanInstalledApps() }
    }
}

// MARK: - 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TCCHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("TCC 权限助手") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
