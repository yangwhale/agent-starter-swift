# 离线测试

**这台开发机是 Linux、没有 Xcode** —— SwiftUI 和 LiveKit 一行都编不了。
能离线验证的只有纯逻辑，所以规则尽量往只依赖 Foundation 的文件里塞：
写在 View 里的东西，在真机跑之前没有任何人能说它对不对。

目前三个被测文件，都在 `VoiceAgent/CloseCrab/` 下：

| 被测 | 测试 | 条数 | 覆盖什么 |
|---|---|---|---|
| `CCRoomSelection.swift` | `CCRoomSelectionTests.swift` | 26 | 名单规范化的两条不变量、顺序稳定性、去重、幂等、勾选 toggle 四种情形、方块那圈颜色的优先级、多房间槽位增删计划 |
| `CCLook.swift` | `CCLookTests.swift` | 45 | 四段天色的八个边界、越界输入折回、「还有多久换」含跨夜、背景选项解析、rawValue 往返无损 |
| `CCMotionPolicy.swift` | `CCMotionPolicyTests.swift` | 56 | 「减弱动态效果」的 2×2 真值表、开关关闭时 decorative 不参与决策、开关打开时两档必须有区分度、幂等 |
| `CCVisibilityPolicy.swift` | `CCVisibilityPolicyTests.swift` | 93 | 「关要慢、开要快」的不对称、宽限期边界、回前台清零不累计、inactive→background 不重置、deadline 排定时器（含已隐藏返回 nil、晚醒不为负）|
| `CCAvatarState.swift` | `CCAvatarStateTests.swift` | 75 | 四个状态的解析（大小写/空白/未知值）、`unknown` 与 `off` 不能合并、「报错」和「显示画面」都必须同时看用户自己的开关、rawValue 与服务端逐字对齐 |
| `CCAvatarRoles.swift` | `CCAvatarRolesTests.swift` | 48 | 双击的互斥语义（含「抢过来再双击是全关不是弹回」）、**关掉的角色必须显式写 `false`**、老键只镜像 principal、存盘规范形与解析容错、角色 rawValue 与服务端 `policy.py` 逐字对齐 |
| `CCStage.swift` | `CCStageTests.swift` | 14 | 主画面三态的判定：在说话时视频压过一切（连没连上都不问）、**没开数字人不许显示静图**、开了但图没下下来要退回柱子、只有那个角色自己的图算数、两个角色同时开着时结果必须稳定（不能用 Set 的 first）|

> `CCVisibilityPolicy` 那条不对称最值得留意：**两个方向的代价完全不一样。**
> 误判成「看不见」会让正在看的人画面断掉并重起（首帧 1.26 秒 + 重抢槽位），
> 误判成「看得见」只是多渲染几秒。写成对称的（两边都等、或两边都立刻）
> 编译一样过、日常用一样顺 —— 只有「扫一眼通知再回来」时才现形。
>
> `CCMotionPolicy` 被抽出来的理由值得单独说一句：它**只在用户打开了辅助功能
> 开关时才生效**。开发、演示、给人看 demo 永远走不到那条分支 —— 写反了
> 不会有任何人发现，直到一个真正需要它的人装上 app。
> 这正是「往 Foundation-only 文件里塞」这条规则要捞的那类逻辑。

## 怎么跑

本机没装 Swift 工具链，走 docker：

```bash
mkdir -p /tmp/swtest
cp VoiceAgent/CloseCrab/CCLook.swift /tmp/swtest/
cp Tests/CCLookTests.swift /tmp/swtest/main.swift
docker run --rm -v /tmp/swtest:/w -w /w swift:6.2-noble \
  bash -c 'swiftc -swift-version 6 -default-isolation MainActor \
             CCLook.swift main.swift -o t && ./t'
```

两件事不能省：

- **`-default-isolation MainActor`** —— 工程开了
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。不加这个标志，编过了不等于
  Xcode 里编得过：漏标的 `nonisolated` 只有加上它才会报出来。
- **文件名必须是 `main.swift`** 才能写顶层语句。

## 全绿不算数，要做变异测试

测试全绿只说明「现在没红」，不说明「错了会红」。加完规则要手动改坏源码、
确认测试真的会炸。`CCLook` 现有 10 条变异（区间开闭、边界值挪位、比较符方向、
跨夜漏加、负数不折回、auto 不看时钟、off 也给图、秒数不参与、两档标签撞名），
**10 杀 0 漏**。`CCVisibilityPolicy` 11 杀 0 漏，`CCAvatarState` 9 杀 0 漏，
`CCStage` 6 杀 0 漏（判定顺序反、不查图、随便一张图就算、用 Set 的 first、没开也兜底、去掉未连接保护），`CCAvatarRoles` 9 杀 0 漏（互斥失效、漏写 `false`、老键镜像错、存盘顺序反、
解析不去空白、属性键少个点、缓存键不带角色、双击关不掉、空集合存占位串）。

### 变异测试自己也会骗人：三个真踩过的坑

**① 测试从源码里读阈值，会跟着变异一起缩放。**
`CCVisibilityPolicy` 的断言全拿 `backgroundGrace` 当基准，所以把这个常量
改成 0（等于没有去抖）时**整套测试照样全绿**。补法是单独钉住区间，
而且钉**需求**不钉数字：「长过一次扫视（≥3 秒）」「短过白烧 GPU 的忍耐
上限（≤30 秒）」—— 改成 5 或 15 都不该红。

