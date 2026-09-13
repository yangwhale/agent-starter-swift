# CloseCrab 语音 App（iOS / macOS）

Fork 自 [livekit-examples/agent-starter-swift](https://github.com/livekit-examples/agent-starter-swift)，
改成连我们自己的常驻房间。上游 README 见 `upstream/main`。

## 为什么不用网页版

网页版（`live.higcp.com`）在 iOS Safari 上有三个躲不开的问题，都是浏览器沙箱决定的，
不是前端代码能修的：

| 问题 | 网页版 | 这个 app |
|---|---|---|
| 每次开页面都要重新授权麦克风 | Safari 的权限按标签页给 | 系统级授权，同意一次就记住 |
| 切到后台就不好使 | 页面被挂起 | `UIBackgroundModes: audio`，锁屏也不断 |
| 一直占着麦，别的输入法用不了 | 没法干净地放掉 | 挂断会完整拆掉 AVAudioSession（**待真机确认**，见下） |

## 相对上游改了什么

| 文件 | 改动 |
|---|---|
| `VoiceAgent/CloseCrab/CCStore.swift` | 新增。服务器地址 / 房间列表 / 信令覆盖存 UserDefaults，共享密钥存 Keychain |
| `VoiceAgent/CloseCrab/CloseCrabTokenSource.swift` | 新增。向我们自己的 `/api/token?room=<bot>` 要 token |
| `VoiceAgent/CloseCrab/CloseCrabConfig.swift` | 新增。给 SwiftUI 用的观察层，持久化仍在 `CCStore` |
| `VoiceAgent/CloseCrab/CloseCrabSettingsView.swift` | 新增。设置页 |
| `VoiceAgent/App/StartView.swift` | 连接按钮上方加房间选择器，底部加设置入口 |
| `VoiceAgent/VoiceAgentApp.swift` | 删掉 `AgentToConnect`（官网演示 agent / Cloud 开发 token server 都不用），关掉摄像头和屏幕共享 |
| bundle id / 显示名 / 开发团队 | 换成 `com.higcp.closecrab.voice` / `CloseCrab` / 留空待填 |
| `VoiceAgent.entitlements` | 去掉 `com.apple.developer.networking.multipath` —— 一行没用到，留着只是给自动签名多一道坎 |

三件**没**动的，都是故意的：

- **控制栏原样保留**。上游那套（麦克风开关 + 输入设备 + 字幕 + 挂断）比一个光秃秃的
  大按钮好用，尤其字幕 —— 出问题时想知道「它到底听成了什么」全靠它。
- **`BroadcastExtension` 留着**。它是屏幕共享用的，我们用不上，但删 target 是 Xcode
  界面上的活儿，命令行改 `.pbxproj` 容易改出一个打不开的工程。签名要是卡在
  App Group 上，在 Xcode 里右键删掉这个 target 就行。
- **预连接音频缓冲开着**（上游默认）。点了通话立刻能说，声音先存着、连上再补发。

## 怎么 build

1. Xcode 打开 `VoiceAgent.xcodeproj`
2. 选 `VoiceAgent` target → Signing & Capabilities → Team 选成自己的
   （`DEVELOPMENT_TEAM` 已经清空，Xcode 会直接提示）
3. 接上 iPhone，跑

Bundle id 是 `com.higcp.closecrab.voice`，没被占用过，自动签名应该能直接建出来。
部署目标 iOS 18 / macOS 15。

## 第一次运行要填什么

启动 → 底部「服务器」：

- **服务器**：取 token 的地址，会去请求 `<这里>/api/token?room=<房间>`
- **信令地址覆盖**：留空就听服务端的。服务端返回的 `serverUrl` 是给浏览器用的，
  手机连不上时在这里填 `wss://...`
- **共享密钥**：服务端还没验签，现在可以留空
- **房间列表**：逗号分隔，房间名就是 bot 名，要和前端 `.env.local` 的
  `ALLOWED_ROOMS` 对得上

回主界面，在连接按钮上方挑房间，点连接。

## 还差什么

**一、服务端那一半 —— 挡路的就是这个。**
现在整个站在 GCLB + IAP 后面，IAP 认的是浏览器登录 cookie。原生 app 没有那张
cookie，token 请求和 WebSocket 握手都会被弹到登录页。要么给手机开一个不走 IAP
的入口（LiveKit 信令本来就是设计成公开的，真正的鉴权是那张 15 分钟有效的 JWT，
需要保护的只有签 token 那个接口），要么换别的认证方式。

这个 app 两边的口子都留好了：地址可配；签名头 `X-CC-Ts` / `X-CC-Sig` 已经会发，
签的是 `<房间>:<秒级时间戳>`，HMAC-SHA256 十六进制。服务端接上就生效，不用重新编译。

**二、麦克风占用那条要真机验。**
挂断之后 AVAudioSession 会不会彻底放掉、豆包输入法能不能抢回麦克风 —— 我没有
iOS 设备，不敢先给结论。如果还是抢，下一步是调 `AudioManager.shared` 的
audio session 配置。

## 跟上游同步

```bash
git fetch upstream
git merge upstream/main    # 改动集中在 VoiceAgent/CloseCrab/，冲突面很小
```
