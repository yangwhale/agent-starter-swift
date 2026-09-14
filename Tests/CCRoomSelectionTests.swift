// 房间选择纯逻辑回归。**在 Linux 上真编真跑**，不是纸面 review。
import Foundation

var pass = 0, fail = 0
@MainActor func check(_ name: String, _ got: some Equatable, _ want: some Equatable) {
    if "\(got)" == "\(want)" { pass += 1; print("✅ \(name)") }
    else { fail += 1; print("❌ \(name)\n     得到 \(got)\n     期望 \(want)") }
}

let ALL = ["bunny", "jarvis", "hulk", "tommy"]

// ── normalize ────────────────────────────────────────────────────────
check("正例：勾了两个，按名单顺序输出",
      CCRoomSelection.normalize(all: ALL, picked: ["hulk", "bunny"], active: "bunny"),
      ["bunny", "hulk"])

check("不变量2：当前房间没勾也要在里面",
      CCRoomSelection.normalize(all: ALL, picked: ["hulk"], active: "bunny"),
      ["bunny", "hulk"])

check("不变量1：已下架的 bot 被丢掉",
      CCRoomSelection.normalize(all: ALL, picked: ["hulk", "已删除的bot"], active: "bunny"),
      ["bunny", "hulk"])

check("顺序不跟勾选先后走（倒着勾，结果一样）",
      CCRoomSelection.normalize(all: ALL, picked: ["tommy", "hulk", "jarvis"], active: "bunny"),
      CCRoomSelection.normalize(all: ALL, picked: ["jarvis", "hulk", "tommy"], active: "bunny"))

check("去重：同一个名字勾两遍只出现一次",
      CCRoomSelection.normalize(all: ALL, picked: ["hulk", "hulk"], active: "bunny"),
      ["bunny", "hulk"])

check("首尾空格被吃掉",
      CCRoomSelection.normalize(all: ALL, picked: ["  hulk  "], active: "bunny"),
      ["bunny", "hulk"])

check("反例：active 是空串时不要塞一个空名字进去",
      CCRoomSelection.normalize(all: ALL, picked: ["hulk"], active: ""),
      ["hulk"])

check("反例：active 不在名单里（刚被下架）也不能凭空塞回来",
      CCRoomSelection.normalize(all: ALL, picked: ["hulk"], active: "已删除的bot"),
      ["hulk"])

check("幂等：规范化两遍结果不变",
      CCRoomSelection.normalize(all: ALL,
        picked: CCRoomSelection.normalize(all: ALL, picked: ["tommy","hulk"], active: "bunny"),
        active: "bunny"),
      ["bunny", "hulk", "tommy"])

// ── toggle ───────────────────────────────────────────────────────────
check("勾上一个新的",
      CCRoomSelection.toggle("hulk", in: ["bunny"], all: ALL, active: "bunny"),
      ["bunny", "hulk"])

check("取消勾一个非当前房间",
      CCRoomSelection.toggle("hulk", in: ["bunny", "hulk"], all: ALL, active: "bunny"),
      ["bunny"])

check("反例：当前房间取消不掉",
      CCRoomSelection.toggle("bunny", in: ["bunny", "hulk"], all: ALL, active: "bunny"),
      ["bunny", "hulk"])

check("反例：勾一个不存在的名字，什么也不该发生",
      CCRoomSelection.toggle("查无此bot", in: ["bunny"], all: ALL, active: "bunny"),
      ["bunny"])

check("来回勾两次回到原点",
      CCRoomSelection.toggle("hulk",
        in: CCRoomSelection.toggle("hulk", in: ["bunny"], all: ALL, active: "bunny"),
        all: ALL, active: "bunny"),
      ["bunny"])

// ── 圈的优先级 ───────────────────────────────────────────────────────
check("没连上 → pending（哪怕又静音又在说话）",
      CCTileRing.derive(isConnected: false, isMuted: true, isSpeaking: true), CCTileRing.pending)
check("静音优先于说话 —— 它在出声但我听不见，该提醒的是听不见",
      CCTileRing.derive(isConnected: true, isMuted: true, isSpeaking: true), CCTileRing.muted)
check("正在说话 → speaking",
      CCTileRing.derive(isConnected: true, isMuted: false, isSpeaking: true), CCTileRing.speaking)
check("在线没说话 → idle",
      CCTileRing.derive(isConnected: true, isMuted: false, isSpeaking: false), CCTileRing.idle)


// ── 槽位增删计划 ─────────────────────────────────────────────────────
func plan(_ cur: [String], _ want: [String], _ active: String) -> String {
    let p = CCRoomSelection.planSlots(current: cur, want: want, active: active)
    return "add=\(p.toAdd) rm=\(p.toRemove) order=\(p.order) active=\(p.active)"
}

check("正例：勾了新房间 → 只新建它，不碰已有的",
      plan(["bunny"], ["bunny", "jarvis"], "bunny"),
      "add=[\"jarvis\"] rm=[] order=[\"bunny\", \"jarvis\"] active=bunny")

check("正例：取消勾选 → 只断它",
      plan(["bunny", "jarvis"], ["bunny"], "bunny"),
      "add=[] rm=[\"jarvis\"] order=[\"bunny\"] active=bunny")

check("正例：当前房间被取消 → 话筒退给名单第一个",
      plan(["bunny", "jarvis"], ["jarvis"], "bunny"),
      "add=[] rm=[\"bunny\"] order=[\"jarvis\"] active=jarvis")

check("反例：没变化 → 三个清单全空，不该触发任何动作",
      plan(["bunny", "jarvis"], ["bunny", "jarvis"], "bunny"),
      "add=[] rm=[] order=[\"bunny\", \"jarvis\"] active=bunny")

check("★ 反例：want 为空（名单还没拉到）→ 什么都不做，绝不能把连着的全断掉",
      plan(["bunny", "jarvis"], [], "bunny"),
      "add=[] rm=[] order=[\"bunny\", \"jarvis\"] active=bunny")

check("正例：整批换掉",
      plan(["bunny"], ["hulk", "tommy"], "bunny"),
      "add=[\"hulk\", \"tommy\"] rm=[\"bunny\"] order=[\"hulk\", \"tommy\"] active=hulk")

check("反例：只是顺序变了，不该产生任何增删",
      plan(["jarvis", "bunny"], ["bunny", "jarvis"], "bunny"),
      "add=[] rm=[] order=[\"bunny\", \"jarvis\"] active=bunny")

check("冷启动：一个槽位都没有 → 全建",
      plan([], ["bunny", "jarvis"], ""),
      "add=[\"bunny\", \"jarvis\"] rm=[] order=[\"bunny\", \"jarvis\"] active=bunny")

print("\n\(pass) 通过 / \(fail) 失败")
exit(fail == 0 ? 0 : 1)
