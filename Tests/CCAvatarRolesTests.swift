// 每个角色一个 Avatar 开关 —— 双击的互斥语义、写给服务端的属性、存盘往返。
//
// 这里最容易写错、而且**错了完全不报错**的是 `attributes()`：
// LiveKit 的 participant attributes 按键合并，不写某个键不等于清掉它。
// 所以从「Bunny 开」切到「语音助手开」时漏写 `principal=false`，
// 服务端看到的是两个都要，按本体优先 —— 画面纹丝不动，日志一切正常。
//
// 跑法见 Tests/README.md，被测文件只依赖 Foundation：
//
//   mkdir -p /tmp/swtest && cp VoiceAgent/CloseCrab/CCAvatarRoles.swift \
//     VoiceAgent/CloseCrab/CCAvatarState.swift /tmp/swtest/
//   cp Tests/CCAvatarRolesTests.swift /tmp/swtest/main.swift
//   docker run --rm -v /tmp/swtest:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
//                CCAvatarRoles.swift CCAvatarState.swift main.swift -o t && ./t'

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    if cond {
        passed += 1
    } else {
        failed += 1
        print("  ✗ \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}

typealias R = CCPersonaRole
typealias W = CCAvatarWants

// MARK: - 角色本身

// ⚠️ 这两个字符串是**跨语言契约**：服务端 `policy.py` 的 `AvatarRole` 逐字相同，
//    形象库的 `?role=` 查询参数也用它。改一个字母三处对不上，而且都不报错。
check("principal 的 rawValue", R.principal.rawValue == "principal")
check("assistant 的 rawValue", R.assistant.rawValue == "assistant")
check("只有两个角色", R.allCases.count == 2)
check("形象缓存键带角色", R.principal.key(room: "bunny") == "bunny|principal")
check("两个角色的缓存键不撞", R.principal.key(room: "b") != R.assistant.key(room: "b"))
check("称呼不为空", R.allCases.allSatisfy { !$0.title.isEmpty })
check("两个称呼不一样", R.principal.title != R.assistant.title)

// MARK: - 属性键

check("principal 的属性键", CCAvatarRoleAttr.want(.principal) == "cc.avatar.principal")
check("assistant 的属性键", CCAvatarRoleAttr.want(.assistant) == "cc.avatar.assistant")
check("老键没改名", CCAvatarRoleAttr.legacyWant == "cc.avatar.want")
// 老键跟两个新键都不能重名 —— 重名的话 attributes() 里后写的会盖掉前面那个，
// 表现是「某个角色的开关永远跟着另一个走」。
check("老键跟新键都不撞",
      CCAvatarRoleAttr.legacyWant != CCAvatarRoleAttr.want(.principal)
          && CCAvatarRoleAttr.legacyWant != CCAvatarRoleAttr.want(.assistant))

// MARK: - 双击

// Chris 定的那条链：谁都没开 → 双击 Bunny → 只有 Bunny → 双击语音助手 →
// 只有语音助手（Bunny 顺带拿走）→ 再双击语音助手 → 谁都没有。
var w = W()
check("起手谁都没开", w.isEmpty)

w = w.toggled(.principal)
check("双击本人 → 本人开", w == W([.principal]))

w = w.toggled(.assistant)
check("接着双击助手 → 只剩助手", w == W([.assistant]),
      "\(w.roles.map(\.rawValue).sorted())")
// ⭐ 这一条是「顺便把那个巴尼就拿走」。写成并集的话它会变成两个都开 ——
//    协议上合法，但客户端现在做的是切换形态，两个都亮等于开关失灵。
check("切换时旧的那个确实被拿走了", !w.contains(.principal))

w = w.toggled(.assistant)
check("再双击助手 → 全关", w.isEmpty)

// 反方向同样成立 —— 不能只有一个方向对。
var v = W([.assistant])
v = v.toggled(.principal)
check("助手开着时双击本人 → 只剩本人", v == W([.principal]))

// 双击两次回到原点 —— **只在「本来就没别人开着」时成立**。
for role in R.allCases {
    for start in [W(), W([role])] {
        check("双击两次回到原点（\(role.rawValue) / \(start.storageValue.isEmpty ? "空" : start.storageValue)）",
              start.toggled(role).toggled(role) == start)
    }
}

// ⭐ 从别人手里抢过来之后再双击，是**全关，不是还给他**。
//
// 这条第一次写测试时我按「双击两次总是回到原点」想当然地断言，红了。
// 红得对：从「助手开」双击本人，是两个动作叠在一起（关助手 + 开本人）；
// 再双击本人只撤销后一个。要让它弹回助手，就得记住「上一个是谁」——
// 那是个藏起来的历史状态，用户在界面上看不见，而看不见的状态迟早会跟
// 他的预期分叉（比如切了房间回来，还弹不弹回去？）。
//
// 所以定死：**双击只表达「这一个，开还是关」，不表达历史。**
for (from, tap) in [(R.assistant, R.principal), (R.principal, R.assistant)] {
    let after = W([from]).toggled(tap).toggled(tap)
    check("抢过来再双击 = 全关，不弹回 \(from.rawValue)", after.isEmpty,
          "\(after.roles.map(\.rawValue).sorted())")
}

// MARK: - 写给服务端的属性

// ⭐⭐ 这一组是整个文件里最值钱的。
let onlyAssistant = W([.assistant]).attributes()
check("两个角色的键都在，一个不能少",
      onlyAssistant[CCAvatarRoleAttr.want(.principal)] != nil
          && onlyAssistant[CCAvatarRoleAttr.want(.assistant)] != nil)
check("开着的那个写 true", onlyAssistant[CCAvatarRoleAttr.want(.assistant)] == "true")
// 关掉的那个**必须显式写 false**。属性是按键合并的：不写 ≠ 清掉。
// 漏了它，切换角色时服务端看到的是「两个都要」，按本体优先 —— 画面不动。
check("关掉的那个显式写 false（不是缺席）",
      onlyAssistant[CCAvatarRoleAttr.want(.principal)] == "false",
      "\(onlyAssistant[CCAvatarRoleAttr.want(.principal)] ?? "缺席")")

let none = W().attributes()
check("全关时两个键也都写 false",
      none[CCAvatarRoleAttr.want(.principal)] == "false"
          && none[CCAvatarRoleAttr.want(.assistant)] == "false")

// 老键只镜像 principal。镜像「任意一个」的话，用户选了语音助手、
// 老 bot 会给他点亮**本体**那张脸 —— 一个看起来正常、实际是错人的结果。
check("老键：本人开 → true",
      W([.principal]).attributes()[CCAvatarRoleAttr.legacyWant] == "true")
check("老键：只有助手开 → false（不镜像任意一个）",
      onlyAssistant[CCAvatarRoleAttr.legacyWant] == "false",
      "\(onlyAssistant[CCAvatarRoleAttr.legacyWant] ?? "缺席")")
check("老键：全关 → false", none[CCAvatarRoleAttr.legacyWant] == "false")
check("属性一共三个键", none.count == 3, "\(none.count)")

// 值只能是服务端 `parse_flag` 认得的那两个字面量。
for wants in [W(), W([.principal]), W([.assistant]), W([.principal, .assistant])] {
    check("属性值只有 true/false（\(wants.storageValue)）",
          wants.attributes().values.allSatisfy { $0 == "true" || $0 == "false" })
}

// 协议允许两个都开 —— 互斥只在 `toggled()` 里，不在属性层。
// 这一条钉住的是「将来放开双路时不用改协议」。
let both = W([.principal, .assistant]).attributes()
check("两个都开时两个键都是 true",
      both[CCAvatarRoleAttr.want(.principal)] == "true"
          && both[CCAvatarRoleAttr.want(.assistant)] == "true")

// MARK: - 存盘往返

for wants in [W(), W([.principal]), W([.assistant]), W([.principal, .assistant])] {
    check("存盘往返无损（\(wants.storageValue.isEmpty ? "空" : wants.storageValue)）",
          W.parse(wants.storageValue) == wants)
}
// 空集合存**空串**，不是不存 —— CCStore 靠 `string(forKey:) == nil` 区分
// 「从来没存过」（走老开关迁移）和「用户主动关掉了」。两者混淆的现象是：
// 用户关掉 Avatar，重启 app 它又自己开回来。
check("空集合的存盘值是空串", W().storageValue == "")
check("nil 解析成空", W.parse(nil).isEmpty)
check("空串解析成空", W.parse("").isEmpty)
// 顺序稳定：同一个集合永远得到同一个字符串，否则 CCAvatarLink 的去重比对
// 会每次都判成「变了」，于是每轮都往服务端写一次属性。
//
// ⚠️ 这条**钉的是具体字符串，不是「两次相等」**。写成「两次相等」的话，
//    改成遍历 Set 它照样绿：Set 的顺序在同一个进程里对同样的元素是一样的，
//    要跨进程（重启 app）才可能不同 —— 那正好是测试看不见的那一次。
//    被测代码因此按 `allCases` 过滤，结构上就不可能乱，不靠排序兜底。
check("存盘是规范形（跟 allCases 同序）",
      W([.assistant, .principal]).storageValue == "principal,assistant",
      W([.assistant, .principal]).storageValue)
check("认不出来的片段丢掉、不带崩",
      W.parse("principal,不存在的角色") == W([.principal]))
check("全是垃圾就解析成空", W.parse("啊,哦").isEmpty)
check("前后空白不影响", W.parse(" principal , assistant ") == W([.principal, .assistant]))

// MARK: - 隔离（编译过就算过）

// 工程开了 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，裸 enum 照样被隔离。
// main.swift 的顶层代码本身在 MainActor 上，**所以漏标 nonisolated 在上面
// 那些断言里永远不会现形** —— 必须显式造一个 nonisolated 上下文读一次。
nonisolated func readFromNonisolatedContext() -> [String] {
    [CCAvatarRoleAttr.want(.principal),
     CCAvatarRoleAttr.want(.assistant),
     CCAvatarRoleAttr.legacyWant,
     CCAvatarWants([.principal]).storageValue]
}
check("契约能从 nonisolated 上下文读（编译过就算过）",
      readFromNonisolatedContext().count == 4)

// MARK: -

print("CCAvatarRoles: \(passed) 过 / \(failed) 败")
if failed > 0 { exit(1) }
