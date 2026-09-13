import Foundation
import Security

/// 配置的真身：普通设置进 UserDefaults，共享密钥进 Keychain。
///
/// 故意**不是** ObservableObject。token source 在后台任务里读它，
/// 而 ObservableObject 天然想待在主 actor 上 —— 在 Swift 6 的严格并发下
/// 把它塞进跨 actor 的闭包只会换来一串告警。这里退成一个无状态的静态门面，
/// 读写都直接落磁盘；UI 那层由 `CloseCrabConfig` 包一层做通知，
/// 两边看到的是同一份东西，不存在「界面改了但连接还用老值」。
enum CCStore {
    /// 网页版用的地址。原样填在这里只是给个起点 —— 手机版多半要换成
    /// 一个**不在 IAP 后面**的入口，因为原生 app 没有浏览器的登录 cookie。
    static let defaultBaseURL = "https://live.higcp.com"

    /// 房间名就是 bot 名。这份列表要和前端 .env.local 里的 ALLOWED_ROOMS 对齐 ——
    /// 服务端会按白名单校验，这边多写一个只会在点连接时拿到 400。
    static let defaultRooms = "bunny,jarvis,hulk,tommy,xiaoaitongxue,tianmaojingling"

    private enum Key {
        static let baseURL = "cc.baseURL"
        static let signalURL = "cc.signalURL"
        static let rooms = "cc.rooms"
        static let room = "cc.room"
    }

    private static let keychainService = "com.higcp.closecrab.voice"
    private static let keychainAccount = "sharedSecret"

    // MARK: - 普通设置

    /// 取 token 的服务端根地址，例如 `https://live.higcp.com`。
    static var baseURL: String {
        get { nonEmpty(UserDefaults.standard.string(forKey: Key.baseURL)) ?? defaultBaseURL }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Key.baseURL) }
    }

    /// 信令地址覆盖（可空）。
    ///
    /// 为什么要有这一项：服务端返回的 `serverUrl` 是给浏览器用的，它和页面同源、
    /// 一起躲在 IAP 后面。手机上进不去那个门，就需要换一个入口 —— 但这属于部署形态，
    /// 不该为了换个地址重新编译一次 app。留空＝听服务端的。
    static var signalURL: String {
        get { nonEmpty(UserDefaults.standard.string(forKey: Key.signalURL)) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Key.signalURL) }
    }

    /// 逗号分隔的房间名，原样存着，给设置页编辑用。
    static var roomsCSV: String {
        get { nonEmpty(UserDefaults.standard.string(forKey: Key.rooms)) ?? defaultRooms }
        set { UserDefaults.standard.set(newValue, forKey: Key.rooms) }
    }

    static var rooms: [String] {
        roomsCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 当前选中的房间。永远返回一个在列表里的值 —— 房间列表被改过之后，
    /// 上次选的那个可能已经不在了，这时候退回第一个，而不是让选择器空着。
    static var room: String {
        get {
            let saved = nonEmpty(UserDefaults.standard.string(forKey: Key.room))
            if let saved, rooms.contains(saved) { return saved }
            return rooms.first ?? ""
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.room) }
    }

    // MARK: - 共享密钥（Keychain）

    /// 这把密钥能换到任意白名单房间的 token，等于一把进所有助理房间的钥匙，
    /// 所以不放 UserDefaults（那是明文 plist，iTunes 备份里能直接看到）。
    /// `AfterFirstUnlock` 而不是 `WhenUnlocked`：锁屏状态下后台要能续 token。
    static var sharedSecret: String {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let value = String(data: data, encoding: .utf8)
            else { return "" }
            return value
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
            ]
            // 先删再加。SecItemUpdate 在「本来就没有」的时候会失败，
            // 而我们这里既要能设也要能清空，删+加一条路走到底最省事。
            SecItemDelete(base as CFDictionary)

            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }

            var add = base
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: -

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
