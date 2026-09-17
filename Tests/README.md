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
**10 杀 0 漏**。

特别值得留的是这两条断言：

- 「全天 4320 个时刻，等待秒数恒为正」
- 「等到点之后相位一定变了」

它们防的是**死循环**和**到点不换** —— 这两种 bug 在单点测试里永远测不出来，
而前者会把电烧光。

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
