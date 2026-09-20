# CloseCrab 语音助理 · 视觉重设计调研与方案

调研日期：2026-09-15 · 目标平台：iOS 26（Liquid Glass 已可用）· 目标人群：00 后 / 10 后

> 本文档只做调研与方案，不含任何代码改动。

---

## 目录

1. [现状诊断：为什么现在"太low"](#一现状诊断)
2. [2025–2026 趋势结论](#二趋势结论)
3. [两个必须先说清的硬约束](#三两个硬约束)
4. [六个完整视觉方案](#四六个完整视觉方案)
   - [A · 极光电台 Aurora Radio](#方案-a极光电台-aurora-radio)
   - [B · 大字报 Loud Type](#方案-b大字报-loud-type)
   - [C · 软糖 Jelly](#方案-c软糖-jelly)
   - [D · 千禧回声 Y2K Echo](#方案-d千禧回声-y2k-echo)
   - [E · 便当电台 Bento Desk](#方案-e便当电台-bento-desk)
   - [F · 液态铬 Liquid Chrome](#方案-f液态铬-liquid-chrome)
5. [专题：agent 说话时的音频可视化](#五专题音频可视化)
6. [选型建议](#六选型建议)
7. [信息来源](#七信息来源)

---

<a name="一现状诊断"></a>
## 一、现状诊断：为什么现在"太low"

我读了现有代码（`VoiceAgent/Helpers/CCTheme.swift`、`Assets.xcassets/Colors/*`、`CCHoldToTalk.swift`、`CCRoomTileRow.swift`、`CCRootView.swift`、`Media/AgentView.swift`），"low" 不是错觉，有四个可定位的技术原因。

### 1. 深色模式几乎是纯黑，直接让 Liquid Glass 失效

现有色板实测值（从 `.colorset/Contents.json` 换算）：

| token | 浅色 | 深色 |
|---|---|---|
| `bg1` 底 | `#F9F9F9`（实为 0.976/0.976/0.965） | `#070707` |
| `bg2` 卡片 | `#F3F3F1` | `#131313` |
| `bg3` | `#E2E2DF` | `#202020` |
| `fg0`→`fg4` | `#000000` → `#707070` | `#FFFFFF` → `#666666` |
| `fgAccent` | `#002CF2`（唯一彩色） | 同上 |

深色模式 `#070707` 距离纯黑只有 3%。**这是"low"的根因，不是审美问题而是物理问题**：Liquid Glass 的视觉效果来自折射背后的内容、采集环境色做 specular 高光。背后是一片近乎纯黑的空白时，玻璃没有任何东西可折射，`.glassEffect()` 渲染出来就是一块半透明灰矩形 —— 跟 iOS 7 时代的毛玻璃没有区别，白白付出了性能代价。

代码里其实已经正确地用了 `.glassEffect(.regular.interactive())`、`GlassEffectContainer`、`glassEffect` 做选中态（`CCRoomTileRow.swift:104`），**工程是对的，只是背景没给它东西可折射**。

### 2. 全局只有一个彩色

`fgAccent = #002CF2` 是整套色板里唯一的非灰色（语义色 success/serious/moderate 只在错误态出现）。24 个 colorset 里 20 个是灰阶。年轻向产品的普遍规律是 **1 主色 + 2–3 个高饱和强调色 + 中性背景**，现在是 0 强调色。

### 3. 字体全程 SF Pro Regular/Medium，没有字阶对比

`CCRoomTileRow` 用 `.caption2`，`CCTalkBar` 用 `.headline`（`roomBar` 那条 `15pt medium` 已随房间条一起去掉）。最大和最小之间差不到 2 倍，整屏没有视觉焦点。2026 年的普遍做法是拉开到 4–6 倍（tubikstudio 与 Figma 都把 "bold typography / expressive type" 列为核心趋势）。

### 4. 音频可视化静止时真的像坏了

`AgentView.swift:37` 用 `BarAudioVisualizer(barCount: 5, barMinOpacity: 0.1)`。看组件源码（`components-swift/.../BarAudioVisualizer.swift`）：

```swift
let barMinHeight = barWidth   // 最小高度 = 条宽
height = (H - barMinHeight) * bands[i] + barMinHeight
cornerRadius = 100            // 全圆角
```

`bands[i] == 0` 时高度 = 宽度 + 全圆角 = **正圆**。5 个正圆、opacity 0.1 的灰点，静止时确实无法与"渲染失败"区分。这不是配色能救的，必须换可视化形态（见[第五节](#五专题音频可视化)）。

---

<a name="二趋势结论"></a>
## 二、2025–2026 趋势结论

综合已抓取的 Figma 2026 Web Design Trends、tubikstudio《7 UI Design Trends of 2026》、uxpilot《12 Product Design Trends for 2026》、gezar.dk《11 Best Web Design Trends 2026》四份来源，与本次补充检索，对"面向 00/10 后的语音 AI app"有效的结论如下。

### 确定在涨的

| 趋势 | 证据 | 对本 app 的意义 |
|---|---|---|
| **高饱和 / dopamine 配色** | Figma Trend 3 "Vibrant color palettes"，明确归因 Y2K 怀旧 + dopamine design，点名 Lush / Headspace / Starface | 直接对症：现在 0 强调色 |
| **Bold / expressive typography** | Figma Trend 4；tubikstudio 也把 raw type 单列 | 字阶必须拉开 |
| **Glassmorphism 2.0** | uxpilot Trend 2，明确说 Apple Liquid Glass 是推动者 | 已有工程基础，但需要彩色背景托底 |
| **Neobrutalism** | Figma Trend 12 + uxpilot Trend 7（点名 Gumroad：黑白 + Lavender Rose + 粗边 + 硬阴影） | 最"不像模板"的方向 |
| **Retro / Y2K revival** | uxpilot Trend 8（点名 Bump by amo 的拼贴、PostHog 的 Win95 桌面）+ gezar Trend 11 | 00/10 后的核心怀旧对象 |
| **Bento grid** | uxpilot Trend 6 + gezar Trend 7 | 多 bot 场景天然适配 |
| **Aurora UI / mesh gradient** | gezar Trend 4，点名 Stripe / Linear / Vercel | 给 Liquid Glass 提供折射源的最省力解法 |
| **Grain & noise 质感** | gezar Trend 9，建议 `feTurbulence` 15–30% 不透明度 | 让渐变不"塑料" |
| **Micro-delight 微交互** | uxpilot Trend 4，点名 Transit / Duolingo / Miro | 语音 app 的等待期特别需要 |
| **Kinetic typography** | uxpilot Trend 9，点名 Bump 的 buzz 按钮文字抖动 | 「按住说话」按钮可用 |

### 有争议的（必须诚实说）

**Liquid Glass 本身正在遭遇反弹。** tubikstudio 把第 7 条直接命名为 **"Anti-Liquid Glass"**，引用 Linear 团队的做法：他们重写了自己的玻璃系统，保留高斯模糊、光标联动的渐变光照、滚动边界的可变模糊，但**刻意去掉了 Apple 的折射畸变**，理由是它在高密度界面里破坏可读性。原文还直接批评 Apple 自家 Music app：「blur reduces contrast and makes core controls harder to perceive」。

对本项目的结论：**Liquid Glass 用在导航层（说话条、控制栏、头像方块）没问题，但不要用在内容层，也不要指望它自己变好看。** Apple 官方立场也一致 ——「Liquid Glass is best reserved for the navigation layer that floats above the content of your app」。

### 明确在跌的

- 纯灰阶极简（tubikstudio 原话：「grayscale graveyards of safe spacing and polite typography」）
- 无意义装饰动画（2026 的共识是 motion 必须传达状态）
- Neumorphism 作为主风格（可访问性问题，只适合做点缀）

### 中文年轻向产品的配色规律

从公开可查的品牌色看（**注：以下为第三方色彩档案整理值，非厂商官方规范文件**）：

- **哔哩哔哩**：`#FB7299` 粉 + `#00A1D6` 蓝（来源：colorarchive.org/brands/bilibili/，标注 unofficial reference）
- **小红书**：高饱和纯红系
- **抖音**：黑底 + 色差 cyan/magenta（chromatic aberration 是其标志性手法）

共同规律，三条：

1. **一个高饱和"品牌色"扛住全部识别，其余全中性。** 不是多色堆砌，是单点爆破。
2. **中性色偏暖偏亮，不用冷灰。** 中文界面文字密度高，冷灰 + 高密度汉字会显脏。
3. **深色模式普遍用带色相的深色而非纯黑**，因为国内 app 大量用彩色插画/头像，纯黑会让它们"浮"在上面像贴纸。

---

<a name="三两个硬约束"></a>
## 三、两个硬约束（选任何方案都绕不开）

### 约束 1：中文没有超粗字重，"大字"必须靠字号和色块

实测本机 `system_profiler SPFontsDataType`，PingFang SC 全部可用字重只有 6 档：

```
Ultralight / Thin / Light / Regular / Medium / Semibold
```

**没有 Bold、没有Heavy、没有 Black。** 而 SF Pro 有到 Black（900）。这意味着：

- 任何依赖"超粗字"的流派（Neo-brutalism、Y2K 大标题、Acid Graphics）在中文上都会**打对折**
- 补偿手段：① 加大字号（中文 32pt Semibold ≈ 英文 24pt Black 的视觉重量）② 用实色块反白 ③ 收紧字距 `tracking(-0.5)` ④ 数字和英文单独用 SF Pro Black，中文用 PingFang Semibold 混排
- 若要真正的超粗中文，需引入第三方字体（如思源黑体 Heavy / 阿里巴巴普惠体 Heavy），**需自行确认商用授权**，且会增加 3–8 MB 包体

下文每个方案的字体策略都已按这个约束写。

### 约束 2：深色模式背景必须给 Liquid Glass "东西可折射"

Apple 的 Clear 变体要求三条全满足才用：① 元素在媒体内容之上 ② 内容不受压暗层影响 ③ 玻璃之上的前景内容明亮粗壮。本 app 的内容区大部分时间是纯色 + 波形，**只能用 `.regular`**。

`.regular` 想有玻璃感，背后必须有色彩变化。所以下文每个深色方案都给了**背景层策略**（mesh blob / 渐变 / 噪点纸），这不是装饰，是让玻璃成立的前提。

同时必须遵守的三条（来自 Apple 官方 + 社区参考实现）：
- 不要 glass-on-glass 堆叠（内容层不上玻璃）
- tint 只给主操作，不要全局染色（「Tint conveys meaning, not decoration」）
- 文字对比度维持 ≥ 4.5:1，在玻璃上尤其要测

---

<a name="四六个完整视觉方案"></a>
## 四、六个完整视觉方案

### 方案 A｜极光电台 Aurora Radio

**定位**：一句话 —— 把 app 变成一块会呼吸的极光玻璃，声音是光。
**流派**：Aurora UI / Mesh Gradient + Liquid Glass 2.0
**参考真实 app**：Linear（玻璃与深色层级）、Arc Search（彩色 mesh + 玻璃）、Stripe 官网 hero（aurora 渐变）、Apple Music 26 的专辑色扩散

#### 配色

**深色模式**（主推形态）

| 角色 | HEX | 说明 |
|---|---|---|
| 背景基底 | `#0E1020` | 深靛蓝，**非纯黑**，OLED 上仍省电但有色相 |
| 背景 mesh blob ①紫 | `#3B1E6E` | blur 半径 140pt，opacity 0.55 |
| 背景 mesh blob ②青 | `#0B4F6C` | blur 140pt，opacity 0.45 |
| 背景 mesh blob ③品红 | `#6E1E4A` | blur 160pt，opacity 0.35 |
| 卡片面 | `#171A2E` | 内容窗口底 |
| 分隔线 | `#2A2F4D` | 1pt |
| 主色 Primary | `#7A5CFF` | 电光靛紫，按钮 tint |
| 强调 Accent | `#38E1B0` | 薄荷，表示「在听 / 活跃」 |
| 强调 Accent-2 | `#FF5FA2` | 品红，表示「在说」 |
| 成功 | `#38E1B0` | 与 Accent 同色 |
| 警告 | `#FFB020` | |
| 危险 | `#FF5C7A` | |
| 文字 一级 | `#F2F3FA` | |
| 文字 二级 | `#A4A8C4` | |
| 文字 三级 | `#6E7290` | 对 `#0E1020` 对比度约 4.6:1，刚过线 |

**浅色模式**

| 角色 | HEX |
|---|---|
| 背景基底 | `#F6F4FF` |
| mesh blob ①/②/③ | `#D9CCFF` / `#C7F0E4` / `#FFD9EC`（opacity 0.7，blur 140pt） |
| 卡片面 | `#FFFFFF` |
| 分隔线 | `#E4E0F5` |
| 主色 | `#5B3DF5` |
| 强调 | `#12B886` |
| 强调-2 | `#E8428F` |
| 文字 一/二/三级 | `#14152B` / `#5A5E7A` / `#8D91AA` |

#### 字体策略

- 显示层（bot 名、状态词）：SF Pro Display **Bold 34pt**，中文 PingFang SC Semibold 32pt，`tracking(-0.6)`
- 正文/字幕：SF Pro Text Regular 17pt / PingFang SC Regular 17pt，行高 1.55（中文需要比英文松）
- 标签/方块名：SF Pro **Rounded** Medium 12pt —— 只在小尺寸用圆体，避免整屏幼齿
- 数字（时长、计数）：SF Pro **Rounded** Semibold + `.monospacedDigit()`，防跳动
- 字阶比：34 / 22 / 17 / 13 / 11，最大最小比 3.1×

#### 材质策略

- **背景层**：3 个 mesh blob 在基底上做超大半径高斯模糊，以 20–40s 周期极缓慢漂移（`.animation(.linear(duration: 32).repeatForever())`）。这是玻璃的折射源。
- **玻璃层**：只给说话条、控制栏、当前 bot 方块。统一 `.regular`，不用 `.clear`。
- **tint 规则**：只有说话条按住时 tint `#38E1B0`，其余全部不 tint。
- **噪点**：全屏覆盖 6% 不透明度的细噪点（防止大面积渐变出现色带 banding，这是 mesh gradient 在 8-bit 屏上的真实问题）。
- **不用**：硬阴影、描边（靠明度差分层）

#### 关键控件

**「按住说话」大按钮**
- 形态：满宽胶囊，高 64pt（比现在 56 再大一号），圆角 32 continuous
- 静止：`.glassEffect(.regular.interactive())`，内部左侧一颗 `#38E1B0` 的 6pt 呼吸点（1.6s 周期 scale 1.0↔1.3）
- 按下：tint 转 `#38E1B0`，同时按钮**下方**溢出一圈 40pt 的同色光晕（blur 30，opacity 0.5→0），像声音扩散出去
- 文案："按住说话" → "松开结束"，用 `.contentTransition(.numericText())`

**底部控制栏**
- 与说话条同在一个 `GlassEffectContainer`（现有代码已经这么做了，保留）
- 高 56pt，未选中按钮无底，选中项一颗 `#7A5CFF` 实心胶囊
- 按钮图标 SF Symbols，`.symbolRenderingMode(.hierarchical)`

**顶部 bot 头像方块**
- 尺寸 60×60（现在 54，放大一点让它成为主角），圆角 20 continuous
- 当前项：玻璃 + 底部 3pt 的 `#7A5CFF` 下划条（比现在的整圈描边干净）
- 说话中：方块本体不描边，改为**外发光** —— `shadow(color: #FF5FA2.opacity(0.6), radius: 14)`
- 静音：右上角一个 `#FF5C7A` 实心小圆 + 斜杠话筒图标，不改方块本体
- 未连接：方块 opacity 0.4，无描边（去掉现有的虚线圈 —— 虚线在 iOS 语义里是占位符，用在这里会显得界面没做完）

**内容卡片**
- `#171A2E` 实色 + 1pt `#2A2F4D` 描边，圆角 28
- **不上玻璃**（遵守 Apple 的内容层规则）
- 卡片本身半透明 92%，让背后的 mesh 微微透出来 —— 这是这套方案的关键细节

#### 动效

- 位移/切换：`spring(response: 0.34, dampingFraction: 0.78)`（比现在的 0.82 稍弹一点）
- 颜色/透明度：`easeOut(0.2)`，不回弹
- 按压：`easeOut(0.1)`
- 背景 mesh：`linear(32s).repeatForever(autoreverses: true)`
- **签名动效**：切 bot 时，背景 mesh 的主色相跟着当前 bot 的主题色旋转 30°，1.2s 缓动。切换不只是内容换了，整个环境的光也变了。

#### 音频可视化

见[第五节方案 A 段](#a-极光环)。核心是**径向声波环**，不是柱状图。

#### 诚实评估

**适合**：
- 与 iOS 26 系统语言最贴，风险最低，Apple 审核和系统更新都不会打架
- 给 Liquid Glass 提供了折射源，一举解决"玻璃看不出来"的根本问题
- 长时间使用不易疲劳（深色基底 + 低饱和大面积 + 高饱和小面积）
- 现有代码改动量最小 —— 色板换掉、加一个背景层，控件结构基本不动

**不适合 / 缺点**：
- **最容易"撞脸"**。Linear、Arc、Vercel、无数 AI 产品都是这一套，00 后看多了会觉得"又一个 AI 工具"，缺乏记忆点。它解决了"low"，但不一定解决"没个性"。
- mesh gradient 在 8-bit 屏上会出色带，必须加噪点，而噪点层是全屏覆盖的，对低端机（iPhone 11/12）有真实的合成开销
- 三个大半径 blur blob 常驻动画，实测这类实现在长时间会话（30min+）下会明显发热，建议接 `ProMotion` 时降到 30fps 或在低电量模式下静止
- 浅色模式下 mesh 很容易变成"糊掉的马卡龙"，必须把 blob 不透明度压到 0.5 以下，否则文字对比度过不了



### 方案 B｜大字报 Loud Type

**定位**：一句话 —— 它不装成一个"AI 产品"，它像一台有脾气的机器。
**流派**：Neo-brutalism（新野兽派 / anti-design）+ 大字排版
**参考真实 app**：Gumroad（黑白 + Lavender Rose + 粗边 + 硬阴影，uxpilot 点名的执行最完整案例）、Poolsuite FM、Gas、Cash App 的 Boost 界面

#### 配色

**浅色模式**（主推形态 —— 野兽派天生是亮底）

| 角色 | HEX | 说明 |
|---|---|---|
| 背景 | `#F5F1E8` | 米白纸，**不是纯白**，纯白会让粗黑边显得刺眼 |
| 卡片面 | `#FFFFFF` | |
| 边框 | `#111111` | 统一 2.5pt，所有元素 |
| 硬阴影 | `#111111` | offset (4, 4)，**无模糊** |
| 主色 Primary | `#2B44FF` | 电光蓝 |
| 强调 Accent | `#E8FF47` | 荧光黄，只用于「在说话」 |
| 强调 Accent-2 | `#FF4D2E` | 番茄红，只用于「静音 / 危险」 |
| 强调 Accent-3 | `#00D9A3` | 薄荷，只用于「在听」 |
| 文字 一级 | `#111111` | |
| 文字 二级 | `#555049` | |

**深色模式**

| 角色 | HEX | 说明 |
|---|---|---|
| 背景 | `#17171A` | 炭黑，**非纯黑** |
| 卡片面 | `#232328` | |
| 边框 | `#F5F1E8` | 2pt 米白 |
| 硬阴影 | `#5C6CFF` | **彩色阴影** —— 深色下黑阴影不可见，必须换色，这是野兽派做深色模式的标准解法 |
| 主色 | `#5C6CFF` | |
| 强调 | `#E8FF47` / `#FF6A4D` / `#2FE8B6` | |
| 文字 一/二级 | `#F5F1E8` / `#A5A099` |

#### 字体策略

- 显示层：SF Pro Display **Black 40pt**，`textCase(.uppercase)`（英文），`tracking(-1.2)`
- **中文补偿**：PingFang SC Semibold 36pt + 反白色块（文字放在实色矩形上）。这是绕开中文无 Black 字重的唯一免费方案。
- 状态标签：SF Mono / SF Pro **Monospaced** Semibold 13pt，`uppercase`，`tracking(1.5)` —— 等宽字是野兽派的标配（tubikstudio Trend 3 "Raw Aesthetics: Monospaced Fonts, Grids, Wireframes"）
- 正文：PingFang SC Regular 16pt
- **不用** SF Rounded（圆体和野兽派冲突）
- 字阶比：40 / 24 / 16 / 13 / 11，最大最小 3.6×

#### 材质策略

- **完全不用 Liquid Glass**。这是本方案的取舍：野兽派靠硬边界和实色块建立层级，玻璃的模糊会把边界糊掉，两者是对立的。
  - 折中版：只有底部控制栏用 `.glassEffect(.regular)` 换取系统一致性，其余全实色。但纯粹度会下降。
- **不用渐变**（最多允许双色 50/50 硬分割）
- **噪点**：可选，纸张质感 8%
- 所有圆角统一 **8pt**（不是 0 —— 全直角在 iOS 上会跟系统控件打架，8pt 是"硬但不生硬"的甜点）

#### 关键控件

**「按住说话」大按钮**
- 形态：满宽矩形，高 72pt（这套风格里它必须是绝对主角），圆角 8
- 静止：`#FFFFFF` 底 + 2.5pt `#111111` 边 + (4,4) 硬阴影，中间 `按住说话` Semibold 26pt
- 按下：**阴影消失，按钮整体位移 (4,4)** —— 物理上"按进去"了，这是野兽派最经典的按压反馈，比 scale 有说服力得多
- 按住中：底色转 `#E8FF47`，文字转 `#111111`，左侧一个 `#111111` 实心方块以 `steps` 曲线闪烁（不是渐变淡入淡出，**硬切**）
- 可选 kinetic：按下瞬间文字做一次 2pt 的随机抖动（参考 Bump 的 buzz 按钮）

**底部控制栏**
- 高 60pt，白底 + 2.5pt 黑边 + 硬阴影
- 每个按钮之间用 2.5pt 黑色竖线**硬分割**（不是间距）
- 选中项：整格填充 `#2B44FF`，图标反白

**顶部 bot 头像方块**
- 尺寸 64×64，圆角 8，2.5pt 黑边
- 当前项：底色 `#2B44FF`，硬阴影 (4,4)；非当前项：白底，无阴影，且**整体下移 4pt**（位置差本身就是选中态）
- 说话中：底色 `#E8FF47`
- 静音：底色 `#FF4D2E`，画一条 2.5pt 黑色对角线穿过整个方块
- 未连接：`#F5F1E8` 底 + 黑边，整块 opacity 0.5
- 名字标签：等宽大写，直接压在方块下沿

**内容卡片**
- 白底 + 2.5pt 黑边 + (6,6) 硬阴影，圆角 8
- 字幕气泡：agent 的用 `#2B44FF` 反白，用户的用白底黑边

#### 动效

- 位移：`spring(response: 0.25, dampingFraction: 0.65)` —— 更快更弹
- 状态切换：**`linear(0.08)` 或直接无动画**。野兽派的动效哲学是"硬切"，渐变淡入会破坏性格。
- 按压：位移 (4,4)，`easeOut(0.06)`
- **签名动效**：切 bot 时，整个内容卡片以 `.move(edge:)` 硬滑出/滑入，**不带淡入淡出**，像翻牌子

#### 音频可视化

见[第五节方案 B 段](#b-硬边-eq)。核心是粗黑竖条 EQ，最小高度 30% 满高，**绝不退化成圆点**。

#### 诚实评估

**适合**：
- **记忆点最强**。这是六个方案里唯一能让人截图发群里的。00 后审美的核心诉求之一就是"不像大厂做的"。
- 对比度天生极高，可访问性最好（黑边 + 实色，WCAG AAA 轻松达标）
- 性能最好 —— 无模糊、无渐变、无常驻动画，低端机和长会话完全无压力
- 静止态永远不会"像坏了"（实色块本身就是活的）

**不适合 / 缺点**：
- **长时间使用会疲劳**，这是硬伤。高对比 + 荧光黄在 30 分钟以上的连续使用后眼睛会累。语音助理如果是高频长时使用场景，这点要认真权衡。
- **和 iOS 26 系统语言完全对立**。系统弹窗、分享面板、键盘一出来就是 Liquid Glass，和你的硬边界面拼在一起会显得割裂。这是个真实的、无法完全消除的问题。
- 中文表现打折最严重 —— 没有 Black 字重，"大字报"的冲击力至少损失 30%，必须靠色块补偿，而色块多了又会显乱
- 深色模式是这个流派的先天短板。彩色阴影是权宜之计，效果明显不如浅色模式。如果用户主要在夜间使用，这个方案要打问号。
- 受众分化剧烈：喜欢的人非常喜欢，不喜欢的人会觉得"这是不是没做完"



### 方案 C｜软糖 Jelly

**定位**：一句话 —— 每个 bot 是一颗有体温的糖，按住说话像捏一下它。
**流派**：Claymorphism（粘土拟物）+ Soft Pastel + Light Skeuomorphism
**参考真实 app**：Locket Widget（暖色 + 圆润 + 极简）、Airbuds、Duolingo（粘土插画 + 弹性动效）、Bump by amo（手作质感）、Headspace

#### 配色

**浅色模式**（主推形态）

| 角色 | HEX | 说明 |
|---|---|---|
| 背景 | `#FFF6F0` | 奶油白，带暖橘底 |
| 背景渐变辅 | `#FFEDE4` → `#FFF9F4` | 极轻的垂直渐变 |
| 卡片面 | `#FFFFFF` | |
| 粘土外阴影 | `rgba(255,138,107,0.20)` | offset (0,10)，blur 24 |
| 粘土内高光 | `rgba(255,255,255,0.95)` | inset (0,-6)，blur 12 |
| 主色 Primary | `#FF8A6B` | 桃橙 |
| 强调 薄荷 | `#7DE0C2` | 「在听」 |
| 强调 天蓝 | `#8FC2FF` | 「在想」 |
| 强调 奶黄 | `#FFD67E` | 「在说」 |
| 危险 | `#FF6B8A` | 静音（用粉红不用正红，保持温度） |
| 文字 一级 | `#3D2B26` | 暖棕黑，**不用纯黑** |
| 文字 二级 | `#8A736B` | |
| 文字 三级 | `#B8A59D` | |

**深色模式**

| 角色 | HEX | 说明 |
|---|---|---|
| 背景 | `#221A20` | 暖棕黑，**非纯黑**，保留"糖果在夜里"的温度 |
| 卡片面 | `#302630` | |
| 粘土外阴影 | `rgba(0,0,0,0.45)` | offset (0,10) blur 20 |
| 粘土内高光 | `rgba(255,255,255,0.10)` | inset (0,-6) blur 12 |
| 主色 | `#FF9E82` | 深色下要提亮 |
| 强调 | `#6FD8BC` / `#7FB6F5` / `#F5C96A` | |
| 危险 | `#FF7E98` | |
| 文字 一/二/三级 | `#FAEFE9` / `#C4ADA4` / `#8A736B` |

#### 字体策略

- **全局 SF Rounded** —— 这是六个方案里唯一全局用圆体的，因为粘土和圆体是同一种语言
- 显示层：SF Pro **Rounded Bold 30pt**；中文 PingFang SC Semibold 28pt（PingFang 本身字形偏圆，和 SF Rounded 混排不违和，这是它的优势）
- 正文：SF Rounded Regular 17pt / PingFang SC Regular 17pt
- 数字：SF Rounded **Bold** + `monospacedDigit`
- 标签：SF Rounded Medium 13pt
- 字阶比：30 / 20 / 17 / 13 / 11，最大最小 2.7×（这个方案不追求强对比，靠形状建立层级）

#### 材质策略

- **Liquid Glass 用量：极少**。只有底部控制栏用 `.regular`，因为粘土的"实心柔软"和玻璃的"通透"是两种材质，混用会脏。
  - 但可以用玻璃做**模态层**（房间列表 sheet），这符合 Apple 的"玻璃属于导航层"规则。
- **核心材质是双层阴影**：外投影（营造漂浮）+ 内高光（营造充气感）。这是 claymorphism 的技术定义。
- 圆角极大：卡片 32pt，按钮 28pt，方块 22pt，全部 continuous
- **渐变**：只在粘土体表面用极轻的 8% 明度渐变（模拟顶光），不用彩色渐变
- **不用噪点** —— 粘土要"干净的塑料感"，噪点会变成"脏橡皮"

#### 关键控件

**「按住说话」大按钮**
- 形态：满宽超圆角矩形，高 68pt，圆角 30
- 静止：`#FFFFFF` 底 + 双层粘土阴影，中间图标 + 文字，图标用 `#FF8A6B`
- 按下：**按钮 Y 轴压扁到 0.94、X 轴撑到 1.02（挤压回弹）**，外阴影缩短到 (0,4) blur 10。这是全套方案里手感最好的按压反馈。
- 按住中：底色渐变到 `#FFD67E`，同时按钮**表面出现一道从左到右移动的白色高光带**（`Shimmering` modifier，代码里已经有现成实现）
- 松手：`spring(response: 0.3, dampingFraction: 0.55)` 明显回弹一下

**底部控制栏**
- 高 58pt，圆角 28，玻璃 `.regular`（唯一用玻璃的地方）
- 选中项：`#FF8A6B` 实心圆 + 微粘土阴影
- 图标：SF Symbols，`.fill` 变体（实心图标和粘土更搭）

**顶部 bot 头像方块**
- **不是方块，是圆角 22 的"糖块"**，尺寸 62×62
- 每个 bot 分配一个固定的粘土色（从 `#FF8A6B` / `#7DE0C2` / `#8FC2FF` / `#FFD67E` / `#C9A5FF` / `#FF9EC4` 六色轮转）—— **这是本方案最大的产品价值：多 bot 场景下颜色即身份，不用读名字就能认出来**
- 当前项：scale 1.12 + 完整粘土阴影
- 非当前项：scale 1.0 + 阴影减半 + 饱和度降到 60%
- 说话中：糖块做 1.0↔1.06 的呼吸脉动（不是描边）
- 静音：糖块上盖一层 45% 白色磨砂 + 一个 `#FF6B8A` 小圆角标
- 未连接：完全去饱和变成 `#E8DDD6` 灰粘土（形状还在，颜色没了 —— 语义很直观）

**内容卡片**
- 白底 + 32 圆角 + 双层粘土阴影，边距比其他方案大（左右 20pt）
- 字幕气泡：agent 用当前 bot 的粘土色 12% 填充 + 该色 Semibold 文字；用户用白底

#### 动效

- 位移/切换：`spring(response: 0.36, dampingFraction: 0.62)` —— 明显回弹，这是"软"的来源
- 挤压：`interpolatingSpring(stiffness: 220, damping: 14)`
- 颜色：`easeInOut(0.25)`（比其他方案慢，柔）
- **签名动效**：切 bot 时，新 bot 的糖块先弹大一下（1.0→1.18→1.12），同时内容卡片的强调色做一次色相过渡。整个切换像"换了一颗糖"。

#### 音频可视化

见[第五节方案 C 段](#c-果冻球)。核心是**一颗会挤压的果冻球**，不是柱状图。

#### 诚实评估

**适合**：
- **最不容易疲劳**。暖色低饱和 + 圆形，长时间使用最舒适，适合日常高频语音助理。
- 情感温度最高。语音助理本质上是"跟一个东西说话"，粘土给了它实体感和亲和力，这在产品语义上是对的。
- 多 bot 色彩身份系统是六个方案里最实用的一条 —— 直接解决"6 个灰方块分不清谁是谁"
- 10 后（小学–初中）接受度最高
- 性能开销中等：阴影是 CPU 便宜的，无常驻模糊动画

**不适合 / 缺点**：
- **偏幼**。这是最大的风险。18–25 岁的大学生/职场新人可能觉得"这是给小孩用的"，而用户说的"00后/10后"横跨了这两个群体。如果主力用户是 00 后大学生，这套会掉分。
- Claymorphism 已经是 2021–2022 的流行峰值，2026 年它是"回潮期"而不是"上升期"。gezar.dk 把它列在 2026 趋势里，但它的热度曲线明显不如 Aurora 和 Neobrutalism。**选它是在赌复古，不是在追新。**
- 双层阴影的可访问性问题（neumorphism 的老毛病）：阴影建立的层级在高对比度模式下会消失，必须为 `accessibilityIncreaseContrast` 单独准备一套描边 fallback
- 深色模式明显弱于浅色。粘土的核心是"内高光"，在暗底上内高光几乎看不见，只剩下投影，质感损失一半。
- 全局 SF Rounded 在信息密集的字幕区会降低阅读效率（圆体的字怀更饱满，同字号下实际可读密度低于 SF Pro Text）



### 方案 D｜千禧回声 Y2K Echo

**定位**：一句话 —— 一台 2003 年想象中的 2026 年语音机器。
**流派**：Y2K Revival / Frutiger Aero / Retrofuturism
**参考真实 app**：Poolsuite FM、Bump by amo（拼贴 + 手作贴纸）、PostHog 官网（Win95 桌面隐喻）、早期 Windows Media Player 可视化、iTunes Visualizer

#### 配色

**深色模式**（主推 —— Frutiger Aero 的深水形态）

| 角色 | HEX | 说明 |
|---|---|---|
| 背景基底 | `#061428` | 深海蓝，**非纯黑** |
| 背景渐变 上 | `#0A2647` | |
| 背景渐变 下 | `#041020` | |
| 水光 blob ①青 | `#00D4FF` | opacity 0.22，blur 120 |
| 水光 blob ②紫 | `#7B2FF7` | opacity 0.18，blur 140 |
| 卡片面 | `rgba(10,38,71,0.72)` | 半透明，让水光透出 |
| Chrome 描边 | 线性渐变 `#FFFFFF` → `#8AB4FF` → `#5A7BB5` → `#FFFFFF` | 1.5pt，45° |
| 主色 Primary | `#00E5FF` | 电光青 |
| 强调 Accent | `#FF2E93` | 千禧粉 |
| 强调 Accent-2 | `#B6FF3C` | 酸绿 |
| 危险 | `#FF4D6D` | |
| 文字 一级 | `#EAF6FF` | |
| 文字 二级 | `#8FB4D9` | |
| 文字 三级 | `#5C7FA3` | |

**浅色模式**（Frutiger Aero 的天空形态 —— 这套的浅色其实更正宗）

| 角色 | HEX |
|---|---|
| 背景基底 | `#E8F6FF` |
| 背景渐变 | `#CFEBFF` → `#F5FCFF` |
| 水光 blob | `#A8E6FF`(0.6) / `#C9B8FF`(0.5) / `#FFC2E2`(0.4) |
| 卡片面 | `rgba(255,255,255,0.78)` |
| Chrome 描边 | `#FFFFFF` → `#9FC4E8` → `#6E92BD` → `#FFFFFF` |
| 主色 | `#0091FF` |
| 强调 | `#FF3D9A` / `#7BD400` |
| 文字 一/二/三级 | `#0A2540` / `#3D6685` / `#7095B3` |

#### 字体策略

- 显示层：SF Pro Display **Heavy 32pt** + 轻微 3D 处理（1pt 白色上偏移 + 1pt 主色下偏移，模拟当年的斜面浮雕）；中文 PingFang SC Semibold 30pt 同处理
- **状态文字全等宽大写**：SF Mono Medium 12pt，`tracking(2.0)` —— 这是 Y2K 的灵魂（`NOW LISTENING` / `PROCESSING...`）
- 正文：SF Pro Text Regular 16pt / PingFang SC Regular 16pt
- 数字：SF Mono，七段数码管感
- **可选加料**：bot 名用像素字体（如 Silkscreen / 04b03），但中文没有免费可商用的像素字体，中文只能退回 PingFang，会造成中英混排不一致。**建议只对英文/数字用像素字。**
- 字阶比：32 / 20 / 16 / 12 / 10

#### 材质策略

- **Liquid Glass `.regular` 重度使用** —— Y2K/Aero 的水玻璃美学和 Liquid Glass 是天然亲缘（Apple 自己就说 Liquid Glass 是对 Aqua 的致敬，Aqua 正是 2001 年的设计）。**这是六个方案里 Liquid Glass 最名正言顺的一个。**
- **Chrome 描边**：所有主要元素加 1.5pt 的四色线性渐变描边，模拟金属高光。这是把"玻璃"变成"2003 年的玻璃"的关键一笔。
- **背景**：深蓝渐变 + 2–3 个缓慢漂浮的水光 blob + 可选的极轻水波纹 shader
- **噪点**：不用。Y2K 要"干净的数字感"，噪点属于 Riso/胶片系。
- **可选加料**：极轻的 scanline（2px 间隔、3% 不透明度水平线）—— 谨慎，容易显廉价，建议只在启动页用
- 圆角：14pt（Y2K 的圆角比现代小，大圆角是 2015 之后的事）

#### 关键控件

**「按住说话」大按钮**
- 形态：满宽胶囊，高 66pt，圆角 33
- 静止：`.glassEffect(.regular.interactive())` + Chrome 渐变描边 + 内部顶部一道 40% 白色高光条（占按钮上半部，模拟 Aqua 按钮的塑料反光）
- 按下：tint `#00E5FF`，高光条下移，整体亮度 +15%
- 按住中：**从按钮向外扩散同心圆水波纹**（2 圈，1.2s 周期，`#00E5FF` 描边 opacity 0.5→0）。声音 = 水波，这个隐喻在 Aero 体系里最自洽。
- 文案等宽大写 + 中文：`按住说话 / HOLD TO TALK` 双行

**底部控制栏**
- 高 56pt，玻璃 + Chrome 描边，圆角 28
- 选中项：`#00E5FF` 实心胶囊 + 内高光
- 图标：SF Symbols `.fill`，加 1pt 同色外发光

**顶部 bot 头像方块**
- 尺寸 60×60，圆角 14，玻璃 + Chrome 描边
- 每个 bot 一个"液体颜色"（青/粉/绿/橙/紫/黄），以 40% 不透明度做方块内部的渐变填充
- 当前项：Chrome 描边加粗到 2pt + 底部一颗 `#00E5FF` 的发光点
- 说话中：方块内部的液体颜色**上下涌动**（一个被 audio level 驱动的水位线）—— 这是本方案最有辨识度的细节
- 静音：液体降到底部 + 灰化
- 未连接：方块变成空玻璃（无液体）

**内容卡片**
- 半透明 72% + Chrome 描边 + 圆角 20
- 卡片顶部一条 3pt 的 `#00E5FF`→`#FF2E93` 渐变条（像当年的窗口标题栏）
- 字幕气泡：agent 用青色玻璃，用户用粉色玻璃

#### 动效

- 位移：`spring(response: 0.3, dampingFraction: 0.75)`
- **水波纹**：`easeOut(1.2)`，scale 1.0→1.8 + opacity 1→0
- 液面涌动：`spring(response: 0.5, dampingFraction: 0.6)`，被音量驱动
- 颜色：`easeInOut(0.22)`
- **签名动效**：切 bot 时，两个方块之间画一条 1pt 的 Chrome 光线快速扫过（0.3s），像数据在传输

#### 音频可视化

见[第五节方案 D 段](#d-水波纹)。核心是**同心圆水波纹 + 液面**。

#### 诚实评估

**适合**：
- **和 Liquid Glass 的契合度最高**。Apple 自己承认 Liquid Glass 致敬 Aqua，这套方案等于顺着 Apple 的设计意图往前推了一步，几乎不会有"系统语言打架"的问题。
- 记忆点强且不冒犯 —— 比野兽派温和，比极光有个性
- 00 后对 Y2K 的接受度经过验证（uxpilot 明确指出这波是 Gen Z 主导的，他们在怀念一个没经历过的年代）
- 水/液体隐喻和"声音"天然匹配，可视化设计空间最大

**不适合 / 缺点**：
- **最容易做 low**。Y2K 和"土"之间只隔一层纸：Chrome 描边稍重就是山寨软件，scanline 稍明显就是廉价特效，像素字用在中文上直接崩。**这套方案对执行精度的要求是六个里最高的**，交给不熟悉这个流派的人做，出来的东西会比现在还难看。
- 有时效性。Y2K 复古已经流行了 3–4 年（2022 起），2026–2027 大概率开始退潮。如果这个 app 的视觉要用 3 年以上，这是个减分项。
- 半透明卡片 + Chrome 描边 + 玻璃 + 水波纹，图层数量在六个方案里最多，**性能开销最大**。iPhone 11/12 上要认真测帧率。
- 浅色模式（天空 Aero）和深色模式（深水 Aero）气质差异大，几乎是两套设计，维护成本翻倍
- 文字对比度是隐患：`#8FB4D9` 在半透明玻璃卡片上叠深蓝背景，实际对比度会低于计算值，必须实测



### 方案 E｜便当电台 Bento Desk

**定位**：一句话 —— 一本会说话的杂志，每个 bot 是一个栏目。
**流派**：Bento Grid + Risograph 质感 + Editorial（编辑部排版）
**参考真实 app**：Apple 产品页的 bento 区块、Rise（有机布局 + 数据）、Arc Browser 的 Spaces、Readwise Reader、Things 3（排版克制但有性格）

#### 配色

**浅色模式**（主推 —— Riso 印刷天生是纸底）

| 角色 | HEX | 说明 |
|---|---|---|
| 背景 | `#EFECE4` | Riso 纸，暖灰米 |
| 卡片面 | `#FAF8F3` | 比背景亮一档，不用纯白 |
| 卡片面-强调 | `#2547D0` | 主色块卡片 |
| 分隔线 | `#D9D4C7` | 1pt |
| 主色 Riso Blue | `#2547D0` | |
| 强调 Riso Fluo Pink | `#FF48A0` | Risograph 荧光粉，这是 Riso 的标志色 |
| 强调 Riso Yellow | `#FFC20E` | |
| 强调 Riso Green | `#00A95C` | |
| 危险 | `#E4322B` | Riso 红 |
| 文字 一级 | `#1A1917` | |
| 文字 二级 | `#5C574C` | |
| 文字 三级 | `#8C8578` | |

**深色模式**

| 角色 | HEX | 说明 |
|---|---|---|
| 背景 | `#1C1B18` | 墨黑偏暖，**非纯黑** |
| 卡片面 | `#26241F` | |
| 分隔线 | `#3A372F` | |
| 主色 | `#6E8BFF` | Riso Blue 提亮 |
| 强调 | `#FF6AB0` / `#FFD24A` / `#3FCE86` | |
| 危险 | `#FF5A52` | |
| 文字 一/二/三级 | `#F0EDE4` / `#B5AFA0` / `#7D7769` |

#### 字体策略

这个方案的字体是主角，规则最细。

- **显示层（栏目标题 / bot 名）**：SF Pro Display **Bold 28pt**，中文 PingFang SC Semibold 26pt，`tracking(-0.4)`
- **元信息（状态、时间、计数）**：SF Mono **Medium 11pt**，`uppercase`，`tracking(1.2)`，颜色 `#8C8578` —— 等宽是编辑部/数据感的来源（tubikstudio Trend 3 明确提到 "return to monospaced or mono-inspired type to align visual rhythm with data logic"）
- **正文/字幕**：SF Pro Text Regular **17pt**，行高 1.6；中文 PingFang SC Regular 17pt 行高 1.7
- **引导语/大标语**：可选 New York（iOS 系统衬线）Semibold —— 衬线体在编辑风里是"权威"的信号，但**中文没有对应的系统衬线体（宋体在 iOS 上只有 Songti SC，字形偏旧）**，中英混排会不一致。建议只在纯英文/数字处使用。
- 字阶比：28 / 20 / 17 / 13 / 11
- **规则**：同一屏最多出现 3 种字号 + 2 种字重

#### 材质策略

- **Liquid Glass：只给底部两条（说话条 + 控制栏）**，`.regular`，无 tint（除按住时）。内容区全实色卡片。这是最保守也最符合 Apple 指引的用法。
- **Riso 噪点是核心材质**：全屏覆盖 10–14% 不透明度的粗颗粒噪点（比其他方案的 6% 重一倍）。Riso 的质感来自油墨不匀，噪点必须看得见。
- **套印错位**：强调元素（波形、图标）用双色叠印 —— 蓝色层 + 粉色层偏移 1.5pt，模拟 Riso 的套印不准。**这是整套方案最有辨识度的一笔，成本极低（一个 offset），效果极强。**
- **不用渐变**（Riso 印不出渐变，只能印网点）
- 圆角：卡片 16pt，小元素 10pt（编辑风偏方，不要大圆角）

#### 关键控件

**「按住说话」大按钮**
- 形态：满宽，高 62pt，圆角 16
- 静止：`.glassEffect(.regular.interactive())`，左侧一个 `#2547D0` 实心方块内放话筒图标，右侧文字左对齐（**不居中** —— 编辑风讲究左对齐基线）
- 按住中：整条 tint `#2547D0`，文字反白；左侧方块变成一个跳动的双色错位波形
- 元信息行：按钮下方一行 SF Mono 10pt 的 `HOLD · 00:12` —— 但注意：**这是直播房间不是录音，不能显示"录音时长"**（现有代码注释已明确指出这点）。改成显示 `LIVE` 或连接延迟更合适。
- 按下：`brightness(-0.04)` + scale 0.99，极克制

**底部控制栏**
- 高 54pt，玻璃，圆角 16
- 选中项：一个 `#2547D0` 的圆角方块（不是胶囊）
- 图标下方带 9pt SF Mono 小标签（`MIC` / `CAM` / `CC`）—— 编辑风允许更多文字

**顶部 bot 头像方块**
- **改成横向 bento 条**：每个 bot 是一个 76×56 的横向卡片，不是正方形
- 卡片内左侧一个 24×24 的色块（bot 身份色），右侧上行是名字（12pt Semibold），下行是 SF Mono 9pt 的状态（`LIVE` / `MUTED` / `IDLE` / `CONN…`）
- **信息量是六个方案里最大的** —— 不用猜颜色的含义，直接写字
- 当前项：卡片底色 `#2547D0`，全部文字反白
- 说话中：色块位置换成双色错位的迷你波形
- 静音：状态字变 `MUTED`，色块加一条红斜线
- 未连接：整卡 opacity 0.45，状态字 `OFFLINE`

**内容卡片**
- Bento 布局：字幕区是主格（占 70%），右下角一个小格显示当前 bot 的元信息（延迟 / 时长 / 模型名）
- 卡片 `#FAF8F3` + 1pt `#D9D4C7` 描边 + 圆角 16，**无阴影**
- 字幕：agent 的话左对齐，前面一个 `#2547D0` 的 3pt 竖线（引文样式）；用户的话缩进 + 灰字。**不用气泡** —— 编辑风用排版建立层级，不用容器。

#### 动效

- 位移：`spring(response: 0.3, dampingFraction: 0.9)` —— 几乎不回弹，克制
- 状态切换：`easeInOut(0.2)`
- **有意的延迟**：tubikstudio Trend 2 指出，关键操作的即时确认反而降低信任感（「Perceived reliability beats actual speed」）。本方案在"切 bot"时故意加一个 120ms 的 `CONNECTING…` 等宽字状态，比瞬间切换更可信。
- **签名动效**：切 bot 时，bento 格子做交叉淡入 + 8pt 上移，像翻页；同时套印错位的偏移量从 4pt 收回到 1.5pt（像油墨对齐了）

#### 音频可视化

见[第五节方案 E 段](#e-套印波形)。核心是**双色套印错位波形 + 磁带计数器扫描线**。

#### 诚实评估

**适合**：
- **信息密度最高，最不容易误操作**。多 bot 场景下"谁在线、谁静音、谁在说"一眼看全，这是现有 6 个灰方块最大的痛点。
- **最耐看**。低饱和 + 纸质 + 克制排版，是六个方案里唯一能用 3 年不腻的。
- 中文表现最好 —— 编辑风本来就不依赖超粗字重，PingFang Semibold 完全够用，这是唯一不受约束 1 影响的方案。
- Riso 套印错位的性价比极高：一个 offset + 一层噪点，就有了别人抄不像的质感
- 性能好：无模糊、无渐变、噪点是静态贴图

**不适合 / 缺点**：
- **"年轻感"最弱**。这是最大的问题，和用户诉求正面冲突。Riso/编辑风的核心受众是设计师、内容创作者、文艺青年，不是泛 00/10 后。10 后大概率觉得"像看课本"。
- 它解决"low"非常有效，但解决"缺乏艺术感"的方式是"高级"而不是"炫"，如果用户想要的是后者，这套会失望
- 粗噪点在小屏 + 小字号下会降低可读性，13pt 以下的文字要避开噪点区域或降低噪点
- Bento 布局在竖屏手机上的格子数受限，超过 4 格就会挤，扩展性不如全屏卡片
- 大量 SF Mono 英文标签（`LIVE` / `MUTED`）对英文不好的低龄用户不友好，需要考虑中文化，但中文没有等宽字，中文化后"数据感"会掉



### 方案 F｜液态铬 Liquid Chrome

**定位**：一句话 —— 声音是一团会分裂重组的液态金属。
**流派**：Acid Graphics（酸性设计）+ Chrome / Liquid Metal + 轻 Vaporwave
**参考真实 app**：Apple Vision Pro 的宣传视觉、Spotify 的 Wrapped 年度报告（近年大量酸性/铬元素）、抖音的色差处理、Blackbird/Nothing OS 的实验性界面、音乐节海报类视觉

#### 配色

**深色模式**（主推，且这套基本只有深色是对的）

| 角色 | HEX | 说明 |
|---|---|---|
| 背景基底 | `#0C0C12` | 带蓝的近黑，**非纯黑**（纯黑会让铬的反射断掉） |
| 背景辉光 | `#1A1630` | 中心径向，半径占屏宽 1.4× |
| 卡片面 | `#15151D` | |
| 分隔线 | `#2A2A38` | |
| **Chrome 渐变**（核心材质） | `#F2F5FA` → `#C9D3E8` → `#6B7A99` → `#EDF1F7` → `#4A5570` | 角度渐变 135°，5 段 |
| 主色 Acid Green | `#B4FF2E` | 酸绿，唯一的"活"色 |
| 强调 Electric Purple | `#8A2BFF` | |
| 强调 Hot Orange | `#FF6A00` | |
| 危险 | `#FF2D55` | |
| 文字 一级 | `#F4F6FB` | |
| 文字 二级 | `#9BA3B8` | |
| 文字 三级 | `#646B80` | |

**浅色模式**（诚实说：这套的浅色是妥协产物）

| 角色 | HEX |
|---|---|
| 背景 | `#E6E9F0` |
| 卡片面 | `#F4F6FA` |
| Chrome 渐变 | `#FFFFFF` → `#D5DCE8` → `#8A94AA` → `#FBFCFE` → `#6B7489` |
| 主色（必须压深，酸绿在白底上不可读） | `#4FA800` |
| 强调 | `#6D1FE0` / `#E85C00` |
| 文字 一/二/三级 | `#14161C` / `#4A5060` / `#787F92` |

#### 字体策略

- 显示层：SF Pro Display **Black 36pt**，`tracking(-1.5)`，**拉伸变形**（`scaleEffect(x: 1.12, y: 0.92)`，酸性设计的标志手法）
- 中文：PingFang SC Semibold 34pt + 同样拉伸 + **Chrome 渐变填充文字**（用 `.foregroundStyle(LinearGradient)`）—— 渐变填充可以部分弥补中文没有 Black 字重的重量损失，这是本方案对约束 1 最有效的补偿
- 标签：SF Mono Bold 11pt，`uppercase`，`tracking(2.5)`
- 正文：SF Pro Text Regular 16pt（正文不做任何特效，保证可读）
- 字阶比：36 / 22 / 16 / 11，最大最小 3.3×

#### 材质策略

- **Chrome 是唯一主材质**。所有主要元素表面用 5 段角度渐变 + 一道 `.blendMode(.overlay)` 的白色高光扫过。
- **Liquid Glass 用量：中等**。`.clear` 变体在这里可以用 —— 因为背景是有辉光和铬反射的"媒体内容"，满足 Apple 对 Clear 变体的三条要求之一。但仍需在玻璃下加一层 20% 压暗。
- **Metaball / 液态融合**：多个圆形元素靠近时融合成一团（`GlassEffectContainer` + `glassEffectUnion` 可以近似实现，代码参考已确认 iOS 26 提供这两个 API）—— 这是本方案的技术亮点
- **色差（chromatic aberration）**：主要元素边缘做 RGB 通道 1pt 偏移（红右移、蓝左移）。抖音用的就是这个。
- **噪点**：4%，很轻，只为了压住铬渐变的色带
- 圆角：极端二分 —— 要么 0（硬切几何），要么完全圆（胶囊/正圆），**不要中间值**

#### 关键控件

**「按住说话」大按钮**
- 形态：满宽胶囊，高 70pt
- 静止：Chrome 渐变填充 + 1pt 深色内描边 + 一道每 4s 从左扫到右的白色高光带
- 文字：`按住说话` Chrome 渐变填充（文字本身也是金属），或反相为 `#0C0C12`
- 按下：整条**液化** —— 边缘做一次 wobble 形变（用 `.distortionEffect` 或简化为 scale x1.03/y0.94 + 圆角变化），同时 Chrome 渐变的角度旋转 45°（像金属被光扫过）
- 按住中：渐变中混入 `#B4FF2E` 的 35%，胶囊两端各长出一颗液滴（metaball 效果），液滴大小被音量驱动
- 松手：液滴被"吸回"主体

**底部控制栏**
- 高 58pt，`.glassEffect(.clear)` + 20% 压暗底 + Chrome 描边
- 选中项：一颗 `#B4FF2E` 实心正圆，带同色 12pt 外发光
- 图标：SF Symbols，Chrome 渐变填充

**顶部 bot 头像方块**
- **正圆，直径 58pt**（不是方块 —— metaball 融合只对圆形成立）
- 每个 bot 是一颗铬球，表面渐变角度按索引各差 30°，所以每颗球的反光方向不同，天然可区分
- 当前项：球体直径 66pt + `#B4FF2E` 的 2pt 环 + 外发光
- **相邻球靠近时边缘融合**（滚动时的 metaball 效果）—— 这是整个 app 最"高级"的一眼，也是最难做的一处
- 说话中：球体表面的高光**快速自转**（被音量驱动的转速）
- 静音：球体去饱和变成哑光深灰 `#3A3A44`（金属变成石头，语义很强）
- 未连接：球体变成线框（只留 1pt Chrome 描边，内部透明）

**内容卡片**
- `#15151D` + 1pt Chrome 描边（渐变描边，不是实色）+ 圆角 0 或 24（二选一，全 app 统一）
- 卡片左上角一个 SF Mono 的索引编号 `01` / `02`（酸性设计常见的伪数据标记）
- 字幕：agent 的话用 `#F4F6FB`，说话中的那一句用 `#B4FF2E`；用户的话用 `#9BA3B8`

#### 动效

- 位移：`spring(response: 0.28, dampingFraction: 0.7)`
- 液化/形变：`interpolatingSpring(stiffness: 180, damping: 12)`
- Chrome 高光扫过：`linear(4.0).repeatForever(autoreverses: false)`
- 色差：静止时 0.5pt，运动时增加到 2pt（速度越快色差越大 —— 这是物理直觉，效果很好）
- **签名动效**：切 bot 时，两颗铬球之间拉出一条液态金属丝，断开后新球"吸收"了那滴液体。0.5s，是六个方案里最炫的一个转场。

#### 音频可视化

见[第五节方案 F 段](#f-液态金属)。核心是**会分裂重组的 metaball 铬球**。

#### 诚实评估

**适合**：
- **上限最高**。做对了是六个方案里唯一能拿设计奖的，00 后的"高级感"认知直接对准这一套（音乐节海报、潮牌、Vision Pro 视觉都在这个语言里）。
- 声音 = 液态金属的隐喻自洽度极高，可视化设计空间最大
- 深色模式是它的主场，不存在其他方案"深色是二等公民"的问题
- 铬球的反光角度差天然区分多 bot，不需要额外配色系统

**不适合 / 缺点**：
- **实现难度是六个方案里最高的，且差距很大**。Metaball 融合、液化形变、色差，在 SwiftUI 里要么靠 `Metal` shader（iOS 17+ 的 `layerEffect`/`distortionEffect`），要么做近似降级。**如果没有能写 shader 的人，做出来的会是"贴了金属贴图的普通界面"，比现在还尴尬。** 这是选它之前必须先评估的。
- **性能风险最大**。Shader + 常驻高光动画 + 色差，在 iPhone 11/12 上大概率掉帧，长会话发热明显。必须准备低端机降级路径（关掉 metaball、关掉色差）。
- **可读性风险**：Chrome 渐变填充的文字对比度是动态的（渐变的暗段对暗底可能只有 2:1），必须逐处实测，或者只对 24pt 以上的大字用渐变填充。
- **酸绿 `#B4FF2E` 长时间看会累**，且它对色弱用户（红绿色盲）和背景的区分度不佳，语义色不能只靠它
- 浅色模式是妥协的 —— 铬在白底上失去对比，高光不明显，整套气质垮掉一半。**如果必须支持浅色模式，这个方案要扣分。**
- 风格偏"酷"、偏冷。语音助理是要跟你说话的东西，太冷会削弱亲近感，这和方案 C 是两个极端



---

<a name="五专题音频可视化"></a>
## 五、专题：agent 说话时的音频可视化

### 问题复述

现在是 `BarAudioVisualizer(barCount: 5, barMinOpacity: 0.1)`。组件内部 `barMinHeight = barWidth` 且 `cornerRadius = 100`，所以**音量为 0 时 5 根条退化成 5 个正圆**，再叠 0.1 的不透明度 —— 看起来和"组件渲染失败"完全一样。

### 通用原则（所有方案都适用，与风格无关）

**原则 1：静止态不能是"最小值"，必须是"另一种活着的状态"。**
柱状图的问题在于它把"没声音"映射成"最矮"，而最矮长得像坏掉。正确做法是让 `listening` 状态有自己独立的、不依赖音频数据的动画（呼吸 / 扫描 / 缓慢漂移）。

**原则 2：四个 agent 状态必须视觉可辨。**
`AgentState` 有 `idle / initializing / listening / thinking / speaking`。现在这四个只靠动画速度区分（组件源码里 `duration` 分别是 `2/n`、`0.5`、`0.15`、`veryLongDuration`），用户根本感知不到差别。应该给**形态**差异，不只是速度差异：

| 状态 | 该表达的意思 | 形态建议 |
|---|---|---|
| `idle` / 未连接 | 它不在 | 极淡、静止、或干脆不显示 |
| `initializing` | 在准备 | 不确定型进度（转圈/流动） |
| `listening` | 在等你说 | **缓慢规律的呼吸** —— 这是最关键的一个，必须明确"我活着且在等你" |
| `thinking` | 在想 | 不规律、有节奏的跳动（对应"处理中"） |
| `speaking` | 在说 | 被真实音频数据驱动 |

**原则 3：不要用 5 这个数字。**
5 是柱状图的"尴尬数量"—— 多到不像单一物体，少到不像频谱。要么 1（一个整体），要么 ≥ 12（真频谱）。

**原则 4：顶部 bot 方块里的迷你可视化和主可视化要是同一套语言的两个尺寸**，不能一个是柱状图一个是圆环。现有代码在 `CCRoomTileRow.swift:184` 用了 `barCount: 4` 的同款组件，主视图用 `barCount: 5`，这是不一致的。

**原则 5：`listening` 的呼吸动画要能被 `accessibilityReduceMotion` 关掉**，关掉后用静态但**明确可见**的形态（比如一个实心圆环），不能退回成 5 个淡点。

---

<a name="a-极光环"></a>
### 方案 A · 极光环（Aurora Ring）

**形态**：一个直径 200pt 的径向声环，不是柱状图。

- `listening`：环是一圈 3pt 的 `#38E1B0`，半径做 1.00↔1.04 的呼吸（2.2s 周期，`easeInOut`），环外侧有 20pt 的同色辉光。**同时环心的 mesh blob 跟着一起呼吸**，整个背景在跟着心跳。
- `thinking`：环变成虚线（8 段），整体以 1.2s/圈的速度旋转，同时环上有一个亮点绕圈跑（`#7A5CFF`）
- `speaking`：环的半径被 24 段频谱数据调制 —— 用 `Path` 画一个极坐标下 `r(θ) = R + amplitude[θ] * 40` 的闭合曲线，颜色从 `#7A5CFF`（低频）渐变到 `#FF5FA2`（高频）。**环内部填充一层同色 15% 的辉光，声音大时辉光扩散。**
- `idle`：环 opacity 降到 0.15，静止

**迷你版（bot 方块内 36×36）**：同一个环，缩小到 3 段频谱，只保留呼吸和半径调制。

**实现难度**：中。`Path` + 极坐标 + `AudioProcessor.bands` 就够，不需要 shader。

---

<a name="b-硬边-eq"></a>
### 方案 B · 硬边 EQ（Hard EQ）

**形态**：7 根粗竖条，每根宽 16pt、间距 8pt、圆角 4pt（不是 100），**最小高度锁死在满高的 30%**。

- `listening`：全部条保持 30% 高度，**一个 `#00D9A3` 的实色块从左到右逐条点亮**（每条 0.12s，像老式卡座的电平表自检）。这是"在听"的标志动作。
- `thinking`：只有中间 3 根条，做 `. . .` 式的依次跳起（30%→60%→30%），`linear` 曲线**无缓动**
- `speaking`：7 段频谱驱动高度，颜色 `#E8FF47`，**动画曲线用 `linear(0.05)` 硬跳**。野兽派不要平滑插值 —— 抖动本身就是性格。
- `idle`：条变成只有 2.5pt 黑色描边的空心框

**迷你版（bot 方块内）**：3 根条，同样锁 30% 最小高度。

**额外**：条的下方加一行 SF Mono 的伪电平数字（`-12 dB`），这种"假仪表盘"是野兽派/酸性设计的常用手法。

**实现难度**：低。这是六个里最容易做的，改几个参数就行。

---

<a name="c-果冻球"></a>
### 方案 C · 果冻球（Jelly Blob）

**形态**：一颗直径 160pt 的果冻球，颜色是当前 bot 的身份色。

- `listening`：球做 1.00↔1.05 的缓慢呼吸（2.4s），同时表面的白色高光点缓慢移动（模拟光源角度变化）。**球下方有一个跟着缩放的椭圆投影**，这个投影是"它是实体"的关键证据。
- `thinking`：球分裂成 3 颗小球，做交替的上下跳跃（弹性曲线，像三颗糖豆）
- `speaking`：**挤压回弹** —— 音量驱动 `scaleX = 1 + level*0.18`、`scaleY = 1 - level*0.14`（体积守恒的错觉）。同时球的下沿被"压平"（用可变圆角实现：底部圆角随音量从 80 降到 50）。
- `idle`：球去饱和成 `#E8DDD6`，静止，投影消失

**迷你版（bot 方块内）**：糖块本体直接做这套挤压，不需要额外元素 —— **这是本方案的巧妙之处：可视化和头像是同一个东西**。

**实现难度**：低–中。纯 `scaleEffect` + 可变 `cornerRadius`，不需要 shader。

---

<a name="d-水波纹"></a>
### 方案 D · 水波纹 + 液面（Ripple & Liquid）

**形态**：屏幕中央一个 180pt 的圆形"水池"（玻璃 + Chrome 描边），内部有液面。

- `listening`：液面停在 50% 高度，表面有极轻的正弦波纹缓慢左右移动（2 条相位不同的 sine，周期 3.5s / 4.8s —— 两条不同周期叠加才像真水）
- `thinking`：水池边缘发出一圈一圈向内收缩的波纹（和 speaking 的方向相反，这个方向差本身就是语义）
- `speaking`：**从中心向外扩散同心圆波纹**，每个音节触发一圈（检测音量峰值），波纹 scale 1.0→2.2 + opacity 1→0，1.2s。同时液面高度被音量驱动上下涌动。
- `idle`：水池空了，只剩 Chrome 边框

**迷你版（bot 方块内）**：就是方块内部那个液面，音量驱动水位 —— 和主视图同一套语言的不同尺寸，完美满足原则 4。

**实现难度**：中。同心圆波纹很简单；液面 sine 波需要 `Canvas` 或 `Path`，也不难。真实的水面折射需要 shader，但可以不做。

---

<a name="e-套印波形"></a>
### 方案 E · 套印波形 + 磁带计数器（Riso Waveform）

**形态**：一条横贯 bento 主格底部的**水平波形带**，高 72pt，不是居中的图形。

- `listening`：一条 `#2547D0` 的 1.5pt 水平基线，**一个竖直扫描线从左到右匀速移动（4s 一轮，到头后从左重来）**，像磁带计数器或老式示波器。扫描线经过的地方基线微微凸起。这个动作非常明确地表达"设备在运行"。
- `thinking`：基线变成虚线，扫描线原地闪烁（打字机光标节奏，0.5s 周期）
- `speaking`：**双色套印错位波形** —— 同一份 32 段频谱数据画两遍：一遍 `#2547D0` 蓝，一遍 `#FF48A0` 荧光粉且整体偏移 (1.5pt, -1.5pt)。重叠区域用 `.blendMode(.multiply)`。这就是 Riso 套印不准的效果，成本几乎为 0，辨识度极高。
- `idle`：只剩一条 `#D9D4C7` 的静止基线

**旁边配一行 SF Mono 元信息**：`LIVE · 44.1kHz · -18dB`（伪数据也行，编辑风需要这种"数据装饰"）

**迷你版（bot 方块内）**：24×16 的迷你套印波形，放在卡片左侧色块的位置。

**实现难度**：低。一个 `Path` 画两遍 + offset + blendMode。**性价比最高的一个。**

---

<a name="f-液态金属"></a>
### 方案 F · 液态金属球（Metaball Chrome）

**形态**：一颗直径 170pt 的铬球，表面是 5 段角度渐变。

- `listening`：球缓慢自转（渐变角度 20s 转一圈），表面一道高光每 4s 扫过一次。球体边缘有 0.5pt 色差。
- `thinking`：球**分裂成 3 颗小球做三角环绕运动**，靠近时边缘融合（metaball），远离时分开。这是全 app 最漂亮的一个状态。
- `speaking`：球体被音量驱动**液化形变** —— 用 16 段频谱调制球的轮廓半径，形成不规则的"液滴"形状，同时渐变中混入 `#B4FF2E`（音量越大绿色占比越高）。色差随音量从 0.5pt 增到 2.5pt。
- `idle`：球变成线框（1pt Chrome 描边，内部透明）

**迷你版（bot 方块内）**：铬球本身就是头像 —— 和方案 C 一样，可视化即头像。

**实现难度**：**高**。真正的 metaball 融合需要 Metal shader（`layerEffect`）或 `GlassEffectContainer` + `glassEffectUnion` 的近似（后者是 iOS 26 提供的，能做到相邻玻璃元素的形状融合，但可控性有限）。液化形变需要 `distortionEffect`。

**降级方案**（没有 shader 能力时）：放弃 metaball，用 3 颗独立的球 + 靠近时的 scale/blur 假融合；放弃液化，用可变圆角的椭圆。效果会掉 40%，但仍然比现在好。

---

### 一个所有方案都该做的小改动

不管选哪个方案，`listening` 状态都应该显示一条**极短的提示文案**（比如 `在听…` / `LISTENING`），配合可视化一起出现。

理由：可视化能表达"设备活着"，但不能表达"轮到你说了"。语音交互最大的用户困惑是"我现在该说话了吗"，这个用一个词解决的成本远低于用动画解决。现有界面完全没有这个信号。



---

<a name="六选型建议"></a>
## 六、选型建议

### 六方案横向对比

| | A 极光 | B 大字报 | C 软糖 | D 千禧 | E 便当 | F 液态铬 |
|---|---|---|---|---|---|---|
| 年轻感 | 中 | **高** | 中高 | **高** | 低 | **高** |
| 记忆点 | 低 | **高** | 中 | 高 | 中 | **高** |
| 长时耐看 | 高 | **低** | **高** | 中 | **高** | 中 |
| 与 iOS 26 契合 | **高** | **低** | 中 | **高** | 高 | 中 |
| 中文表现 | 中 | **低** | 高 | 中 | **高** | 中 |
| 深色模式质量 | 高 | **低** | 中 | 高 | 高 | **高** |
| 浅色模式质量 | 中 | **高** | **高** | 高 | **高** | **低** |
| 实现难度 | 低 | **低** | 低 | 中高 | 低 | **高** |
| 性能风险 | 中 | **低** | 低 | 高 | **低** | **高** |
| 撞脸风险 | **高** | 低 | 中 | 中 | 低 | 低 |
| 可视化观感上限 | 高 | 中 | 中高 | 高 | 中 | **最高** |

（加粗 = 该项的极端值，好坏都有）

### 按目标分流

**如果最重要的是"不再 low、且低风险快速见效"** → **方案 A 极光电台**
它对现有代码改动最小（换色板 + 加背景层），直接修好了"Liquid Glass 没东西可折射"这个根因。缺点是撞脸，但它不会错。

**如果最重要的是"有个性、能被记住、用户愿意截图"** → **方案 B 大字报** 或 **方案 F 液态铬**
B 的实现成本极低但和 iOS 26 对立，且长时使用疲劳；F 的上限最高但需要 shader 能力。**选 F 之前先确认团队能不能写 Metal shader**，不能就别选，降级后的 F 不如 A。

**如果主力用户偏低龄（10 后）、且使用频次很高** → **方案 C 软糖**
它的多 bot 色彩身份系统是真实的产品价值，不只是好看。风险是 00 后可能嫌幼。

**如果想要"和 Liquid Glass 最自洽的年轻化"** → **方案 D 千禧回声**
Apple 自己说 Liquid Glass 致敬 Aqua，Y2K 顺着这条线走最合理。但它对执行精度要求最高，做不好会比现在更土。

**如果用户其实想要的是"高级"而不是"炫"** → **方案 E 便当电台**
它是唯一能用 3 年不腻、且中文表现无短板的方案。但它和"面向 00/10 后"的诉求有明显张力，选它意味着重新定义目标。

### 我的实际建议

用户的原话是"太low、缺乏艺术感"+"面向年轻人"+"彻底重新设计"。这三条同时满足的最优解是 **B 或 F**，但两个都有硬伤（B 的长时疲劳和系统冲突、F 的实现门槛）。

所以更务实的路径是 **A 打底 + B/F 的一个签名元素**：

- 用 A 的背景和色彩体系（解决根因、低风险）
- 借 B 的字体策略（大字阶 + 等宽标签），解决"没有视觉焦点"
- 借 F 的可视化形态（液态球，降级版就够），解决"5 个灰点像坏了"
- 借 C 的 bot 身份色系统，解决"多 bot 分不清"

这样出来的东西不是纯粹的任何一派，但它同时命中了四个具体问题，而且每一块的实现风险都可控。**纯粹度和有效性在这个案子里不是同一件事**，如果用户要的是"解决问题"而不是"做一个风格样板"，混合方案更划算。

如果用户明确说"就要纯粹、要极致、不怕风险"，那就选 **F 液态铬**，但前置条件是先做一个 metaball + 液化形变的技术验证 demo，验证不通过就退回 **B 大字报**。

### 无论选哪个，这四件事必须做

1. 深色模式背景从 `#070707` 换成带色相的深色（各方案已给值），否则 Liquid Glass 永远出不来效果
2. 音频可视化换形态，不能继续用 `barCount: 5` 的默认柱状图
3. 字阶拉开到 3× 以上，现在不到 2×
4. 给多 bot 一套颜色/形态身份系统，6 个方块不能都是灰的



---

<a name="七信息来源"></a>
## 七、信息来源

### 趋势判断依据

| 来源 | URL | 本文用到的结论 |
|---|---|---|
| Figma, *Top Web Design Trends for 2026* | https://www.figma.com/resource-library/web-design-trends/ | Trend 3 高饱和配色（归因 Y2K + dopamine design，点名 Lush/Headspace/Starface）、Trend 4 bold typography、Trend 9 retrofuturism、Trend 12 neo-brutalism（点名 Balenciaga/Diesel/Mailchimp） |
| tubikstudio, *What's Next: 7 UI Design Trends of 2026* | https://tubikstudio.com/blog/ui-design-trends-2026/ | Trend 2「artificial delay 提升信任」、Trend 3 raw aesthetics/monospaced、**Trend 7 Anti-Liquid Glass（引用 Linear 的玻璃重写、批评 Apple Music 对比度）**、"grayscale graveyards" 对纯灰阶的批评 |
| uxpilot, *12 Product Design Trends for 2026* | https://uxpilot.ai/blogs/product-design-trends | Trend 2 Glassmorphism 2.0（点名 Apple Liquid Glass 与其可访问性风险）、Trend 4 micro-delight（Transit/Duolingo/Miro）、Trend 6 bento box、**Trend 7 neobrutalism（Gumroad 的 Black+White+Lavender Rose 执行细节）**、Trend 8 retro web（Bump by amo 拼贴、PostHog Win95）、Trend 9 kinetic typography |
| Gezar, *The 11 Best Web Design Trends in 2026* | https://gezar.dk/en/blog/web-design-trends-2026 | Claymorphism/Aurora UI/Grain & Noise/Y2K 的具体定义与技术实现建议；**"Never use pure black (#000)" 的深色模式建议与 `#111117`/`#1a1a2e` 推荐值**；aurora 点名 Stripe/Linear/Vercel |
| Brucira, *Top UI Design Trends* | https://blog.brucira.com/top-ui-design-trends/ | 深色模式应从 color token 出发而非反色；bento grid 应限制在 2–3 种卡片尺寸 |

### iOS 26 / Liquid Glass 技术依据

| 来源 | URL | 本文用到的结论 |
|---|---|---|
| Apple Developer, *Adopting Liquid Glass* | https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass | 官方采用指南 |
| conorluddy/LiquidGlassReference | https://github.com/conorluddy/LiquidGlassReference | `.regular`/`.clear`/`.identity` 三变体的适用条件；**Clear 变体的三条前置要求**；`.tint()` 只用于语义不用于装饰；`.interactive()` 的行为清单；**「Liquid Glass is best reserved for the navigation layer」**；反模式清单（glass-on-glass、内容层上玻璃、全局 tint）；`GlassEffectContainer` / `glassEffectUnion` / `glassEffectID` API；iOS 26.1+ 的 Tinted mode；最低 iOS 26 + iPhone 11 |

### 品牌色参考

| 来源 | URL | 说明 |
|---|---|---|
| ColorArchive, Bilibili | https://colorarchive.org/brands/bilibili/ | `#FB7299` 粉 / `#00A1D6` 蓝。**该页自述为 unofficial reference**，非厂商官方规范 |

### 本地实测

| 事实 | 取证方式 |
|---|---|
| PingFang SC 仅 6 个字重（Ultralight/Thin/Light/Regular/Medium/Semibold，**无 Bold/Black**） | `system_profiler SPFontsDataType \| grep "Full Name: PingFang SC"` |
| 现有色板 HEX 值（`bg1` 深色 `#070707` 等） | 解析 `VoiceAgent/Assets.xcassets/Colors/*.colorset/Contents.json` |
| 5 个灰点的成因（`barMinHeight = barWidth` + `cornerRadius = 100`） | 阅读 `components-swift/Sources/LiveKitComponents/UI/Visualizer/BarAudioVisualizer.swift` |
| 现有控件结构与 Liquid Glass 用法 | 阅读 `CCTheme.swift` / `CCHoldToTalk.swift` / `CCRoomTileRow.swift` / `CCRootView.swift` / `AgentView.swift` |

### 未能验证 / 需注意

- 本文提到的 Lapse / Locket / BeReal / Gas / Airbuds / Soul / 即刻 的**具体配色 HEX 没有官方公开规范**，文中未给出这些 app 的精确色值，只引用了它们的风格特征。若需要精确取色，建议直接在设备上截图取样。
- 小红书、抖音的品牌色未找到可引用的官方规范文档，文中只描述了配色规律，未给 HEX。
- 所有方案的 HEX 值是本文基于各流派特征设计的，**不是从任何现有 app 抄来的**，需要在真机上（尤其是 OLED 屏和户外强光下）实测对比度后再定稿。


