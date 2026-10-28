# AirControl

<p align="center">
  <strong>超低延迟、无广告的 Apple 原生无线触控板、键盘 Deck 与智能远程电源中心</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13.0%2B-black" alt="macOS" />
  <img src="https://img.shields.io/badge/iOS-16.0%2B-black" alt="iOS" />
  <img src="https://img.shields.io/badge/Transport-Apple%20Multipeer%20AWDL-blue" alt="Transport" />
  <img src="https://img.shields.io/badge/Filter-1€%20Adaptive%20Filter-purple" alt="1-Euro Filter" />
  <img src="https://img.shields.io/badge/Motion-120Hz%20ProMotion-orange" alt="Motion" />
  <img src="https://img.shields.io/badge/Power-Wake--on--LAN-red" alt="WoL" />
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License" />
</p>

---

## 概述 (Overview)

AirControl 将您的 iPhone 转换为一台极高精度、超低延迟的无线触控板、键盘 Deck 和智能远程电源中心，专门为将 Mac 放置于电视机或大屏显示器旁的家庭控制场景打造。

区别于商业软件的臃肿弹窗、收费与卡顿，AirControl 追求极客工程水准与原生质感：

* **极致丝滑与 Remote Mouse 动态非线性加速度引擎**：
  * **深度逆向 Remote Mouse 动态加速度模型**：摒弃导致相位滞后与微抖的低通滤波，采用经逆向工程验证的 `(dist / dt / speed)` 动态非线性加速度曲线，并在加速度系数上施加 40ms 时间常数的指数平滑 (EMA)，实现微小位移像素级精准定位、高速甩动无拖拽感。
  * **网络抖动与微突发时钟保护**：针对 Wi-Fi 数据包微突发（Micro-burst < 2ms）或丢包延迟（Lag > 50ms），自动钳位至基准 60Hz 帧时 `dt = 1/60s`，彻底解决传统网络鼠标在数据包聚集到达时光标暴冲、掉帧的问题。
  * **绝对坐标目标定位与 Session Event Tap**：使用绝对屏幕坐标 `CGPoint` 注入，杜绝 `mouseEventDeltaX` / `mouseEventDeltaY` 驱动层双重累加，经由 `kCGSessionEventTap` 直达当前会话，跳过全系统 HID 过滤链。
  * **多显示器屏幕边界物理吸附**：结合 `CGGetDisplaysWithPoint` 与 `CGDisplayBounds`，防止光标跑飞越界。
  * **零队列延迟直发**：iOS 端 `touchesMoved` 采样直接发送，移除多重线程排队，实现真正毫秒级即时响应。
* **灵敏度规范**：
  * 原先的黄金速度 1.8x 直接在软件中定义为基准「1.0x」。
  * 灵敏度/速度调节完全移到手机端（iOS App）界面中，支持低速 (0.7x) / 标准 1.0x / 高速 (1.4x) 调节。
  * 电脑端（Mac 菜单栏）彻底移除滑块与药丸按钮，保持 Mac 菜单栏极度干净小巧。
* **电脑息屏/未开机状态下的手机端开关机 (Wake-on-LAN + 远程电源管理)**：
  * Mac 端在握手 `host_ack` 中自动携带网卡物理 MAC 地址与当前电源状态。
  * 手机端内置 **Wake-on-LAN (WoL) 魔术包广播器 (`WakeOnLAN.swift`)**：电脑在电视旁睡眠/息屏待机状态（功耗仅 0.5W）下，手机点击「唤醒开机」1 秒瞬间唤醒！
  * 手机端提供「唤醒开机」、「息屏休眠 (睡眠显示器)」、「系统休眠 (0.5W 待机)」、「彻底关机 (Shutdown)」与「系统重启 (Restart)」。
* **GitHub 自动化更新与 SideStore 社区源规范**：
  * 编写完整的 SideStore 社区源清单 (`source.json`) 与 GitHub Actions 自动发布脚本 (`.github/workflows/release.yml`)。
  * 手机端提供「一键添加源至 SideStore (`sidestore://source?url=...`)」与「SideStore 原位安装 (`sidestore://install?url=...`)」，不消耗免费个人开发者 3 个应用名额。
  * 局域网离线回退：Mac 端保留 8923 本地更新 HTTP 托管，无外网时亦可极速升级。
* **纯白苹果原生极简风格 (Apple Minimalist White)**：全中文交互，无冗余无广告，原汁原味 iOS / macOS 质感。

---

## 架构设计 (Architecture)

