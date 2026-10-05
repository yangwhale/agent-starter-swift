# facebench：活脸 vs AgentTouch 原固件，逐帧对照

在 Linux 上把**原固件的真代码**（`face.cpp` + `grokface.cpp`）和我们的移植（`CCFaceMotion` →
`CCFacePainter`）按同皮肤、同状态、同一绝对时刻画出来并排比。不用手机，不用板子。

## 许可边界（为什么这里没有 AgentTouch 的代码）

AgentTouch 是 PolyForm Noncommercial。这个目录**只放我们自己写的部分**：

- `harness/` —— 假的 Arduino_GFX（`Arduino_GFX_Library.h` + `gfx.cpp`，光栅算法逐行转写自
  [Arduino_GFX](https://github.com/moononournation/Arduino_GFX) `src/Arduino_GFX.cpp`，BSD，
  文件头带出处）、几个桩头文件、`bench.cpp` 主程序、两个只写了 `#include "face.cpp"` 和取静态变量的 TU。
- `swift/export.swift` —— 调 `CCFaceMotion` 导出每帧绘制清单 / 引擎时间线。
- `tools/*.py` —— 照 `CCFacePainter` 写的光栅器、对照与统计脚本、出动图。

`harness/build.sh` 从**你自己 clone 的** AgentTouch 里把 `face.cpp face.h grokface.cpp grokface.h
grok_eyes.h config.h` 拷进构建目录再编（引号 include 先找同目录，桩必须跟它们放一起）。

## 跑法

```bash
git clone https://github.com/wentong2022-arch/agenttouch /tmp/agenttouch
export FACEBENCH=/tmp/facebench            # 工作目录（帧缓存、输出都在这）
mkdir -p $FACEBENCH && cp -r tools/facebench/* $FACEBENCH/
AGENTTOUCH_SRC=/tmp/agenttouch/firmware/src $FACEBENCH/harness/build.sh $FACEBENCH/build   # g++
REPO=$PWD $FACEBENCH/swift/build.sh $FACEBENCH/swift/work                                   # docker swift:6.2-noble

cd $FACEBENCH
python3 tools/compare.py r1            # 6 皮肤 × 10 状态，8 s × 30 fps：IoU、轮廓边误差、关键帧对照图
python3 tools/stats.py r1              # 随机部分比分布：首次眨眼 / 眨眼间隔 / 时长 / 换脸间隔 / 表情池使用
python3 tools/spring_check.py          # grok 弹簧：换表情后逐帧 s_pos vs spring()
python3 tools/make_gifs.py r1          # 并排动图（classic 全状态、六皮肤四状态）
python3 tools/transitions.py r1        # （make_gifs 之后）每次换状态后 0.9 s 是否一致
python3 tools/timeline.py r1 classic   # 眼睛上沿 / 下沿 / 中心 / 面积随时间的曲线
python3 tools/zoom.py r1 robo idle 30 100,180,380,290 2   # 某一帧放大对照
```

## 要点

- **时间对齐**：原固件 `millis()` = 1 000 000 ↔ 移植 t = 1000.0 s。所有 `sin(t·k)`、`t % 周期`
  都用绝对时间，所以呼吸、扫视、弹跳、问号、z 的相位逐帧对得上。
- **30 fps**：原固件主循环 `now - lastFrame >= 33`。grok 弹簧是逐帧积分的，帧率不同曲线就不同。
- **随机数对不齐**：原固件是按开机毫秒播种的 LCG，移植是按房间名的 splitmix64 —— 只能比分布。
  `compare.py` 的「确定性帧」= 两边都没在眨眼、且还没到第一次换表情的帧，这些帧必须一致。
- **基准渲染器先验过**：跟 `media/states.gif` 比 idle 0.998、needs 0.999（IoU）。
- 原固件的底部名牌 / 小圆点 / 批准气泡不属于脸，bench 里压掉了（`hideBubble`、席位状态恒定、
  预热一帧耗掉名牌的 3 秒）；`offline` 切换时名牌仍会浮出 —— 对照里那几帧的「多出来的小点」就是它。
- 噪声底：Arduino_GFX 整数像素 ＋ `(int)` 截断 vs 移植连续坐标 ＋ 抗锯齿，轮廓边误差 ≤ 1–2 px；
  `fillArc`/`fillCircle` 外径按 r+0.5、内径按 r−0.5 判，原版圆环比数学上厚约 1 px。

逐轮记录（发现了什么、怎么修、修完的数）见 `ROUNDS.md`。
