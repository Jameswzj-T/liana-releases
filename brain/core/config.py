"""配置与密钥。密钥只从环境变量 / .env 读,绝不写进代码或提交。"""
import os
from dataclasses import dataclass


def _load_dotenv() -> None:
    """把项目根的 .env 作为缺省值加载。没装依赖或没文件都安静跳过。"""
    try:
        from dotenv import load_dotenv
    except ImportError:
        return
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))



    load_dotenv(os.path.join(root, ".env"), override=False)


def _smart_dictation_guard_mode(raw: str) -> str:
    """只接受两种自动整理闸门模式；未知值回到当前实验默认。"""
    value = (raw or "").strip().lower()
    return value if value in {"model_first", "strict"} else "model_first"


@dataclass
class Config:

    credential_generation: str = ""

    asr_provider: str = "local"


    asr_engine: str = "qwen3_06"
    asr_api_key: str = ""
    asr_model: str = "qwen3-asr-flash"
    llm_api_key: str = ""
    llm_base_url: str = "https://api.deepseek.com"
    polish_model: str = "deepseek-v4-flash"
    polish_style: str = "clean"
    polish_min_chars: int = 20
    polish_disabled: bool = True
    text_enhancement_enabled: bool = False
    smart_dictation_enabled: bool = False


    smart_dictation_guard_mode: str = "model_first"




    polish_tuned: bool = False



    polish_gate_off: bool = False





    smoother_enabled: bool = False




    save_audio: bool = False
    language: str = "zh"
    voice_punct: bool = False
    polish_terms: bool = False
    polish_layout: bool = False
    speaker_verify: bool = False

    speaker_tail_refine: bool = False



    speaker_threshold: float = 0.5





    asr_cloud: bool = False


    asr_e2e: bool = False
    asr_cloud_model: str = "qwen3-asr-flash"
    asr_cloud_key: str = ""




    asr_context: str = ""

    asr_qwen3_06_context: bool = False


    vocab_context_enabled: bool = True
    vocab_context_min_occurrences: int = 2


    corrections_hard_enabled: bool = True

    number_normalize: bool = True


    asr_cloud_format: str = "MP3"

    @classmethod
    def from_env(cls) -> "Config":
        _load_dotenv()
        _asr_cloud_raw = os.environ.get("ASR_CLOUD", "")
        _asr_e2e_raw = os.environ.get("ASR_E2E", "")
        return cls(
            credential_generation=os.environ.get("LIANA_CREDENTIAL_GENERATION", ""),
            asr_provider=os.environ.get("ASR_PROVIDER", "local"),
            asr_engine=os.environ.get("ASR_ENGINE", "qwen3_06"),
            asr_api_key=os.environ.get("ASR_API_KEY", ""),
            asr_model=os.environ.get("ASR_MODEL", "qwen3-asr-flash"),
            llm_api_key=os.environ.get("LLM_API_KEY", ""),
            llm_base_url=os.environ.get("LLM_BASE_URL", "https://api.deepseek.com"),
            polish_model=os.environ.get("POLISH_MODEL", "deepseek-v4-flash"),
            polish_style=os.environ.get("POLISH_STYLE", "clean"),
            polish_min_chars=int(os.environ.get("POLISH_MIN_CHARS", "20")),
            polish_disabled=os.environ.get("POLISH_DISABLE", "1") not in ("", "0", "false", "False"),
            text_enhancement_enabled=os.environ.get("TEXT_ENHANCEMENT_ENABLED", "") in ("1", "true", "True"),
            smart_dictation_enabled=os.environ.get("SMART_DICTATION_ENABLED", "") in ("1", "true", "True"),
            smart_dictation_guard_mode=_smart_dictation_guard_mode(
                os.environ.get("SMART_DICTATION_GUARD_MODE", "model_first")
            ),
            smoother_enabled=os.environ.get("SMOOTH_ENABLE", "") in ("1", "true", "True"),
            polish_gate_off=os.environ.get("POLISH_GATE_OFF", "") in ("1", "true", "True"),
            polish_tuned=os.environ.get("POLISH_TUNED", "") in ("1", "true", "True"),
            save_audio=os.environ.get("ASR_SAVE_AUDIO", "") in ("1", "true", "True"),
            language=os.environ.get("LANGUAGE", "zh"),
            voice_punct=os.environ.get("VOICE_PUNCT", "") not in ("", "0", "false", "False"),
            polish_terms=os.environ.get("POLISH_TERMS", "") not in ("", "0", "false", "False"),
            polish_layout=os.environ.get("POLISH_LAYOUT", "") not in ("", "0", "false", "False"),
            speaker_verify=os.environ.get("SPEAKER_VERIFY", "") not in ("", "0", "false", "False"),
            speaker_tail_refine=os.environ.get("SPEAKER_TAIL_REFINE", "") in ("1", "true", "True"),
            speaker_threshold=float(os.environ.get("SPEAKER_THRESHOLD", "0.5")),
            asr_cloud=(_asr_cloud_raw == "1" or _asr_cloud_raw.lower() == "true"),
            asr_e2e=(_asr_e2e_raw == "1" or _asr_e2e_raw.lower() == "true"),
            asr_cloud_model=os.environ.get("ASR_CLOUD_MODEL", "qwen3-asr-flash"),
            asr_cloud_key=os.environ.get("ASR_CLOUD_KEY", ""),
            asr_cloud_format=os.environ.get("ASR_CLOUD_FORMAT", "MP3"),
            asr_qwen3_06_context=os.environ.get("ASR_QWEN3_06_CTX", "") in ("1", "true", "True"),
            vocab_context_enabled=os.environ.get("VOCAB_CONTEXT", "1") in ("1", "true", "True"),
            vocab_context_min_occurrences=max(
                1, int(os.environ.get("VOCAB_CONTEXT_MIN_OCCURRENCES", "2"))
            ),
            corrections_hard_enabled=os.environ.get("CORRECTIONS_HARD", "1") in ("1", "true", "True"),
            number_normalize=os.environ.get("ASR_NUMBER_NORMALIZE", "1") not in ("0", "false", "False"),
        )
