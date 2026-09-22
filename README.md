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

## 一次登录，六个（或更多）聊天室

一个 bot 一个常驻房间，房间名就是 bot 名，所以「换房间」＝「换一个助理说话」。
这是会话中途最常做的事，不是启动参数：

- **左上角汉堡**打开房间抽屉，连着的时候也能开，上面直接写着当前在跟谁说话
- 点另一个房间就切过去，**不用退出 app**（内部是挂断再连，一个 `Session` 用到底）
- 名单**从服务端拉**（`GET <服务器>/api/rooms`），加了 bot 这边自动多出来，
  不用挨个设备去改一遍
- 每个房间带状态：绿＝助理在岗、橙＝房间在但助理不在、灰＝离线或状态未知

状态里的「未知」是**第三种**颜色，不是「离线」。服务端查不到 SFU 的时候会回 `null`，
把它画成红色会让人以为 bot 挂了，实际只是管理接口抽风。

## 相对上游改了什么

| 文件 | 改动 |
|---|---|
| `VoiceAgent/CloseCrab/CCStore.swift` | 新增。服务器地址 / 信令覆盖 / 房间缓存进 UserDefaults，共享密钥进 Keychain |
| `VoiceAgent/CloseCrab/CCEndpoint.swift` | 新增。地址拼装 + HMAC 签名，两个调用方共用一份 |
| `VoiceAgent/CloseCrab/CCRoomDirectory.swift` | 新增。拉 `/api/rooms`，本地只留一份缓存垫底 |
| `VoiceAgent/CloseCrab/CCRoomListView.swift` | 新增。房间抽屉，会话中途可切 |
| `VoiceAgent/CloseCrab/CloseCrabTokenSource.swift` | 新增。向 `/api/token?room=<bot>` 要 token，每次现读当前房间 |
| `VoiceAgent/CloseCrab/CloseCrabConfig.swift` | 新增。给 SwiftUI 用的观察层，持久化仍在 `CCStore` |
| `VoiceAgent/CloseCrab/CloseCrabSettingsView.swift` | 新增。设置页（房间列表在这里是只读的） |
| `VoiceAgent/App/AppView.swift` | 连上之后左上角加汉堡菜单 |
| `VoiceAgent/App/StartView.swift` | 连接按钮上方的房间入口，开的是同一个抽屉 |
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

新增的文件都在 `VoiceAgent/CloseCrab/` 下面，工程用的是 Xcode 16 的
`PBXFileSystemSynchronizedRootGroup`，目录里的 `.swift` 自动进 target，不用手动加。

## 第一次运行要填什么

只有**一项**必填：抽屉左上角齿轮 → 共享密钥。

- **服务器**：默认已经是 `https://live.higcp.com/native`，不用改。
  这条路在负载均衡上挂到不走 IAP 的后端 —— 原生 app 没有浏览器的登录 cookie，
  走正常入口会被弹到 Google 登录页
- **信令地址覆盖**：留空。服务端会按入口回对应的地址（native 拿到
  `wss://live.higcp.com/native/lk`），这一项只是换域名时的逃生口
- **共享密钥**：对应后端 `.env.local` 里的 `CC_NATIVE_SECRET`。
  不填的话 `/native` 那条路一律回 401
- **房间列表**：只读。从 `/api/rooms` 拉，和后端换 token 用的是同一份
  `ALLOWED_ROOMS`，所以不会出现「这里列得出、那里连不上」

签名带秒级时间戳，服务端只收 ±300 秒，**设备时钟得是准的**（开着自动对时就行）。

## 服务端那一半

已经上线了，这个 app 对着现成的接口写：

| 东西 | 状态 |
|---|---|
| `/native/*` 走非 IAP 后端（GCLB url-map） | 已加 |
| Caddy 打 `X-CC-Entry` 头，IAP 那条路显式 unset | 已加 |
| `GET /api/rooms` 房间目录 | 已加 |
| `/api/token` HMAC 验签 + 按入口回信令地址 | 已加 |

验签规则：`HMAC-SHA256(密钥, "<scope>:<unix 秒>")` 十六进制小写，
scope 对 `/api/token` 是房间名、对 `/api/rooms` 是字面量 `rooms`。
把 scope 签进去是为了让一张签名只能用在它申请的那个房间上 ——
否则抓到一次 `?room=bunny` 的请求就能改成 `?room=jarvis` 重放。

## 还差什么

**麦克风占用那条要真机验。** 挂断之后 AVAudioSession 会不会彻底放掉、
豆包输入法能不能抢回麦克风 —— 我没有 iOS 设备，不敢先给结论。
如果还是抢，下一步是调 `AudioManager.shared` 的 audio session 配置。

**代码只做过语法检查，没编译过。** 开发机是 Linux，装了 Swift 工具链也只能
`swiftc -parse`（SwiftUI 和 LiveKit SDK 在 Linux 上都不存在），类型、可用性、
ViewBuilder 那些得到 Xcode 里才知道。

## 跟上游同步

```bash
git fetch upstream
git merge upstream/main    # 改动集中在 VoiceAgent/CloseCrab/，冲突面很小
```

## 文档

- [`docs/ios-mic-indicator.md`](docs/ios-mic-indicator.md) — 麦克风橙点关不掉：SDK 每建一个房间就把全局静音模式覆盖成「灯常亮」那一档（**灯又亮起来先读这份**）
- [`docs/power-profile-2026-09-22.md`](docs/power-profile-2026-09-22.md) — 电量实测：渲染侧优化天花板 9%，大头是 WebRTC（**再做省电前先读这份**）
- [`docs/mac-audio-input-devices.md`](docs/mac-audio-input-devices.md) — Mac 上为什么没有麦克风输入设备切换（2026-09-21 做了又删，实测结论存档）
- [`docs/apple-platform-notes-2026.md`](docs/apple-platform-notes-2026.md)
- [`docs/visual-redesign-2026.md`](docs/visual-redesign-2026.md)
