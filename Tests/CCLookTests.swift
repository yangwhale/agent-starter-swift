// 外观纯逻辑回归。**在 Linux 上真编真跑**，不是纸面 review。
//
// 跑法见 Tests/README.md。文件名必须是 main.swift 才能写顶层语句。
import Foundation

var pass = 0, fail = 0
@MainActor func check(_ name: String, _ got: some Equatable, _ want: some Equatable) {
    if "\(got)" == "\(want)" { pass += 1; print("✅ \(name)") }
    else { fail += 1; print("❌ \(name)\n     得到 \(got)\n     期望 \(want)") }
}

// ── 相位边界 ──────────────────────────────────────────────────────────
// 每个边界都测**前一分钟和当分钟**两个点。只测中间值的话，把 `..<` 写成 `...`
// 这种差一错永远抓不到。

check("04:59 还是夜里", CCSky.phase(hour: 4, minute: 59), CCSkyPhase.night)
check("05:00 进黎明（边界含左）", CCSky.phase(hour: 5, minute: 0), CCSkyPhase.dawn)
check("07:59 还是黎明", CCSky.phase(hour: 7, minute: 59), CCSkyPhase.dawn)
check("08:00 进白天（边界含左）", CCSky.phase(hour: 8, minute: 0), CCSkyPhase.day)
check("16:29 还是白天", CCSky.phase(hour: 16, minute: 29), CCSkyPhase.day)
check("16:30 进黄昏（边界含左）", CCSky.phase(hour: 16, minute: 30), CCSkyPhase.dusk)
check("19:29 还是黄昏", CCSky.phase(hour: 19, minute: 29), CCSkyPhase.dusk)
check("19:30 进夜里（边界含左）", CCSky.phase(hour: 19, minute: 30), CCSkyPhase.night)
check("午夜 00:00 是夜里", CCSky.phase(hour: 0, minute: 0), CCSkyPhase.night)
check("23:59 是夜里", CCSky.phase(hour: 23, minute: 59), CCSkyPhase.night)

// 反例：越界输入要折回去，不能返回一个「看起来正常」的值。
check("反例：hour=24 折回 00:00＝夜里", CCSky.phase(hour: 24, minute: 0), CCSkyPhase.night)
check("反例：hour=30 折回 06:00＝黎明", CCSky.phase(hour: 30, minute: 0), CCSkyPhase.dawn)
check("反例：hour=-1 折回 23:00＝夜里", CCSky.phase(hour: -1, minute: 0), CCSkyPhase.night)
check("反例：hour=-18 折回 06:00＝黎明", CCSky.phase(hour: -18, minute: 0), CCSkyPhase.dawn)
check("分钟溢出：08:-60 ＝ 07:00 ＝ 黎明", CCSky.phase(hour: 8, minute: -60), CCSkyPhase.dawn)

// 四段必须都能取到 —— 防止某一段被边界写死成永远取不到。
check("四段各自可达",
      Set([0, 6, 12, 18].map { CCSky.phase(hour: $0) }).count, 4)

// ── 下一次换天色还有多久 ──────────────────────────────────────────────

check("04:00 → 距 05:00 是 3600 秒",
      CCSky.secondsUntilNextPhase(hour: 4, minute: 0), 3600)
check("05:00 整点踩在边界上，等的是下一个 08:00",
      CCSky.secondsUntilNextPhase(hour: 5, minute: 0), 3 * 3600)
check("16:00 → 距 16:30 是 1800 秒",
      CCSky.secondsUntilNextPhase(hour: 16, minute: 0), 1800)
check("19:00 → 距 19:30 是 1800 秒",
      CCSky.secondsUntilNextPhase(hour: 19, minute: 0), 1800)
check("20:00 跨夜 → 距次日 05:00 是 9 小时",
      CCSky.secondsUntilNextPhase(hour: 20, minute: 0), 9 * 3600)
check("23:59:30 跨夜 → 距次日 05:00 是 5 小时零 30 秒",
      CCSky.secondsUntilNextPhase(hour: 23, minute: 59, second: 30), 5 * 3600 + 30)
check("秒数也算进去：04:59:30 → 30 秒",
      CCSky.secondsUntilNextPhase(hour: 4, minute: 59, second: 30), 30)

// 这一条是保命的：**返回值永远要为正**。返回 0 会让视图的等待循环空转成死循环，
// 那是会把电烧光的 bug，而且只在特定时刻出现。
@MainActor func allPositive() -> Bool {
    for h in 0 ..< 24 {
        for m in stride(from: 0, to: 60, by: 1) {
            for s in [0, 30, 59] where CCSky.secondsUntilNextPhase(hour: h, minute: m, second: s) <= 0 {
                print("  ⚠️ \(h):\(m):\(s) 返回了非正数")
                return false
            }
        }
    }
    return true
}
check("全天 4320 个时刻，等待秒数恒为正", allPositive(), true)

