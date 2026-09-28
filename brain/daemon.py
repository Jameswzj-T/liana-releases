""




















import base64
from dataclasses import replace
import hashlib
import json
import os
import re
import sys
import threading
import time
import uuid

from core.config import Config
from core.literal_text import LiteralText
from core import spoken_repetition
from core import asr
from core import credential_check
from core import e2e
from core import gate
from core import polish
from core import postprocess
from core import neutral_list_labels
from core import voice_commands
from core import vocab_context
from core.stream_asr import StreamingTranscriber
from core.text_enhancement import (
    EnhancementInput,
    EnhancementResult,
    OpenAICompatibleProvider,
    Operation,
    TextEnhancer,
    TEXT_CONNECT_TIMEOUT_SECONDS,
    safe_provider_diagnostics,
    smart_dictation_prompt_identity,
    smart_dictation_request_identity,
)


def _normalize_run_id(value) -> str:
    """把外壳传来的 UUID 收成无连字符小写；缺失/非法时本地生成，不信任日志输入。"""
    try:
        return uuid.UUID(str(value)).hex
    except (AttributeError, TypeError, ValueError):
        return uuid.uuid4().hex


def _receipt_token(value) -> str:
    """运行回执只收稳定错误码，避免把异常正文、路径或凭据写进元数据行。"""
    token = re.sub(r"[^a-z0-9_.:-]+", "_", str(value or "").strip().lower())
    return token.strip("_.:-")[:80]


def _runtime_receipt(
    *,
    run_id,
    entry_route: str,
    asr_route: str,
    smart: dict | None = None,
    fallback_reason: str = "",
    e2e_failed: bool = False,
    prompt_id: str | None = None,
    prompt_sha256: str | None = None,
    final_status: str | None = None,
) -> dict:
    """生成不含正文的最小听写回执，供协议、终端和 debug.log 共用。"""
    smart = smart or {}
    reasons = []
    if token := _receipt_token(fallback_reason):
        reasons.append(token)
    if e2e_failed:
        reasons.append("e2e_failed")
    if smart.get("status") == "fallback":
        error = _receipt_token(smart.get("error_code")) or "unknown"
        reasons.append(f"smart:{error}")
    elif smart.get("status") == "skipped" and smart.get("error_code"):
        reasons.append(f"smart_skipped:{_receipt_token(smart['error_code'])}")
    reasons = list(dict.fromkeys(reasons))

    smart_status = _receipt_token(smart.get("status")) or "not_applicable"
    if final_status is None:
        final_status = {
            "applied": "smart_applied",
            "unchanged": "smart_unchanged",
            "fallback": "asr_only_smart_fallback",
            "disabled": "asr_only_smart_disabled",
            "skipped": "asr_only_smart_skipped",
        }.get(smart_status, "asr_only")

    receipt = {
        "schema": "liana.dictation_run.v1",
        "run_id": _normalize_run_id(run_id),
        "actual_route": f"{_receipt_token(entry_route) or 'unknown'}/"
                        f"{_receipt_token(asr_route) or 'unknown'}",
        "smart_status": smart_status,
        "prompt_id": prompt_id if prompt_id is not None else smart.get("prompt_id"),
        "prompt_sha256": (
            prompt_sha256 if prompt_sha256 is not None else smart.get("prompt_sha256")
        ),
        "fallback_reason": ",".join(reasons) or None,
        "final_status": final_status,
    }

    if smart.get("request_template_id"):
        receipt["request_template_id"] = smart["request_template_id"]
        receipt["request_template_sha256"] = smart.get("request_template_sha256")
    if diagnostic := safe_provider_diagnostics(smart.get("provider_diagnostics")):
        receipt["provider_diagnostics"] = diagnostic
    return receipt


def _content_diagnostics_enabled() -> bool:
    """正文诊断必须由开发者显式开启；正式包默认只记录运行元数据。"""
    return os.environ.get("LIANA_CONTENT_DIAGNOSTICS", "").strip().casefold() in {
        "1", "true", "yes", "on",
    }


