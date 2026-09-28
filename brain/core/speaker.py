"""声纹「只听我」:登记一次用户的声音 → 之后只放行声纹匹配的语音段(逐段门控)。

sherpa-onnx SpeakerEmbeddingExtractor 算声纹向量(归一化),余弦相似度比对。
纯逻辑(除模型加载/存盘外),可脚本自证。默认关:没登记 = 管线完全不碰(行为跟现在一样)。
模型:3D-Speaker CAM++ 中英通用(models/speaker/campplus.onnx)。
"""
import os

_extractor = None


def _model_path() -> str:
    return os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models", "speaker", "campplus.onnx"
    )


def _enroll_file() -> str:
    return os.path.expanduser("~/Library/Application Support/VoiceFlow/speaker_enroll.npy")


def available() -> bool:
    """声纹模型在不在(没下就静默不启用,绝不崩)。"""
    return os.path.exists(_model_path())


def _get_extractor():
    global _extractor
    if _extractor is None:
        import sherpa_onnx
        _extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
            sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=_model_path(), num_threads=2)
        )
    return _extractor


def compute_embedding(samples):
    """算一段音频的声纹向量(L2 归一化 → 余弦相似度=点积)。samples:16k 单声道 float32。"""
    import numpy as np
    ex = _get_extractor()
    s = ex.create_stream()
    s.accept_waveform(16000, np.asarray(samples, dtype="float32").reshape(-1))
    s.input_finished()
    emb = np.asarray(ex.compute(s), dtype="float32")
    n = float(np.linalg.norm(emb))
    return emb / n if n > 0 else emb


def enroll(samples) -> bool:
    """登记:算用户声纹存盘。可重复调(覆盖)。"""
    import numpy as np
    emb = compute_embedding(samples)
    os.makedirs(os.path.dirname(_enroll_file()), exist_ok=True)
    np.save(_enroll_file(), emb)
    return True


def read_enrollment():
    try:
        import numpy as np
        return np.load(_enroll_file())
    except Exception:
        return None


def is_enrolled() -> bool:
    return os.path.exists(_enroll_file())


def clear_enrollment() -> None:
    try:
        os.remove(_enroll_file())
    except OSError:
        pass


def similarity(samples, enrolled=None) -> float:
    """这段音频的声纹 与【已登记声纹】的余弦相似度([-1,1])。未登记 → -1(当作不匹配)。"""
    import numpy as np
    if enrolled is None:
        enrolled = read_enrollment()
    if enrolled is None:
        return -1.0
    return float(np.dot(compute_embedding(samples), enrolled))
