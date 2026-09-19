import Foundation

// 跑法（本机没 Swift 工具链，走 docker）：
//   mkdir -p /tmp/swstage
//   cp VoiceAgent/CloseCrab/CCAvatarRoles.swift VoiceAgent/CloseCrab/CCStage.swift /tmp/swstage/
//   cp Tests/CCStageTests.swift /tmp/swstage/main.swift
//   docker run --rm -v /tmp/swstage:/w -w /w swift:6.2-noble \
//     bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
//                CCAvatarRoles.swift CCStage.swift main.swift -o t && ./t'

var pass = 0, fail = 0

func check(_ name: String, _ got: CCStage, _ want: CCStage) {
    if got == want { pass += 1; print("  ✅ \(name)") }
    else { fail += 1; print("  ❌ \(name) — 得到 \(got)，期望 \(want)") }
}

let none = CCAvatarWants()
let principal = CCAvatarWants([.principal])
let assistant = CCAvatarWants([.assistant])
let both = CCAvatarWants([.principal, .assistant])
let all: (CCPersonaRole) -> Bool = { _ in true }
let nothing: (CCPersonaRole) -> Bool = { _ in false }

print("\n── 在说话：视频压过一切 ──")
check("有视频且在说 → 视频", ccStage(connected: true, speakingWithVideo: true,
                                wants: principal, hasImage: all), .video)
check("⭐ 图在手上也不许挡住视频", ccStage(connected: true, speakingWithVideo: true,
                              wants: principal, hasImage: all), .video)
check("⭐ 没开数字人却有视频在说 → 还是播（帧在流就说明它在）",
      ccStage(connected: true, speakingWithVideo: true, wants: none, hasImage: nothing), .video)
check("⭐ 有帧在流就不用问连没连上",
      ccStage(connected: false, speakingWithVideo: true, wants: none, hasImage: all), .video)

print("\n── 没在说话 ──")
check("⭐ 没开数字人 → 柱子，**不许**显示静图",
      ccStage(connected: true, speakingWithVideo: false, wants: none, hasImage: all), .bars)
check("开了 principal 且图在手 → 静图",
      ccStage(connected: true, speakingWithVideo: false, wants: principal, hasImage: all),
      .still(.principal))
check("开了 assistant 且图在手 → 静图（是 assistant 那张）",
      ccStage(connected: true, speakingWithVideo: false, wants: assistant, hasImage: all),
      .still(.assistant))
check("⭐ 开了数字人但图还没下下来 → 退回柱子，不留空白",
      ccStage(connected: true, speakingWithVideo: false, wants: principal, hasImage: nothing),
      .bars)

print("\n── 只有那个角色的图算数 ──")
// 抓的是「拿角色去查图」有没有被写成「随便有一张就行」
check("⭐ 开 assistant，但只有 principal 的图 → 柱子",
      ccStage(connected: true, speakingWithVideo: false, wants: assistant,
              hasImage: { $0 == .principal }), .bars)
check("⭐ 开 principal，但只有 assistant 的图 → 柱子",
      ccStage(connected: true, speakingWithVideo: false, wants: principal,
              hasImage: { $0 == .assistant }), .bars)

print("\n── 两个角色同时开着：必须稳定，不许随机 ──")
// Set 顺序每个进程都不一样。反复调必须每次都一样，否则真机上会来回跳脸。
var seen = Set<String>()
for _ in 0..<200 {
    seen.insert("\(ccStage(connected: true, speakingWithVideo: false, wants: both, hasImage: all))")
}
if seen.count == 1 { pass += 1; print("  ✅ ⭐ 200 次调用结果完全一致：\(seen.first!)") }
else { fail += 1; print("  ❌ ⭐ 结果不稳定，出现了 \(seen.count) 种：\(seen)") }
check("两个都开时取 allCases 里靠前的那个（principal）",
      ccStage(connected: true, speakingWithVideo: false, wants: both, hasImage: all),
      .still(.principal))

print("\n── 没连上 ──")
check("没连上且没在说 → 什么都不画",
      ccStage(connected: false, speakingWithVideo: false, wants: principal, hasImage: all), .idle)
check("⭐ 没连上时即使开着数字人也不许画静图",
      ccStage(connected: false, speakingWithVideo: false, wants: principal, hasImage: all), .idle)

print("\n── 底片（ccPoster）：跟在不在说话无关 ──")
// ⭐ 这一组守的是 Chris 09-19 实测的那个毛病：静图和视频写成二选一之后，
//    「开始说话的时候它就消失了」—— 切到视频时首帧还没到，中间一段空白。
//    修法是把静图垫在底下，所以「有没有底片」必须能单独问、且**说话时依然为真**。
func pcheck(_ name: String, _ got: CCPersonaRole?, _ want: CCPersonaRole?) {
    if got == want { pass += 1; print("  ✅ \(name)") }
    else { fail += 1; print("  ❌ \(name) — 得到 \(String(describing: got))，期望 \(String(describing: want))") }
}
pcheck("⭐ 说话时底片依然在（它垫在视频底下，不是二选一）",
       ccPoster(connected: true, wants: principal, hasImage: all), .principal)
pcheck("没开数字人 → 没有底片", ccPoster(connected: true, wants: none, hasImage: all), nil)
pcheck("开了但图没下下来 → 没有底片",
       ccPoster(connected: true, wants: principal, hasImage: nothing), nil)
pcheck("没连上 → 没有底片", ccPoster(connected: false, wants: principal, hasImage: all), nil)
pcheck("只有别的角色的图 → 没有底片",
       ccPoster(connected: true, wants: assistant, hasImage: { $0 == .principal }), nil)
// ⭐ 两个判据必须同源：ccStage 说要显示静图时，ccPoster 必须给出同一个角色
for w in [none, principal, assistant, both] {
    for h in [all, nothing] {
        let st = ccStage(connected: true, speakingWithVideo: false, wants: w, hasImage: h)
        let po = ccPoster(connected: true, wants: w, hasImage: h)
        let consistent = (st == .still(po ?? .principal) && po != nil) || (st == .bars && po == nil)
        if consistent { pass += 1 } else {
            fail += 1; print("  ❌ ⭐ 两个判据不同源：stage=\(st) poster=\(String(describing: po))")
        }
    }
}
print("  ✅ ⭐ ccStage 和 ccPoster 在 8 种组合下同源")

print("\n\(String(repeating: "=", count: 46))")
print("通过 \(pass) 条，失败 \(fail) 条")
exit(fail == 0 ? 0 : 1)
