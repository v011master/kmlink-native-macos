# 项目背景

## 为什么做这个项目

一些 USB 键鼠共享线可以把一套键盘和鼠标连接到两台电脑，并通过专用软件在
macOS 与 Windows 之间切换输入、同步剪贴板。这类产品中有一部分使用
OTi/GO! Bridge 方案，macOS 端软件名为 MacKMLink。

原厂软件能够工作，但版本较老，主要以 Intel `x86_64` 形式发布。在 Apple
Silicon Mac 上，它需要 Rosetta 2，且可能出现启动缓慢、自动退出、设备独占
失败或剪贴板不稳定等问题。公开渠道也很难找到持续维护的新版本。

KMLink Native 的目标不是重新分发或修改厂商软件，而是：

1. 用现代 Swift 和 macOS 系统 API 实现键鼠转发的原生路径。
2. 记录设备的 USB/SCSI 通信形态，形成可复现的兼容性研究。
3. 在纯原生剪贴板协议尚未完全稳定时，提供一个受控的旧宿主兼容桥。
4. 给同类硬件用户一个可审计、可构建、可继续维护的基础。

## 技术路线

设备在 macOS 上会暴露小型磁盘/CD-ROM 与 SCSI 服务。程序通过 IOKit 和
SCSI task 接口打开设备，使用已确认的厂商 CDB 发送 12 字节 HID 报告和
64 KiB 数据帧。

主要模块包括：

- `USBDeviceMonitor`：识别目标 VID/PID 和插拔状态。
- `OTiHIDTransport`：发送键盘、鼠标和滚轮 HID 报告。
- `EventTapMonitor`：捕获本机输入并实现观察、镜像和远端独占模式。
- `ClipboardUPipeMessage`：编码和解析 GO! Bridge 文本剪贴板消息。
- `OTiDataProbe`：执行原生数据通道探针。
- `LegacyClipboardBridge`：按需启动用户本机已有的旧版 MacKMLink，完成
  已验证的双向文本剪贴板兼容路径。

## 已完成的真实设备验证

在一台 Apple Silicon Mac 与 Windows 11 电脑之间，使用
`VID 0x0EA0 / PID 0x2213` 设备完成了以下人工验收：

- 键盘输入和按键释放正常。
- 鼠标移动、左键和滚轮正常。
- Mac 复制的文本可在 Windows 粘贴。
- Windows 复制的文本可写入 macOS pasteboard。

项目同时保留命令行诊断、协议编解码测试和人工验收脚本，便于区分 USB 枚举、
SCSI 独占、旧宿主连接和剪贴板消息层的问题。

## 开源边界

仓库只发布自行编写的源码和研究笔记，不包含：

- MacKMLink、GoBridgeDemon 或其他厂商应用；
- `OTiTransfer.framework`、`KMClipboard.dylib` 等私有组件；
- SANWA 或其他厂商固件；
- 从厂商网站下载的页面、cookies 或安装包；
- 本机日志和构建产物。

兼容模式要求用户自行确认其拥有使用旧版软件的权利。本项目不提供绕过授权、
篡改固件或重新分发专有程序的功能。

## 项目状态

这是硬件特定的实验性项目，而不是通用 KVM 驱动。键鼠路径已经可用；文本
剪贴板通过兼容桥完成了双向验证；纯原生剪贴板数据通道仍保留为研究功能。

