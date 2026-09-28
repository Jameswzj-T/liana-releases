"""ASR:把本地音频文件转成原始文字。

两种 provider(config.asr_provider):
- local     : 本地 SenseVoice(阿里达摩院,sherpa-onnx/ONNX),~0.3s、离线、免费 ★默认★
              非自回归,比 whisper 快 1~2 个数量级,中文更准、更不易幻觉。
- qwen_cloud: 阿里百炼 qwen3-asr-flash,准确但走网络(VPN 下 ~7s)

结果解析(_extract_text)是纯函数,可单测;模型/SDK 调用惰性导入,
没装 sherpa-onnx/dashscope、没网、CI 都不受影响。
"""
import os
import re
import time
import unicodedata
from pathlib import Path


_BEIJING_API_URL = "https://dashscope.aliyuncs.com/api/v1"


class ASRText(str):
    """兼容 ``str`` 的一次转写结果，同时携带这一次的语言元数据。

    现有调用方大量把 ASR 返回值当普通字符串使用；直接改成 dataclass 会扩大改动面。
    这个值对象保持字符串契约，同时让语言跟着本次结果走，不借用会被长录音探针覆盖的
    模块级全局变量。调用 ``str.strip`` 会得到普通字符串，因此上层必须先读取属性。
    """

    def __new__(cls, text: str = "", detected_languages=()):
        obj = super().__new__(cls, text or "")
        obj.detected_languages = tuple(detected_languages or ())
        return obj


_QWEN_LANGUAGE_NAMES = (
    "Chinese", "English", "Cantonese", "Arabic", "German", "French",
    "Spanish", "Portuguese", "Indonesian", "Italian", "Korean", "Russian",
    "Thai", "Vietnamese", "Japanese", "Turkish", "Hindi", "Malay", "Dutch",
    "Swedish", "Danish", "Finnish", "Polish", "Czech", "Filipino", "Persian",
    "Greek", "Romanian", "Hungarian", "Macedonian",
)
_QWEN_LANGUAGE_CANONICAL = {name.casefold(): name for name in _QWEN_LANGUAGE_NAMES}
_QWEN_LANGUAGE_CANONICAL.update({
    "zh": "Chinese", "zh-cn": "Chinese", "cmn": "Chinese",
    "en": "English", "yue": "Cantonese", "ja": "Japanese", "jp": "Japanese",
    "ko": "Korean", "kr": "Korean",
})


def normalize_detected_languages(value) -> tuple[str, ...]:
    """把 Qwen 的 ``str | list | None`` 收成稳定、去重的语言全名元组。

    当前 mlx-audio 即使单块也返回 ``["English"]``。未知值不猜成英文，而是明确
    标为 ``Unknown``，让后面的规则路由降到最小安全集。
    """
    if value is None:
        items = []
    elif isinstance(value, str):
        items = [value]
    elif isinstance(value, (list, tuple)):
        items = value
    else:
        items = [value]

    out = []
    for item in items:
        if not isinstance(item, str) or not item.strip():
            continue
        canonical = _QWEN_LANGUAGE_CANONICAL.get(item.strip().casefold(), "Unknown")
        if canonical not in out:
            out.append(canonical)
    return tuple(out)



_COMMON_TECH_EN = [
    "Python", "JavaScript", "TypeScript", "React", "Vue", "Node", "Rust", "Golang",
    "Docker", "Kubernetes", "Redis", "Postgres", "MySQL", "MongoDB", "Kafka", "Nginx",
    "GraphQL", "REST", "API", "SDK", "CLI", "TUI", "IT", "ASR", "LLM", "GLM", "JSON", "HTTP", "OAuth", "Webhook",
    "Anthropic", "OpenAI", "Claude", "Claude Code", "ChatGPT", "Gemini", "Llama", "Qwen3", "Qwen3-ASR", "PyTorch",
    "TensorFlow", "Whisper", "Hugging Face", "GitHub", "V2EX", "Linux", "Ubuntu",
    "Cursor", "Copilot", "Codex", "Liana", "Xcode", "Swift", "Kotlin",



    "Next.js", "Node.js", ".env", "CUDA", "ONNX", "PostgreSQL", "cache", "debug",
    "rollback", "commit", "index", "query", "response", "refactor", "log",

]


def common_tech_terms() -> tuple[str, ...]:
    """返回确定性写法层可复用的内置标准词，不暴露可变全局列表。"""
    return tuple(_COMMON_TECH_EN)


def _extract_text(content) -> str:
    """从百炼响应的 content 拼出纯文本。content 可能是 list[dict] 或 str。纯函数,可测。"""
    if isinstance(content, list):
        return "".join(c.get("text", "") for c in content if isinstance(c, dict)).strip()
    return (content or "").strip()


def _to_audio_ref(audio_path: str) -> str:
    """本地路径转成百炼要求的 file:// 绝对路径;已是 URL 则原样透传。"""
    if audio_path.startswith(("http://", "https://", "file://")):
        return audio_path
    return f"file://{os.path.abspath(audio_path)}"



_HALLUCINATIONS = (
    "字幕", "谢谢观看", "謝謝觀看", "谢谢大家", "谢谢大家观看", "请不吝", "請不吝", "订阅", "訂閱",
    "明镜", "明鏡", "独播剧场", "獨播劇場", "优优", "yoyo television",
    "thank you for watching", "thanks for watching", "please subscribe",
)










_WHOLE_HALLUCINATION = (
    "请不吝", "請不吝",
    "点赞订阅", "點贊訂閱", "点赞、订阅", "订阅转发", "訂閱轉發",
    "谢谢观看", "謝謝觀看", "谢谢大家观看", "谢謝大家觀看",
    "字幕由", "字幕组", "字幕組",
    "明镜与点点", "明鏡與點點",
    "独播剧场", "獨播劇場", "yoyo television",
    "thank you for watching", "thanks for watching", "please subscribe",
)


def _looks_like_hallucination(text: str) -> bool:
    """短句且含【只可能是字幕组幻觉】的字串 → 判为空(兜底,主要靠能量检测)。
    ★用窄名单★:见 _WHOLE_HALLUCINATION 上面那段 —— 整句丢弃不能靠"订阅/字幕"这种日常词。"""
    t = text.strip().lower()
    return any(h in t for h in _WHOLE_HALLUCINATION) and len(t) < 30