def _debug_log(out: dict) -> None:
    ""



    try:
        base = os.path.expanduser("~/Library/Application Support/VoiceFlow")
        os.makedirs(base, exist_ok=True)
        include_content = _content_diagnostics_enabled()

        def flat(s):
            return (s or "").replace("\n", "⏎").strip()

        note = f" {out['note']}" if out.get("note") else ""



        pre_raw = out.get("pre_collapse") or ""
        pre_line = (
            f"  pre: {flat(pre_raw)}\n"
            if include_content and "\n" in pre_raw else ""
        )



        blk = out.get("gate_blocked") or ""
        blk_line = f"  blk: {flat(blk)}\n" if include_content and blk else ""


        ret = out.get("retention")
        ret_line = (f"  ret: {ret:.2f}(输出/输入 token·明显变短,留意有没有漏内容)\n"
                    if isinstance(ret, (int, float)) and ret < 0.65 else "")



        sv_probe = out.get("sv_probe") or ""
        sv_line = (
            f"  sv : {flat(sv_probe)}\n"
            if include_content and sv_probe
            and flat(sv_probe) != flat(out.get("asr_raw")) else ""
        )



        pre_smooth = out.get("pre_smooth") or ""
        sm_line = (
            f"  sm : {flat(pre_smooth)}  ←顺滑前\n"
            if include_content and pre_smooth
            and flat(pre_smooth) != flat(out.get("asr_raw")) else ""
        )


        pre_vocab = out.get("pre_vocab") or ""
        post_vocab = out.get("post_vocab") or ""
        src_line = (
            f"  src: {flat(pre_vocab)}  ←词库纠正前\n"
            if include_content and pre_vocab else ""
        )
        voc_line = (f"  voc: {flat(post_vocab)}  ←词库纠正后\n"
                    if include_content and pre_vocab
                    and flat(post_vocab) != flat(pre_vocab) else "")

        seg = out.get("segment_diag") or {}
        seg_line = ""
        if seg:
            if seg.get("mode") == "segmented":
                blocks = ",".join(str(x) for x in seg.get("block_s", []))
                boundaries = ",".join(str(x) for x in seg.get("boundaries_s", []))
                action_names = {
                    "drop_terminal": "删块尾标点",
                    "soften_terminal": "块尾改软标点",
                    "keep_terminal": "留块尾标点",
                    "no_terminal": "块尾无标点",
                    "skip_empty": "空块跳过",
                }
                actions = ",".join(action_names.get(x, x) for x in seg.get("seam_actions", []))
                seg_line = (f"  seg: 原音{seg.get('audio_s')}s·送模{seg.get('engine_s')}s"
                            f"·VAD{seg.get('vad_segments')}段·{seg.get('blocks')}块[{blocks}]"
                            f"·缝@{boundaries}s·裁决[{actions}]\n")
            else:
                seg_line = (f"  seg: 原音{seg.get('audio_s')}s·送模{seg.get('engine_s')}s"
                            f"·整段\n")
        languages = ",".join(out.get("detected_languages") or []) or "unknown"
        rule_route = out.get("rule_route") or "external"
        language_line = f"  lang: {languages}·规则[{rule_route}]\n"
        receipt = out.get("runtime_receipt") or {}
        receipt_line = ""
        if receipt:
            prompt_id = receipt.get("prompt_id") or "-"
            prompt_sha = receipt.get("prompt_sha256") or ""
            prompt_ref = f"{prompt_id}@{prompt_sha[:12]}" if prompt_sha else prompt_id
            request_id = receipt.get("request_template_id")
            request_sha = receipt.get("request_template_sha256") or ""
            request_ref = f"·request={request_id}@{request_sha[:12]}" if request_id else ""
            layout_ref = (
                f"·layout={receipt['layout_policy_id']}+{receipt.get('layout_newlines_added', 0)}"
                if receipt.get("layout_policy_id") else ""
            )
            receipt_line = (
                f"  run: {receipt.get('run_id', '-')}"
                f"·route={receipt.get('actual_route', '-')}"
                f"·prompt={prompt_ref}"
                f"{request_ref}"
                f"·fallback={receipt.get('fallback_reason') or '-'}"
                f"·final={receipt.get('final_status', '-')}{layout_ref}\n"
            )
        ls = out.get("layout_stats") or {}
        layout_line = (f"  layout: 动了·标点{ls.get('标点数', '?')}个·变化{ls.get('标点变化', '?')}处"
                       f"·换行{ls.get('换行差', 0):+d}\n"
                       if ls.get("动了") else "")
        smart = out.get("smart_enhancement") or {}
        smart_status = smart.get("status") or ""
        smart_line = ""
        if smart_status in {"applied", "unchanged", "fallback"}:
            issue_codes = ",".join(smart.get("validation_issues") or ()) or "-"
            warning_codes = ",".join(smart.get("validation_warnings") or ()) or "-"
            usage = smart.get("usage") or {}
            token_line = ""
            if usage:
                token_line = (
                    f"·tokens={usage.get('input_tokens', '?')}"
                    f"/{usage.get('output_tokens', '?')}"
                    f"/{usage.get('total_tokens', '?')}"
                )
            smart_line = (
                f"  smart: {smart_status}·{smart.get('latency_ms', 0)}ms"
                f"·error={smart.get('error_code') or '-'}"
                f"·guard={smart.get('guard_mode') or '-'}"
                f"·issues={issue_codes}·warnings={warning_codes}{token_line}\n"
            )
            if diagnostic := safe_provider_diagnostics(smart.get("provider_diagnostics")):
                smart_line += "  provider: " + json.dumps(diagnostic, sort_keys=True) + "\n"
            local_text = out.get("local_text")
            candidate = out.get("smart_candidate")
            if include_content and local_text is not None:
                smart_line += f"  loc: {flat(local_text)}  ←确定性清洗后\n"
            if include_content and candidate is not None:
                smart_line += f"  pol: {flat(candidate)}  ←云端候选\n"
        raw_line = f"  raw: {flat(out.get('asr_raw'))}\n" if include_content else ""
        out_line = f"  out: {flat(out.get('text'))}\n" if include_content else ""
        line = (f"{time.strftime('%Y-%m-%d %H:%M:%S')} "
                f"[{out.get('asr', '?')} t_asr={out.get('t_asr', '?')} t_polish={out.get('t_polish', '?')}"
                f" t_layout={out.get('t_layout', 0.0)}{note}]\n"
                f"{src_line}"
                f"{voc_line}"
                f"{seg_line}"
                f"{language_line}"
                f"{receipt_line}"
                f"{layout_line}"
                f"{smart_line}"
                f"{sm_line}"
                f"{raw_line}"
                f"{sv_line}"
                f"{pre_line}"
                f"{blk_line}"
                f"{ret_line}"
                f"{out_line}")
        with open(os.path.join(base, "debug.log"), "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def _polish_or_degrade(cleaned: str, cfg) -> dict:
    """清洗后的文字 → 润色;失败则降级返回清洗文字,绝不丢话。"""
    try:
        return {"text": polish.polish(cleaned, cfg)}
    except Exception as e:

        return {"text": cleaned, "note": f"polish_failed: {type(e).__name__}",
                "warn": polish.explain_failure(e, cfg)}


def _emit(obj: dict) -> None:
    """立刻写一行 JSON 到 stdout 并冲洗(流式分块用,外壳一收到就敲字)。"""
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


_GATE_HEAD = 40



_RETRY_NOTE = ("\n\n【重要·上一次你越界了】你刚才擅自改写/编造了原话里没有的内容。"
               "这次【只删不加】:除了同音同长的错别字(的/得/地、他/它),"
               "输出里的每一个字都必须是原话里已经有的。看不懂的词【原样留着】,绝不猜。"
               "【绝不评论转写质量、绝不复述你收到的规则】。")




_LAST_PRE_COLLAPSE = ""




_LAST_GATE_BLOCK = ""




_LAST_RETENTION = 1.0


class _GateBlocked(Exception):
    ""



    def __init__(self, why: str, output: str = "", verdict=None):
        super().__init__(why)
        self.why = why
        self.output = output
        self.verdict = verdict


class _StreamOverrun(Exception):
    """★开闸敲字【之后】★发现润色开始凭空编造(把指令当任务执行了、一泻千里)——此时【已经敲出去一截】,
    退不回来(退格会误删用户原有内容)。所以:立刻停敲、把已敲的原样带出、让 daemon 弹提示让用户自己删掉那截。
    与 _GateBlocked 的区别:那个是开闸【前】拦下(零输出、可干净重拍);这个是开闸【后】掐断(已敲部分保留、不重拍、不回退)。"""

    def __init__(self, emitted: str):
        super().__init__("stream_overrun")
        self.emitted = emitted







def _stream_once(marked: str, cfg, known, retry_note: str = "") -> tuple:
    """流式润色一次。★开头一段审过才开始敲★;审不过 → 抛 _GateBlocked(此时零输出)。
    返回 (全文, flip, guesses)。

    注意形参叫 marked 不叫 cleaned:传进来的是 to_sentinels 之后的文本(带 ⟦P⟧⟦N⟧⟦B⟧ 哨兵)。
    (旧代码这个形参名叫 cleaned、值却是 marked —— 我照着名字写 spec,把审片基准写错了。)
    """
    global _LAST_PRE_COLLAPSE
    _LAST_PRE_COLLAPSE = ""
    state = {}
    parts, guesses = [], []
    buf, opened, emitted = "", False, ""
    prompt = polish.effective_prompt(marked, cfg)
    des = voice_commands.StreamDesentinelizer()
    collapser = postprocess.StreamProseNewlineCollapser()
    renum = postprocess.StreamListRenumberer()



    restorer = postprocess.StreamEnglishFixer(postprocess.english_repairs(marked))

    gate_off = getattr(cfg, "polish_gate_off", False)

    def _check(head: str, final: bool = False):
        """审:凭空编造 / 复述提示词 / 吞话。过了就返回 guesses(润色替转写猜的词,不拦但要记)。

        final=True → head 其实是【完整输出】(短输出走到收尾才审)→ 保留率闸这时才判得了。
        """





        leak = gate.suspect_prompt_leak(prompt, marked, head)
        if leak:
            raise _GateBlocked(leak, output=head)
        if gate_off:
            return []
        v = gate.review(marked, head, known, partial=not final)
        if not v.ok:
            raise _GateBlocked(v.reason, output=head, verdict=v)
        return v.guesses

    for chunk in polish.polish_stream(marked, cfg, state, retry_note):
        parts.append(chunk)

        out = postprocess.strip_hard_breaks(des.feed(renum.feed(collapser.feed(restorer.feed(chunk)))))
        if not out:
            continue
        if opened:


            if not gate_off and gate.looks_like_runaway(marked, emitted + out):
                raise _StreamOverrun(emitted)







            if not gate_off and (gate.looks_like_repeat(emitted + out)
                                 or gate.looks_like_cycle(emitted + out)):
                raise _StreamOverrun(emitted)
            emitted += out
            _emit({"delta": out})
            continue
        buf += out
        head, rest = gate.split_head(buf, _GATE_HEAD)
        if head is None:
            continue
        guesses += _check(head)
        _emit({"delta": head + rest})
        buf, opened, emitted = "", True, head + rest


    tail_out = postprocess.strip_hard_breaks(
        des.feed(renum.feed(collapser.feed(restorer.flush())))
        + des.feed(renum.feed(collapser.flush()))
        + des.feed(renum.flush()) + des.flush())
    if not opened:
        buf += tail_out
        if buf:
            guesses += _check(buf, final=True)
            _emit({"delta": buf})
    elif tail_out:
        _emit({"delta": tail_out})

    full = "".join(parts)
    tail = polish._dropped_tail_request(marked, full)
    if tail:
        _emit({"delta": tail})
        full += tail
    _LAST_PRE_COLLAPSE = full

    return (postprocess.strip_hard_breaks(voice_commands.from_sentinels(
                postprocess.renumber_lists(postprocess.collapse_prose_newlines(full)))),
            state.get("flip", False), guesses)


def _full_why(exc) -> str:
    """把 _GateBlocked 的【完整】越界清单摊平成一行(不像 Verdict.reason 只取前 3 条)——诊断要看全。"""
    v = getattr(exc, "verdict", None)
    if v is not None and v.violations:
        return f"[越界{v.mass}] " + "; ".join(v.violations)
    return exc.why


def _watch_eaten(marked: str, full: str) -> str:
    ""


    global _LAST_RETENTION
    _LAST_RETENTION = gate.retention(marked, full)
    return ("润色可能吞掉了你的话(输出比原话短很多)—— 请核对,必要时重说一遍。"
            if gate.suspect_eaten(marked, full) else "")


def _stream_polish(marked: str, cfg) -> tuple:
    """流式润色 + 审片闸。返回 (全文, note, flip, guesses, warn)。
    warn = 给用户看的人话(空串=没事);note 仍是给日志看的短码。

    闸响 → 重拍一次(换提示词)→ 还不行 → 回退到转写原文。★绝不丢话,也绝不给他看编的东西。★
    不做撤回:Paster.type 会把空白压成单空格 → daemon 数的字符数 ≠ 屏幕上的字符数,
    按数退格会删掉用户【原有】的内容(多敲几个字 ⌘Z 能救,多退几十个格是数据丢失)。
    所以闸子放在【敲字之前】,而不是敲完再撤。
    """
    global _LAST_GATE_BLOCK, _LAST_RETENTION
    _LAST_GATE_BLOCK = ""
    _LAST_RETENTION = 1.0
    if not marked.strip():
        return "", None, False, [], ""
    known = {t.lower() for t in polish.read_vocab_terms()} | {r.lower() for _, r in polish.read_corrections()}
    try:
        full, flip, guesses = _stream_once(marked, cfg, known)
        return full, None, flip, guesses, _watch_eaten(marked, full)
    except _GateBlocked as first:
        try:
            full, flip, guesses = _stream_once(marked, cfg, known, _RETRY_NOTE)
            return full, f"gate_retry: {first.why}", flip, guesses, _watch_eaten(marked, full)
        except _GateBlocked as again:


            _LAST_GATE_BLOCK = (f"稿1「{first.output}」← {_full_why(first)}  ‖  "
                                f"稿2「{again.output}」← {_full_why(again)}")
            deg = voice_commands.from_sentinels(marked)
            _emit({"delta": deg})

            return deg, f"gate_blocked: {again.why}", False, [], "润色这次改动过大(疑似重写了你的话)→ 已退回未润色原文,守住「不改你原意」。"
        except _StreamOverrun as ovr:

            return ovr.emitted, "stream_overrun_retry", False, [], "润色跑偏已拦停 —— 后面没再敲,请检查并删掉刚才这几个字。"
        except Exception as e:
            deg = voice_commands.from_sentinels(marked)
            _emit({"delta": deg})
            return deg, f"polish_failed: {type(e).__name__}", False, [], polish.explain_failure(e, cfg)
    except _StreamOverrun as ovr:


        return ovr.emitted, "stream_overrun", False, [], "润色跑偏已拦停 —— 后面没再敲,请检查并删掉刚才这几个字。"
    except Exception as e:
        deg = voice_commands.from_sentinels(marked)
        _emit({"delta": deg})
        return deg, f"polish_failed: {type(e).__name__}", False, [], polish.explain_failure(e, cfg)


_KANA = re.compile(r"[\u3040-\u30ff\uff66-\uff9f]")
_HANGUL = re.compile(r"[\uac00-\ud7af\u1100-\u11ff]")
_HAN = re.compile(r"[\u3400-\u9fff]")
_LATIN = re.compile(r"[A-Za-z]")




_EXPLICIT_SHORT_REPLY_SPELLINGS = {
    "yes": "Yes",
    "no": "No",
    "yeah": "Yeah",
    "yep": "Yep",
    "nope": "Nope",
    "ok": "OK",
    "okay": "Okay",
}


def _is_explicit_short_reply(text: str) -> bool:
    normalized = re.sub(r"[^a-z]+", "", (text or "").lower())
    return normalized in _EXPLICIT_SHORT_REPLY_SPELLINGS


def _canonicalize_explicit_short_reply(text: str) -> str:
    """统一完整英文短回答的大小写和句末标点，不猜测同音中文。"""
    original = (text or "").strip()

    if re.search(r"[^A-Za-z\s.!?。！？]", original):
        return text
    normalized = re.sub(r"[^a-z]+", "", original.lower())
    spelling = _EXPLICIT_SHORT_REPLY_SPELLINGS.get(normalized)
    if spelling is None:
        return text
    terminal = re.search(r"([.!?。！？])\s*$", original)
    punctuation = terminal.group(1) if terminal else "."
    punctuation = {"。": ".", "！": "!", "？": "?"}.get(
        punctuation, punctuation
    )
    return spelling + punctuation


def _local_rule_route(text: str, detected_languages) -> str:
    """把本次模型语言收成首版三档规则路由。

    ``detected_languages is None`` 只用于旧调用方和单元测试兼容，按文字脚本做保守推断；
    真实本地 ASR 会显式传元组。文字脚本只看路径、代码和成对引文之外的正文，
    与后续清洗复用同一字面边界；字面内容不能把英语正文改分到中文或其他语种。
    显式缺失、未知、粤语、其他语种、多语冲突或标签与正文假名/韩文冲突仍走
    ``minimal``，不让中文经验规则越界。
    """
    text = LiteralText(text or "").masked
    if detected_languages is None:
        if _KANA.search(text) or _HANGUL.search(text):
            return "minimal"
        if _HAN.search(text):
            return "zh_or_zh_en"
        if _LATIN.search(text):
            return "en"
        return "minimal"

    languages = asr.normalize_detected_languages(detected_languages)
    if not languages or "Unknown" in languages:
        return "minimal"
    if _KANA.search(text) or _HANGUL.search(text):
        return "minimal"

    language_set = set(languages)
    if not language_set <= {"Chinese", "English"}:
        return "minimal"
    if language_set == {"English"} and not _HAN.search(text):
        return "en"
    return "zh_or_zh_en"


def _finalize_transcription(
    model_raw: str,
    cfg,
    *,
    t0: float | None = None,
    local_rules: bool | None = None,
    detected_languages=None,
    route: str = "stream",
    source_route: str | None = None,
    e2e_fail: str = "",
    allow_smart_enhancement: bool = False,
    run_id: str | None = None,
    fallback_reason: str = "",
    smart_progress: bool = False,
) -> dict:
    """把一次 ASR 原文收成免费版最终结果。

    ``stream:stop`` 是正常入口，``path`` 是守护进程没有给出结果时的备用入口。
    两者必须共用这里，不能让备用入口又回到旧的 ``pipeline.process`` 清洗链；否则
    同一段录音会因为入口不同得到两种结果。

    这里故意只保留免费版的最小确定性出口：本地词库实验层、明确数字格式化、噪音
    过滤和自动分段。云端 ASR 只做技术记号/缩写空格的窄格式修复；E2E 不套本地规则。
    """
    model_raw = (model_raw or "").strip()
    raw = model_raw
    if local_rules is None:
        local_rules = (
            getattr(cfg, "asr_provider", "local") == "local"
            and not getattr(cfg, "asr_cloud", False)
        )
    if source_route is None:
        source_route = "local" if local_rules else "external"
    rule_route = (
        _local_rule_route(model_raw, detected_languages)
        if local_rules
        else "external"
    )
    zh_rules = local_rules and rule_route == "zh_or_zh_en"
    english_rules = local_rules and rule_route == "en"
    latin_term_rules = zh_rules or english_rules



    literals = LiteralText(model_raw)
    raw = literals.masked

    common_terms, user_terms, context_terms = [], [], []
    if local_rules:
        common_terms = list(asr.common_tech_terms()) if latin_term_rules else []
        if getattr(cfg, "vocab_context_enabled", False) and (zh_rules or latin_term_rules):
            user_terms = polish.read_vocab_terms()
            if zh_rules:
                raw = vocab_context.resolve_text(
                    raw,
                    user_terms,
                    getattr(cfg, "asr_context", ""),
                    min_context_occurrences=getattr(cfg, "vocab_context_min_occurrences", 2),
                )


            if getattr(cfg, "asr_context", ""):
                from core import screen_context
                context_terms = screen_context.extract_terms(
                    cfg.asr_context, asr._english_words()
                )
        if latin_term_rules:
            raw = vocab_context.resolve_spoken_latin_alphanumeric_terms(
                raw, common_terms + user_terms + context_terms,
            )
            if zh_rules:
                raw = postprocess.normalize_spoken_technical_notation(
                    raw,
                    common_terms + user_terms + context_terms,
                )
            raw = vocab_context.resolve_spoken_latin_structured_terms(
                raw,
                common_terms + user_terms + context_terms,
            )
            raw = vocab_context.resolve_spoken_latin_numeric_suffixes(
                raw,
                common_terms + user_terms + context_terms,
            )

            raw = vocab_context.resolve_latin_text(
                raw,
                common_terms,
                require_internal_space=True,
                alphanumeric_standards=common_terms + user_terms + context_terms,
            )
            if getattr(cfg, "vocab_context_enabled", False):
                raw = vocab_context.resolve_latin_text(
                    raw, user_terms + context_terms,
                    alphanumeric_standards=common_terms + user_terms + context_terms,
                )


            raw = vocab_context.apply_builtin_product_corrections(raw)
        if getattr(cfg, "corrections_hard_enabled", False):

            raw = vocab_context.apply_exact_corrections(raw, polish.read_corrections())
        if latin_term_rules:
            raw = postprocess.normalize_spaced_initialisms(raw)
            raw = postprocess.normalize_parallel_latin_numbered_labels(raw)
        if english_rules and getattr(cfg, "number_normalize", True):
            raw = postprocess.normalize_english_contextual_numbers(raw)
        if zh_rules and getattr(cfg, "number_normalize", True):
            raw = postprocess.normalize_numbers(raw)
    elif source_route == "cloud":



        common_terms = list(asr.common_tech_terms())
        if getattr(cfg, "vocab_context_enabled", False):
            user_terms = polish.read_vocab_terms()

        raw = vocab_context.resolve_spoken_latin_alphanumeric_terms(
            raw, common_terms + user_terms,
        )
        raw = postprocess.normalize_spoken_technical_notation(
            raw,
            common_terms,
        )
        raw = vocab_context.resolve_spoken_latin_structured_terms(
            raw,
            common_terms,
        )
        raw = postprocess.normalize_spaced_initialisms(raw)
        raw = vocab_context.resolve_spoken_latin_numeric_suffixes(raw, common_terms)
        raw = postprocess.normalize_parallel_latin_numbered_labels(raw)
        if getattr(cfg, "number_normalize", True):
            raw = postprocess.normalize_explicit_latin_model_numbers(raw)

    cleaned = _canonicalize_explicit_short_reply(raw)




    if (
        zh_rules
        and not literals.has_literals
        and asr._is_all_filler(cleaned)
        and not _is_explicit_short_reply(cleaned)
    ):
        cleaned = ""
    if zh_rules:



        cleaned = postprocess.ma_to_question(cleaned)
        cleaned = postprocess.collapse_prose_newlines(cleaned)
        cleaned = postprocess.punctuate_explicit_list_breaks(cleaned)
        cleaned = postprocess.add_list_intro_colons(cleaned)
    if zh_rules or not local_rules:
        cleaned = postprocess.paragraphize_sentinel(cleaned)
    full = voice_commands.from_sentinels(cleaned)
    if zh_rules:


        full = postprocess.space_cjk_en(full)


    full = postprocess.drop_redundant_comma_after_strong_punct(full)
    full = literals.restore(full)
    raw = literals.restore(raw)


    t_asr = round(time.time() - t0, 2) if t0 is not None else 0.0
    local_text = full

    run_id = _normalize_run_id(run_id)
    def report_progress(sequence, elapsed):
        frame = {"type": "smart_progress", "stage": "polishing", "run_id": run_id,
                 "sequence": sequence, "elapsed_seconds": elapsed}
        if sequence == 0:
            frame.update(local_text=local_text, asr_raw=model_raw)
        _emit(frame)
    smart = _smart_dictation(
        local_text,
        cfg,
        route=route,
        local_rules=bool(local_rules),
        source_route=source_route,
        allow_network=allow_smart_enhancement,
        on_progress=report_progress if smart_progress else None,
        protected_terms=tuple(dict.fromkeys(
            asr.common_tech_terms() + vocab_context.alphanumeric_standard_variants(
                common_terms + user_terms + context_terms,
            )
        )),
    )
    full = smart["text"]


    layout_eligible = (
        smart["status"] in {"applied", "unchanged"}
        and route in {"stream", "path_fallback"}
        and source_route in {"local", "cloud"}
    )
    layout_started = time.perf_counter()
    layout_error_code = None
    spoken_cleanup_removed = 0
    spoken_cleanup_error = None
    if layout_eligible:



        try:
            repaired = spoken_repetition.repair_demonstrative_restart(full, source=model_raw)
            spoken_cleanup_removed = len(full) - len(repaired)
            full = repaired
        except Exception:
            spoken_cleanup_error = "spoken_cleanup_failed"
        try:
            full = neutral_list_labels.format_after_refinement(full, source_text=model_raw)
        except Exception:

            layout_error_code = 'layout_failed'

    t_layout = round(time.perf_counter() - layout_started, 4) if layout_eligible else 0.0
    segment_diag = getattr(asr, "_last_segment_diag", None) or {}
    reported_languages = asr.normalize_detected_languages(
        detected_languages
        if detected_languages is not None
        else segment_diag.get("detected_languages")
    )
    segment_route = (
        f"分段{segment_diag.get('blocks', '?')}块"
        if segment_diag.get("mode") == "segmented"
        else "整段"
    )
    e2e_note = f"⚠️端到端失败({e2e_fail})→回落·" if e2e_fail else ""
    if source_route == "cloud":
        asr_label = getattr(asr, "_last_rescue", "") or (
            f"云端 {getattr(cfg, 'asr_cloud_model', '?')}(整段)"
        )
    else:
        asr_label = f"{getattr(cfg, 'asr_engine', '?')}/{segment_route}"
    out = {
        "text": full,
        "done": True,
        "route": route,
        "source_route": source_route,
        "asr_raw": model_raw,
        "vocab_context_text": raw,
        "vocab_context_applied": raw != model_raw,

        "pre_vocab": model_raw,
        "post_vocab": raw,
        "t_asr": t_asr,
        "t_polish": round(smart["latency_ms"] / 1000.0, 3),
        "t_layout": t_layout,
        "segment_diag": segment_diag,
        "detected_languages": list(reported_languages),
        "rule_route": rule_route,
        "asr": e2e_note + asr_label,
        "local_text": local_text,
        "smart_candidate": smart.get("candidate"),
        "smart_enhancement": {
            "status": smart["status"],
            "error_code": smart["error_code"],
            "guard_mode": smart["guard_mode"],
            "latency_ms": smart["latency_ms"],
            "validation_issues": list(smart["validation_issues"]),
            "validation_warnings": list(smart["validation_warnings"]),
        },
    }
    out["runtime_receipt"] = _runtime_receipt(
        run_id=run_id,
        entry_route=route,
        asr_route=source_route,
        smart=smart,
        fallback_reason=fallback_reason,
        e2e_failed=bool(e2e_fail),
    )
    if layout_eligible:
        out["runtime_receipt"].update(
            spoken_cleanup_policy_id=spoken_repetition.SPOKEN_REPETITION_POLICY_ID,
            spoken_cleanup_removed_chars=spoken_cleanup_removed,
            spoken_cleanup_error=spoken_cleanup_error,
            layout_policy_id=neutral_list_labels.POLICY_ID,
            layout_newlines_added=full.count("\n") - smart["text"].count("\n"),
        )
    if layout_error_code:
        out["runtime_receipt"]["layout_error_code"] = layout_error_code
    if not full:
        out["runtime_receipt"]["final_status"] = "empty_result"
    if smart.get("usage"):
        out["smart_enhancement"]["usage"] = smart["usage"]
    if diagnostic := safe_provider_diagnostics(smart.get("provider_diagnostics")):
        out["smart_enhancement"]["provider_diagnostics"] = diagnostic
    if getattr(asr, "_last_english_offline", False):
        out["warn"] = "网络不可用:纯中文可离线,这句英文没转出来,请联网重说。"
    elif smart.get("warn"):
        out["warn"] = smart["warn"]
    if fallback_reason == "cloud_not_configured":
        cloud_warning = "云端转写未启用：专用 Key 未配置或读取失败，本次使用本地转写。"
        out["warn"] = " ".join(filter(None, (cloud_warning, out.get("warn"))))
    _debug_log(out)
    return out


def _stream_used_local_rules(st, cfg, *, e2e_priority: bool) -> bool:
    """判断本次 stream 成品是否真的来自本地免费路线。

    不能用 ``ASR_CLOUD`` 开关代替实际路线：开关打开但没有 DashScope key 时，
    ``StreamingTranscriber`` 会明确回落本地。旧判断仍把它当云端结果，导致数字、
    疑问语气和本地排版规则全部被跳过。
    """
    if e2e_priority or getattr(cfg, "asr_provider", "local") != "local":
        return False
    actual_route = getattr(st, "last_route", "")
    if actual_route:
        return actual_route == "local"

    cloud_available = (
        getattr(cfg, "asr_cloud", False)
        and bool((getattr(cfg, "asr_cloud_key", "") or "").strip())
    )
    return not cloud_available


def _make_text_enhancer(cfg, *, timeout: tuple[int, int | None] = (TEXT_CONNECT_TIMEOUT_SECONDS, 45)) -> TextEnhancer:
    """只从已解析的 Config 组装 provider；不读环境、Keychain 或用户文件。"""
    provider = OpenAICompatibleProvider(
        base_url=getattr(cfg, "llm_base_url", ""),
        api_key=getattr(cfg, "llm_api_key", ""),
        model=getattr(cfg, "polish_model", ""),
        timeout=timeout,
    )
    return TextEnhancer(provider)


_SMART_DICTATION_CATASTROPHIC_ISSUES = frozenset(
    {
        "empty_output",
        "output_too_long",
        "output_too_short",
        "punctuation_removed",
        "language_changed",
    }
)


def _wait_for_smart_result(call, on_progress):
    """主线程独占 stdout；只有支持取消的新客户端才进入持续等待。

    心跳仅表示本机仍在等，不代表供应商正在生成。取消由 Swift 中断管道并终止
    自己的 daemon（包括阻塞 HTTP 线程），不向同一请求追加第二次模型调用。
    """
    if on_progress is None:
        return call()
    completed = threading.Event()
    result, failures = [], []
    def work():
        try:
            result.append(call())
        except BaseException as exc:
            failures.append(exc)
        finally:
            completed.set()
    started = time.monotonic()
    on_progress(0, 0.0)
    threading.Thread(target=work, name="liana-smart-request", daemon=True).start()
    sequence = 0
    while not completed.wait(1.0):
        sequence += 1
        on_progress(sequence, round(time.monotonic() - started, 3))
    if failures:
        raise failures[0]
    return result[0]


def _supports_smart_progress(req):

    if req.get("smart_progress") is not True:
        return False
    try:
        uuid.UUID(str(req.get("run_id", "")))
        return True
    except (ValueError, AttributeError, TypeError):
        return False


def _smart_dictation(
    text: str,
    cfg,
    *,
    route: str,
    local_rules: bool,
    source_route: str | None = None,
    allow_network: bool,
    protected_terms: tuple[str, ...] | None = None,
    on_progress=None,
) -> dict:
    ""







    raw_guard_mode = str(getattr(cfg, "smart_dictation_guard_mode", "strict") or "")
    guard_mode = "model_first" if raw_guard_mode.strip().lower() == "model_first" else "strict"
    base = {
        "text": text,
        "candidate": None,
        "status": "skipped",
        "error_code": None,
        "guard_mode": guard_mode,
        "latency_ms": 0,
        "validation_issues": (),
        "validation_warnings": (),
        "usage": None,
        "warn": "",
        "prompt_id": None,
        "prompt_sha256": None,
    }
    if not getattr(cfg, "smart_dictation_enabled", False):
        return {**base, "status": "disabled"}
    if not allow_network:
        return {**base, "error_code": "network_not_authorized"}
    if source_route is None:
        source_route = "local" if local_rules else "external"
    if route not in {"stream", "path_fallback"} or source_route not in {"local", "cloud"}:
        return {**base, "error_code": "ineligible_route"}
    if not (text or "").strip():
        return {**base, "error_code": "empty_selection"}
    if not (getattr(cfg, "llm_api_key", "") or "").strip():
        return {
            **base,
            "status": "fallback",
            "error_code": "no_polish_key",
            "warn": "智能整理未运行：没有配置文字模型 Key，已保留整理前的转写结果。",
        }

    prompt_id, prompt_sha256 = smart_dictation_prompt_identity()
    request_id, request_sha256 = smart_dictation_request_identity()
    attempted = {
        **base,
        "prompt_id": prompt_id,
        "prompt_sha256": prompt_sha256,
        "request_template_id": request_id,
        "request_template_sha256": request_sha256,
    }
    try:
        request = EnhancementInput(
            selection=text,
            operation=Operation.SMART_DICTATION,
            protected_terms=asr.common_tech_terms() if protected_terms is None else protected_terms,
        )
        result = _wait_for_smart_result(lambda: _make_text_enhancer(
            cfg, timeout=(TEXT_CONNECT_TIMEOUT_SECONDS, None) if on_progress is not None else (2, 4)
        ).enhance(request), on_progress)
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception:
        result = EnhancementResult(
            text=text,
            ready_for_preview=False,
            status="fallback",
            operation=Operation.SMART_DICTATION.value,
            latency_ms=0,
            error_code="provider_failed",
        )

    issues = tuple(result.validation_issues)
    warnings = tuple(result.validation_warnings)
    usage = result.usage.as_dict() if result.usage is not None else None
    diagnostic_candidate = result.diagnostic_candidate or result.text
    safe = result.ready_for_preview and not issues
    if safe:
        return {
            **attempted,
            "text": result.text,
            "candidate": result.text,
            "status": "unchanged" if result.text == text else "applied",
            "latency_ms": result.latency_ms,
            "validation_warnings": warnings,
            "usage": usage,
        }

    catastrophic_issues = _SMART_DICTATION_CATASTROPHIC_ISSUES.intersection(issues)
    adopt_observed_candidate = (
        guard_mode == "model_first"
        and result.error_code == "validation_failed"
        and bool((result.diagnostic_candidate or "").strip())
        and not catastrophic_issues
    )
    if adopt_observed_candidate:
        return {
            **attempted,
            "text": diagnostic_candidate,
            "candidate": diagnostic_candidate,
            "status": "unchanged" if diagnostic_candidate == text else "applied",
            "error_code": "validation_observed",
            "latency_ms": result.latency_ms,
            "validation_issues": issues,
            "validation_warnings": warnings,
            "usage": usage,
        }

    error_code = result.error_code or (
        "validation_warning" if warnings else "validation_failed"
    )
    if issues:
        warn = "智能候选已生成，但关键内容发生变化，已保留整理前的转写结果。"
    elif error_code == "provider_output_truncated":
        warn = "智能整理的响应被服务截断，已保留完整转写。"
    elif error_code == "provider_timeout":
        stage = safe_provider_diagnostics(result.provider_diagnostics).get("failure_stage")
        reason = {
            "connect": "连接文字服务超时",
            "read": "文字服务连接或响应等待超时",
            "handshake_or_read": "文字服务连接或响应等待超时",
        }.get(stage, "文字服务请求超时")
        warn = reason + "，已保留完整转写。"
    elif error_code == "provider_network_error":
        stage = safe_provider_diagnostics(result.provider_diagnostics).get("failure_stage")
        warn = ("文字服务安全连接失败" if stage == "tls" else "文字服务连接中断") + "，已保留完整转写。"
    elif error_code == "provider_content_rejected":
        warn = "文字服务因内容审核拒绝处理，已保留完整转写。"
    elif error_code == "provider_bad_request":
        warn = "文字服务未接受本次请求（HTTP 400），已保留完整转写。"
    elif error_code == "provider_auth_failed":
        warn = "文字服务验证失败，请检查 Key；已保留完整转写。"
    elif error_code == "provider_rate_limited":
        warn = "文字服务限流或额度不足，请检查服务账户；已保留完整转写。"
    else:
        warn = "智能整理暂时不可用，已保留整理前的转写结果。"
    return {
        **attempted,
        "candidate": diagnostic_candidate,
        "status": "fallback",
        "error_code": error_code,
        "latency_ms": result.latency_ms,
        "validation_issues": issues,
        "validation_warnings": warnings,
        "usage": usage,
        "warn": warn,
        "provider_diagnostics": safe_provider_diagnostics(result.provider_diagnostics) or None,
    }


def _enhancement_preview_response(
    result: EnhancementResult,
    *,
    instruction: str | None = None,
) -> dict:
    ""




    payload = {
        "status": result.status,
        "ready_for_preview": result.ready_for_preview,
        "candidate": result.text,
        "operation": result.operation,
        "latency_ms": result.latency_ms,
        "error_code": result.error_code,
        "validation_issues": list(result.validation_issues),
        "validation_warnings": list(result.validation_warnings),
    }
    if result.usage is not None:
        payload["usage"] = result.usage.as_dict()
    if diagnostic := safe_provider_diagnostics(result.provider_diagnostics):
        payload["provider_diagnostics"] = diagnostic
    if instruction is not None:
        payload["instruction"] = instruction
    return {"enhancement_preview": payload}


def _review_history_refinement(result: EnhancementResult) -> EnhancementResult:
    """手动文字重润色沿用V8；非灾难性差异供预览核对，不自动落字。"""
    if (
        result.error_code == "validation_failed"
        and result.diagnostic_candidate and result.diagnostic_candidate.strip()
        and not _SMART_DICTATION_CATASTROPHIC_ISSUES.intersection(result.validation_issues)
    ):
        result = replace(
            result, text=result.diagnostic_candidate, ready_for_preview=True, status="ready",
            error_code=None, validation_issues=(),
            validation_warnings=tuple(dict.fromkeys(result.validation_issues + result.validation_warnings)),
        )
    if result.ready_for_preview:
        result = replace(result, text=postprocess.linebreak_explicit_ordinals(result.text))
    return result


def _enhancement_preview_fallback(
    selection: str,
    operation: str,
    error_code: str,
    *,
    instruction: str | None = None,
) -> dict:
    return _enhancement_preview_response(
        EnhancementResult(
            text=selection,
            ready_for_preview=False,
            status="fallback",
            operation=operation,
            latency_ms=0,
            error_code=error_code,
        ),
        instruction=instruction,
    )


_ENHANCEMENT_EVENT_TOKEN = re.compile(r"^[A-Za-z0-9_.:-]{1,96}$")
_ENHANCEMENT_EVENT_OPERATIONS = frozenset(
    {operation.value for operation in Operation} | {"instruction"}
)


def _safe_enhancement_event_token(value, *, fallback: str = "unknown") -> str:
    """把运行元数据限制为短标识符，避免正文或供应商响应混进诊断日志。"""
    if isinstance(value, str) and _ENHANCEMENT_EVENT_TOKEN.fullmatch(value):
        return value
    return fallback


def _enhancement_event(
    request: dict,
    response: dict,
    cfg,
    *,
    timestamp: str | None = None,
) -> dict | None:
    ""




    if not isinstance(request, dict):
        return None
    if "enhance_preview" in request:
        route = "selected_fixed_action"
        body = request.get("enhance_preview")
        if isinstance(body, dict) and body.get("operation") == Operation.SMART_DICTATION.value:
            route = "history_text_refinement"
        instruction_mode = "none"
    elif "enhance_instruction_preview" in request:
        route = "selected_voice_instruction"
        body = request.get("enhance_instruction_preview")
        if isinstance(body, dict) and isinstance(body.get("instruction"), str) and body["instruction"].strip():
            instruction_mode = "text"
        elif isinstance(body, dict) and isinstance(body.get("path"), str) and body["path"]:
            instruction_mode = "local_audio"
        else:
            instruction_mode = "missing"
    else:
        return None

    body = body if isinstance(body, dict) else {}
    preview = response.get("enhancement_preview") if isinstance(response, dict) else None
    preview = preview if isinstance(preview, dict) else {}

    operation = preview.get("operation")
    if not isinstance(operation, str) or operation not in _ENHANCEMENT_EVENT_OPERATIONS:
        requested_operation = body.get("operation")
        operation = (
            requested_operation
            if isinstance(requested_operation, str)
            and requested_operation in _ENHANCEMENT_EVENT_OPERATIONS
            else ("instruction" if route == "selected_voice_instruction" else "unknown")
        )

    raw_status = preview.get("status")
    status = raw_status if raw_status in {"ready", "rejected", "fallback"} else "daemon_error"
    raw_error_code = preview.get("error_code")
    if status == "daemon_error":
        error_code = "daemon_exception"
    elif raw_error_code is None:
        error_code = "none"
    else:
        error_code = _safe_enhancement_event_token(raw_error_code, fallback="unclassified")

    def safe_codes(value) -> list[str]:
        if not isinstance(value, (list, tuple)):
            return []
        return [
            token
            for item in value[:20]
            if (token := _safe_enhancement_event_token(item, fallback=""))
        ]

    def safe_count(value) -> int | None:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return max(0, int(value))

    selection = body.get("selection")
    candidate = preview.get("candidate")
    usage = preview.get("usage")
    usage = usage if isinstance(usage, dict) else {}
    event = {
        "schema": "liana.enhancement_event.v2",
        "timestamp": timestamp or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "route": route,
        "operation": operation,
        "instruction_mode": instruction_mode,
        "status": status,
        "ready_for_preview": preview.get("ready_for_preview") is True,
        "error_code": error_code,
        "latency_ms": safe_count(preview.get("latency_ms")),
        "selection_chars": len(selection) if isinstance(selection, str) else 0,
        "candidate_chars": len(candidate) if isinstance(candidate, str) else 0,
        "validation_issues": safe_codes(preview.get("validation_issues")),
        "validation_warnings": safe_codes(preview.get("validation_warnings")),
        "input_tokens": safe_count(usage.get("input_tokens")),
        "output_tokens": safe_count(usage.get("output_tokens")),
        "total_tokens": safe_count(usage.get("total_tokens")),
        "model": _safe_enhancement_event_token(
            getattr(cfg, "polish_model", ""), fallback="custom"
        ),
    }
    if diagnostic := safe_provider_diagnostics(preview.get("provider_diagnostics")):
        event["provider_diagnostics"] = diagnostic
    return event


def _append_enhancement_event(event: dict | None, *, path: str | None = None) -> None:
    ""
    if event is None:
        return
    try:
        event_path = path or os.path.expanduser(
            "~/Library/Application Support/VoiceFlow/enhancement-events.jsonl"
        )
        directory = os.path.dirname(event_path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        fd = os.open(event_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8", closefd=True) as handle:
                handle.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
        except Exception:
            try:
                os.close(fd)
            except OSError:
                pass
            raise
    except (OSError, TypeError, ValueError):
        return


def _handle(req: dict, cfg, state: dict):
    if "credential_check" in req:

        return credential_check.handle(req["credential_check"], cfg, state)

    if "enroll" in req:
        from core import speaker
        try:
            speaker.enroll(asr._as_samples(req["enroll"]))
            return {"enrolled": True}
        except Exception as e:
            return {"enrolled": False, "error": f"{type(e).__name__}: {e}"}
    if "speaker" in req:
        from core import speaker
        op = req["speaker"]
        if op == "clear":
            speaker.clear_enrollment()
            return {"enrolled": False}
        return {"enrolled": speaker.is_enrolled(), "available": speaker.available()}
    if "speaker_config" in req:
        sc = req["speaker_config"]
        cfg.speaker_verify = bool(sc.get("verify", cfg.speaker_verify))
        cfg.speaker_threshold = float(sc.get("threshold", cfg.speaker_threshold))
        return None


    if "enhance_preview" in req:
        ec = req["enhance_preview"]
        if not isinstance(ec, dict):
            ec = {}
        selection = ec.get("selection", "")
        selection = selection if isinstance(selection, str) else ""
        operation = ec.get("operation", "")
        operation = operation if isinstance(operation, str) else ""

        if not getattr(cfg, "text_enhancement_enabled", False):
            return _enhancement_preview_fallback(
                selection, operation, "text_enhancement_disabled"
            )
        if ec.get("allow_network") is not True:
            return _enhancement_preview_fallback(
                selection, operation, "network_not_authorized"
            )
        if not (getattr(cfg, "llm_api_key", "") or "").strip():
            return _enhancement_preview_fallback(selection, operation, "no_polish_key")

        raw_terms = ec.get("protected_terms", ())
        protected_terms = (
            tuple(term for term in raw_terms if isinstance(term, str) and term.strip())
            if isinstance(raw_terms, (list, tuple))
            else ()
        )
        try:
            result = _make_text_enhancer(cfg).enhance(
                EnhancementInput(
                    selection=selection,
                    operation=operation,
                    protected_terms=protected_terms,
                )
            )
        except Exception:

            return _enhancement_preview_fallback(selection, operation, "provider_failed")
        if operation == Operation.SMART_DICTATION.value:
            result = _review_history_refinement(result)
        return _enhancement_preview_response(result)



    if "enhance_instruction_preview" in req:
        ec = req["enhance_instruction_preview"]
        if not isinstance(ec, dict):
            ec = {}
        selection = ec.get("selection", "")
        selection = selection if isinstance(selection, str) else ""
        operation = "instruction"
        instruction = ec.get("instruction", "")
        instruction = instruction.strip() if isinstance(instruction, str) else ""

        if not getattr(cfg, "text_enhancement_enabled", False):
            return _enhancement_preview_fallback(
                selection,
                operation,
                "text_enhancement_disabled",
                instruction=instruction,
            )
        if ec.get("allow_network") is not True:
            return _enhancement_preview_fallback(
                selection,
                operation,
                "network_not_authorized",
                instruction=instruction,
            )
        if not (getattr(cfg, "llm_api_key", "") or "").strip():
            return _enhancement_preview_fallback(
                selection,
                operation,
                "no_polish_key",
                instruction=instruction,
            )
        if not selection.strip():
            return _enhancement_preview_fallback(
                selection,
                operation,
                "empty_selection",
                instruction=instruction,
            )

        if not instruction:
            path = ec.get("path", "")
            if isinstance(path, str) and path:
                try:

                    instruction = str(asr._transcribe_local(path, cfg)).strip()
                except Exception:
                    return _enhancement_preview_fallback(
                        selection,
                        operation,
                        "instruction_transcription_failed",
                        instruction="",
                    )
        if not instruction:
            return _enhancement_preview_fallback(
                selection,
                operation,
                "no_instruction",
                instruction="",
            )

        raw_terms = ec.get("protected_terms", ())
        protected_terms = (
            tuple(term for term in raw_terms if isinstance(term, str) and term.strip())
            if isinstance(raw_terms, (list, tuple))
            else ()
        )
        try:
            result = _make_text_enhancer(cfg).enhance(
                EnhancementInput(
                    selection=selection,
                    operation=operation,
                    protected_terms=protected_terms,
                    instruction=instruction,
                )
            )
        except Exception:
            return _enhancement_preview_fallback(
                selection,
                operation,
                "provider_failed",
                instruction=instruction,
            )
        return _enhancement_preview_response(result, instruction=instruction)



    if "edit" in req:
        ec = req["edit"]
        selection = ec.get("selection", "")
        instruction = ec.get("instruction", "")

        if not getattr(cfg, "text_enhancement_enabled", False):
            return {"error": "text_enhancement_disabled"}
        if ec.get("allow_network") is not True:
            return {"error": "network_not_authorized"}
        if not (getattr(cfg, "llm_api_key", "") or "").strip():
            return {"error": "no_polish_key"}
        if not instruction and ec.get("path"):
            instruction = postprocess.clean(asr._transcribe_local(ec["path"], cfg))
        if not selection.strip():
            return {"error": "no_selection"}
        if not instruction.strip():
            return {"error": "no_instruction"}
        try:
            return {"text": polish.edit(selection, instruction, cfg), "instruction": instruction}
        except Exception as e:
            return {"error": f"{type(e).__name__}: {e}"}


    if "learn" in req:
        lc = req["learn"]
        return {"learned": polish.learn_correction(lc.get("old", ""), lc.get("new", ""), cfg, raw=lc.get("raw", ""))}


    if "set_engine" in req:
        cfg.asr_engine = req["set_engine"]
        asr.warm_local(cfg)
        return None


    op = req.get("stream")
    if op == "start":
        old = state.get("stream")
        if old is not None:
            old.close()



        cfg.asr_context = req.get("context", "") or ""
        e2e_priority = e2e.enabled(cfg)
        state["e2e_priority"] = e2e_priority
        stream_cfg = (replace(cfg, asr_provider="local", asr_cloud=False)
                      if e2e_priority else cfg)
        state["stream"] = StreamingTranscriber(stream_cfg)
        return None
    if op == "audio":
        st = state.get("stream")
        if st is not None:
            import numpy as np
            pcm = np.frombuffer(base64.b64decode(req["pcm"]), dtype=np.int16)
            st.feed(pcm.astype(np.float32) / 32768.0)
        return None
    if op == "cancel":
        st = state.pop("stream", None)
        state.pop("e2e_priority", None)
        if st is not None:
            st.close()
        return None
    if op == "stop":
        st = state.pop("stream", None)
        e2e_priority = state.pop("e2e_priority", False)
        if st is None:
            return {"error": "no active stream"}
        cfg.polish_style = req.get("style", "clean")
        t0 = time.time()




        _e2e_fail = ""
        if e2e_priority:
            frames = getattr(st, "_all", None)
            if frames:
                import numpy as _np
                _samples = _np.concatenate(frames)




                if len(_samples) < 16000 * 0.5:
                    _samples = None
                _context = asr._e2e_context(cfg)
                _text = e2e.transcribe(_samples, cfg, _context)







                if _text:
                    _leak = gate.suspect_prompt_leak(e2e.system_prompt(_context), "", _text)
                    if _leak:
                        _text = ""
                        e2e.LAST_ERROR = f"复述提示词({_leak[:16]}…)"
                _e2e_fail = e2e.LAST_ERROR if not _text else ""
                if _text:
                    st.close()
                    final = voice_commands.from_sentinels(
                        postprocess.strip_hard_breaks(postprocess.fix_english(
                            _text, postprocess.english_repairs(_text))))
                    final = postprocess.drop_redundant_comma_after_strong_punct(final)
                    _emit({"delta": final})
                    out = {"text": final, "done": True, "asr_raw": _text,
                           "route": "stream", "source_route": "e2e",
                           "asr": f"e2e/{e2e._MODEL}", "note": "e2e",
                           "t_asr": round(time.time() - t0, 2), "t_polish": 0.0}
                    out["runtime_receipt"] = _runtime_receipt(
                        run_id=req.get("run_id"),
                        entry_route="stream",
                        asr_route="e2e",
                        prompt_id="e2e-system-current",
                        prompt_sha256=hashlib.sha256(
                            e2e.system_prompt(_context).encode("utf-8")
                        ).hexdigest(),
                        final_status="e2e_applied",
                    )
                    _debug_log(out)
                    return out

        model_raw = st.finish()
        return _finalize_transcription(
            model_raw,
            cfg,
            t0=t0,


            local_rules=_stream_used_local_rules(
                st, cfg, e2e_priority=e2e_priority
            ),
            detected_languages=getattr(st, "detected_languages", None),
            route="stream",
            source_route=getattr(st, "last_route", None),
            e2e_fail=_e2e_fail,
            run_id=req.get("run_id"),
            fallback_reason=getattr(st, "fallback_reason", "") or "",
            smart_progress=_supports_smart_progress(req),


            allow_smart_enhancement=(
                req.get("smart_enhance") is True
                and req.get("allow_network") is True
            ),
        )


    cfg.polish_style = req.get("style", "clean")
    path = req["path"]
    t0 = time.time()
    try:
        transcription = asr.transcribe(path, cfg)
        model_raw = str(transcription)
        source_route = (
            "cloud"
            if getattr(cfg, "asr_provider", "local") == "qwen_cloud"
            else "local"
        )
        return _finalize_transcription(
            model_raw,
            cfg,
            t0=t0,



            local_rules=source_route == "local",
            detected_languages=getattr(transcription, "detected_languages", None),
            route="path_fallback",
            source_route=source_route,
            run_id=req.get("run_id"),
            fallback_reason=req.get("fallback_reason", ""),
            smart_progress=_supports_smart_progress(req),


            allow_smart_enhancement=(
                req.get("smart_enhance") is True
                and req.get("allow_network") is True
            ),
        )
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}"}


def main() -> None:
    cfg = Config.from_env()
    asr.warm_local(cfg)

    state: dict = {}
    sys.stdout.write(json.dumps({"ready": True, "credentials": credential_check.readiness(cfg)}) + "\n")
    sys.stdout.flush()


    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        request = None
        try:
            request = json.loads(line)
            payload = _handle(request, cfg, state)
        except Exception as e:
            payload = {"error": f"{type(e).__name__}: {e}"}
        if payload is None:
            continue
        _append_enhancement_event(_enhancement_event(request, payload, cfg))
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
