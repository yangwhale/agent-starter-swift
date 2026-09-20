# Apple 平台实践笔记（2026-09 蒸馏）

调研 macOS 26/27 与 WWDC26 之后，**只留对这个 app 有用的**。
每条都标了「我们现在怎样」——泛泛的最佳实践清单没有价值，
有价值的是「这条跟我们的代码对不对得上」。

来源：Apple HIG（Materials）、WWDC26 What's new in SwiftUI、
`pfandrade.me` 的 Mac-assed SwiftUI 系列、`blakecrosley.com` 的 Liquid Glass 实践。

---

## 一、Liquid Glass 的分层规则（最重要的一条）

Apple HIG 原文：

> **Don't use Liquid Glass in the content layer.** Liquid Glass works best when it
> provides a clear distinction between interactive elements and content, and
> including it in the content layer can result in unnecessary complexity and a
> confusing visual hierarchy.

两层，材质不同：

| 层 | 是什么 | 用什么 |
|---|---|---|
| **内容层** | 文档、列表、照片、正在消费的东西 | **标准材质**（`.regularMaterial` / `.thickMaterial`…） |
| **功能层** | 控件、导航、临时浮层 | **Liquid Glass**（`.glassEffect`） |

### ✅ 我们是合规的

核过全部 12 处 `.glassEffect`：控制栏、按住说话条、房间方块、房间条、启动页按钮 ——
**全在功能层**。内容层那块主面板用的是 `.thickMaterial`（标准材质）。

> 这条值得记在这儿，因为它是**反直觉**的：「Liquid Glass 好看，那就多用点」
> 恰恰是 Apple 明确反对的。一个把 glass 涂在列表行和照片卡上的 app，
> 用的是同一个 API，出来就是不对 —— **材质是对的，底下的架构不是**。

### ⚠️ 两条容易踩的

**「玻璃不能放在纯色背景上。」** Glass 靠折射背后的东西成立；背后是一块纯色的话，
折射没东西可弯，出来就是个扁平的带色方块。

→ 我们那套背景图 + 极光**存在的理由就是这个**，不是装饰。
（参考的那个 app 也是同样做法：专门跑一段循环视频当背景，就为了让玻璃有东西可折射。）

**「高频内容上慎用 glass。」** 原话：*a waveform or audio visualizer at 60 Hz is
unproven and likely fights the morph animation*。

→ 我们的 `CCVoiceBars` 正是 30fps 的音量柱。好在它用的是**金属渐变 + 遮罩，不是
`.glassEffect`** —— 现在是安全的。**以后别手痒给柱子加 glass。**

---

## 二、WWDC26 里对我们有用的

### 🔧 该做的

| 项 | 为什么对我们有用 | 我们现在 |
|---|---|---|
| **窗口活跃/非活跃状态** | SwiftUI 现在自动调整，另给了新 environment value。Mac 上窗口失焦该有视觉区分，这是基本礼貌 | ❌ **完全没处理** |
| **`\.backgroundProminence`** | 表达选中态的系统标准途径，跟 `List`/`Table` 语义一致 | ⚠️ 房间方块用自己的 `isActive` 画 |
| **`.onMoveCommand`** | 比 `.onKeyPress` 更对：它表达的是「用户想往下移」这个**意图**，不是「按了下箭头」。macOS 可用（iOS 没有，是 API 缺口不是设计） | ⚠️ 我们刚用 `.onKeyPress` 做了空格；方向键切房间该用这个 |

### 📌 该知道的

- **`@State` 变成宏了**，`@State` 持有的 class 只初始化一次，**回溯到 iOS 17**。
  → 我们为 `@StateObject(wrappedValue:)` 写的那些「autoclosure 只求值一次」的注释，
  框架层面现在已经保证了，不再是「靠约定」。
- **Liquid Glass 在 macOS 27 变强制**，那个 Info.plist 退出开关只支持到 iOS 27。
  → 不影响我们（本来就在用），但别指望还能退回去。
- **AppKit 控件（`NSSlider`/`NSSwitch`）内部改用 SwiftUI 了**，很多 AppKit 方法支持
  `Observation`，回溯到 macOS 15。→ 混用的成本比以前低。
- 工具栏一组新 API（`.visibilityPriority`、`ToolbarOverflowMenu`、
  `topBarPinnedTrailing`、`toolbarMinimizeBehavior`）。
  → 我们几乎不用 toolbar，**优先级最低**，记着有就行。

---

## 三、`ObservableObject` —— ✅ 2026-09-20 已迁移（本节原来的结论已作废）

**现状：我们自己的类型 `ObservableObject` 已经清零。**

还剩两个 `.environmentObject` 注入点，那是 LiveKit SDK 的 `Session` 和
`LocalMedia` —— 它们是 SDK 的类型，改不了，**只能不读**（见下面第 3 阶段）。
SDK 哪天自己迁到 `@Observable`，这两行才能跟着换。

