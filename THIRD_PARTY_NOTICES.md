# 第三方组件与许可证

Liana 自有源码使用 MIT。第三方模型、解释器与库不是 Liana 的原创作品，各自许可证继续适用。

本仓库不包含模型权重或 Python 运行环境。`brain/model-manifest.json` 记录支持的模型来源、固定版本及逐文件校验值；`brain/runtime-requirements.lock` 固定 Python 依赖版本。`brain/runtime-source-lock.json` 补充部分发行文件的来源与许可证信息，不代替完整二进制分发审计。

| 组件 | 来源 | 许可证 |
| --- | --- | --- |
| Qwen3-ASR 0.6B 8-bit | [MLX 转换与固定版本](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit/tree/89e96d92ba34aca20b3e29fb10cc284097d1219f)，原始模型来自 Qwen | Apache-2.0 |
| Silero VAD v4 | [Silero](https://github.com/snakers4/silero-vad/tree/v4.0)，下载资产由 sherpa-onnx 托管 | MIT |
| CPython | [Python](https://www.python.org/) | PSF 及随附历史声明 |
| SentencePiece | [Google SentencePiece](https://github.com/google/sentencepiece) | Apache-2.0 |
| Tokenizers | [Hugging Face Tokenizers](https://github.com/huggingface/tokenizers) | Apache-2.0 |
| sherpa-onnx | [k2-fsa sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Apache-2.0 |

以上组件的补充许可证正文在 `THIRD_PARTY_LICENSES/`。其他依赖的声明随其发行包提供；打包运行环境时需保留所有适用的 LICENSE、NOTICE、作者与版权声明，不能只复制本表。
