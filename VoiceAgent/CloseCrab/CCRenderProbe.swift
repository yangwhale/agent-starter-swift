import Foundation
import os
import SwiftUI

/// 数「谁在疯狂重算」的探针。
///
/// ## 为什么要有这个东西
///
/// 2026-09-20：app 静止不动就满转 72% CPU、两分钟内存涨 883 MB，卡住之后
/// **再也回不来**。我按崩溃栈猜了三轮根因，**三轮全错**：
///
/// 1. 猜「几何动画 id 跨页撞车」→ 改完照样犯，而且犯病时根本没横滑
/// 2. 猜「定时器起点写成 `.now` 自激」→ 形状确实错，但……
/// 3. tommy 把状态屏 / 人名牌子 / 主画面采样 / 背景**四个全关掉，照样烧**
///
/// 第 3 条把前两个都否了。教训很直白：**崩溃栈只告诉你「卡在渲染循环里」，
/// 它不告诉你是谁在驱动这个循环。** 靠读代码猜驱动源，猜一次错一次。
///
/// 所以改成让它自己说：**每个 view 的 body 每被求值一次就记一笔**，
/// 每秒汇总一次，超过阈值的打到系统日志。转疯了的那个会自己跳出来。
///
/// ## 怎么看
///
/// Mac 上接着设备：
/// ```
/// log stream --device --predicate 'subsystem == "com.higcp.closecrab.probe"'
/// ```
/// 正常：安静，或者偶尔几条个位数。
/// 出问题：某个 label 每秒几百上千次，那就是驱动源。
///
/// ⚠️ **定位完删掉整个文件和所有 `ccProbe` 调用点。** 它自己也有开销。
///
/// ## ⚠️ 整个类型标 `nonisolated`，不要逐个成员标
///
/// 工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，**裸 enum 也被隔离**。
/// 我第一版逐个给 `static var` 标 `nonisolated(unsafe)`，**漏了 `lock` 和
/// `startDumper()`** —— 编译三个 error，全是同一条规则。
///
/// 这个仓库里已经有九处在用 `nonisolated enum`（`CCStore` / `CCEndpoint` /
/// `CCType` …）。**新写这类无状态门面，第一笔就该照着抄。**
/// 逐个成员标是在跟编译器比谁记性好，而且只在「被 nonisolated 上下文读到」
/// 时才报错 —— 漏了的那个可能要等到另一个调用点才暴露。
///
/// 2026-09-20 我在同一条规则上栽了三次：CCBotStatus 的属性名常量、
/// CCRosterRow.height（那次是虚惊，同隔离域读不报错）、这里。
nonisolated enum CCProbe {
    private static let log = Logger(subsystem: "com.higcp.closecrab.probe",
                                    category: "render")

    /// 每秒超过这个次数才打印。
    ///
    /// 正常界面一秒重算十几次很常见（定时器 0.2 秒一跳、说话状态在变），
    /// 那些不是问题。**真正失控的会是三位数以上**，所以阈值定在这儿
    /// 既不刷屏、又不会漏掉。
    ///
    /// ⚠️ 2026-09-20 从 30 提到 100：实测 `VoiceBars` 长期稳定压在 30
    /// （它是 30 fps 的电平动画，**正常**），把真正的异常盖住了。
    /// 真正失控的量级是三位数 —— 峰值抓到过 306。
    private static let noisyPerSecond = 100

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var started = false

    /// 记一笔。**调用点要放在 body 求值路径上**，不是 onAppear。
    static func tick(_ label: String) {
        lock.lock()
        counts[label, default: 0] += 1
        let need = !started
        if need { started = true }
        lock.unlock()
        if need { startDumper() }
    }

    /// 非 body 的事件也能记（属性到达、objectWillChange 之类）。
    /// 跟 body 计数分开看 —— **要分清「谁在被重算」和「谁在驱动重算」**。
    static func event(_ label: String) {
        tick("⚡️" + label)
    }

    private static func startDumper() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler {
            lock.lock()
            let snapshot = counts
            counts.removeAll(keepingCapacity: true)
            lock.unlock()

            let noisy = snapshot.filter { $0.value >= noisyPerSecond }
                .sorted { $0.value > $1.value }
            guard !noisy.isEmpty else { return }
            // 一行一个，最多五个 —— 排在前面的才是驱动源，后面的多半是被它带着转的。
            let line = noisy.prefix(5)
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "  ")
            // ⚠️ **两条都发，不能只发 os_log。**
            //
            // `Logger` 走的是统一日志系统，**不进 stdout** —— 而从 Mac 上
            // 拉连接设备的日志需要 `log stream --device`，那个选项在现在的
            // macOS 上**已经不存在了**（tommy 2026-09-20 实测 `unrecognized
            // option --device`，`log stream --help` 里也没有任何 device 相关项）。
            //
            // 能实时、全量、零依赖拿到的只有 stdout：
            //     xcrun devicectl device process launch --console
            // 所以真正到得了我们手里的是 `print`。os_log 那条留着是给
            // Console.app / sysdiagnose 用的，两条不冲突。
            //
            // ⚠️ 这个坑最毒的地方：采集链路不通时看到的是「一条输出都没有」，
            // 跟「探针没触发」长得一模一样，但含义完全相反。
            print("🔥 每秒重算次数: " + line)
            log.error("🔥 每秒重算次数: \(line, privacy: .public)")
        }
        t.resume()
        timer = t
    }

    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
}

extension View {
    /// 给这个 view 的 body 求值计数。
    ///
    /// ⚠️ 用法是在 body **里面**写 `let _ = CCProbe.tick("X")`，
    /// 不是挂这个修饰符 —— 挂修饰符只会数到修饰符自己被构造的次数，
    /// 那跟宿主 view 的 body 求值次数不是一回事。
    /// 这个修饰符只给「没法改 body 内部」的情况兜底。
    func ccProbe(_ label: String) -> some View {
        CCProbe.tick(label)
        return self
    }
}
