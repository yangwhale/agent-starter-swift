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
        static let mutedRooms = "cc.mutedRooms"
        static let netReadout = "cc.netReadout"
        // 二分排障用的四个开关，见 `CCStore.offStatusPanel` 那段注释。
        static let offStatusPanel = "cc.off.statusPanel"
        static let offRoster = "cc.off.roster"
        static let offAgentSampler = "cc.off.agentSampler"
        static let offBackdrop = "cc.off.backdrop"
        static let releaseMicWhenIdle = "cc.audio.releaseMicWhenIdle"
        static let voiceProcessing = "cc.voiceProcessing"
        static let backdrop = "cc.backdrop"
        static let pushToTalkKey = "cc.pttKey"
        static let appearance = "cc.appearance"
        /// **存的是「关掉了吗」，不是「开着吗」** —— 见 `CCStore.haptics` 的注释。
        static let hapticsOff = "cc.haptics.off"
        static let handwritten = "cc.handwritten"
        /// **只读的迁移种子**，见 `avatarWants(room:)`。2026-09-18 起没人再写它。
        static let legacyLiveAvatar = "cc.liveAvatar"
        /// 每个房间一条，键是 `cc.avatar.roles.<房间名>`。
        static func avatarRoles(room: String) -> String { "cc.avatar.roles.\(room)" }
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

    /// 哪几个房间被我静音了（听不见它说话）。逗号分隔，跟 `onlineRooms` 同款。
    ///
    /// **只存不校验**：静音一个当前没在线的房间是合法的 —— 你可能先静音、
    /// 再取消勾选、过几天又勾回来，那时候它该还是静音的。
    static var mutedRooms: Set<String> {
        get {
            Set((nonEmpty(UserDefaults.standard.string(forKey: Key.mutedRooms)) ?? "")
                .split(separator: ",").map(String.init))
        }
        set {
            UserDefaults.standard.set(newValue.sorted().joined(separator: ","),
                                      forKey: Key.mutedRooms)
        }
    }

    static func setMuted(_ muted: Bool, room name: String) {
        var set = mutedRooms
        if muted { set.insert(name) } else { set.remove(name) }
        mutedRooms = set
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

    /// 不说话的时候把麦克风让给别的 App。**默认开。**
    ///
    /// 关掉就退回 LiveKit 自己那套 —— 它一旦录过一次音，就把音频类别钉在
    /// 「又放又录」上直到断开，静音也不松手（原因见 `CCAudioSessionPolicy`）。
    ///
    /// ⚠️ **`bool(forKey:)` 在没存过的时候返回 `false`，所以这里不能用它** ——
    /// 用了的话默认值就悄悄变成「关」，而这个功能的默认应该是「开」。
    ///
    /// ⚠️ 改完**要重启 App 才生效**：接管发生在启动时，中途换回去没法干净地
    /// 把 session 还给 SDK。设置页那段说明里写了这一条。
    static var releaseMicWhenIdle: Bool {
        get { UserDefaults.standard.object(forKey: Key.releaseMicWhenIdle) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.releaseMicWhenIdle) }
    }

    /// 显不显示网络读数（缓冲深度 / 丢包率）。
    ///
    /// **默认关。** 平时它是噪音 —— 正常人不需要随时盯着丢包率。
    /// 只有「地铁上又吞字了」那一刻它才值钱，所以做成开关。
    /// ## 二分排障开关（2026-09-20 加，定位完就删）
    ///
    /// 症状：**静止不动、没人操作，app 就持续满转 72% CPU，两分钟内存从
    /// 165 MB 涨到 1049 MB**（设备 cpu_resource 报告，PID 5240）。
    /// 采样栈跟 09-19 那次看门狗崩溃**落在同一个位置** ——
    /// `ViewGraphRootValueUpdater.render` / `_UIHostingView.layoutSubviews`，
    /// 说明崩溃只是这个自激循环偶尔一轮超过 20 秒的结果。
    ///
    /// **为什么做成开关而不是一次改一处**：每换一个猜想就要编一次、装一次、
    /// 占一次 Chris 的手机。四个开关做进同一个包，现场拨一下就能二分，
    /// 一次装机跑完全部实验。
    ///
    /// 四个候选都是「不用任何操作就一直在跑」的东西 —— 这是从
    /// 「静止也烧」这个事实倒推出来的筛选条件：
    /// 状态屏（1 秒一跳）、人名牌子（0.35 秒一跳，还带头像图）、
    /// 主画面采样（0.2 秒一跳）、背景（Liquid Glass 折射）。
    static var offStatusPanel: Bool {
        get { UserDefaults.standard.bool(forKey: Key.offStatusPanel) }
        set { UserDefaults.standard.set(newValue, forKey: Key.offStatusPanel) }
    }

    static var offRoster: Bool {
        get { UserDefaults.standard.bool(forKey: Key.offRoster) }
        set { UserDefaults.standard.set(newValue, forKey: Key.offRoster) }
    }

    static var offAgentSampler: Bool {
        get { UserDefaults.standard.bool(forKey: Key.offAgentSampler) }
        set { UserDefaults.standard.set(newValue, forKey: Key.offAgentSampler) }
    }

    static var offBackdrop: Bool {
        get { UserDefaults.standard.bool(forKey: Key.offBackdrop) }
        set { UserDefaults.standard.set(newValue, forKey: Key.offBackdrop) }
    }

    static var netReadout: Bool {
        get { UserDefaults.standard.bool(forKey: Key.netReadout) }
        set { UserDefaults.standard.set(newValue, forKey: Key.netReadout) }
    }

    // MARK: - 外观

    /// 背景用哪张图。默认 `.auto`（跟着时钟走四段天色）。
    ///
    /// 存 rawValue 字符串而不是下标：加一张图、调一次顺序都不会让老用户
    /// 存的值指到别的地方去。读不出来就退回默认，不崩。
    /// macOS 按住说话的触发键。iOS 上没有键盘热键这回事，存了也不读。
    static var pushToTalkKey: CCPushToTalkKey {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.pushToTalkKey),
                  let v = CCPushToTalkKey(rawValue: raw) else { return .rightOption }
            return v
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.pushToTalkKey) }
    }

    static var backdrop: CCBackdropChoice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.backdrop),
                  let value = CCBackdropChoice(rawValue: raw)
            else { return .auto }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.backdrop) }
    }

    /// 深浅色。默认跟随系统。
    static var appearance: CCAppearance {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.appearance),
                  let value = CCAppearance(rawValue: raw)
            else { return .system }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.appearance) }
    }

    /// 手势要不要震动。**默认开。**
    ///
    /// `UserDefaults.bool` 在没存过时返回 `false`，所以不能直接读 ——
    /// 那样默认值就成了「关」。存一个反过来的键（"关掉了吗"）是最省事的写法：
    /// 没存过 ＝ 没关过 ＝ 开着。
    static var haptics: Bool {
        get { !UserDefaults.standard.bool(forKey: Key.hapticsOff) }
        set { UserDefaults.standard.set(!newValue, forKey: Key.hapticsOff) }
    }

    /// 房间名和首字母用不用手写体。**默认关** ——
    /// 这是个审美选择，不是功能，不该替人做主。
    static var handwritten: Bool {
        get { UserDefaults.standard.bool(forKey: Key.handwritten) }
        set { UserDefaults.standard.set(newValue, forKey: Key.handwritten) }
    }

    /// 这个房间里，用户想让哪几个角色有脸。**默认一个都不开。**
    ///
    /// 默认关有两个理由，缺一个都不够：
    ///
    /// 1. 服务端 GPU 槽位有限。默认开的话，每个装了 app 的人一进房就抢一路，
    ///    而多数时候他只是想听个声。
    /// 2. 这是个「多给一点」的功能，不是修好一个缺陷。默认开等于替人做主。
    ///
    /// 结果会经 `cc.avatar.principal` / `cc.avatar.assistant` 发给服务端，
    /// 由它按资源合成最终决定 —— 见 `CCAvatarLink` 和服务端 `policy.py`。
    ///
    /// ## 迁移：老的全局开关
    ///
    /// 2026-09-18 之前是设置页里一个全局 `cc.liveAvatar`。**没存过这个房间的
    /// 新键、而老开关是开着的**，就当成「这个房间要本体」—— 老开关本来就只能
    /// 驱动本体那一路。不这么做的话，升级完 app 的人会发现功能凭空没了，
    /// 而新开关藏在一个他还不知道的双击手势后面。
    ///
    /// ⚠️ 判据是 `string(forKey:) == nil`（从来没存过），**不能用「空集合」**：
    /// 用户主动关掉之后存的就是空串，拿空集合当「没存过」的话，
    /// 他每次重启 app 都会看到 Avatar 自己又开回来。
    static func avatarWants(room: String) -> CCAvatarWants {
        let raw = UserDefaults.standard.string(forKey: Key.avatarRoles(room: room))
        if raw == nil, UserDefaults.standard.bool(forKey: Key.legacyLiveAvatar) {
            return CCAvatarWants([.principal])
        }
        return CCAvatarWants.parse(raw)
    }

    static func setAvatarWants(_ wants: CCAvatarWants, room: String) {
        UserDefaults.standard.set(wants.storageValue, forKey: Key.avatarRoles(room: room))
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
