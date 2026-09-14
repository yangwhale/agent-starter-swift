# 离线测试

这里只有一个文件，因为**这台开发机是 Linux、没有 Xcode** —— SwiftUI 和 LiveKit
一行都编不了。能离线验证的只有纯逻辑，所以规则尽量往 `CCRoomSelection.swift` 里塞：
写在 View 里的东西，在真机跑之前没有任何人能说它对不对。

跑法（需要一份 Linux Swift 工具链）：

```bash
swiftc -swift-version 6 \
  ../VoiceAgent/CloseCrab/CCRoomSelection.swift \
  CCRoomSelectionTests.swift -o /tmp/t && /tmp/t
```

⚠️ 文件名必须是 `main.swift` 才能写顶层语句 —— 编译时直接
`cp CCRoomSelectionTests.swift /tmp/x/main.swift`。

覆盖 18 条：名单规范化的两条不变量、顺序稳定性、去重、空白、幂等、
勾选 toggle 的四种情形，以及方块那圈颜色的优先级（静音优先于说话）。