def _strip_prompt_echo(text: str) -> str:
    """whisper 偶尔把 initial_prompt 的"常用词:…"标签当内容整段回吐(静音/纯外文时尤甚,那次纯英文 auto 吐出"常用词、"就是它)。
    只剥【开头】的这段回声:完整前缀"常用词:…。",或裸标签"常用词"后紧跟标点/结尾时。剥完只剩空 → 判空。
    收得很紧(裸标签必须后接标点/空/结尾才剥),真话里的"常用词有哪些"这种不会被误伤。"""
    if not text:
        return text
    m = re.match(r"\s*常用词\s*[:：].*?[。.]", text)
    if m:
        text = text[m.end():]
    text = re.sub(r"^\s*常用词(?=[、,，。.:：\s]|$)[、,，。.:：\s]*", "", text)
    return text.strip()


def _strip_trailing_hallucination(text: str) -> str:
    """剥掉结尾脑补的致谢类幻觉:whisper 静音/收尾时爱在真内容后面接一句'谢谢大家'/'thanks for watching'。
    只在【句末标点后】命中、且前面还留 ≥8 字实质内容时才剥,尽量不误伤真的收尾语。"""
    for h in _HALLUCINATIONS:
        m = re.search(r"(?<=[。.!！?？])\s*" + re.escape(h) + r"[\s。.!！?？…~]*$", text, re.IGNORECASE)
        if m and len(text[:m.start()].rstrip()) >= 8:
            return text[:m.start()].rstrip()
    return text


def _is_repeat_noise(text: str) -> bool:
    """停顿/噪音里 whisper 常吐的复读幻觉,丢弃:
    ① 单字符重复(甜甜甜);② 短单元长串复读(中文'文化文化…'、英文'flows…'——靠字符多样性极低判,中英通用);
    ③ 英文单词复读(短串靠空格分词兜一道)。"""
    t = re.sub(r"[\s,，。、！？!?.…~～]+", "", text)
    if len(t) >= 3 and len(set(t)) == 1:
        return True
    if len(t) >= 10 and len(set(t)) / len(t) <= 0.25:
        cjk = sum(1 for c in t if "一" <= c <= "鿿")
        if cjk / len(t) > 0.5:
            return True
    words = [w.lower() for w in text.split()]
    if len(words) >= 4:
        most = max((words.count(w) for w in set(words)), default=0)
        if most / len(words) >= 0.85:
            return True
    return False


def _is_noise_token(text: str) -> bool:
    """极短输出若完全不含 Unicode 字母/数字，才按符号噪音丢弃。

    旧规则只承认汉字与 ASCII，导致 ``はい / 네 / да / لا`` 等真实外语短句被清空。
    多语路线不能靠“不是中英文”判断噪音；韩文字母 ``ㅋ`` 也必须保守放行。
    """
    t = re.sub(r"[\s,，。、！？!?.…~～·\-]+", "", text)
    return 0 < len(t) <= 2 and not any(char.isalnum() for char in t)



_NOISE_FILLERS = {
    "the", "a", "an", "i", "you", "yeah", "yes", "no", "oh", "um", "uh", "uhh",
    "mm", "mhm", "hmm", "ah", "huh", "ok", "okay",
    "嗯", "啊", "哦", "呃", "诶", "我", "唉", "哈",
}
_EN_FILLERS = sorted((f for f in _NOISE_FILLERS if f.isascii()), key=len, reverse=True)


def _token_is_filler(tok: str) -> bool:
    t = tok.lower()
    if t in _NOISE_FILLERS:
        return True
    if not t.isascii():
        return False
    i = 0
    while i < len(t):
        for f in _EN_FILLERS:
            if t.startswith(f, i):
                i += len(f)
                break
        else:
            return False
    return True


def _is_all_filler(text: str) -> bool:
    """整段只由噪音填充词(可能粘连,如 'IYes')+ 标点组成 → 多半是噪音/呼吸/咳嗽的幻觉。
    整句层面判:只要句中还有别的实词就不算,不会误伤句子里的"我"。"""
    tokens = re.findall(r"[A-Za-z]+|[一-鿿]", text)
    return bool(tokens) and all(_token_is_filler(t) for t in tokens)



_vad = None


def _vad_model_path() -> str:
    return os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models", "silero_vad.onnx"
    )


def new_vad():
    """造一个【全新的】silero VAD。边说边转要独占一个跨整段录音的实例 —— 不能用下面那个全局单例
    (别处会 reset() 它,会把正在进行的流打断)。"""
    import sherpa_onnx
    c = sherpa_onnx.VadModelConfig()
    c.silero_vad.model = _vad_model_path()
    c.silero_vad.threshold = 0.5
    c.silero_vad.min_speech_duration = 0.1
    c.silero_vad.min_silence_duration = 0.1
    c.sample_rate = 16000
    return sherpa_onnx.VoiceActivityDetector(c, buffer_size_in_seconds=30)


def _get_vad():
    """全局单例(停录后的一次性 VAD 用:_speech_segments / _has_speech,它们每次先 reset)。"""
    global _vad
    if _vad is None:
        _vad = new_vad()
    return _vad


def _as_samples(audio):
    """统一成 16k 单声道 float32 numpy。"""
    import numpy as np
    if isinstance(audio, str):
        import soundfile as sf
        s, _ = sf.read(audio, dtype="float32")
        if getattr(s, "ndim", 1) > 1:
            s = s[:, 0]
        return np.asarray(s, dtype="float32").reshape(-1)
    return np.asarray(audio, dtype="float32").reshape(-1)


_VAD_DETECTION_TARGET_RMS = 0.01
_VAD_DETECTION_MAX_GAIN = 4.0


