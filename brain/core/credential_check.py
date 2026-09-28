"""Explicit one-shot service checks after a user saves/authorizes a credential.

Never reads files, Keychain, microphone, vocabulary or history. The daemon must
use its already-loaded Config; a check cannot activate dictation cloud settings.
"""
import base64
import io
import time
import uuid
import wave

from core.text_enhancement import (
    Message, OpenAICompatibleProvider, PolishProviderError, ProviderRequest,
)


def readiness(cfg) -> dict:
    return {
        "generation": getattr(cfg, "credential_generation", ""),
        "text_key_loaded": bool((getattr(cfg, "llm_api_key", "") or "").strip()),
        "asr_key_loaded": bool((getattr(cfg, "asr_cloud_key", "") or "").strip()),
    }


def _check_text(cfg) -> None:
    import requests

    class OneShotSession(requests.Session):
        def post(self, url, **kwargs):
            return super().post(url, allow_redirects=False, **kwargs)

    with OneShotSession() as session:
        provider = OpenAICompatibleProvider(
            base_url=cfg.llm_base_url, api_key=cfg.llm_api_key,
            model=cfg.polish_model, timeout=(4, 12), session=session,
        )

        output = provider.complete(ProviderRequest(
            messages=(Message("user", "This is a connection test. Reply with OK."),),
            max_tokens=128,
        ))
    if not output:
        raise PolishProviderError("provider_invalid_response")


def _silence_data_uri() -> str:
    audio = io.BytesIO()
    with wave.open(audio, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b"\x00\x00" * 16000)
    return "data:audio/wav;base64," + base64.b64encode(audio.getvalue()).decode("ascii")


def _check_asr(cfg) -> None:
    import requests



    body = {
        "model": cfg.asr_cloud_model,
        "input": {"messages": [{"role": "user", "content": [{"audio": _silence_data_uri()}]}]},
        "parameters": {"result_format": "message", "asr_options": {"enable_itn": True}},
    }
    try:
        with requests.Session() as session:
            response = session.post(
                "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
                json=body, headers={"Authorization": "Bearer " + cfg.asr_cloud_key},
                timeout=(4, 12), allow_redirects=False,
            )
            if response.status_code != 200:
                raise PolishProviderError(OpenAICompatibleProvider._error_code(response.status_code))
            payload = response.json()
        content = payload["output"]["choices"][0]["message"]["content"]
        valid = isinstance(content, str) or (
            isinstance(content, list) and bool(content)
            and all(isinstance(item, dict) and isinstance(item.get("text"), str) for item in content)
        )
        if not valid:
            raise PolishProviderError("provider_invalid_response")
    except PolishProviderError:
        raise
    except requests.exceptions.Timeout:
        raise PolishProviderError("provider_timeout") from None
    except requests.exceptions.ConnectionError:
        raise PolishProviderError("provider_network_error") from None
    except (ValueError, KeyError, IndexError, TypeError):
        raise PolishProviderError("provider_invalid_response") from None
    except Exception:
        raise PolishProviderError("provider_failed") from None


def handle(body, cfg, state: dict) -> dict:
    allowed = {"kind", "check_id", "generation", "allow_network"}
    if not isinstance(body, dict) or set(body) != allowed:
        return {"credential_check": {"code": "invalid_request"}}
    kind, check_id, generation = (body.get(key) for key in ("kind", "check_id", "generation"))
    try:
        if not isinstance(check_id, str) or str(uuid.UUID(check_id)) != check_id:
            raise ValueError
    except (ValueError, TypeError, AttributeError):
        return {"credential_check": {"code": "invalid_request"}}
    result = {"kind": kind, "check_id": check_id, "generation": generation,
              "code": "invalid_request", "latency_ms": 0}
    if kind not in ("text", "asr") or not isinstance(generation, str):
        return {"credential_check": {"code": "invalid_request"}}
    if body["allow_network"] is not True:
        return {"credential_check": {**result, "code": "network_not_authorized"}}
    if not generation or generation != getattr(cfg, "credential_generation", ""):
        return {"credential_check": {**result, "code": "configuration_changed"}}
    checks = state.setdefault("credential_checks", {})
    identity = (kind, check_id, generation)
    if identity in checks:
        return {"credential_check": dict(checks[identity])}
    loaded = readiness(cfg)[kind + "_key_loaded"]
    if not loaded:
        result["code"] = "credential_not_loaded"
    else:
        started = time.monotonic()
        try:
            (_check_text if kind == "text" else _check_asr)(cfg)
            result["code"] = "ok"
        except PolishProviderError as exc:
            result["code"] = exc.code
        except Exception:

            result["code"] = "provider_failed"
        result["latency_ms"] = round((time.monotonic() - started) * 1000)
    if len(checks) >= 16:
        checks.pop(next(iter(checks)))
    checks[identity] = dict(result)
    return {"credential_check": result}