```
+-------------------------------------------------------------+
|              iOS Native Client (SwiftUI / ProMotion)        |
|                                                             |
|   [ 120Hz 纯白触控板 (解耦队列) ] [ 指针速度调节 (0.7x/1.0x/1.4x) ]|
|   [ Wake-on-LAN 远程唤醒开机 ]    [ 系统休眠 / 关机 / 重启 ]      |
|   [ SideStore 社区源与更新中心 ]  [ Mac 运行程序 Dock 同步 ]      |
+------------------------------+------------------------------+
                               |
       +-----------------------+-----------------------+
       |                                               |
 Apple Multipeer (.unreliable)               Apple Multipeer (.reliable)
 - 16 字节固定紧凑二进制数据包                  - JSON 控制流 (可靠传输)
 - 120Hz 极速投递 (无 TCP 队头阻塞)            - 键盘快捷键 / 中文输入 / Dock
 - 解耦异步网络投递                            - 物理 MAC / 休眠 / 关机 / 重启
       |                                               |
       v                                               v
+-------------------------------------------------------------+
|             macOS Native Host Agent (Swift 6)               |
|                                                             |
|   * Remote Mouse 动态加速度模型 (InputSimulator.swift)       |
|   * 绝对坐标目标定位 (移除 DeltaX/Y 双重累加)                |
|   * kCGSessionEventTap 快速事件注入                          |
|   * 多显示器边界物理吸附 (CGGetDisplaysWithPoint)            |
|   * 本地 HTTP 更新服务 (Port 8923，托管 IPA 与 source.json)  |
+-------------------------------------------------------------+
```

---

## 项目结构 (Repository Structure)

```
├── .github/
│   └── workflows/
│       └── release.yml       # GitHub Actions 自动化构建与发布
├── source.json               # SideStore / AltStore 官方社区源清单
├── apps/
│   ├── desktop-macos/        # macOS 原生菜单栏常驻程序 (Swift 6 + SwiftUI)
│   │   ├── Sources/App/      # 状态管理、生命周期与网卡 MAC 发现
│   │   ├── Sources/Core/     # 一欧元自适应滤波、光标模拟、系统电源控制
│   │   ├── Sources/Network/  # Apple Multipeer 服务端与本地 HTTP 更新服务
│   │   └── Sources/UI/       # 纯白菜单栏小巧面板
│   └── mobile-ios/           # iOS 原生客户端 (SwiftUI)
│       ├── Sources/App/      # 客户端入口与生命周期
│       ├── Sources/Network/  # Multipeer 客户端与 Wake-on-LAN 广播器
│       ├── Sources/UI/       # 触控板(解耦队列)、电源与 SideStore 社区源更新
│       ├── Info.plist        # 本地网络与对等网络配置
│       └── AirControl.xcodeproj # 标准 Xcode 项目工程文件
├── dist/                     # 编译发布产物
│   ├── AirControl.app        # macOS 签名应用程序
│   ├── AirControl.ipa        # iOS 原生独立安装包 (支持 TrollStore / SideStore)
│   └── AirControl-macOS.zip  # macOS 便携分发压缩包
├── spec/
│   └── protocol.md           # 16 字节二进制事件、WoL 与控制协议规范
├── scripts/
│   ├── build-macos.sh        # macOS 独立编译构建脚本
│   └── build-ipa.sh          # iOS arm64 IPA 自动化打包脚本
├── LICENSE
└── README.md
```

---

## 快速使用 (Getting Started)

### 1. 运行电脑端 (macOS)

```bash
# 启动 macOS 菜单栏应用
open dist/AirControl.app
```

> **首次运行提示**：
> macOS 会弹出“辅助功能权限”请求（`系统设置 -> 隐私与安全性 -> 辅助功能`），勾选允许 AirControl 控制光标。
> 菜单栏小图标将常驻，显示当前连接状态、本机 IP 与网卡 MAC 地址。

---

### 2. 安装手机端 (iOS)

手机端安装包位于：[`dist/AirControl.ipa`](dist/AirControl.ipa)

#### 安装与更新方式：
1. **SideStore 社区源安装（强烈推荐）**：
   * 在 iPhone 上安装 SideStore。
   * 点击 App 内的「一键添加源至 SideStore」或手动在 SideStore 中添加源：
     `https://raw.githubusercontent.com/emokeshi/Aircontrol/main/source.json`
   * 点击安装即可。后续更新直接在 SideStore 中原位覆盖更新，**不占用个人免费开发者的 3 个应用名额**！
2. **TrollStore 安装**：
   * 将 `AirControl.ipa` 发送到 iPhone，使用 TrollStore 打开直接一键永久免签安装。
3. **应用内直接下载**：
   * 在 iPhone App 内点击「应用内直接下载 IPA」，下载完成后可直接分享至 TrollStore 或保存到文件。

---

### 3. 电脑未开机/息屏下的远程唤醒 (Wake-on-LAN)

1. 将 Mac 放置在电视机旁，在系统偏好设置中开启 `处于睡眠状态时通过网络唤醒`（Wake for network access）。
2. 在手机端连接过一次电脑后，AirControl 会自动记住 Mac 的物理 MAC 地址。
3. 当电脑处于息屏休眠状态（功耗约 0.5W）时，手机端点击「局域网唤醒开机」，1 秒内即可唤醒 Mac！

---

## 构建方式 (Building from Source)

```bash
# 1. 编译 macOS 应用程序
./scripts/build-macos.sh

# 2. 编译并打包 iOS IPA
./scripts/build-ipa.sh
```

---

## 开源协议 (License)

本项目遵循 [MIT License](LICENSE) 开源协议。
