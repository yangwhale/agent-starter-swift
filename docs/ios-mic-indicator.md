# iOS 麦克风橙点：为什么「闭麦」不等于「关麦」

> 搜这些词应该能找到这里：抢麦 / 麦克风灯 / 橙点 / 橙色小圆点 / 麦克风被占用 /
> 闭麦不生效 / 关不掉麦克风 / mic indicator / orange dot / microphoneMuteMode /
> `.inputMixer` / `.restart` / `AudioManager` / `LocalMedia`。

2026-09-22。Chris 报「加第二个 bot 之后麦克风橙点一直亮，退出那个 bot 也不灭」。
**前两版修的都不是真因** —— 这份文档记的是真因、它为什么难找、以及怎么防。

## 真因：SDK 每建一个 `LocalMedia` 就把全局静音模式改成「灯常亮」那一档

`client-sdk-swift` 2.17.0，`SwiftUI/LocalMedia.swift:114`：

```swift
private func observeDevices() {
    try? AudioManager.shared.set(microphoneMuteMode: .inputMixer)  // ← 这一句
    ...
```

而 `.inputMixer` 是什么，SDK 自己的文档注释写着（`AudioManager+MuteMode.swift:30`）：

> Simply mutes the output of the input mixer.
> **The mic indicator remains on**, and the internal `AVAudioEngine`
> continues running without reconfiguration.

⇒ **这个模式下「闭麦」只是把输入调成静音 —— 麦克风一直开着，灯一直亮。**
我们所有的 `setMicrophone(enabled: false)` **都生效了，它们只是不关麦。**

### 为什么偏偏是「第二个房间」

| | |
|---|---|
| `AudioManager` | **全进程单例** |
| `LocalMedia` | **每个房间一份**（`CCRoomSlot.init`） |

我们在 `CCAudioSessionPolicy.install()`（App 启动）里设 `.restart`，**只设一次**：

- 第一个房间的 `LocalMedia` 建在它**之前** ⇒ `.restart` 赢 ⇒ 灯不亮
- **第二个房间建在它之后** ⇒ 一建就覆盖成 `.inputMixer` ⇒ **灯亮**
- 退出那个房间**也不恢复** —— 没有任何人再设回来

⇒ 一次解释全部三个现象，包括「退出不自愈」。

⚠️ 「第一个房间不受影响」是**推断**（取决于构造顺序）；
「每个 `LocalMedia` 都覆盖成 `.inputMixer`、而那个模式让灯常亮」
是**源码 ＋ SDK 自己的文档**，不是推断。

## 三档静音模式，只有一档真关麦

| 模式 | SDK 原话 | 灯 |
|---|---|---|
| `.voiceProcessing` | 引擎照跑，不重配会话，**iOS 会响一声** | 亮 |
| `.inputMixer` | 只静音输入混音器，**「mic indicator remains on」** | **亮** |
| **`.restart`** | 重启引擎、不带麦克风输入；**「Deactivates the audio session on mute」** | **灭** |

## 关麦是**两步接力**，缺第一棒后面永远不发生

```
.restart  →  引擎在闭麦时报告「不录音了」
          →  CCAudioSessionPolicy 收到（engineDidDisable）
          →  既不放音也不录音 ⇒ setActive(false, .notifyOthersOnDeactivation)
          →  日志「已释放（麦克风让出去了）」⇒ 灯灭
```

被覆盖成 `.inputMixer` 之后，**第一棒就没交出去** ——
引擎从不报告「停录了」，后面三步永远不触发。
**我们那套释放逻辑一直是对的，只是从来没被叫醒过。**

## 修法

`CCAudioSessionPolicy.reassertMuteMode()`，
**紧跟在 `CCRoomSlot.init` 里 `LocalMedia(session:)` 那一句后面调**。
不能只在启动时调 —— 那正是出问题的写法。

## 代价（诚实写下来）

`.restart` 比 `.inputMixer` 慢：每次闭麦要停引擎、开麦要重配会话。
SDK 默认选 `.inputMixer` 正是图快、图不响那一声。
我们拿这点速度换「真的把麦还回去」。单房间一直这么跑，「按住说话」体感没问题。

## 已知未解 / 未完全验证

1. **`setRecordingAlwaysPreparedMode(true)`** —— `LocalMedia.observeDevices()`
   里紧接着的第二句，同样是全局的，我们**没动它**。
   现在没暴露问题，但「没暴露不等于不在」。**灯再亮，它是第一个要查的。**
2. **验证程度**：Chris 的原话是「**基本上**都能闭上麦」，不是「完全」。
   逐步（只连一个 / 加第二个 / 退出 / 反复开闭 / 切后台）的灯态**没有逐条拿到**。
   ⇒ 记作「现象改善」，**不是**「已解决」。

## 这次为什么难找 —— 值得记的两条

1. **「设过一次」不等于「现在还是」。**
   我查过 `.restart` 是对的、也设了，然后就默认它一直是那个值。
   **全局单例上的设置，谁都能改，而且改的人不会告诉你。**
2. **覆盖它的那个函数叫 `observeDevices`** —— 听起来只是「观察设备列表」，
   **完全看不出它会碰全局音频配置**。
   ⇒ 排查全局状态被改时，不能只看「名字像会改它的地方」。
