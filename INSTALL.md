# Install the Liana early preview

> This guide is for **RC5**. [RC4](https://github.com/Jameswzj-T/liana-releases/releases/tag/v0.1.0-rc.4) remains available as a previous release. RC5 requires Apple Silicon and macOS 26+. It is an unnotarized open-source preview; follow the per-app steps below rather than disabling system protection.

[中文安装说明](#安装-liana-早期预览版)

## Before downloading

- **Apple Silicon Mac** (M-series chip); Intel Macs are not supported.
- **macOS 26 or later.**
- Microphone permission for recording, and Accessibility permission for the global hotkey and inserting text.
- The RC5 ZIP is about **1.07 GB**. The speech model and runtime are included; you do not need to install Python or download a separate model.

This is a free open-source early preview. It is ad-hoc signed, but has **no Apple Developer ID signature and is not Apple-notarized**. macOS may block its first launch. If you are not comfortable approving this app, do not install the prebuilt download. Source and [build instructions](docs/BUILDING.md) are available separately; a future notarized release is not promised.

## Download and verify

1. On the [RC5 release page](https://github.com/Jameswzj-T/liana-releases/releases/tag/v0.1.0-rc.5), download `Liana-0.1.0-rc.5-macos-arm64.zip` and `SHA256SUMS.txt` from **Assets**.
2. If the ZIP is in your Downloads folder, run this in Terminal:

   ```bash
   shasum -a 256 ~/Downloads/Liana-0.1.0-rc.5-macos-arm64.zip
   ```

3. The hash at the start of the output must be:

   ```text
   83eb30a9ea5fce180eb464849600aaf5c08deb427eaf932b0a94a8a9aed8eefe
   ```

If it differs, do not open the app. Download it again from this repository. A matching hash confirms that your file matches this release; **it is not an Apple safety certification**.

## First launch

Only continue if you trust the preview and have checked its source and hash.

1. Unzip the archive and drag `Liana.app` into **Applications**.
2. Try opening Liana once. If macOS blocks it, dismiss the notice.
3. Open **System Settings → Privacy & Security**, then find Liana in the Security section and use **Open Anyway**, if available.
4. Confirm the system prompt. Depending on your macOS version, the wording may differ and macOS may ask you to authenticate.

See [Apple's explanation of opening an app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac). Do not disable Gatekeeper globally. If macOS reports malware, the file hash differs, or the expected option is unavailable, stop and report the exact warning instead of trying additional bypass commands.

## Permissions and your first dictation

1. Allow **Microphone** access when requested.
2. Allow **Accessibility** access for Liana in System Settings. Restart Liana if macOS asks you to.
3. Open Notes or TextEdit and place the cursor in a blank text field.
4. Tap **Right Command** once, say a short ordinary sentence, then tap it again to finish and insert text. Do not hold it down. Use the shortcut shown in Liana Settings if you have customized it.

Start with the default local route. It needs no Liana account or API key. **Right Option** is the new-install shortcut for selected-text rewriting: select text first, then tap it to open the panel and speak an instruction. This optional cloud text feature must be enabled and configured before requesting a rewrite; approve the preview before replacement.

If no text appears, check that Liana is running, both permissions are enabled, and the text field has focus. For unresolved problems, [report an issue](https://github.com/Jameswzj-T/liana-releases/issues) with your Mac chip, macOS version, target app, and the warning or behavior you saw. Do not include API keys, private text, recordings, or full logs. Security issues belong in [private vulnerability reporting](https://github.com/Jameswzj-T/liana-releases/security/advisories/new).

## Local and optional cloud features

Local dictation is the default. Cloud transcription, automatic text cleanup, and selected-text rewriting are off on a new installation.

- High-accuracy cloud transcription sends audio and spelling hints to Qwen.
- Automatic text cleanup sends the transcript, without audio, to a text service.
- Selected-text rewriting sends selected text and your instruction text, without audio, and previews the result before replacement.

Each cloud feature needs opt-in and your own provider key. Saving a key does not enable a feature. **Save and test / Test service** explicitly sends a fixed test sentence or generated one-second silent clip and may incur a small charge, even when cloud dictation switches are off. Keys stay in macOS Keychain. See [Privacy](https://github.com/Jameswzj-T/liana-releases/blob/main/PRIVACY.md).

## Updates and removal

There is no automatic updater in this preview. Check this repository's releases for later versions.

To update, quit Liana, keep a copy of the previous ZIP if you want to roll back, then replace `Liana.app` in Applications with the new copy. Avoid keeping multiple extracted copies in different folders. Your existing settings, history, cloud switches, and saved custom shortcuts are retained; a new ad-hoc build may request Accessibility or Keychain authorization again. Do not delete stored keys to work around an authorization prompt.

To remove the app, quit Liana and move `Liana.app` from Applications to the Trash. Removing the app does not automatically remove its local settings/history, macOS permission entries, or Keychain credentials. This preview has no one-click data-cleanup tool.

---

# 安装 Liana 早期预览版

## 运行要求

- Apple Silicon Mac（M 系列芯片）
- macOS 26 或更新版本
- 麦克风权限
- 辅助功能权限（用于全局热键及把文字写入当前光标处）

## 下载与校验

1. 从 [RC5 发布页](https://github.com/Jameswzj-T/liana-releases/releases/tag/v0.1.0-rc.5)
   下载 `Liana-0.1.0-rc.5-macos-arm64.zip` 和 `SHA256SUMS.txt`。
2. 建议在终端运行：

   ```bash
   shasum -a 256 ~/Downloads/Liana-0.1.0-rc.5-macos-arm64.zip
   ```

3. 结果必须是：

   ```text
   83eb30a9ea5fce180eb464849600aaf5c08deb427eaf932b0a94a8a9aed8eefe
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

默认本地听写无需 API Key。云端听写能力只有在你主动打开相应开关并保存自己的 Key 后才会发送数据。设置中的“保存并测试／测试服务”会主动发送固定测试句或生成的一秒静音片段，可能产生少量费用，即使听写开关仍关闭；本地钥匙串授权本身不调用云服务。

## 更新

退出 Liana 后，用新版本替换“应用程序”中的 `Liana.app`。想要回退时，保留上一版 ZIP 即可，避免在多个目录保留解压后的同名应用。现有设置、历史、云端开关及已保存的自定义快捷键会保留；新临时签名版本可能再次请求辅助功能或钥匙串授权，不要为消除提示而删除已有 Key。

## 卸载

退出 Liana 后，将“应用程序”中的 `Liana.app` 移到废纸篓即可。macOS 的权限、Keychain 凭证及
本地设置不会因为删除应用自动清除；早期预览版暂未提供一键清理工具。

## 补充：首次听写与预览边界

新安装默认听写热键为**右侧 Command**；若已自定义，以设置页为准。在备忘录或文本编辑的空白输入框，点一下开始说话，再点一下结束并查看落字，不用一直按住。默认本地听写无需填写任何 Key。

默认**右侧 Option**用于选中文字改写：先选中文字，再点一下打开面板并说出指令，再点一下结束；确认预览后才替换。此项云端文字功能需先主动启用并配置自己的服务商 Key。

RC5 下载约1.07GB，模型与运行环境已包含，无需另装 Python。此版没有 Developer ID 签名和苹果公证；如果你不愿为该应用单独确认打开，请不要安装预编译包，也可查看[源码构建说明](docs/BUILDING.md)。本项目不承诺未来提供公证版。哈希一致只说明文件与发布附件一致，不代表苹果安全认证。遇到恶意软件警告、哈希不同或没有预期的打开选项时，请先停止并反馈，不尝试额外绕过命令。

暂不提供自动更新。本地历史也不会随移除 App 自动清除。反馈请使用本仓库 Issues 并先脱敏；不要公开 Key、私人正文、录音或完整日志。
