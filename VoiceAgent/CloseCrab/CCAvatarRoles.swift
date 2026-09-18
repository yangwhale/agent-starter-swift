import Foundation

/// 一个房间里有两个会说话的角色，**各有各的脸、各有各的 Avatar 开关**。
///
/// 对面是服务端 `closecrab_avatar/policy.py` 的 `AvatarRole` /
/// `ATTR_WANT_BY_ROLE`，rawValue 必须逐字对齐。
///
/// ## 开关为什么从系统设置挪到房间里
///
/// Chris 2026-09-18：「那个 Avatar 的开关，你把它给我从系统配置里边拿出来，
/// 放到每一个这个房间里。双击 Bunny 可以打开 Avatar，然后在 Bunny 头上放一个
/// 标记的图标。再双击就关闭。双击语音助手的时候，这个 Avatar 就变成语音助手开。」
///
/// 原来那个全局开关表达不了「给谁」—— 它只能说「我要一张脸」，而房间里有
/// 两路声音。要在设置页里补一个「给谁」的选择器，用户就得**离开正在看的画面**
/// 去改一个只对眼前这个房间有意义的东西。放在牌子上，开关就长在它作用的对象上。
///
/// ## ⭐ 客户端只表达意图，分配是服务端的事
///
/// 这两个属性是**意图**（这个角色我想让它有脸），不是**分配**（现在有几路 GPU、
/// 该给谁）。服务端 `allocate()` 按容量决定实际给谁，只有一路时本体优先。
///
/// 所以协议上**两个可以同时为真**。下面 `toggled()` 做成互斥，那是
/// 「现在 iOS 上是切换形态」这个**产品选择**，不是协议限制 ——
/// 将来资源多了要放开，改的是这一个函数，协议一个字不用动。
nonisolated enum CCPersonaRole: String, CaseIterable, Sendable {
    /// 本人（bot 自己的播报那一路，identity 形如 `bunny-speaker`）。
    /// **老数据默认算这个** —— 加角色之前存的图在语义上就是本人，
    /// 服务端那边也是这么回落的。
    case principal
    /// 语音助手。
    case assistant

    /// 形象图缓存用的键。**必须把角色拼进去** —— 只用房间名的话两张脸会互相
    /// 覆盖，而且不报错：用户给助手换了图，兔子也跟着变了。
    func key(room: String) -> String { "\(room)|\(rawValue)" }

    /// 给用户看的称呼。跟 `CCRosterRole.title` 一致 —— 本人那块牌子上实际显示的
    /// 是 bot 自己的名字（Bunny），这里是拿不到名字时的通称。
    var title: String {
        switch self {
        case .principal: "本人"
        case .assistant: "语音助手"
        }
    }
}

/// 每角色一个属性键。**改一个字母两边就对不上，而且两边都不报错** ——
/// 服务端读不到只会按缺省当「没要」，现象是「双击了没反应」。
enum CCAvatarRoleAttr {
    /// `cc.avatar.principal` / `cc.avatar.assistant`。
    nonisolated static func want(_ role: CCPersonaRole) -> String {
        "cc.avatar.\(role.rawValue)"
    }

    /// 老的全房开关 `cc.avatar.want`。**还得继续写**，见
    /// `CCAvatarWants.attributes()` 里的理由。
    nonisolated static let legacyWant = CCAvatarAttr.want
}

