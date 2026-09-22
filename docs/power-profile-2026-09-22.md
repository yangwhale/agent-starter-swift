# 电量实测：渲染侧的优化天花板是 9%

> 搜这些词应该能找到这里：手机发烫 / 耗电 / 省电 / 锁屏还在耗电 /
> battery / power / energy / Time Profiler / xctrace / 渲染闸门 /
> `CCRenderGate`。

2026-09-22。Chris 报 iOS app 一开播就烫，并要求「正经上 profiler 看电耗在哪」。
**这份文档存的是那次测量的结果，以及它否掉的那个假设。**

## 结论先行

**锁屏只省了 9%。屏幕刷新不是电的大头。**

采样密度（`xctrace 'Time Profiler'`，样本/秒，越高越忙）：

| 场景 | 时长 | 密度 |
|---|---|---|
| C 前台**空闲** | 30s | **232 /s** |
| A 前台**说话** | 90s | **788 /s** |
| B **锁屏**说话 | 90s | **718 /s** |

- **说话 vs 空闲：3.4 倍** —— 开销压倒性地来自「在说话」
- **锁屏 vs 前台（都在说话）：只降 9%**

⇒ 在此之前做的两轮省电（渲染闸门、删极光、柱子改成说话才接）**是有效的** ——
那 9% 就是它省的。**但它能省的本来就只有 9%。**

⚠️ 锁屏后真正消失的那些（`__CFRunLoopRun`、`AG::Graph::UpdateStack::update()`、
SwiftUI 那套）**加起来不到 1%**。
⇒ **继续在渲染侧优化，天花板就是这不到 1%。**

## 大头：LiveKitWebRTC

按二进制归属：

| 场景 | LiveKitWebRTC | Swift＋系统＋我们 |
|---|---|---|
| C 前台空闲 | **13.5%** | 12.5% |
| A 前台说话 | 3.0% | 12.6% |
| B 锁屏说话 | **5.2%** | 14.7% |

两个要看懂的地方：

- **C 那一列最要紧**：空闲时 WebRTC 占 13.5%，是最大的单一来源 ——
  而那会儿**没人说话、屏幕也没动**。⇒ **五路音频常驻本身就在烧。**
- **B 比 A 的占比更高**（5.2% vs 3.0%）：锁屏后渲染退场，
  WebRTC 在剩下的总量里占比上升 —— **它本身没减少，只是别的减少了。**

锁屏后新增最重的、唯一有名字的一条是
`webrtc::PhysicalSocketServer::WaitPoll(TimeDelta, bool)` —— 网络轮询。

## 要再降，只有一个杠杆，而它是**功能取舍**

让**非当前房间**的音频停下来。两种做法：

| 做法 | 省多少 | 代价 |
|---|---|---|
| `set(enabled: false)` | 大头 | 听不到别的房间的 bot；**切回去恢复快**（订阅还在） |
| `set(subscribed: false)` | 更多 | 切回去要重新协商，**有明显空白** |

前者就是「静音某个房间」现在用的机制（见 `CCRoomSlot.applyMute` 的注释），
成熟、恢复快。

⚠️ **这不是优化，是产品决定**：挂五个房间的人，是想同时听到所有 bot，
还是只听当前这个。**没有 Chris 拍板不要做。**

## 方法与限制（照抄，别美化）

- 工具：`xcrun xctrace record --template 'Time Profiler' --device <硬件UDID>
  --attach VoiceAgent`
- ⚠️ **`xctrace --device` 要「硬件 UDID」**（`xctrace list devices` 给的那个），
  **不吃 `devicectl` 用的 CoreDevice 标识** —— 两个 ID 不通用。
- ⚠️ 声音是自己造的：`~/lk-gemini-agent/speak_into_room.py <room> "<长文本>"
  --identity <room>-probe`。**identity 必须改掉** ——
  默认的 `<room>-speaker` 会把真正的播报出口踢下线。
  它 token 里带 `with_kind("agent")`，所以 app 会把它当 bot 音轨，
  柱子会真的动 —— **是真场景不是假负载**。
- A 和 B 之间隔了约 2 分钟，避免余温混进去。

**限制（都要记着）**：

1. **这是 CPU 时间，不是能耗。** GPU 和网络那部分 Time Profiler 看不见。
   `Power Profiler` 没录 —— 要录得再占用人一次。
2. **WebRTC 内部到不了函数名。** 叶子符号大量是 `0x1035xxxxx` 这类地址，
   `atos` 还原不出来（二进制 xcframework，没有符号表）。
   归属是靠 trace 里的 `<binary load-addr=…>` 区间反推的。
3. **系统是 iOS 27.0。** 那台手机当天从 26.6.2 升上来的，
   而且是我们事后才发现的 —— 跨版本比较这批数字时要留意。
