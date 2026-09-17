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

## 三、最大的一笔技术债：`ObservableObject`

**现状：14 处 `ObservableObject`，0 处 `@Observable`。**

多篇资料都指向同一件事：`ObservableObject` 会触发
**state invalidation cascade** —— 任何一个 `@Published` 变化都可能让整棵视图树重新求值，
而 `@Observable` 只让**真正读了那个属性的视图**重算。

对我们尤其相关：`CCRooms` 在切房间、连接状态变化、说话状态变化时都会发通知，
而订阅它的是根视图 —— 相当于每次状态抖动整棵树都过一遍。

⚠️ **但不要顺手迁移。** 找到的资料里专门有一篇讲迁移的七个坑，
其中两个跟我们直接相关：`@State` 持有引用类型时的非惰性初始化、嵌套 observable 的更新丢失。
**这是一次要单独排期、带回归测试做的事**，不是顺手改。

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

## 五、下一步（按性价比排）

1. **窗口失焦状态** —— 成本最低，Mac 上最显眼的「不像原生」之处
2. **方向键切房间用 `.onMoveCommand`** —— 顺手，而且是「意图」层面更对的 API
3. **房间方块选中态对齐 `\.backgroundProminence`** —— 语义对齐，为以后塞进 `List` 留路
4. **`@Observable` 迁移** —— 收益最大但要单独排期，不要顺手做
