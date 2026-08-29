// 内置的 tccplus 兼容命令行工具
// 用法: tccplus <add|remove|reset> <service> <bundle-id|path> [app-path]
//   add    -> auth_value = 2 (允许)
//   remove -> auth_value = 0 (拒绝)
//   reset  -> 删除记录，应用下次请求时重新弹窗
import Foundation
import SQLite3
import Security
import SystemConfiguration

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func usage() -> Never {
    print("""
    用法: tccplus <add|remove|reset> <service> <bundle-id> [app-path]

    service 可用短名 (Camera / Microphone / ScreenCapture / Accessibility /
    ListenEvent / SystemPolicyAllFiles / AppleEvents / Photos …) 或完整的
    kTCCService* 名称。给出 app-path 时会顺带写入代码签名要求 (csreq)。
    """)
    exit(0)
}

// MARK: 服务名归一化 + 数据库路由

func normalize(_ service: String) -> String {
    service.hasPrefix("kTCCService") ? service : "kTCCService" + service
}

/// 这些服务住在系统级 TCC.db，其余在用户级
let systemScoped: Set<String> = [
    "kTCCServiceAccessibility", "kTCCServiceScreenCapture", "kTCCServiceListenEvent",
    "kTCCServicePostEvent", "kTCCServiceSystemPolicyAllFiles",
    "kTCCServiceSystemPolicySysAdminFiles", "kTCCServiceDeveloperTool",
    "kTCCServiceEndpointSecurityClient", "kTCCServiceScreenRecording",
]

/// 解析「真正的用户」家目录。
/// 提权运行时 NSHomeDirectory() 会变成 /var/root，用户级 TCC.db 并不在那里。
func realUserHome() -> String {
    let env = ProcessInfo.processInfo.environment

    // 1. 调用方显式指定（GUI 提权执行时会传这个）
    if let h = env["TCC_USER_HOME"], !h.isEmpty { return h }

    // 2. sudo 保留的原始用户
    if let u = env["SUDO_USER"], !u.isEmpty, u != "root", let home = homeDir(of: u) { return home }

    // 3. 当前登录图形界面的用户（osascript 提权时走这条）
    if let console = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String?,
       !console.isEmpty, console != "root", console != "loginwindow",
       let home = homeDir(of: console) { return home }

    // 4. 本来就是普通用户运行
    return NSHomeDirectory()
}

func homeDir(of user: String) -> String? {
    guard let pw = getpwnam(user) else { return nil }
    return String(cString: pw.pointee.pw_dir)
}

func dbPath(for service: String) -> String {
    if systemScoped.contains(service) {
        return "/Library/Application Support/com.apple.TCC/TCC.db"
    }
    return (realUserHome() as NSString)
        .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
}

// MARK: csreq

/// 取 App 的指定代码要求，序列化成 TCC 需要的 blob
func codeRequirement(forAppAt path: String) -> Data? {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
          let code = staticCode else { return nil }
    var req: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess,
          let requirement = req else { return nil }
    var data: CFData?
    guard SecRequirementCopyData(requirement, [], &data) == errSecSuccess,
          let d = data else { return nil }
    return d as Data
}

// MARK: SQLite 辅助

func openDB(_ path: String) -> OpaquePointer {
    var db: OpaquePointer?
    if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
        die("""
            无法打开 \(path)
            \(msg)
            提示: 修改 TCC 数据库要求调用方拥有「完全磁盘访问」权限，系统级数据库还需要 root。
            """)
    }
    return db!
}

func columns(of db: OpaquePointer, table: String) -> [String] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    var cols: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let c = sqlite3_column_text(stmt, 1) { cols.append(String(cString: c)) }
    }
    return cols
}

// MARK: 主流程

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args[0] == "-h" || args[0] == "--help" { usage() }
guard args.count >= 3 else { die("参数不足。用 --help 查看用法。") }

let action = args[0].lowercased()
guard ["add", "remove", "reset"].contains(action) else { die("未知动作: \(action)") }
let service = normalize(args[1])
let client = args[2]
let appPath: String? = args.count >= 4 ? args[3] : nil

