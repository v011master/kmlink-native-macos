# KMLink Native for macOS

一个面向 Apple Silicon 的实验性 macOS 菜单栏程序，用于驱动部分基于
OTi/GO! Bridge 方案的 USB 键鼠共享线，并与 Windows 电脑共享键盘、鼠标和
文本剪贴板。

项目最初用于替代一套只能稳定运行在旧版 Intel macOS 环境中的 MacKMLink
软件。它通过 IOKit/SCSI 直接访问设备，并在必要时临时调用用户自己安装的
旧版 MacKMLink，实现兼容的双向文本剪贴板。

> 本项目与 SANWA、OTi、GO! Bridge 或相关硬件厂商没有隶属或授权关系。
> 仓库不包含固件、厂商应用、私有 framework 或其他专有二进制。

## 已验证功能

- 识别 USB 设备 `VID 0x0EA0 / PID 0x2213`
- Apple Silicon 原生构建
- 键盘输入与按键释放
- 鼠标移动、单击和滚轮
- Mac -> Windows 文本剪贴板
- Windows -> Mac 文本剪贴板
- 菜单栏状态、诊断和手动测试
- 无设备环境下的协议编码/解码测试

双向剪贴板的稳定兼容路径目前仍需要用户合法取得并安装旧版
`MacKMLink.app`。纯原生剪贴板传输保留为协议研究功能。

## 系统要求

- macOS 13 或更高版本
- Apple Silicon Mac；Intel Mac 未作为主要目标测试
- Xcode Command Line Tools / Swift 5.9+
- 兼容的 USB 键鼠共享线
- Windows 端已安装该共享线对应的软件
- 使用兼容剪贴板模式时：Rosetta 2 和旧版 `MacKMLink.app`

## 快速安装

```bash
git clone https://github.com/ccloving2007/kmlink-native-macos.git
cd kmlink-native-macos
./scripts/build-app.sh
open build/KMLinkNative.app
```

首次启动后，请在“系统设置 -> 隐私与安全性 -> 辅助功能”中允许
`KMLink Native` 控制电脑。

完整步骤、旧版应用路径配置和验证方法见
[安装文档](docs/installation.zh-CN.md)。

## 使用

程序启动后常驻菜单栏。建议先使用菜单中的诊断和测试动作确认设备状态，再开启
需要的转发模式。

- 观察模式只记录本机输入。
- 镜像转发会同时保留本机输入并发送到 Windows。
- 远端独占模式会抑制本机输入并发送到 Windows。
- `Control + Option + Command + K` 可退出远端独占模式。

设备传输使用独占 SCSI 会话。请不要同时运行多个 KMLink Native 实例，也不要
让旧版 MacKMLink 长期占用设备；兼容剪贴板功能会在需要时自行启动旧宿主。

## 构建与测试

```bash
# 构建菜单栏应用
./scripts/build-app.sh

# 无硬件协议回归
./scripts/regression.sh --no-device

# 连接设备后的完整回归
./scripts/regression.sh

# Windows 端人工验收
./scripts/interactive-acceptance.sh
```

涉及可见键盘、点击和滚轮操作的测试默认不会自动执行，避免误操作当前 Windows
窗口。

## 文档

- [项目背景](docs/background.zh-CN.md)
- [安装与配置](docs/installation.zh-CN.md)
- [故障排查](docs/troubleshooting.zh-CN.md)
- [协议研究笔记](docs/protocol-notes.md)
- [第三方组件说明](THIRD_PARTY_NOTICES.md)

## 当前限制

- 只验证了 `0EA0:2213` 这一类设备。
- 剪贴板目前只面向文本，文件和图片传输不属于稳定功能。
- 应用由用户本地构建并使用 ad-hoc 签名，没有 Apple 公证。
- 兼容剪贴板依赖旧版厂商程序，不能随本项目重新分发。
- 协议来自兼容性研究，其他固件版本可能表现不同。

## 许可证

本项目源码采用 [MIT License](LICENSE)。厂商软件、固件和私有 framework
不在此许可证范围内。