### 当初的判断对，但「不要顺手迁移」那句被现实推翻了

本节原文写着「最大的一笔技术债」「⚠️ 但不要顺手迁移，要单独排期」。
**前半句是对的，后半句被一次事故否掉了** —— 2026-09-20 那天不是「顺手」做的，
是被逼着做的：

`ObservableObject` 的 state invalidation cascade 在真机上实测出来是
**静置不动 72–81% CPU、两分钟内存涨 1.7 GB、进程半小时被系统回收 8 次**。
它不是「以后该还的债」，是**当天就在烧电池的故障**。

### 真实的根因比本节原来写的更具体

原文说「`CCRooms` 发通知、根视图订阅它」。实测下来主犯是另一条：

    CCRoomSlot: session.objectWillChange.sink { self.objectWillChange.send() }

把 LiveKit 的**每一条**变更通知原样转发成自己的「我变了」，而订阅槽位的是
整屏布局 —— 探针实测峰值 **730 次界面重算/秒**，静置无操作。

### 迁移实际怎么做的（分三阶段，都编过真机）

1. **叶子对象**（10 个，不在 environment、无人订阅其 objectWillChange）
2. **核心链路** `CCRoomSlot` / `CCRooms` / `CloseCrabConfig` ——
   这一步才是重点：不只是换标注，而是**把「转发通知」改成「发布派生值」**，
   六个镜像属性逐项比对、只有真变了才写，外加 80 ms 合并窗口
3. **拆掉 view 对 `Session` 的订阅** —— 从 9 处降到 1 处
   （`Session` 是 LiveKit 的 ObservableObject，改不了它；
   但**读它任何一个属性就等于订阅它全部变化**，所以只能不读）

结果：界面重算 730 次/秒 → **0**；事件合并比在连接尖峰段 **310 : 1**。

### 原文担心的那两个坑，实际都没发生

`@State` 持引用类型的非惰性初始化、嵌套 observable 更新丢失 —— 都没踩到。
**真正栽的是另外两个**，记在这儿给下一次：

- **去掉属性包装器之后，那个属性会参与 memberwise init**。它是 `private` 的话，
  合成的 init 就被降级成 `private`，跨文件构造直接编不过。
  解法：单例引用改成计算属性（`private var x: T { .shared }`），不进 memberwise init。
- **`@EnvironmentObject` 只要声明就订阅，跟 body 里读不读无关。**
  改完读法却留着声明 = 整件事白做。实测有 2 处是**声明了从没使用过的死订阅**。

---

## 四、一条跟「做得 fancy」有张力的官方建议

WWDC26 设计场次原话：

> **Don't heavily customize the UI, platform familiarity is important.**
> Move color into the content area of your app, into the scroll view.
> Use color to communicate status, feedback, and selection states. Use sparingly.

也就是说：Apple 认为**个性应该体现在内容区的用色上，而不是把系统控件改得面目全非**。

这跟「我想要特别 fancy」不冲突，但方向要选对 ——
我们现在的做法（背景图带身份色、控件保持系统形态）**正好是这条建议的方向**：
色彩在内容层，控件用系统的。

反面是去重画控制栏、自定义滚动条那种 —— 花力气多、坏得快、还不像 Mac 应用。

---

## 五、同一套原则套到 iOS 上，查出来四条（已修）

上面那些是拿 Mac 当靶子查的。同一套原则对着 iOS 侧再走一遍，
**最值钱的一条恰恰是我差点写反的那条**。

### 1. 字体：一个开关顺带改变了「跟不跟系统字号」

Apple 文档写得很明白，这两个是**不同行为**：

```
Font.custom(_:size:)              "scales with the body text style"   ← 自动跟
Font.system(size:weight:design:)                                      ← 固定，不跟
```

`CCType` 三个函数原本两个分支直接这么写，于是同一个界面：

| 手写体开关 | 走哪条 | 后果 |
|---|---|---|
| 关 | `.system(size:)` | 用户把系统字号调大，我们**纹丝不动**（该跟的没跟） |
| 开 | `.custom(_:size:)` | 字跟着放大，但方块写死 54pt、名字那行 `lineLimit(1)` ＋ 固定宽度 → 辅助功能字号下截成「J…」 |

**两头都错，而且方向相反。** 一个装饰性开关不该顺带改变无障碍行为。

> 我原本打算写的是「手写体不跟动态字号」—— **正好反了**。
> 这是典型的「听起来像常识的 API 行为」：自定义字体当然不跟系统字号，
> 多合理啊。查文档花了三十秒。

