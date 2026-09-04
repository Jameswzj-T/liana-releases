# Liana for macOS · Early Preview

Liana 是一款面向 macOS 的本地优先听写工具：按住热键说话，松开后把文字写入当前光标处。

> 当前版本是免费的早期预览版，不是已完成苹果公证的正式发行版。请先阅读下面的安装提示与隐私边界。

- 系统：macOS 14 或更新版本
- 设备：Apple Silicon（M 系列芯片）
- 版本：`v0.1.0-rc.3`
- 费用：Liana 当前不收费；主动启用第三方云服务时，可能由对应服务商向你收费
- 签名状态：应用经过临时签名，但**尚未使用 Apple Developer ID 签名，也未经过苹果公证**

## 下载

从 [v0.1.0-rc.3 发布页](https://github.com/Jameswzj-T/liana-releases/releases/tag/v0.1.0-rc.3) 下载：

`Liana-0.1.0-rc.3-macos-arm64.zip`

下载后可以在终端核对文件：

```bash
shasum -a 256 ~/Downloads/Liana-0.1.0-rc.3-macos-arm64.zip
```

正确的 SHA-256 是：

```text
601a40b010388396938d9c45deb79c3a4e18730597144c66d391454ea46c4a39
```

完整安装步骤见 [INSTALL.md](INSTALL.md)。

## 它能做什么

- 默认在本机使用 Qwen3-ASR 0.6B 完成中文、英文和中英混合听写；
- 通过全局热键在多数 macOS 输入区域直接落字；
- 进行确定性的断句、标点和格式清理；
- 保存偏好拼写和明确的转写纠正规则；
- 在本机历史记录中查看最终文本和对应原始转写；
- 可选高准确云端转写、智能整理和选中文字增强。

自动整理用于清除口头禅、无意义重复和明显的说话噪音，不应替用户重新写作。翻译、精简、
商务表达和结构化等主动改写操作会先显示预览，只有确认后才替换文字。

## 默认隐私边界

新安装默认使用本地转写，不需要账户，也不上传音频或文字。

云端能力彼此独立，只有用户主动开启并配置自己的 API Key 后才会工作：

| 能力 | 默认状态 | 发往第三方服务的内容 |
|---|---:|---|
| 本地听写 | 开 | 不发送 |
| 高准确云端转写 | 关 | 当前录音及必要的拼写提示 |
| 自动整理听写 | 关 | 当前转写文字，不含音频 |
| 选中文字增强 | 关 | 选中文字和本次指令文字，不含音频 |

API Key 保存在 macOS Keychain。保存 Key 本身不会自动打开云端功能。详细说明见
[PRIVACY.md](PRIVACY.md)。

## 免费版与未来版本

这次早期预览用于验证是否真的有人愿意安装并持续使用。当前安装包不设置付费墙，已有功能均可
测试；需要第三方云服务的功能由用户自行提供 API Key。

Liana 的本地听写核心计划保持免费。未来是否推出专业版、哪些云端和高级工作流进入专业版，
会根据真实使用反馈再决定；本页不构成定价或功能承诺。

## 已知限制

- 尚未经过苹果 Developer ID 签名和公证，首次打开会看到 macOS 安全提示；
- 目前只提供 Apple Silicon 版本；
- 这是候选版本，尚未完成大规模用户与多台 Mac 验证；
- 尚无自动更新，请从本仓库发布页手动下载新版本；
- 云端能力依赖用户选择的第三方服务，其可用性、隐私条款和费用由对应服务商决定。

## 反馈

请在 [Issues](https://github.com/Jameswzj-T/liana-releases/issues) 提交问题。不要公开粘贴 API Key、
私人听写正文、未脱敏日志或录音。安全问题请使用仓库的私密漏洞报告入口。

这个仓库只用于公开下载、安装说明与反馈；开发源码在早期预览阶段仍保存在私有仓库中。

---

## English summary

Liana is a local-first dictation app for Apple Silicon Macs running macOS 14 or later. The default
transcription path stays on your Mac. Optional cloud transcription and text features require explicit
opt-in and your own API key.

This free early preview is ad-hoc signed and **not Apple-notarized**. macOS may block the first launch;
follow [INSTALL.md](INSTALL.md) only if the download and SHA-256 match this repository. Please report
issues without including secrets or private dictated content.