// 而且「等到点之后相位一定变了」—— 否则视图会醒来、发现没变、再睡同样长，
// 表现是背景到点不换。
@MainActor func alwaysAdvances() -> Bool {
    for h in 0 ..< 24 {
        for m in [0, 17, 29, 30, 31, 59] {
            let wait = CCSky.secondsUntilNextPhase(hour: h, minute: m)
            let then = (CCSky.minutes(hour: h, minute: m) * 60 + wait) / 60
            if CCSky.phase(hour: 0, minute: then) == CCSky.phase(hour: h, minute: m) {
                print("  ⚠️ \(h):\(m) 等了 \(wait) 秒之后相位没变")
                return false
            }
        }
    }
    return true
}
check("等到点之后相位一定变了", alwaysAdvances(), true)

// ── 选哪张图 ──────────────────────────────────────────────────────────

check("off ＝ 不要图", CCSky.asset(for: .off, hour: 12) ?? "nil", "nil")
check("auto 在白天取白天那张", CCSky.asset(for: .auto, hour: 12) ?? "nil", "cc-bg-day")
check("auto 在夜里取夜里那张", CCSky.asset(for: .auto, hour: 23) ?? "nil", "cc-bg-night")
check("auto 在黎明取黎明那张", CCSky.asset(for: .auto, hour: 6) ?? "nil", "cc-bg-dawn")
check("auto 在黄昏取黄昏那张", CCSky.asset(for: .auto, hour: 17) ?? "nil", "cc-bg-dusk")
check("手动锁定 orbit 不受时间影响（白天）", CCSky.asset(for: .orbit, hour: 12) ?? "nil", "cc-bg-orbit")
check("手动锁定 orbit 不受时间影响（夜里）", CCSky.asset(for: .orbit, hour: 3) ?? "nil", "cc-bg-orbit")
check("手动锁定 grid", CCSky.asset(for: .grid, hour: 12) ?? "nil", "cc-bg-grid")
check("手动锁定 night 在白天也给深空", CCSky.asset(for: .night, hour: 12) ?? "nil", "cc-bg-night")

// 每一个非 off 的选项都必须解析出一个资源名，而且**互不重复** ——
// 重复意味着某两个选项在界面上是两行、实际是同一张图。
@MainActor func everyChoiceResolves() -> String {
    var names: [String] = []
    for c in CCBackdropChoice.allCases where c != .off {
        guard let n = CCSky.asset(for: c, hour: 12) else { return "\(c) 解析成了 nil" }
        names.append(n)
    }
    // auto 在 12 点解析成 day，和显式的 .day 撞名是**预期的**，所以去掉 auto 再查重。
    let explicit = CCBackdropChoice.allCases
        .filter { $0 != .off && $0 != .auto }
        .compactMap { CCSky.asset(for: $0, hour: 12) }
    return Set(explicit).count == explicit.count ? "ok" : "有重复：\(explicit)"
}
check("每个选项都解析得出、且显式选项互不重名", everyChoiceResolves(), "ok")

check("资源名全部带 cc-bg- 前缀",
      CCBackdropChoice.allCases.compactMap { CCSky.asset(for: $0, hour: 9) }
          .allSatisfy { $0.hasPrefix("cc-bg-") }, true)

// ── 枚举本身 ──────────────────────────────────────────────────────────

check("背景选项 8 个", CCBackdropChoice.allCases.count, 8)
check("深浅色 3 档", CCAppearance.allCases.count, 3)
check("深浅色默认档的 rawValue 是 system", CCAppearance.system.rawValue, "system")

// 持久化存的是 rawValue，所以**往返必须无损**。改枚举时最容易在这儿翻车：
// 改了 case 名字 = 老用户存的那个值再也读不出来，表现是设置被悄悄重置。
check("背景选项 rawValue 往返无损",
      CCBackdropChoice.allCases.allSatisfy { CCBackdropChoice(rawValue: $0.rawValue) == $0 }, true)
check("深浅色 rawValue 往返无损",
      CCAppearance.allCases.allSatisfy { CCAppearance(rawValue: $0.rawValue) == $0 }, true)
check("天色相位 rawValue 往返无损",
      CCSkyPhase.allCases.allSatisfy { CCSkyPhase(rawValue: $0.rawValue) == $0 }, true)

// 每个选项都得有个能显示的中文名 —— 空字符串会在设置页里变成一行空白。
check("每个背景选项都有标签",
      CCBackdropChoice.allCases.allSatisfy { !$0.label.isEmpty }, true)
check("每个深浅色档都有标签",
      CCAppearance.allCases.allSatisfy { !$0.label.isEmpty }, true)
check("标签互不重复",
      Set(CCBackdropChoice.allCases.map(\.label)).count, CCBackdropChoice.allCases.count)

// ── 结果 ──────────────────────────────────────────────────────────────
print("\n\(pass) 通过 / \(fail) 失败")
exit(fail == 0 ? 0 : 1)
