# Liana — dictation for your Mac

Tap Right Command, speak, then tap again to insert text into the focused text field. The speech model runs locally by default. Enable optional cloud tools when you want help rewriting a draft.

**[Download Liana 0.1.0](https://github.com/Jameswzj-T/liana-releases/releases/tag/v0.1.0)** · [Installation](INSTALL.md) · [Privacy](PRIVACY.md) · [Feedback](https://github.com/Jameswzj-T/liana-releases/issues)

Requires **Apple Silicon and macOS 26+**. The model and Python runtime are included, about 1.09 GB. No Intel build or automatic updater.

> Ad-hoc signed, with **no Apple Developer ID signature or Apple notarization**. macOS may block first launch. Use Apple's per-app approval flow only if you trust the download; do not disable system security globally.

## What it does

- Dictate Chinese, English, or mixed-language speech into a focused macOS text field. Recognition and app compatibility vary; check the result.
- Use local dictation without a Liana account, provider key, separate Python installation, or model download.
- Keep preferred spellings and explicit transcription corrections locally. Review and copy transcripts from history.
- Optionally enable cloud transcription, automatic cleanup, or selected-text rewriting with your own provider key.
- Review a selected-text preview, choose **Copy candidate**, then return to your editor, confirm the selection, and paste yourself. Copying replaces the clipboard contents; it does not automatically replace text in another app.

0.1.0 freezes this feature set. It includes RC7 hotkey recovery and a further cancellation recovery fix. Experimental diagnostic builds and later vocabulary/history candidates are excluded.

## Quick start

1. Download `Liana-0.1.0-macos-arm64.zip` and `SHA256SUMS.txt` from the [release](https://github.com/Jameswzj-T/liana-releases/releases/tag/v0.1.0). Verify in Terminal:

   ```sh
   cd ~/Downloads
   shasum -a 256 -c SHA256SUMS.txt
   ```

   Stop if the checksum differs. A match confirms the release file's identity; it is not Apple safety certification.

2. Unzip and drag `Liana.app` to Applications. Follow [Installation](INSTALL.md) if macOS blocks it.
3. Allow Microphone and Accessibility when requested. Focus a blank editor, tap **Right Command**, say a short sentence, and tap again to finish.
4. For optional rewriting, enable the text feature and configure a provider key first. Select text, tap **Right Option**, speak an instruction, and tap again. Review, copy the candidate, then paste manually.

Tap; do not hold. Existing shortcuts and feature switches are retained. Use the shortcut shown in Settings if you customized it.

## Data and fees

| Feature | New-install default | Data sent to a provider |
| --- | --- | --- |
| Local dictation | On | None |
| Cloud transcription | Off | Current recording and spelling hints |
| Automatic text cleanup | Off | Current transcript |
| Selected-text rewriting | Off | Selected text and instruction text |

The source is MIT-licensed and the download has no Liana subscription fee. Optional providers charge separately. Saving a key does not enable cloud features. **Save and test / Test service** explicitly calls a provider and may cost money even with cloud switches off. Provider policies apply to data you choose to send.

Keys stay in macOS Keychain. History, vocabulary, corrections, and settings are local. Default logs contain diagnostic metadata; explicit content diagnostics can include text, and old logs are not automatically cleared. Existing installations retain cloud switches and data. [Privacy details](PRIVACY.md).

## Limits and verification

Recognition and AI cleanup can change names, numbers, times, languages, quotations, or intent. Review important content. Earlier model tests found omissions and unwanted rewriting; 0.1.0 does not claim those problems are solved or advertise an accuracy rate. Cloud tools are optional and off by default.

Package checks cover locked models/dependencies, relocation, native library paths, signatures, archive integrity, and private-file exclusion. Synthetic offline tests are not a clean-device install, microphone test, physical-hotkey acceptance, or a guarantee of every editor's compatibility. New-device permissions and long-term use remain limited. History is not a document backup; disk errors can prevent persistence.

Keep the previous app/ZIP for rollback and quit before replacing the app; do not delete user data or stored keys. [RC6](https://github.com/Jameswzj-T/liana-releases/releases/tag/v0.1.0-rc.6) remains available. See [Release notes](releases/v0.1.0.md).

## Feedback and source

[Report real-use problems](https://github.com/Jameswzj-T/liana-releases/issues) with your chip, macOS/Liana version, target app, and local/cloud settings. Use a synthetic example; do not publish keys, private text, recordings, or full logs. Security reports belong in [private vulnerability reporting](https://github.com/Jameswzj-T/liana-releases/security/advisories/new).

This public repository contains product source, synthetic tests, docs, approved demo assets, and licenses. Private development history and user data are excluded. See [Building](docs/BUILDING.md), [中文源码说明](docs/SOURCE_OVERVIEW_ZH.md), and [third-party notices](THIRD_PARTY_NOTICES.md). Third-party components retain their licenses.

## 中文简介

Liana 是 Mac 口述转文字、需要时润色的小工具。点一下右侧 Command 开始说话，再点一下结束，文字写入当前文本框。支持中文、英文及中英混说；新安装默认本地转写，模型和运行环境随包提供，无需账号或 API Key。

0.1.0 是本次定型版本，要求 Apple Silicon、macOS 26 及以上。选中文字的云端改写需主动开启并自备 Key，先预览，再“复制候选”，回编辑器确认选区后自行粘贴。复制会覆盖剪贴板内容，不自动替换。云端可能另收费；时间、数字、引文和改口需检查，不承诺模型完全正确。

安装包为临时签名，未做 Apple Developer ID 签名和公证。首次打开按[安装说明](INSTALL.md)的单应用流程，不关闭全局安全保护。已有设置、历史、Key 和快捷键沿用，不运行多个副本或删除重装。欢迎实际使用后反馈，私人正文与凭据请勿公开。
