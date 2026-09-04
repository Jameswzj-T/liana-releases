# 安装 Liana 早期预览版

## 运行要求

- Apple Silicon Mac（M 系列芯片）
- macOS 14 或更新版本
- 麦克风权限
- 辅助功能权限（用于全局热键及把文字写入当前光标处）

## 下载与校验

1. 从 [RC3 发布页](https://github.com/Jameswzj-T/liana-releases/releases/tag/v0.1.0-rc.3)
   下载 `Liana-0.1.0-rc.3-macos-arm64.zip`。
2. 建议在终端运行：

   ```bash
   shasum -a 256 ~/Downloads/Liana-0.1.0-rc.3-macos-arm64.zip
   ```

3. 结果必须是：

   ```text
   601a40b010388396938d9c45deb79c3a4e18730597144c66d391454ea46c4a39
   ```

如果结果不同，请不要打开应用，并从本仓库重新下载。

## 首次打开

这个早期预览版尚未经过苹果公证，因此双击时 macOS 可能阻止打开。请确认文件来自本仓库且哈希
一致后，再按下面的系统标准流程操作：

1. 解压 ZIP，把 `Liana.app` 拖入“应用程序”；
2. 尝试打开一次，macOS 出现提示后关闭提示；
3. 打开“系统设置” → “隐私与安全性”；
4. 在安全性区域找到刚被阻止的 Liana，点击“仍要打开”；
5. 再次确认打开。

苹果的官方说明：
[安全地打开 Mac 上的 App](https://support.apple.com/zh-cn/guide/mac-help/mh40616/mac)。

不要使用会全局关闭 Gatekeeper 的命令。

## 授予权限

首次使用时：

- 允许麦克风权限，以便录音；
- 允许辅助功能权限，以便监听全局热键并把结果写入当前应用；
- 如果系统要求重启 Liana，请退出后重新打开。

默认本地听写无需 API Key。云端能力只有在你主动打开相应开关并保存自己的 Key 后才会发送数据。

## 卸载

退出 Liana 后，将“应用程序”中的 `Liana.app` 移到废纸篓即可。macOS 的权限、Keychain 凭证及
本地设置不会因为删除应用自动清除；早期预览版暂未提供一键清理工具。