let path = dbPath(for: service)
guard FileManager.default.fileExists(atPath: path) else {
    die("""
        找不到 TCC 数据库: \(path)
        当前用户: \(NSUserName())  解析出的家目录: \(realUserHome())
        提示: 提权运行时可用 TCC_USER_HOME 指定真实用户的家目录。
        """)
}
let db = openDB(path)
defer { sqlite3_close(db) }

let cols = Set(columns(of: db, table: "access"))
guard !cols.isEmpty else { die("读不到 access 表结构，可能没有访问权限。") }
// 10.14 用 allowed，10.15+ 用 auth_value
let valueColumn = cols.contains("auth_value") ? "auth_value" : "allowed"

func exec(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        die("SQL 准备失败: \(String(cString: sqlite3_errmsg(db)))\n\(sql)")
    }
    defer { sqlite3_finalize(stmt) }
    bind(stmt!)
    if sqlite3_step(stmt) != SQLITE_DONE {
        die("SQL 执行失败: \(String(cString: sqlite3_errmsg(db)))")
    }
}

switch action {
case "reset":
    exec("DELETE FROM access WHERE service = ? AND client = ?") { s in
        sqlite3_bind_text(s, 1, service, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(s, 2, client, -1, SQLITE_TRANSIENT)
    }
    print("已重置 \(service) → \(client)（下次请求时会重新弹窗）")

case "add", "remove":
    let value = action == "add" ? 2 : 0

    // 按当前系统的表结构挑列，避免版本差异
    var names: [String] = ["service", "client", "client_type", valueColumn]
    var binders: [(OpaquePointer, Int32) -> Void] = [
        { s, i in sqlite3_bind_text(s, i, service, -1, SQLITE_TRANSIENT) },
        { s, i in sqlite3_bind_text(s, i, client, -1, SQLITE_TRANSIENT) },
        { s, i in sqlite3_bind_int(s, i, client.hasPrefix("/") ? 1 : 0) },
        { s, i in sqlite3_bind_int(s, i, Int32(value)) },
    ]
    func add(_ name: String, _ b: @escaping (OpaquePointer, Int32) -> Void) {
        guard cols.contains(name) else { return }
        names.append(name)
        binders.append(b)
    }
    add("auth_reason") { s, i in sqlite3_bind_int(s, i, 2) }        // User Consent
    add("auth_version") { s, i in sqlite3_bind_int(s, i, 1) }
    let csreq = appPath.flatMap(codeRequirement(forAppAt:))
    add("csreq") { s, i in
        if let d = csreq {
            _ = d.withUnsafeBytes { sqlite3_bind_blob(s, i, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
        } else {
            sqlite3_bind_null(s, i)
        }
    }
    add("policy_id") { s, i in sqlite3_bind_null(s, i) }
    add("indirect_object_identifier_type") { s, i in sqlite3_bind_int(s, i, 0) }
    add("indirect_object_identifier") { s, i in sqlite3_bind_text(s, i, "UNUSED", -1, SQLITE_TRANSIENT) }
    add("indirect_object_code_identity") { s, i in sqlite3_bind_null(s, i) }
    add("flags") { s, i in sqlite3_bind_int(s, i, 0) }
    add("last_modified") { s, i in sqlite3_bind_int64(s, i, Int64(Date().timeIntervalSince1970)) }
    add("pid") { s, i in sqlite3_bind_null(s, i) }
    add("pid_version") { s, i in sqlite3_bind_null(s, i) }
    add("boot_uuid") { s, i in sqlite3_bind_text(s, i, "UNUSED", -1, SQLITE_TRANSIENT) }
    add("last_reminded") { s, i in sqlite3_bind_int(s, i, 0) }

    let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
    let sql = "INSERT OR REPLACE INTO access (\(names.joined(separator: ", "))) VALUES (\(placeholders))"
    exec(sql) { s in
        for (idx, b) in binders.enumerated() { b(s, Int32(idx + 1)) }
    }
    let verb = action == "add" ? "已授权" : "已拒绝"
    let note = csreq == nil ? "" : "，含 csreq"
    print("\(verb) \(service) → \(client)\(note)")

default:
    die("未知动作")
}
