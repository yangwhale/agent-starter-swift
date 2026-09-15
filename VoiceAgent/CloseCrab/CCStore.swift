import Foundation
import Security

/// 配置的真身：普通设置进 UserDefaults，共享密钥进 Keychain。
///
/// 故意**不是** ObservableObject。token source 在后台任务里读它，
/// 而 ObservableObject 天然想待在主 actor 上 —— 在 Swift 6 的严格并发下
/// 把它塞进跨 actor 的闭包只会换来一串告警。这里退成一个无状态的静态门面，
/// 读写都直接落磁盘；UI 那层由 `CloseCrabConfig` 包一层做通知，
/// 两边看到的是同一份东西，不存在「界面改了但连接还用老值」。
///
/// `nonisolated` 是必须的：工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// 不标注的类型会被隐式推成 `@MainActor`，上面那段「退成静态门面」的打算就落空了 ——
/// `CloseCrabTokenSource.fetch` 是协议要求的 nonisolated async，从那里读会直接编译失败。
/// 这里没有共享可变状态（读写都直接落 UserDefaults / Keychain，两者本身线程安全），
/// 所以脱离 actor 是安全的。
nonisolated enum CCStore {
    /// 原生入口。**不是**网页版那个地址 —— 网页版走 `https://live.higcp.com`，
    /// 整站在 IAP 后面，靠浏览器的登录 cookie 过关，原生 app 没有那张 cookie。
    /// `/native/*` 在负载均衡上挂到不走 IAP 的后端，鉴权换成 HMAC 签名
    /// （见 `CCEndpoint.signedHeaders`），所以这条路必须配共享密钥才能用。
    static let defaultBaseURL = "https://live.higcp.com/native"

    /// 冷启动、还没拉到服务端名单时先垫着的一份。真理在后端的 `ALLOWED_ROOMS`，
    /// 每次 `/api/rooms` 拉成功都会整份覆盖掉这里（见 `CCRoomDirectory`）。
    static let defaultRooms = "bunny,jarvis,hulk,tommy,xiaoaitongxue,tianmaojingling"

    private enum Key {
        static let baseURL = "cc.baseURL"
        static let signalURL = "cc.signalURL"
        static let rooms = "cc.rooms"
        static let room = "cc.room"
        static let onlineRooms = "cc.onlineRooms"
        static let netReadout = "cc.netReadout"
        static let voiceProcessing = "cc.voiceProcessing"
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

    /// 逗号分隔的房间名。只是 `/api/rooms` 上次结果的本地缓存，不给人手编。
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

    /// 勾选为「在线」的房间 —— 连着、听得见声音的那几个。
    ///
    /// **这跟 `room` 是两个轴，别合成一个。** `room` 是「话筒现在对着谁」，
    /// 同一时刻只有一个；`onlineRooms` 是「哪几个连着」，可以有好几个。
    /// Chris 09-14 的原话：通常就选俩，多了脑子受不了。
    ///
    /// 两条不变量，读写都强制一遍，**不靠调用方自觉**：
    /// 1. 只保留仍在服务端名单里的 —— bot 下架之后勾选还留着的话，
    ///    界面会显示一个连不上的房间，而错误要到连接那一刻才冒出来。
    /// 2. **当前说话的那个永远在线。** 对着一个没连上的 bot 说话是无意义状态，
    ///    与其在界面上防，不如让它在数据层就不可能出现。
    ///
    /// 输出顺序跟随 `rooms`（服务端名单顺序），不跟随勾选先后 ——
    /// 否则头像方块的位置会随着你勾来勾去乱跳，肌肉记忆全废。
    static var onlineRoomsCSV: String {
        get { nonEmpty(UserDefaults.standard.string(forKey: Key.onlineRooms)) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Key.onlineRooms) }
    }

    /// 规则本身在 `CCRoomSelection` 里，这儿只负责存取。
    /// 分开是为了能测 —— 那个文件只依赖 Foundation，Linux 上 swiftc 能直接编译运行，
    /// 而这个文件碰 UserDefaults / Keychain，离开真机就跑不了。
    static var onlineRooms: [String] {
        get {
            CCRoomSelection.normalize(
                all: rooms,
                picked: onlineRoomsCSV.split(separator: ",").map { String($0) },
                active: room
            )
        }
        set {
            onlineRoomsCSV = CCRoomSelection
                .normalize(all: rooms, picked: newValue, active: room)
                .joined(separator: ",")
        }
    }

    /// 勾 / 取消勾。当前房间取消不掉的规则也在 `CCRoomSelection` 里。
    static func toggleOnline(_ name: String) {
        onlineRooms = CCRoomSelection.toggle(name, in: onlineRooms, all: rooms, active: room)
    }

    // MARK: - 语音处理

    /// 麦克风的回声消除 / 降噪 / 自动增益由谁来做。
    ///
    /// **默认 `.software`（WebRTC 自己那套），不是 SDK 默认的 `.automatic`。**
    /// `.automatic` 会优先用 Apple 的系统语音处理，而我们这个场景里
    /// bot 的声音从扬声器出来又被麦克风收回去，实测软件这套消得更干净。
    ///
    /// 这是**全局**设置，不跟房间走 —— 它描述的是「这台设备的麦克风怎么处理声音」，
    /// 跟你在跟谁说话没关系。所以入口在设置页的齿轮里，不在通话界面上。
    static var voiceProcessing: VoiceProcessingMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.voiceProcessing),
                  let mode = VoiceProcessingMode(rawValue: raw)
            else { return .software }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.voiceProcessing) }
    }

    /// 显不显示网络读数（缓冲深度 / 丢包率）。
    ///
    /// **默认关。** 平时它是噪音 —— 正常人不需要随时盯着丢包率。
    /// 只有「地铁上又吞字了」那一刻它才值钱，所以做成开关。
    static var netReadout: Bool {
        get { UserDefaults.standard.bool(forKey: Key.netReadout) }
        set { UserDefaults.standard.set(newValue, forKey: Key.netReadout) }
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