/// 这个房间里，用户希望哪几个角色有脸。
///
/// 单独抽成一个只依赖 Foundation 的值类型，是为了**能离线把它钉死** ——
/// 这台开发机没有 Xcode，写在 View 里的东西在上真机之前没有任何人能说它对不对。
nonisolated struct CCAvatarWants: Equatable, Sendable {
    private(set) var roles: Set<CCPersonaRole>

    init(_ roles: Set<CCPersonaRole> = []) { self.roles = roles }

    func contains(_ role: CCPersonaRole) -> Bool { roles.contains(role) }
    var isEmpty: Bool { roles.isEmpty }

    /// 双击某个角色之后的新状态。**目前是互斥的单选**：
    ///
    ///     谁都没开 → 双击 Bunny        → 只有 Bunny
    ///     只有 Bunny → 双击 Bunny      → 谁都没有
    ///     只有 Bunny → 双击语音助手     → 只有语音助手（Bunny 顺带关掉）
    ///
    /// 最后那条正是 Chris 说的「双击语音助手的时候，顺便把那个巴尼就拿走」。
    ///
    /// ⚠️ 互斥写在**这一个函数**里，不写进属性协议 —— 见类型上的说明。
    /// 将来要允许两个都开，只把 `CCAvatarWants([role])` 改成 `roles.union([role])`。
    func toggled(_ role: CCPersonaRole) -> CCAvatarWants {
        contains(role) ? CCAvatarWants() : CCAvatarWants([role])
    }

    /// 写给服务端的属性。
    ///
    /// ## ⚠️ 关掉的那个必须显式写 `false`，不能不写
    ///
    /// LiveKit 的 participant attributes 是**按键合并**的：不写某个键 ≠ 把它清掉，
    /// 而是「保持上一次的值」。所以从「Bunny 开」切到「语音助手开」时，
    /// 如果只写 `assistant=true`，服务端那边 `principal` 还是上次那个 `true` ——
    /// 两个都算被要，`allocate()` 按本体优先，**画面纹丝不动**。
    ///
    /// 这个错的现象是「双击语音助手没反应」，但日志里一切正常。
    ///
    /// ## 为什么还在写老的 `cc.avatar.want`
    ///
    /// 三层（iOS / bot / 网关）不可能同一秒切换，中间必然有新旧并存的窗口。
    /// 老 bot 只认这个键，而且它只会把自己那一路（本体）接上去。
    ///
    /// 所以这里**只镜像 principal，不镜像「任意一个」**：镜像任意一个的话，
    /// 用户选了语音助手，老 bot 会给他点亮**本体**那张脸 —— 一个看起来正常、
    /// 实际上是错人的结果，比干脆没反应更难查。
    func attributes() -> [String: String] {
        var out: [String: String] = [:]
        for role in CCPersonaRole.allCases {
            out[CCAvatarRoleAttr.want(role)] = contains(role) ? "true" : "false"
        }
        out[CCAvatarRoleAttr.legacyWant] = contains(.principal) ? "true" : "false"
        return out
    }

    // MARK: - 存盘

    /// 存进 UserDefaults 的形态。**空集合存空串，不是不存** ——
    /// 「存过、而且是空的」和「从来没存过」要能分开，后者才走老开关的迁移。
    ///
    /// ⚠️ **按 `allCases` 过滤，不遍历 `roles`。** 同一个集合必须永远得到同一个
    /// 字符串，否则 `CCAvatarLink` 的去重比对每轮都判成「变了」，于是每轮都往
    /// 服务端写一次属性 —— 而属性不适合高频写。
    ///
    /// 遍历 Set 再排序也能得到稳定结果，但那是**靠一行 `.sorted()` 兜着**：
    /// Swift 的 Set 用每进程随机的哈希种子，顺序在同一个进程里稳、跨进程可能变。
    /// 也就是说漏掉 `.sorted()` 的话，测试**多数时候照样绿**，只在重启之后偶尔
    /// 现形。按 `allCases` 走则是结构上就不可能乱，没有这一层运气成分。
    var storageValue: String {
        CCPersonaRole.allCases.filter(contains).map(\.rawValue).joined(separator: ",")
    }

    /// 从存盘字符串还原。**认不出来的片段直接丢掉，不抛。**
    /// 这条路径在启动读设置时跑，抛出去就是开不了机；丢掉最坏是少开一个开关。
    static func parse(_ raw: String?) -> CCAvatarWants {
        guard let raw else { return CCAvatarWants() }
        let roles = raw.split(separator: ",")
            .compactMap { CCPersonaRole(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
        return CCAvatarWants(Set(roles))
    }
}
