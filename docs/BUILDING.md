# 构建与运行

## 1. 准备工具链

当前锁定组合的目标平台为 Apple Silicon / macOS 26+，需要支持 Swift 6 的 Xcode 工具链、Python 3.12。Swift 外壳虽声明 macOS 14+，但锁定的 MLX 0.32.0 及其 Metal 运行库使用 macOS 26 arm64 wheel，整套组合不能据此宣称支持 macOS 14。以下命令从仓库根目录运行。源码包不含 Python 解释器、模型或用户设置。

## 2. 安装 Python 依赖（联网，不调用付费模型）

```sh
python3.12 -m venv brain/.venv
brain/.venv/bin/python -m pip install --only-binary=:all: --no-deps -r brain/runtime-requirements.lock
```

这份锁定清单对应受支持的本地路线和可选云端客户端，不是所有上游可选功能的完整环境。安装失败时保留错误信息核对平台与版本，不要自动换成不同版本或安装额外模型后端。

## 3. 下载模型（联网，不需要服务商 Key）

先查看下载计划，再明确执行：

```sh
python3.12 scripts/setup_models.py
python3.12 scripts/setup_models.py --download
python3.12 brain/tools/verify_models.py --group first_release
```

工具只下载清单中的 Qwen3-ASR 0.6B 固定版本、Silero VAD 和可选声纹功能所需的 CAM++ 模型，并逐个校验 SHA-256。已有同名但校验不同的文件不会被覆盖。模型体积约 1 GB，请预留下载及临时文件空间。

Qwen 放在 `~/Library/Application Support/VoiceFlow/models/Qwen3-ASR-0.6B-8bit/`，Silero 放在 `brain/models/`，CAM++ 放在 `brain/models/speaker/campplus.onnx`。如果已使用 Liana，这些模型文件可能已存在；校验一致的文件会复用，不读取历史、声纹登记或 Key。下载模型不会自动开启声纹筛选。

实际运行优先使用 `ASR_QWEN3_06_MODEL` 指定的目录，其次为仓库内 `brain/models/Qwen3-ASR-0.6B-8bit/`，最后才是上述应用支持目录。不要让旧的环境变量或模型副本覆盖刚校验的版本；下面的运行命令明确使用该目录。

## 4. 检查和编译（离线）

```sh
bash build.sh check
bash build.sh build
```

只做这些检查不会启动 Liana、加载语音模型、访问真实钥匙串或调用付费 API。Swift 测试使用注入的假服务操作；Python 测试使用合成文本。首次 Swift 构建会写入本机编译缓存。

## 5. 手动运行

先退出任何已经运行的 Liana，然后在仓库根目录执行：

```sh
LIANA_BRAIN_DIR="$PWD/brain" \
ASR_QWEN3_06_MODEL="$HOME/Library/Application Support/VoiceFlow/models/Qwen3-ASR-0.6B-8bit" \
mac/.build/release/Liana
```

首次运行按 macOS 提示授权麦克风和辅助功能。在空白编辑器中测试听写；首次加载模型可能较慢。默认路线不需要云服务 Key。

本程序为菜单栏应用。若系统请求授权，请在系统设置中确认实际运行的程序；不要关闭系统安全功能，也不要把 Mac 登录密码填入 API Key 输入框。

## 已有用户注意

开发构建仍使用 `com.voiceflow.mac` 与 `~/Library/Application Support/VoiceFlow`，会共享已有设置、历史和钥匙串条目，并不是隔离账号。已有云端开关也可能继续生效。需要干净首次运行测试时，使用独立 macOS 用户或另一台测试设备，不删除现有用户数据。

反复使用不同签名或路径的开发构建可能需要重新授权钥匙串/辅助功能。源码构建及本项目的未公证预览发布不要求购买苹果开发者会员；编译成功不代表升级和权限行为已经验证。预编译包的单应用首次打开步骤见[安装说明](../INSTALL.md)，不要全局关闭系统安全保护。
