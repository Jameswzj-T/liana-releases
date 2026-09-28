""


















import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace

from core import asr

_SR = 16000
_CHUNK_S = 15
_MAX_INFLIGHT = 4
_MIN_CLOUD_UTTERANCE_S = 0.5


class StreamingTranscriber:
    """录音时 feed() 攒帧;开了云端就边攒边把封口的块发去转,停录时 finish() 只等尾块。
    close() 丢弃(Esc 取消)。"""

    def __init__(self, config, transcribe_fn=None):
        import numpy as np
        self._cfg = config
        self._np = np
        self._transcribe = transcribe_fn or asr.transcribe
        self._all = []


        self._live = self._should_stream(config)
        self._vad = None
        self._carry = np.zeros(0, dtype=np.float32)
        self._pend = []
        self._pend_len = 0
        self._futures = []
        self._pool = None
        self._lock = threading.Lock()
        self._failed = False


        self.last_route = "pending"

        self.fallback_reason = ""


        self.detected_languages = None

    @staticmethod
    def _should_stream(config) -> bool:
        """要不要边说边转:只有【开了云端 ASR 且有 key】才有意义 —— 本地 SenseVoice 整段只要
        0.25s,切块反而添乱。"""
        if not getattr(config, "asr_cloud", False):
            return False
        return bool((getattr(config, "asr_cloud_key", "") or "").strip())



    def feed(self, samples) -> None:
        arr = self._np.asarray(samples, dtype=self._np.float32).reshape(-1).copy()
        self._all.append(arr)
        if not self._live or self._failed:
            return
        try:
            for seg in self._pop_segments(arr):
                self._pend.append(seg)
                self._pend_len += len(seg)
            if self._pend_len >= _CHUNK_S * _SR:
                self._send_chunk()
        except Exception:
            self._failed = True
            self.fallback_reason = "stream_preprocess_failed"

    def _pop_segments(self, arr) -> list:
        """把新帧喂给流式 VAD,收【已封口】的语音段(静音自动丢掉)。还在说的那段不会返回。

        VAD 只吃 512 样本的整帧。外壳每次喂的量【不保证是 512 的倍数】→ 不足一帧的尾巴必须
        留到下次拼上(_carry),否则每帧最多丢 511 个样本、累积起来就是真丢音频。"""
        if self._vad is None:
            self._vad = asr.new_vad()
        x = self._np.asarray(arr, dtype="float32")
        if self._carry.size:
            x = self._np.concatenate([self._carry, x])
        n = len(x) - len(x) % 512
        out = []
        for i in range(0, n, 512):
            self._vad.accept_waveform(x[i:i + 512])
            while not self._vad.empty():
                out.append(self._np.asarray(self._vad.front.samples, dtype="float32"))
                self._vad.pop()
        self._carry = x[n:].copy()
        return out

    def _send_chunk(self) -> None:
        """声纹过滤(录音期做 → 松键后≈0)+ 把这块丢给云端(后台线程,不挡录音)。"""
        segs, self._pend, self._pend_len = self._pend, [], 0
        kept = asr.gate_segments(segs, self._cfg)
        if not kept:
            return
        chunk = self._np.concatenate(kept)
        if self._pool is None:
            self._pool = ThreadPoolExecutor(max_workers=_MAX_INFLIGHT)
        with self._lock:
            self._futures.append(self._pool.submit(asr._transcribe_cloud_asr, chunk, self._cfg))




    def finish(self) -> str:
        asr._last_english_offline = False
        self.detected_languages = ()
        if not self._all:
            return ""
        _save_audio_for_diagnosis(self._all, self._np, self._cfg)
        try:
            if self._live and not self._failed:
                return self._finish_live()


            hybrid_unavailable = (
                getattr(self._cfg, "asr_provider", "local") == "local"
                and getattr(self._cfg, "asr_cloud", False)
                and not self._should_stream(self._cfg)
            )
            if self._failed:
                return self._fallback_to_local(
                    self.fallback_reason or "stream_preprocess_failed"
                )
            if hybrid_unavailable:
                return self._fallback_to_local("cloud_not_configured")
            return self._finish_whole()
        finally:
            self._shutdown()

    def _fallback_to_local(self, reason: str) -> str:
        """以稳定原因码回到整段本地 ASR；不把异常详情带入协议或日志。"""
        self.fallback_reason = reason
        return self._finish_whole(local_only=True)

    def _finish_whole(self, *, local_only: bool = False) -> str:
        """整段转一次（没开云端 / 云端不可用 / 边转失败后的本地回落）。"""
        full = self._np.concatenate(self._all)
        cfg = (replace(self._cfg, asr_provider="local", asr_cloud=False)
               if local_only else self._cfg)
        self.last_route = (
            "local"
            if local_only or (
                getattr(cfg, "asr_provider", "local") == "local"
                and not getattr(cfg, "asr_cloud", False)
            )
            else "hybrid"
        )
        if not full.size:
            self.detected_languages = ()
            return ""
        result = self._transcribe(full, cfg)
        self.detected_languages = getattr(result, "detected_languages", None)
        return str(result).strip()

    def _finish_short_cloud(self) -> str:
        ""




        import time

        full = self._np.concatenate(self._all)
        if full.size < int(_MIN_CLOUD_UTTERANCE_S * _SR):
            return self._fallback_to_local("cloud_bypassed_short_audio")

        try:
            cloud_audio = asr._speaker_gate(full, self._cfg)
        except Exception:
            return self._fallback_to_local("speaker_gate_failed")
        if not cloud_audio.size:
            self.last_route = "cloud"
            self.detected_languages = ()
            return ""

        if (cloud_audio.size > getattr(asr, "_SHORT_AUDIO_S", 1.5) * _SR
                and not asr._has_speech(cloud_audio)):
            self.last_route = "cloud"
            self.detected_languages = ()
            return ""

        asr._last_segment_diag = {}
        asr._last_snaps, asr._last_rescue, asr._last_timing = [], "", {}
        t0 = time.perf_counter()
        try:
            text = asr._transcribe_cloud_asr(cloud_audio, self._cfg)
        except Exception:
            return self._fallback_to_local("cloud_request_failed")
        if not isinstance(text, str) or not text.strip():
            return self._fallback_to_local("cloud_empty")

        asr._last_timing["整段云端"] = round(time.perf_counter() - t0, 2)
        asr._last_rescue = (
            f"云端 {getattr(self._cfg, 'asr_cloud_model', '?')}(短句整段)"
        )
        self.last_route = "cloud"
        self.detected_languages = ()
        return text.strip()

    def _finish_live(self) -> str:
        """边说边转的收尾:冲洗 VAD 尾巴 → 发尾块 → 按序收齐所有块 → 拼回 → 过词库后处理。
        不到分块阈值的短句 → 整段云端一次；够长但尚未封口 → 先冲洗尾块再收齐。
        任何一块炸了 → 整段回落本地,绝不丢话。"""
        import time

        asr._last_segment_diag = {}


        with self._lock:
            started = bool(self._futures)
        if not started:
            full_size = sum(len(frame) for frame in self._all)
            if full_size < _CHUNK_S * _SR:
                return self._finish_short_cloud()
        asr._last_snaps, asr._last_rescue, asr._last_timing = [], "", {}
        t0 = time.perf_counter()
        try:
            self._flush_tail()
        except Exception:
            return self._fallback_to_local("cloud_chunk_prepare_failed")
        with self._lock:
            futures = list(self._futures)
        if not futures:


            if asr.speaker_gate_on(self._cfg):
                self.last_route = "cloud"
                self.detected_languages = ()
                return ""
            return self._fallback_to_local("cloud_vad_empty")
        parts = []
        for f in futures:
            try:
                part = f.result(timeout=30)
            except Exception:
                return self._fallback_to_local("cloud_chunk_failed")
            if not isinstance(part, str) or not part.strip():
                return self._fallback_to_local("cloud_chunk_empty")
            parts.append(part)

        asr._last_timing["尾块"] = round(time.perf_counter() - t0, 2)
        asr._last_rescue = f"云端 {getattr(self._cfg, 'asr_cloud_model', '?')}(边说边转·{len(futures)} 块)"
        self.last_route = "cloud"
        self.detected_languages = ()

        return asr._join_chunks(parts).strip()

    def _flush_tail(self) -> None:
        """录音结束:补零凑满最后一帧喂进 VAD(别丢余数)→ flush 冲出还没封口的语音 →
        连同没凑够一块的存货合成尾块发走。"""
        if self._vad is None:
            return
        if self._carry.size:
            pad = self._np.zeros(512 - self._carry.size, dtype=self._np.float32)
            self._vad.accept_waveform(self._np.concatenate([self._carry, pad]))
            self._carry = self._np.zeros(0, dtype=self._np.float32)
        self._vad.flush()
        while not self._vad.empty():
            self._pend.append(self._np.asarray(self._vad.front.samples, dtype="float32"))
            self._pend_len += len(self._pend[-1])
            self._vad.pop()
        if self._pend_len:
            self._send_chunk()

    def _shutdown(self) -> None:
        if self._pool is not None:
            self._pool.shutdown(wait=False)
            self._pool = None

    def close(self) -> None:
        """Esc 取消:丢弃一切(在飞的块结果也不要了)。"""
        self._all = []
        self._pend = []
        self._pend_len = 0
        with self._lock:
            self._futures = []
        self._shutdown()

def _save_audio_for_diagnosis(frames, np, cfg) -> None:
    ""










    if not getattr(cfg, "save_audio", False):
        return
    try:
        import os
        import time
        import wave
        base = os.path.expanduser("~/Library/Application Support/VoiceFlow/audio")
        os.makedirs(base, exist_ok=True)
        full = np.concatenate(frames)
        pcm = (np.clip(full, -1.0, 1.0) * 32767).astype(np.int16)
        name = time.strftime("%Y-%m-%d_%H-%M-%S") + ".wav"
        with wave.open(os.path.join(base, name), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(pcm.tobytes())
        keep = sorted(f for f in os.listdir(base) if f.endswith(".wav"))
        for old in keep[:-_KEEP_AUDIO]:
            os.remove(os.path.join(base, old))
    except Exception:
        pass


_KEEP_AUDIO = 60
