# Mac 麦克风输入设备：为什么我们**不**提供切换

2026-09-21 花了一整个下午做输入设备菜单，**最后整个删掉了**。
这份文档是那天所有实测结论的存档 —— 删代码不该把这些一起删掉。

> Chris 的原话（16:47）：
> 「我一旦切换了输入的音频的话，马上就没有办法输入了，就坏掉了。
> 要不算了吧，咱也别切换了，你就 follow 系统的设置就完了，把那个开关给它去掉。」

## 现在的行为

**不给切换入口，跟随系统默认输入设备。**
要换麦克风，去「系统设置 → 声音 → 输入」。

LiveKit 那边我们从不调 `select(audioDevice:)`，`AudioManager.inputDevice`
保持在它的默认模式 —— 日志里那条 `id=default` 的伪条目就是这个状态。
这也是加菜单**之前**一直在跑的状态，稳定。

（输出那一头本来就是这样，见 `CCAudioOutput`：macOS 分支退成空视图。）

---

## 实测结论存档

删掉的代码是 `CCAudioInputs.swift` ＋ `ControlBar/AudioDeviceSelector.swift`，
git 里从 `bee441c` 到 `2baf8d6` 那一串。下面是它换来的东西。

### 1. `LocalMedia.audioDevices` 不能直接用

client-sdk-swift 2.17.0，`LocalMedia.swift:61,125`：

```swift
@Published var audioDevices = AudioManager.shared.inputDevices   // ① 建对象那一刻的快照
AudioManager.shared.onDeviceUpdate = { ... audioDevices = ... }  // ② 之后只靠这个回调
```

- **① 快照太早**：`LocalMedia` 建在 `CCRoomSlot.init`，那会儿 WebRTC 的音频
  设备模块还没热。实测同一个调用前后两次分别报 **1 个**和 **6 个**。
- **② 那个回调是全局单槽，而我们有 N 个房间**：每建一个 `LocalMedia` 覆盖一次，
  而 `LocalMedia.deinit` 会把它**置回 nil** —— 关掉任意一个房间，
  从此设备插拔再也不刷新。

⚠️ 上游没写错，它假设「一个 app 一个 `LocalMedia`」。是**我们的多房间用法**
踩出来的。

### 2. LiveKit 的 `deviceId` == CoreAudio 的 `uid`（逐字相同）

```
LiveKit id=AppleUSBAudioEngine:AU05:AU05:202606031150:1
系统   uid=AppleUSBAudioEngine:AU05:AU05:202606031150:1
```

**唯一例外**：LiveKit 清单第一条永远是 `id=default`，`name` 借用当前默认设备的
名字。它不是设备，是「跟随系统默认」这个选项。
菜单里那个「重复的 AirPods」就是它 —— **不是枚举重复，是两条语义不同的条目
撞了名字**。

### 3. ⛔ 「输入声道数 > 0 ＝ 输入设备」这条判据是错的

```
MacBook Air Speakers   4ch bltn   uid=BuiltInSpeakerDevice
```

内置扬声器**确实声明了 4 个输入声道**（回声消除参考通道那类）。
不是查询失效、不是时序问题。任何按声道数筛输入设备的写法都会把它放进来。

### 4. 能区分的是**输入流的终端类型**，但它只有一半有效

| 设备 | 声道 | term |
|---|---|---|
| AirPods `:input` | 1ch | `micr` |
| AirPods `:output` | 2ch | `hdph` |
| AU05 / 罗技摄像头 | 2ch | `micr` |
| Unknown USB Audio Device | 2ch | `spkr` |
| MacBook Air Microphone | 1ch | **空** |
| iPhone 连续互通麦 | 1ch | **空** |
| MacBook Air Speakers | 4ch | **空** |
| 聚合设备（`grup`） | 4ch | `micr,spkr` |

⚠️ **`term` 是「有则可信、无则无信息」的字段。**
空的那一档里**真麦克风和扬声器混在一起**，所以不能反过来用
「没有 `micr` 就扔」—— 那会把内置麦克风滤掉。

取法：`kAudioDevicePropertyStreams`（scope = Input）列流，
再逐条问 `kAudioStreamPropertyTerminalType`。终端类型挂在**流**上不是设备上。

### 5. 清单本身在抖（**未解**）

60 秒四次采样，没人插拔任何设备：

```
系统侧    10 / 6 / 10 / 10
LiveKit    1 / 6 /  8 /  6
```

`VPAUAggregateAudioDevice` 的地址每次都变（语音处理单元在反复建销聚合设备），
连 `CADefaultDeviceAggregate-<pid>` 自己的声道数都在 1ch / 2ch 之间跳。

⇒ **用户在不同时机打开菜单，看到的条目数可能不同。**
这比「只有一条」更难查，因为它**间歇性正确**。

### 6. 勾选状态不能读 `localMedia.selectedAudioDeviceID`

SDK 在设备更新时把它赋成 `defaultInputDevice.deviceId`，而那是个 `let`，
**AudioManager 建的时候就定死了**。手动选过设备之后，任何一次设备变化
都会让界面跳回开机默认，而实际在用的是另一个。
要读当前的得用 `AudioManager.shared.inputDevice`（不带 `default` 前缀那个）。
另外冷启动时它会是**空串**。

---

## 如果将来要重做

按顺序过这几关，前面两关没过就别开工：

1. **先查清「切换之后为什么采不到音」** —— 这是这次真正致命的一条，
   而它到删除为止**都没有定位**。现象：选任何一个设备（包括看起来正常的
   内置麦），输入立刻失效。
2. **想清楚抖动怎么处理** —— 见第 5 条。菜单内容取决于打开时机。
3. 过滤规则只能是**单向**的：有正面证据（`term` ∈ {`spkr`,`hdph`} 且无 `micr`）
   才滤，判不出来一律留。**漏掉一台能用的麦克风，比多列一台没用的更糟。**
4. 别按名字或 UID 前缀筛 —— 那是字符串启发式。
5. `id=default` 那条要保留并改标签（「跟随系统默认（X）」），
   它是用户选错之后回到安全状态的那条路。

## 一条更一般的教训

**「让用户能选」和「保证每个选项都能用」是两件事。**

改动之前菜单里只有一条，想选错都选不了。放开到六条之后，里面混进了
采不到音的设备，而选中它们的后果是**静音、且没有任何提示**。

⇒ 放开一个受限的界面时，要问：**原来那个限制，是不是正在顺带挡住别的东西。**
