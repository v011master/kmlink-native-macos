# 故障排查

## 找不到 USB 设备

运行：

```bash
system_profiler SPUSBDataType
diskutil list
```

已验证设备的 VID/PID 为 `0x0EA0/0x2213`。如果型号不同，当前程序可能需要新增
设备匹配或协议适配。

## 出现 `transport-busy` 或 SCSI exclusive 错误

- 退出旧版 MacKMLink 和 GoBridgeDemon。
- 确认没有第二个 KMLink Native 实例。
- 等待几秒后重试。
- 必要时拔插共享线。

设备会同时暴露小磁盘和 `MacKMLink` CD-ROM。程序会在原生 SCSI 操作前卸载
这些介质，以取得独占会话。

## 键盘或鼠标无响应

- 检查“系统设置 -> 隐私与安全性 -> 辅助功能”权限。
- 重新启动 KMLink Native。
- 先运行 `--self-test` 和 `--test-hid-release`。
- 确认 Windows 端共享线软件处于活动状态。

如果远端独占模式导致本机输入被抑制，按
`Control + Option + Command + K` 退出。

## 剪贴板发送或接收失败

确认旧版兼容组件路径：

```bash
test -x "${KMLINK_LEGACY_APP_PATH:-$HOME/Library/MacKMLinkFull/MacKMLink.app}/Contents/MacOS/MacKMLink"
```

Apple Silicon 还需要 Rosetta 2：

```bash
arch -x86_64 /usr/bin/true
```

接收测试会先输出：

```text
clipboard.receive.ready: true
```

看到该行后，再在 Windows 端执行复制。旧宿主日志保存在：

```text
~/Library/Logs/KMLinkNative/
```

关键诊断字段：

- `connected=true`：旧宿主已连接 Windows。
- `sawTransferClipboard=true`：看到了远端剪贴板消息。
- `sawPasteboardUpdate=true`：旧宿主已写入 macOS pasteboard。
- `sawClipboard39=true`：Mac 端已发出剪贴板 XML 命令。

## 虚拟 `MacKMLink` CD-ROM 不再出现

某些失败的独占会话后，虚拟 CD-ROM 可能暂时不再枚举。拔掉共享线，等待几秒，
再重新插入。正常情况下 `diskutil list` 会再次看到 `MacKMLink` 分区。

## 收集诊断

```bash
build/KMLinkNative.app/Contents/MacOS/KMLinkNative --diagnose
build/KMLinkNative.app/Contents/MacOS/KMLinkNative --self-test
```

提交 issue 时请删除序列号、用户名、剪贴板正文和其他个人信息。不要上传厂商
安装包、私有 framework 或 cookies。

