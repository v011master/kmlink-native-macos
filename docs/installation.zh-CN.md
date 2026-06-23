# 安装与配置

## 1. 准备环境

安装 Xcode Command Line Tools：

```bash
xcode-select --install
```

确认 Swift 版本：

```bash
swift --version
```

项目要求 Swift 5.9 或更高版本，并以 macOS 13 为最低部署目标。

## 2. 获取源码

```bash
git clone https://github.com/ccloving2007/kmlink-native-macos.git
cd kmlink-native-macos
```

## 3. 可选：准备旧版剪贴板兼容组件

键鼠原生功能不要求仓库包含厂商 framework。当前经过真实设备验证的双向文本
剪贴板兼容模式，需要用户自己合法安装旧版 `MacKMLink.app`，并需要 Rosetta 2。

安装 Rosetta 2：

```bash
softwareupdate --install-rosetta --agree-to-license
```

默认查找路径为：

```text
~/Library/MacKMLinkFull/MacKMLink.app
```

如果应用位于其他位置，请在启动或测试前设置：

```bash
export KMLINK_LEGACY_APP_PATH="/path/to/MacKMLink.app"
```

如果你自己配置了会反复拉起旧应用的 LaunchAgent，可选设置：

```bash
export KMLINK_LEGACY_LAUNCH_AGENT_PATH="$HOME/Library/LaunchAgents/your-agent.plist"
```

仓库不会下载、安装或分发上述厂商软件。

## 4. 构建应用

```bash
./scripts/build-app.sh
```

生成文件：

```text
build/KMLinkNative.app
```

直接启动：

```bash
open build/KMLinkNative.app
```

也可以把应用复制到 `/Applications`：

```bash
cp -R build/KMLinkNative.app /Applications/
open /Applications/KMLinkNative.app
```

这是本地 ad-hoc 签名构建，不经过 Apple 公证。若系统阻止首次打开，请在 Finder
中右键应用并选择“打开”，或在“系统设置 -> 隐私与安全性”中确认。

## 5. 授予辅助功能权限

键盘和鼠标捕获依赖 macOS 辅助功能权限。

1. 打开“系统设置”。
2. 进入“隐私与安全性 -> 辅助功能”。
3. 允许 `KMLink Native` 控制电脑。
4. 如权限未立即生效，退出并重新打开应用。

## 6. 连接设备

1. 将共享线连接到 Mac 与 Windows 电脑。
2. 确认 Windows 端对应软件已启动。
3. 启动 KMLink Native。
4. 从菜单栏查看 USB、辅助功能和传输状态。

不要同时运行多个 KMLink Native 实例。旧版 MacKMLink 也不应长期驻留占用
设备；兼容剪贴板功能会在需要时临时启动它。

## 7. 验证

无设备构建与协议测试：

```bash
./scripts/regression.sh --no-device
```

连接设备后的基础诊断：

```bash
build/KMLinkNative.app/Contents/MacOS/KMLinkNative --self-test
```

完整设备回归：

```bash
./scripts/regression.sh
```

Windows 端键盘、鼠标、滚轮和双向剪贴板人工验收：

```bash
./scripts/interactive-acceptance.sh
```

脚本会在每个会产生可见输入的动作前询问，不会直接对 Windows 当前窗口执行
点击或打字。

## 8. 登录时启动

确认程序稳定后，可在“系统设置 -> 通用 -> 登录项”中添加
`KMLinkNative.app`。建议先完成一次完整人工验收，再设置自动启动。

