"""Narrow cleanup of a duplicated demonstrative in successful dictation.

This is not general deduplication: ordinary reduplication, names, quoted text,
code, and repetitions separated by punctuation are not rewritten.
"""
import re

from core.literal_text import LiteralText

SPOKEN_REPETITION_POLICY_ID = "spoken-demonstrative-repair-v1"
_RESTART = re.compile(
    r"(?<![这A-Za-z0-9_@#$])这这"
    r"(?P<quantity>(?:[一二两三四五六七八九十百]{1,4}|[1-9][0-9]{0,3}|几))"
    r"(?P<classifier>[个件条项台位张本份次])"
    r"(?![A-Za-z0-9_])"
)



_LITERAL_INTENT = re.compile(
    r"逐字|逐句|原样|原文|照抄|照读|拼写|字符|汉字|字样|字面|字数|"
    r"重复字|两个字|个字|变量|字段|标识|代码|口令|密码|昵称|人名|名字|"
    r"名为|叫做|叫这这|叫那那|网名|用户名"
)
_CODE = re.compile(r"^[ \t]*\t|^ {4}|[=<>\[\]{}()\\]|->", re.MULTILINE)
_UNPAIRED = re.compile(r"[`\"“”‘’「」『』《》]")
_SINGLE_QUOTE = re.compile(r"(?<![A-Za-z])'|'(?![A-Za-z])")


def _plain(text: str) -> LiteralText | None:
    if _LITERAL_INTENT.search(text):
        return None
    held = LiteralText(text)


    if (_CODE.search(held.masked) or _UNPAIRED.search(held.masked)
            or _SINGLE_QUOTE.search(held.masked)):
        return None
    return held


def repair_demonstrative_restart(text: str, *, source: str | None = None) -> str:
    """Remove one redundant 这 from 恰好两次这 + quantity + classifier.

Use only after accepted automatic refinement. Pass the original input too so
the model dropping a literal marker cannot turn a quotation into cleanup text.
No whitespace, punctuation, numbers, other words, or layout are changed.
"""
    if "这这" not in text:
        return text
    if source is not None:
        original = _plain(source)
        if original is None:
            return text


        if source.count("这这") != original.masked.count("这这"):
            return text
    held = _plain(text)
    if held is None:
        return text
    repaired = _RESTART.sub(
        lambda match: "这" + match["quantity"] + match["classifier"], held.masked
    )
    return held.restore(repaired)