def _vad_detection_copy(samples):
    """只给 VAD 的低音量检测副本做有限增益，模型仍接收未经放大的原音。

    FLEURS 英语真声样本 RMS 0.0023 时 Silero 判空，放大 4 倍即可检出；静音、白噪音和工频声
    在同一增益下仍判空。增益封顶，避免把任意底噪无限抬高。
    """
    import numpy as np

    arr = np.asarray(samples, dtype="float32").reshape(-1)
    if not arr.size:
        return arr
    rms = float(np.sqrt(np.mean(arr.astype("float64") ** 2)))
    if not np.isfinite(rms) or rms <= 0:
        return arr
    gain = min(
        _VAD_DETECTION_MAX_GAIN,
        max(1.0, _VAD_DETECTION_TARGET_RMS / rms),
    )
    if gain == 1.0:
        return arr
    return np.clip(arr * gain, -1.0, 1.0).astype("float32", copy=False)


def _has_speech(samples) -> bool:
    """silero VAD:这段里有没有人在说话。噪音/呼吸/咳嗽 → False(不转,从源头避免幻觉)。"""
    import numpy as np
    try:
        vad = _get_vad()
        vad.reset()
        x = np.pad(_vad_detection_copy(samples), (0, 512))
        for i in range(0, len(x) - 512, 512):
            vad.accept_waveform(x[i:i + 512])
        vad.flush()
        spoke = not vad.empty()
        while not vad.empty():
            vad.pop()
        return spoke
    except Exception:
        return True



_recognizer = None


def _model_dir() -> str:
    """SenseVoice 模型目录(默认仓库内 models/sense-voice,可用 ASR_MODEL_DIR 覆盖)。"""
    default = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models", "sense-voice"
    )
    return os.environ.get("ASR_MODEL_DIR", default)


def _get_recognizer(config):
    global _recognizer
    if _recognizer is None:
        import sherpa_onnx
        d = _model_dir()
        _recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=os.path.join(d, "model.int8.onnx"),
            tokens=os.path.join(d, "tokens.txt"),
            num_threads=4,
            use_itn=True,
            language="auto",
        )
    return _recognizer


def _run_engine(samples, config, engine) -> str:
    ""


    if engine == "qwen3_06":
        return _transcribe_qwen3_06(samples, config)
    raise ValueError(f"v3 只支持 qwen3_06,收到: {engine}")


def _result_languages(text) -> tuple[str, ...]:
    """取本次结果的语言；非空文字缺元数据时显式记 ``Unknown``。"""
    if not str(text or "").strip():
        return ()
    languages = normalize_detected_languages(
        getattr(text, "detected_languages", None)
    )
    return languages or ("Unknown",)


def _transcribe_segmented_probe(flat, groups, config, engine):
    """逐块转写 + 用探针保守裁决每个块边界的句号。返回拼好的整段文本。"""
    global _last_segment_diag
    import numpy as np
    results = [
        _run_engine(np.concatenate([flat[i] for i in g]), config, engine)
        for g in groups
    ]
    parts = [str(result) for result in results]
    block_languages = [_result_languages(result) for result in results]
    seam_actions = []
    for k in range(1, len(groups)):
        prev, cur = parts[k - 1], parts[k]
        if not prev:
            seam_actions.append("skip_empty")
            continue
        if prev[-1] not in _PROBE_TERMINALS:
            seam_actions.append("no_terminal")
            continue

        left = flat[groups[k - 1][-1]]
        right = flat[groups[k][0]]
        probe_audio = _boundary_probe_audio(left, right)

        probe = str(_run_engine(probe_audio, config, engine))
        separator = _probe_continuation_separator(
            probe,
            split_ratio=_boundary_probe_split_ratio(left, right),
        )
        if separator:


            parts[k - 1] = prev[:-1] + _seam_separator(separator, prev, cur)
            seam_actions.append("soften_terminal")
        else:
            seam_actions.append("keep_terminal")
    detected_languages = tuple(dict.fromkeys(
        language
        for part, languages in zip(parts, block_languages)
        if part.strip()
        for language in languages
    ))
    _last_segment_diag["seam_actions"] = seam_actions
    _last_segment_diag["detected_languages"] = list(detected_languages)
    return ASRText(
        _join_chunks(parts, block_languages),
        detected_languages,
    )


def _transcribe_segmented(samples, config, engine, segs=None) -> str:
    """长音频:VAD 切出说话片段(丢静音/停顿)→ 攒成 ≤_CHUNK_S 秒的块 → 逐块转 → 拼。
    治两件事:① 超长音频平方级爆炸(那次 t_asr=585s)② 中间长停顿白占算力。

    segs:已经切好的语音段。传进来就【不再重切】—— 见 _transcribe_local 里那段说明:
    声纹门控和这里原来各切一次 VAD,中间还把段拼回一整段,是吃字的真凶。
    """
    global _last_segment_diag
    if segs is None:
        segs = _speech_segments(samples)
    flat, groups = _group_indices(segs, _CHUNK_S * 16000)
    block_s = [round(sum(len(flat[i]) for i in g) / 16000, 2) for g in groups]
    boundaries_s, elapsed = [], 0.0
    for seconds in block_s[:-1]:
        elapsed += seconds
        boundaries_s.append(round(elapsed, 2))
    _last_segment_diag = {
        "mode": "segmented",
        "audio_s": round(len(samples) / 16000, 2),
        "engine_s": round(sum(map(len, flat)) / 16000, 2),
        "vad_segments": len(segs),
        "blocks": len(groups),
        "block_s": block_s,
        "boundaries_s": boundaries_s,
        "seam_actions": [],
        "detected_languages": [],
    }
    if not groups:
        return ASRText("")
    return _transcribe_segmented_probe(flat, groups, config, engine)




_SPEAKER_MIN_VERIFY_S = 1.2


_SPEAKER_ABS_FLOOR = 0.2





_SPEAKER_TAIL_REFINE_MIN_S = 2.4
_SPEAKER_TAIL_WINDOW_S = 1.2
_SPEAKER_TAIL_HOP_S = 0.6
_SPEAKER_TAIL_MAX_WINDOWS = 5
_SPEAKER_TAIL_ANCHOR_MIN = 0.35
_SPEAKER_TAIL_RATIO = 0.6
_CLOUD_PROMPT_MAX = 1500