**② Python 那侧：等长的变异 + 同一秒内还原 = 跑的是旧字节码。**
Python 判 `.pyc` 新旧只看源文件的 **(秒级 mtime, 字节数)**。
`visible` → `visable` 字节数一样，还原又在同一秒内，两个判据都没变 ⇒
执行的是**带变异的缓存**。现象可以是「源码 grep 干净但测试红」，
更糟的是反过来 —— 变异被上一轮缓存掩盖成「杀掉了」。
⇒ **每次改写和还原都要清 `__pycache__`**，否则整套结论不可信。

**③ 「全杀」也可能是测试台自己没了。**
2026-09-18 跑 `CCAvatarRoles` 的变异时，清理用的 `rm -rf m*` 把变异体目录
`m0…m8` **和 `main.swift` 一起删了**。于是每个变异体都在
`error: error opening input file 'main.swift'` 上失败，脚本把编译失败
一律记成「编译期拦住」，最后打印 **9 杀 0 漏** —— 一个满分，而实际上
一条断言都没跑过。

两条防法，都很便宜：

- **每轮先跑一遍未变异的基线并要求它全绿。** 基线绿 ⇒ 测试台完好；
  这一步能把上面那种整体性故障一次性挡掉。
- **「编译失败 ＝ 杀掉」这条要留个心眼。** 它对「改坏了类型」是对的，
  对「文件找不到」「模块缺失」这类**跟变异无关**的失败是错的。
  真要严谨就把 swiftc 的 stderr 打出来看一眼是不是类型错。

更一般的那条：**满分本身就是个该起疑的信号。**

特别值得留的是这两条断言：

- 「全天 4320 个时刻，等待秒数恒为正」
- 「等到点之后相位一定变了」

它们防的是**死循环**和**到点不换** —— 这两种 bug 在单点测试里永远测不出来，
而前者会把电烧光。

## ⚠️ 默认隔离开着时，「能编过」要看是从哪个上下文编的

工程设了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，**所有类型默认
MainActor-isolated —— 包括 Foundation-only 文件里的裸 `enum`**。
而 `main.swift` 的顶层代码本身也在 MainActor 上，所以测试里的每一条断言
都是在隔离内读的：**少标 `nonisolated` 这类错，在这个测试台上永远不会现形。**

2026-09-17 实际踩到：三个属性常量要给一个 `nonisolated` 的 delegate 回调读
（`RoomDelegate` 是 `@objc` + `Sendable`，回调不能是 MainActor 的）。
本地 docker 两次全绿，CI 两次报同一条
`can not be referenced from a nonisolated context`。

⇒ **只要被测符号会被 `nonisolated` 的代码读到，测试里就必须显式造一个
`nonisolated` 函数去读一次。** 这是**编译期断言** —— 编过就算过，
运行时那句 `check` 只是占位：

```swift
nonisolated func readKeysFromNonisolatedContext() -> [String] {
    [CCAvatarAttr.want, CCAvatarAttr.visible, CCAvatarAttr.state]
}
check("三个键能从 nonisolated 上下文读（编译过就算过）",
      readKeysFromNonisolatedContext().count == 3)
```

这类断言同样要做变异：拿掉一个 `nonisolated`，确认 docker 里复现出
跟 CI 逐字相同的报错。不验的话你只知道它现在能编，不知道错了会不会拦。

## 写不进这里的部分

View 层（`CCBackdrop` 的图层顺序、`CCRoomTileRow` 的手势、`CCHaptics` 的实际震动）
只能靠真机。退而求其次做了两道：

1. `swiftc -parse` 逐文件语法检查 —— 能抓括号、逗号这类低级错，抓不到类型错：
   ```bash
   docker run --rm -v /tmp/parsecheck:/w -w /w swift:6.2-noble \
     bash -c 'for f in *.swift; do swiftc -parse "$f" || echo "FAIL $f"; done'
   ```

   ⚠️ **别只检查改过的文件。** 括号错的表现位置常常不在你改的那一行 ——
   一个多出来的 `}` 会把后面整段代码推到错误的作用域里，而报错点在很远的地方。
   全量扫 49 个文件也就几十秒。

2. **给新增的 API 建最小类型桩**。`-parse` 过了不代表类型对，而
   Linux 上没有 SwiftUI 没法真编译。折中做法是照着要用的那几个
   SwiftUI 符号写一个只有类型形状、没有行为的桩，把新代码和模拟调用点
   一起编一遍。

   值不值得建看**复用面**：`ccAnimation` 有 20 个调用点，签名错了全线崩，
   那就值；只用一次的东西不用折腾。

   桩本身也要做变异测试 —— 否则你只是证明了「它能编过」，
   没有证明「错了它会拦」。
2. **会静默失败的东西必须有个地方能看出来。** 比如 `Font.custom` 找不到字体时
   不报错、直接退回系统字 —— 所以手写体没装上时，设置页会把
   `CCHandFont.lastNote` 原样显示出来，而不是留一个拨了没反应的开关。