修法：两个分支都改 `fixedSize:` 关掉字体自带的缩放，缩放交给调用点
一个 `@ScaledMetric` 统一驱动 —— **字和承载它的方块用同一个系数长**。
方块行本来就在横向 `ScrollView` 里，长出去能滚，所以不设上限，
是完整支持动态字号而不是卡个天花板了事。角标位置和角标字号也按同一个
系数派生，否则字长了角标还钉在原地。

### 2. 「减弱动态效果」只覆盖了 1/12

研究里那条原话是 *every glass animation should be gated on
`accessibilityReduceMotion`* —— 玻璃形变是 kinetic effect，不是淡入淡出。
实际只有 `CCAurora` 一个文件读了这个环境值，另外 11 个文件 23 处动画全裸奔，
其中两处还是 `repeatForever`。

做法不是在 11 个文件各加一个 `@Environment`（那就是在等下一次漏），
而是加一层拦截：`.ccAnimation(_:value:)` / `.ccDecorativeAnimation(_:value:)`。

**分两档是有讲究的** —— 这个开关针对前庭反应，淡入淡出不在其列：

- 状态切换类 → 退化成**淡出**。直接不动会让切换变硬跳，看着像界面卡了
- 纯装饰的无限循环 → **彻底停**

两个不该套这个模板的，单独处理了：

- `Spinner` 停下来像卡死（它唯一的作用就是说「还在跑」）→ 换成透明度呼吸
- `CCVoiceBars` 的柱子**本身就是内容** → 保留。而且去掉那 33ms 插值只会更差：
  泵是 30fps，不抹平两帧之间柱子变成一格一格硬跳，比平滑起伏更刺激

判定逻辑抽成了 `CCMotionPolicy`（Foundation-only，56 条测试、6 条变异全杀）——
因为它**只在用户打开开关时才生效**，写反了日常开发永远撞不到。

### 3. VoiceOver：标签挂在多元素容器上等于没挂

房间方块视觉上是一个按钮，无障碍树里却是六样东西（底板、描边、角标、
波形、名字、选中条）。原来那句 `.accessibilityLabel` 直接挂在 `VStack` 上，
**没有先 `accessibilityElement(children: .ignore)`，落不到一个元素上**。

补齐的三样：合成单元素、`.isButton` ＋ `.isSelected` trait、
以及 —— 这条最实在 —— **两个命名动作**：

> 双击静音和长按换图标这两个手势被 VoiceOver 自己接管了，传不到我们的
> `gestures` 上。不补 `.accessibilityAction`，这两个功能对 VoiceOver 用户
> 就是**缺失的，而界面上看不出任何异样**。

`CCVoiceBars` 和 `CCTileConnector` 是自绘图形，显式 `.accessibilityHidden(true)` ——
它们传递的信息旁边都有文字承载（状态提示、房间标签），重复念一遍不是更无障碍，是更吵。

### 4. 拿两档信号驱动一个连续的量

`ChatInputView` 原来是 `horizontalSizeClass == .regular ? 512 : 368`。

**问题不在 size class 过时** —— 它在分屏和可变窗口下是会跟着变的，
WWDC26 反对的是 `userInterfaceIdiom` 和 orientation，那两个我们一处都没用。
问题在于窗口宽度是连续变的，输入框却只在某个阈值上「啪」地跳一下，
跳之前还有一段明显留白。WWDC26 把「iPhone app 可被自由缩放」列为新常态，
这种二值跳变正是那个场景下最显眼的破绽。

改成只留上限：容器比它窄时 `maxWidth` 自然让位。**少一个分支，行为反而更对。**

---

## 六、下一步（按性价比排）

1. **窗口失焦状态** —— 成本最低，Mac 上最显眼的「不像原生」之处
2. **方向键切房间用 `.onMoveCommand`** —— 顺手，而且是「意图」层面更对的 API
   （iOS 没这个 API，是缺口不是设计；iPad 外接键盘只能走 `.onKeyPress`）
3. **房间方块选中态对齐 `\.backgroundProminence`** —— 语义对齐，为以后塞进 `List` 留路
4. ~~**`@Observable` 迁移**~~ —— ✅ 2026-09-20 已做，见第三节。
   **在 iOS 上应该比在 Mac 上更靠前**：`CCRooms` 的说话状态是音量驱动、
   接近每帧在变，失效级联在 Mac 上是浪费，在 iPhone 上是掉帧加耗电
5. **全局字阶 `CC.Font` 六个字号全是固定的** —— 换成语义字号能拿到动态字号支持，
   但**iOS 和 macOS 的语义字号点数不一样**，不是无损替换，要配一轮真机目测。
   单独排，别跟别的改动混在一起

> ⚠️ 上面全部改动**只过了语法检查和纯逻辑测试**，Linux 上编不了 SwiftUI。
> 第一次真正的编译验证在 Xcode 里。