def speaker_gate_on(config) -> bool:
    """声纹门控这次要不要生效(开关开 + 模型在 + 已登记)。stream_asr 也要问,故不带下划线。"""
    from core import speaker
    return bool(getattr(config, "speaker_verify", False)
                and speaker.available() and speaker.is_enrolled())


def _gate_cut(sims, config) -> float:
    ""

















    import statistics
    ratio = getattr(config, "speaker_threshold", 0.5)
    med = statistics.median(sims)
    return max(_SPEAKER_ABS_FLOOR, med * ratio)


def _trim_nonmatching_tail(samples, enrolled, base_cut: float, anchor: float):
    """只裁掉【已放行段】末尾连续的低声纹尾巴。

    声纹门控的粒度原本是 VAD 段。若用户说话后停下、电视仍在说,而 VAD 没有及时封口,
    整段会因前半段像用户而被放行,电视尾巴也就一起进入 ASR。这里用重叠的 1.2 秒上下文
    给最后最多 5 个 0.6 秒核心窗口打分,只在“前面有高分、末尾连续低分”时从第一个低分
    核心窗口处截断。没有高分锚点、窗口不足、声纹模型报错时原样返回。

    这是尾部保护,不是源分离:两个人真正重叠在同一窗口里的声音仍然无法被 CAM++ 抠开。
    """
    import numpy as np
    from core import speaker

    arr = np.asarray(samples, dtype="float32").reshape(-1)
    sr = 16000
    min_len = int(_SPEAKER_TAIL_REFINE_MIN_S * sr)
    if len(arr) < min_len or anchor < _SPEAKER_TAIL_ANCHOR_MIN:
        return arr

    window = int(_SPEAKER_TAIL_WINDOW_S * sr)
    hop = int(_SPEAKER_TAIL_HOP_S * sr)
    starts = list(range(0, len(arr), hop))
    starts = [s for s in starts if len(arr) - s >= hop // 2]
    starts = starts[-_SPEAKER_TAIL_MAX_WINDOWS:]
    if len(starts) < 3:
        return arr

    scored = []
    try:
        for core_start in starts:

            ctx_start = max(0, core_start - (window - hop) // 2)
            ctx_start = min(ctx_start, max(0, len(arr) - window))
            ctx = arr[ctx_start:ctx_start + window]
            if len(ctx) < window:
                continue
            scored.append((core_start, float(speaker.similarity(ctx, enrolled))))
    except Exception:
        return arr

    if len(scored) < 3:
        return arr

    tail_cut = max(base_cut, anchor * _SPEAKER_TAIL_RATIO)
    last_good = -1
    for i, (_start, score) in enumerate(scored):
        if score >= tail_cut:
            last_good = i

    if last_good < 0 or last_good == len(scored) - 1:
        return arr

    trim_at = scored[last_good + 1][0]

    if trim_at < int(_SPEAKER_MIN_VERIFY_S * sr):
        return arr
    return arr[:trim_at]


def gate_segments(segs, config) -> list:
    """给【已切好的语音段】做声纹过滤,返回保留的段。纯段级逻辑 —— 停录后的整段门控和
    录音期的逐块门控共用(后者让声纹的开销落在说话时间里,松键后≈0)。

    【短段放行】短于 _SPEAKER_MIN_VERIFY_S 的段声纹判不准 → 无条件保留(治"短句/小声被吃字"):
    那么短根本无法可靠算声纹,而用户刚按完热键就说话、几乎必然是本人;为过滤把自己的话吃掉是最糟的体验。
    长句(≥阈值时长)按 _gate_cut 算出的【自适应判定线】过滤,别人正常说话(通常是连续长段)仍被挡掉。"""
    from core import speaker
    from concurrent.futures import ThreadPoolExecutor
    segs = [s for s in segs if len(s)]
    if not segs or not speaker_gate_on(config):
        return segs
    enrolled = speaker.read_enrollment()
    min_len = int(_SPEAKER_MIN_VERIFY_S * 16000)


    need = [i for i, s in enumerate(segs) if len(s) >= min_len]
    if not need:
        return segs
    with ThreadPoolExecutor(max_workers=min(6, len(need))) as ex:
        sims = dict(zip(need, ex.map(lambda i: speaker.similarity(segs[i], enrolled), need)))
    cut = _gate_cut(list(sims.values()), config)
    anchor = max(sims.values())






    kept = []
    for i, s in enumerate(segs):
        if i in sims and sims[i] < cut:
            continue
        if i in sims and getattr(config, "speaker_tail_refine", False):
            s = _trim_nonmatching_tail(s, enrolled, cut, anchor)
        kept.append(s)
    return kept


def _speaker_gate(samples, config):
    ""











    import numpy as np
    if not speaker_gate_on(config):
        return samples
    segs = _speech_segments(samples)
    kept = gate_segments(segs, config)
    if len(kept) == len(segs) and all(len(a) == len(b) for a, b in zip(kept, segs)):
        return samples
    return np.concatenate(kept) if kept else np.zeros(0, dtype="float32")


_qwen3_06 = None
_QWEN3_06_MAX_TOKENS = 512
_QWEN3_06_MAX_TOKENS_CAP = 2048
_QWEN3_06_INTERNAL_CHUNK_S = 1200.0
_QWEN3_06_MODEL_NAME = "Qwen3-ASR-0.6B-8bit"
_QWEN3_06_REQUIRED_FILES = (
    "config.json",
    "model.safetensors",
    "preprocessor_config.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
)

_QWEN3_06_WHOLE_S = float(os.environ.get("ASR_QWEN3_06_WHOLE_S", "90"))


def _qwen3_06_model_dir() -> Path:
    """模型路径优先级：显式环境变量 > App 包内模型 > 历史用户目录。

    开发机和旧安装继续使用 ``Application Support``；最终便携 App 把
    模型放在 ``Resources/brain/models`` 后即可断网首启，不依赖这台开发机。
    """
    override = os.environ.get("ASR_QWEN3_06_MODEL", "").strip()
    if override:
        return Path(override).expanduser().resolve()

    brain_root = Path(__file__).resolve().parents[1]
    bundled = brain_root / "models" / _QWEN3_06_MODEL_NAME
    if bundled.is_dir():
        return bundled.resolve()

    return (
        Path.home()
        / "Library/Application Support/VoiceFlow/models"
        / _QWEN3_06_MODEL_NAME
    ).resolve()


def _get_qwen3_06(config):
    """只从明确的本地目录加载 0.6B 8-bit；文件不全就报错，绝不按仓库名联网补。"""
    global _qwen3_06
    if _qwen3_06 is None:
        path = _qwen3_06_model_dir()
        missing = [name for name in _QWEN3_06_REQUIRED_FILES if not (path / name).is_file()]
        if missing:
            raise FileNotFoundError(
                f"Qwen3-ASR-0.6B-8bit 本地模型不完整: {path} (缺少 {', '.join(missing)})"
            )
        from mlx_audio.stt.utils import load_model
        _qwen3_06 = load_model(str(path), lazy=False)
    return _qwen3_06


def _qwen3_06_max_tokens(samples) -> int:
    """长整段按时长放宽输出上限；上限只防截断，不强迫模型生成更多文字。"""
    seconds = len(_as_samples(samples)) / 16000
    estimated = int(seconds * 8 + 64)
    return max(_QWEN3_06_MAX_TOKENS, min(_QWEN3_06_MAX_TOKENS_CAP, estimated))







_QWEN3_06_CTX = os.environ.get("ASR_QWEN3_06_CTX", "") not in ("", "0", "false", "False")
_QWEN3_06_CTX_MAX = 5


def _qwen3_06_prompt(config) -> str | None:
    """开关开且屏幕上下文非空 → 提取前 N 个专名做 system_prompt;否则 None。"""

    if not getattr(config, "asr_qwen3_06_context", _QWEN3_06_CTX):
        return None
    ctx = (getattr(config, "asr_context", "") or "").strip()
    if not ctx:
        return None
    from core import polish
    from core import screen_context
    from core import vocab_context
    terms = screen_context.extract_terms(ctx, _english_words(), limit=_QWEN3_06_CTX_MAX)
    if not terms:
        return None


    standards = polish.read_vocab_terms()
    terms = [vocab_context.canonical_latin_term(term, standards) for term in terms]
    return (
        "以下是当前屏幕中可能出现的专名。只有音频确实说到时才使用这些标准写法，"
        f"不要凭空添加：{', '.join(dict.fromkeys(terms))}"
    )


def _transcribe_qwen3_06(samples, config) -> str:
    ""

    model = _get_qwen3_06(config)
    audio = _as_samples(samples)
    out = model.generate(
        audio,
        max_tokens=_qwen3_06_max_tokens(audio),
        verbose=False,
        system_prompt=_qwen3_06_prompt(config),
        chunk_duration=_QWEN3_06_INTERNAL_CHUNK_S,
    )
    detected_languages = normalize_detected_languages(getattr(out, "language", None))
    text = (getattr(out, "text", "") or "").strip()


    can_use_repeat_guard = bool(detected_languages) and set(detected_languages) <= {
        "Chinese", "English"
    }
    rejected = (
        _looks_like_hallucination(text)
        or (can_use_repeat_guard and _is_repeat_noise(text))
        or _is_noise_token(text)
    )
    return ASRText("" if rejected else text, detected_languages)






_LONG_AUDIO_S = 30

















_SHORT_AUDIO_S = 1.5




























_CLOUD_DIRECT_S = 20



def _latin_token_runs(tokens):
    """找 token 序列里【连续含拉丁字母】的段,返回 [(起, 止), …](含端点索引)。
    SenseVoice 英文按词/子词出 token,词间空格编在 token 前缀里,故连续拉丁 token = 一个英文短语。"""
    runs, i, n = [], 0, len(tokens)
    while i < n:
        if re.search(r"[A-Za-z]", tokens[i]):
            j = i
            while j + 1 < n and re.search(r"[A-Za-z]", tokens[j + 1]):
                j += 1
            runs.append((i, j))
            i = j + 1
        else:
            i += 1
    return runs




_MAX_RESCUE_RUNS = 2


_PROBE_TERMINALS = "。！？.!?"
_PROBE_SOFT_MARKS = "，、；：,;:"


def _probe_continuation_separator(probe: str, split_ratio: float = 0.5) -> str | None:
    ""









    text = (probe or "").strip()
    if not text:
        return None
    body = text.rstrip(_PROBE_TERMINALS + " \n")
    if not body.strip() or any(c in body for c in _PROBE_TERMINALS):
        return None

    marks = [(i, c) for i, c in enumerate(body) if c in _PROBE_SOFT_MARKS]
    if not marks:
        return None
    ratio = min(1.0, max(0.0, float(split_ratio)))
    target = ratio * max(0, len(body) - 1)
    index, mark = min(marks, key=lambda pair: abs(pair[0] - target))
    tolerance = max(1.0, len(body) * 0.20)
    return mark if abs(index - target) <= tolerance else None


def _probe_says_continue(probe: str, split_ratio: float = 0.5) -> bool:
    ""











    return _probe_continuation_separator(probe, split_ratio) is not None


def _boundary_probe_split_ratio(left, right, sample_rate=16000) -> float:
    """返回探针中左侧音频的时长占比，与 ``_boundary_probe_audio`` 使用同一裁剪上限。"""
    edge = _PROBE_EDGE_S * sample_rate
    left_n = min(len(left), edge)
    right_n = min(len(right), edge)
    total = left_n + right_n
    return left_n / total if total else 0.5


def _seam_separator(mark: str, prev: str, cur: str) -> str:
    """把探针软标点安全放回输出；英文 ASCII 标点后保留语法空格。"""
    if mark in ",;:" and not re.search(r"[一-鿿]", prev[-20:] + cur[:20]):
        return mark + " "
    if mark in ",;:":
        return {",": "，", ";": "；", ":": "："}[mark]
    return mark


def _boundary_probe_audio(left, right, sample_rate=16000):
    import numpy as np
    edge = _PROBE_EDGE_S * sample_rate
    return np.concatenate([left[-edge:], right[:edge]])


def _group_into_chunks(segs, cap):
    """把语音片段【攒成 ≤cap 样本的块】(纯逻辑,可测):单段超 cap 的先按窗切;其余顺序累积、要超 cap 就换块。"""
    import numpy as np
    flat = []
    for seg in segs:
        if len(seg) > cap:
            for j in range(0, len(seg), cap):
                flat.append(seg[j:j + cap])
        elif len(seg):
            flat.append(seg)
    chunks, cur, cur_len = [], [], 0
    for seg in flat:
        if cur and cur_len + len(seg) > cap:
            chunks.append(np.concatenate(cur)); cur, cur_len = [], 0
        cur.append(seg); cur_len += len(seg)
    if cur:
        chunks.append(np.concatenate(cur))
    return chunks


def _group_indices(segs, cap):
    """把语音段攒成块,返回每块包含的【段下标】(纯逻辑,可测)。单段超 cap 的先按窗切。"""
    flat = []
    for seg in segs:
        if len(seg) > cap:
            for j in range(0, len(seg), cap):
                flat.append(seg[j:j + cap])
        elif len(seg):
            flat.append(seg)
    groups, cur, cur_len = [], [], 0
    for i, seg in enumerate(flat):
        if cur and cur_len + len(seg) > cap:
            groups.append(cur)
            cur, cur_len = [], 0
        cur.append(i)
        cur_len += len(seg)
    if cur:
        groups.append(cur)
    return flat, groups


_COMPACT_BOUNDARY_LANGUAGES = frozenset({"Chinese", "Cantonese", "Japanese"})


def _compact_script_char(char: str) -> bool:
    """中文/日文常见的不以空格分词字符；仅用于缺语言元数据时的保守回退。"""
    return bool(char) and (
        "\u3400" <= char <= "\u9fff"
        or "\u3040" <= char <= "\u30ff"
        or "\uff66" <= char <= "\uff9f"
    )


def _chunk_boundary_gap(prev: str, cur: str, left_languages=(), right_languages=()) -> str:
    """按正文块语言决定是否在块缝保留一个空格。"""
    if not prev or not cur or prev[-1].isspace() or cur[0].isspace():
        return ""
    labels = {
        language
        for language in tuple(left_languages or ()) + tuple(right_languages or ())
        if language != "Unknown"
    }
    if labels and labels <= _COMPACT_BOUNDARY_LANGUAGES:
        return ""


    if _compact_script_char(cur[0]):
        return ""

    left = prev[-1]
    right = cur[0]
    left_is_word_or_punct = left.isalnum() or unicodedata.category(left).startswith("P")
    return " " if right.isalnum() and left_is_word_or_punct else ""


def _join_chunks(parts, language_groups=None) -> str:
    """按语言把正文块拼回整段；中文/日文紧接，空格型文字保留词界。

    旧实现只认 ASCII，俄文、阿拉伯文和韩文在块缝会粘成一串。``language_groups``
    与 ``parts`` 一一对应；缺元数据时退回 Unicode 脚本判断，不凭文本猜具体语种。
    """
    parts = list(parts)
    language_groups = list(language_groups or [() for _ in parts])
    entries = [
        (str(part), tuple(language_groups[index]) if index < len(language_groups) else ())
        for index, part in enumerate(parts)
        if part
    ]
    if not entries:
        return ""
    out, previous_languages = entries[0]
    for part, languages in entries[1:]:
        out += _chunk_boundary_gap(out, part, previous_languages, languages) + part
        previous_languages = languages
    return out.strip()


_SEAM_LOOK = 10
_PROBE_EDGE_S = 4


def _speech_segments(samples):
    """silero VAD 把音频切成【有人说话】的片段,丢掉静音/停顿。返回 [np.float32 一维, …](可能空=没人说话)。
    仅 VAD 报错时退回"整段一块",绝不丢话。"""
    import numpy as np
    arr = np.asarray(samples, dtype="float32").reshape(-1)
    try:
        vad = _get_vad()
        vad.reset()
        x = np.pad(arr, (0, 512))
        out = []
        for i in range(0, len(x) - 512, 512):
            vad.accept_waveform(x[i:i + 512])
            while not vad.empty():
                out.append(np.asarray(vad.front.samples, dtype="float32"))
                vad.pop()
        vad.flush()
        while not vad.empty():
            out.append(np.asarray(vad.front.samples, dtype="float32"))
            vad.pop()
        return out
    except Exception:
        return [arr]


def _bias_terms(config=None) -> list:
    """扁平版(whisper 弱 initial_prompt / 拿不了分层的路径用):用户词优先 + 上下文在后。"""
    user, context = _bias_terms_layered(config)
    return user + context


def _bias_terms_layered(config=None) -> tuple:
    ""










    from core import polish
    from core import screen_context
    seen = set()

    def dedup(items):
        out = []
        for t in items:
            if t and t.lower() not in seen:
                seen.add(t.lower())
                out.append(t)
        return out

    user = dedup(polish.read_vocab_terms())
    ctx = (getattr(config, "asr_context", "") or "").strip() if config is not None else ""
    context = dedup(screen_context.extract_terms(ctx, _english_words())) if ctx else []
    context += dedup(_COMMON_TECH_EN)
    return user, context


def _cloud_system_prompt(config) -> str:
    ""
















    user, context = _bias_terms_layered(config)
    if not user and not context:
        return ""
    parts = []
    if user:


        parts.append("用户常用词(优先按这些拼写):" + "、".join(user))
    if context:
        parts.append("上下文里可能还会出现:" + "、".join(context))
    return "\n".join(parts)[:_CLOUD_PROMPT_MAX]



_CHUNK_S = 25


_SEAM_LOOK = 10
_PROBE_EDGE_S = 4

def _transcribe_local(audio, config) -> str:
    """本地转写:短音频整段转;长音频(>_LONG_AUDIO_S 秒)走 VAD 切片(去静音 + 分块)。
    最后统一过词库纠错。引擎分发(含 auto 的"探路→重转")在 _run_engine 里。"""
    global _last_snaps, _last_rescue, _last_timing, _last_english_offline, _last_probe
    global _last_pre_vocab, _last_post_vocab, _last_segment_diag
    _last_snaps = []
    _last_rescue = ""
    _last_timing = {}
    _last_english_offline = False
    _last_probe = ""
    _last_pre_vocab = ""
    _last_post_vocab = ""
    _last_segment_diag = {}
    samples = _as_samples(audio)
    if samples.size == 0:
        return ""
    _last_segment_diag = {
        "mode": "whole",
        "audio_s": round(samples.size / 16000, 2),
        "engine_s": round(samples.size / 16000, 2),
        "vad_segments": 0,
        "blocks": 1,
        "block_s": [round(samples.size / 16000, 2)],
        "boundaries_s": [],
        "seam_actions": [],
        "detected_languages": [],
    }
    engine = getattr(config, "asr_engine", "auto")


    long_audio = (samples.size > _LONG_AUDIO_S * 16000
                  and not getattr(config, "asr_cloud", False))



    qwen_whole = (engine == "qwen3_06"
                  and samples.size <= _QWEN3_06_WHOLE_S * 16000)

    if qwen_whole:
        t0 = time.perf_counter()
        samples = _speaker_gate(samples, config)
        if getattr(config, "speaker_verify", False):
            _last_timing["声纹"] = round(time.perf_counter() - t0, 2)
        _last_segment_diag["engine_s"] = round(samples.size / 16000, 2)
        _last_segment_diag["block_s"] = [round(samples.size / 16000, 2)] if samples.size else []
        _last_segment_diag["blocks"] = 1 if samples.size else 0
        if samples.size == 0:
            return ""
        if samples.size > _SHORT_AUDIO_S * 16000 and not _has_speech(samples):
            return ""
        text = _run_engine(samples, config, engine)
    elif long_audio:












        t0 = time.perf_counter()
        segs = _speech_segments(samples)
        if speaker_gate_on(config):
            segs = gate_segments(segs, config)
            _last_timing["声纹"] = round(time.perf_counter() - t0, 2)
            if not segs:
                return ""
        text = _transcribe_segmented(samples, config, engine, segs=segs)
    else:
        t0 = time.perf_counter()
        samples = _speaker_gate(samples, config)
        _last_segment_diag["engine_s"] = round(samples.size / 16000, 2)
        _last_segment_diag["block_s"] = [round(samples.size / 16000, 2)] if samples.size else []
        _last_segment_diag["blocks"] = 1 if samples.size else 0
        if getattr(config, "speaker_verify", False):
            _last_timing["声纹"] = round(time.perf_counter() - t0, 2)
        if samples.size == 0:
            return ""


        if (_SHORT_AUDIO_S * 16000 < samples.size <= _LONG_AUDIO_S * 16000
                and not _has_speech(samples)):
            return ""


        text = _run_engine(samples, config, engine)



    detected_languages = _result_languages(text)
    _last_segment_diag["detected_languages"] = list(detected_languages)
    return ASRText(str(text), detected_languages)


_word_set = None


def _english_words() -> set:
    """系统字典里的英文单词表(词库层「只纠非词」的判据)。v3 保留:screen_context 用。"""
    global _word_set
    if _word_set is None:
        _word_set = set()
        for p in ("/usr/share/dict/words", "/usr/dict/words"):
            try:
                with open(p, encoding="utf-8", errors="ignore") as f:
                    _word_set = {w.strip().lower() for w in f if w.strip()}
                break
            except OSError:
                continue
    return _word_set


def _correction_terms(config=None) -> list:
    ""







    from core import polish
    from core import screen_context
    terms, seen = [], set()

    def add(items):
        for t in items:
            if t and t.lower() not in seen:
                seen.add(t.lower())
                terms.append(t)

    ctx = (getattr(config, "asr_context", "") or "").strip() if config is not None else ""
    if ctx:
        add(screen_context.extract_terms(ctx, _english_words()))
    add(polish.read_vocab_terms())
    return terms


def apply_vocab_postprocess(text: str, config=None) -> str:
    ""







    from core import postprocess
    return postprocess.fix_chunk_seam(text)


def _transcribe_cloud(audio, config) -> str:
    """阿里百炼 qwen3-asr-flash。需要 config.asr_api_key + 网络。"""
    import dashscope

    dashscope.api_key = config.asr_api_key
    dashscope.base_http_api_url = _BEIJING_API_URL
    messages = [{"role": "user", "content": [{"audio": _to_audio_ref(audio)}]}]
    resp = dashscope.MultiModalConversation.call(
        api_key=config.asr_api_key,
        model=config.asr_model,
        messages=messages,
        result_format="message",
        asr_options={"language": config.language, "enable_itn": True},
    )
    status = getattr(resp, "status_code", 200)
    if status != 200:
        raise RuntimeError(
            f"ASR 失败 [{status}] {getattr(resp, 'code', '')}: {getattr(resp, 'message', '')}"
        )
    return _extract_text(resp.output.choices[0].message.content)


_CLOUD_EXT = {"MP3": "mp3", "OGG": "ogg", "FLAC": "flac", "WAV": "wav"}


def _remove_temp_audio(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


def _cloud_audio_file(samples, fmt: str = "MP3") -> str:
    """把 samples 写成临时音频文件发云端。★默认 MP3★——70s 音频 2.21MB→0.38MB(小 5.8 倍),编码只要 0.09s。
    写不出压缩格式(libsndfile 缺编码器)就自动回落 WAV,绝不因此失败。

    ★文件名必须唯一★:分块并发上云时多个线程同时写,固定名会互相踩(踩过——4 块并发全返回同一段乱码)。
    """
    import tempfile
    import numpy as np
    import soundfile as sf
    arr = np.asarray(samples, dtype="float32").reshape(-1)
    fmt = (fmt or "MP3").upper()
    ext = _CLOUD_EXT.get(fmt, "wav")
    fd, path = tempfile.mkstemp(prefix="liana_cloud_asr_", suffix=f".{ext}")
    os.close(fd)
    try:
        if fmt == "WAV":
            sf.write(path, arr, 16000, subtype="PCM_16")
        else:
            sf.write(path, arr, 16000, format=fmt)
        return path
    except Exception:
        _remove_temp_audio(path)
        if fmt == "WAV":
            raise
        fd, wav_path = tempfile.mkstemp(prefix="liana_cloud_asr_", suffix=".wav")
        os.close(fd)
        try:
            sf.write(wav_path, arr, 16000, subtype="PCM_16")
        except Exception:
            _remove_temp_audio(wav_path)
            raise
        return wav_path


def _transcribe_qwen3_flash(samples, config) -> str:
    """★默认云端 ASR★ qwen3-asr-flash(阿里 DashScope,LLM 式 ASR,非 CTC)——专为中英混说训练。
    三模型对决实测(69s 音频):耗时 2.78s(Paraformer 16s、Groq Whisper 2.98s);
    Flask/FastAPI/async/Vue/TypeScript/Kubernetes/Redis/Nginx/Claude 全对(另两个都有垮的);
    中文完美且【自带标点】(Groq 的 Whisper 中文反而更差、且完全没标点)。
    只使用专用 DashScope 转写 key;没 key 返空;网络/额度/超时抛异常 → 上层回落本地。"""
    key = (getattr(config, "asr_cloud_key", "") or "").strip()
    if not key:
        return ""
    fmt = (getattr(config, "asr_cloud_format", None) or "MP3").upper()
    try:
        return _qwen3_once(samples, config, key, fmt)
    except _CloudASRResponseError as exc:
        if fmt == "WAV" or not _is_media_rejection(exc):
            raise
        return _qwen3_once(samples, config, key, "WAV")


class _CloudASRResponseError(RuntimeError):
    def __init__(self, status: int, code: str, message: str):
        self.status = status
        self.code = code or ""
        self.message = message or ""
        super().__init__(f"云端 ASR 失败 [{status}] {self.code}: {self.message}")


def _is_media_rejection(exc: _CloudASRResponseError) -> bool:
    """只有响应明确拒绝音频媒体格式时才值得换 WAV 再上传一次。"""
    if exc.status == 415:
        return True
    code = re.sub(r"[^a-z0-9]", "", exc.code.casefold())
    if (any(word in code for word in ("format", "codec", "mediatype"))
            and any(word in code for word in ("invalid", "unsupported", "reject", "notsupport"))):
        return True
    message = exc.message.casefold()
    subject = any(phrase in message for phrase in (
        "audio format", "media format", "file format", "media type", "audio codec", "codec",
    ))
    rejection = any(phrase in message for phrase in (
        "invalid", "unsupported", "not supported", "reject", "unrecognized",
    ))
    return subject and rejection


def _qwen3_once(samples, config, key: str, fmt: str) -> str:
    """一次 qwen3-asr-flash 调用(指定上传格式)。非 200 抛 RuntimeError;网络异常原样上抛。"""
    import dashscope

    dashscope.api_key = key
    path = _cloud_audio_file(samples, fmt)
    messages = []
    sys_prompt = _cloud_system_prompt(config)
    if sys_prompt:
        messages.append({"role": "system", "content": [{"text": sys_prompt}]})
    messages.append({"role": "user", "content": [{"audio": _to_audio_ref(path)}]})
    try:
        resp = dashscope.MultiModalConversation.call(
            api_key=key,
            model=config.asr_cloud_model,
            messages=messages,
            result_format="message",
            asr_options={"enable_itn": True},
        )
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
    status = getattr(resp, "status_code", 200)
    if status != 200:
        raise _CloudASRResponseError(
            status,
            getattr(resp, "code", ""),
            getattr(resp, "message", ""),
        )
    return _extract_text(resp.output.choices[0].message.content)


def _transcribe_cloud_asr(samples, config) -> str:
    """云端 ASR 统一入口 → qwen3-asr-flash(唯一后端;选型依据见 config.Config 的对决实测)。"""
    return _transcribe_qwen3_flash(samples, config)


def transcribe(audio, config) -> str:
    """把音频转文字。按 config.asr_provider 选本地或云端。"""
    global _last_pre_vocab, _last_post_vocab, _last_segment_diag


    _last_pre_vocab = ""
    _last_post_vocab = ""
    _last_segment_diag = {}
    if config.asr_provider == "local":
        return _transcribe_local(audio, config)
    if config.asr_provider == "qwen_cloud":
        return _transcribe_cloud(audio, config)
    raise ValueError(f"unknown ASR provider: {config.asr_provider}")


def _warm_log(msg: str) -> None:
    """暖机情况追加到 ~/Library/Application Support/VoiceFlow/warm.log。
    外壳把 daemon 的 stderr 丢进 nullDevice,print 看不到 → 留个文件痕迹,排查首句慢用。"""
    try:
        import time
        base = os.path.expanduser("~/Library/Application Support/VoiceFlow")
        os.makedirs(base, exist_ok=True)
        with open(os.path.join(base, "warm.log"), "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} warm {msg}\n")
    except Exception:
        pass


def warm_local(config) -> None:
    ""


    if config.asr_provider != "local":
        return
    import time
    engine = getattr(config, "asr_engine", "qwen3_06")
    t: dict = {}
    try:
        s = time.perf_counter(); _get_vad(); t["vad"] = round(time.perf_counter() - s, 2)
        if engine == "qwen3_06":
            s = time.perf_counter(); _get_qwen3_06(config); t["qwen3_06_load"] = round(time.perf_counter() - s, 2)
            wav = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "warmup.wav")
            if os.path.exists(wav):
                s = time.perf_counter(); _transcribe_qwen3_06(_as_samples(wav), config); t["qwen3_06_run"] = round(time.perf_counter() - s, 2)
            _warm_log(f"ok engine={engine} {t}")
            return
        _warm_log(f"FAILED engine={engine} 非 qwen3_06(v3 唯一引擎)")
    except Exception as e:
        _warm_log(f"FAILED engine={engine} {t} err={type(e).__name__}: {e}")


def _e2e_context(config) -> str:
    """给端到端多模态模型的专名清单(和转写层注入共用同一份词表,别再另立一套)。"""
    user, context = _bias_terms_layered(config)
    return "、".join(user + context[:20])
