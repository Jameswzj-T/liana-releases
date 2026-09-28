""













import re

_MAX_TERMS = 40
_MIN_LEN = 2


_TOKEN = re.compile(r"[A-Za-z][A-Za-z0-9_.\-]*")
_HAS_DIGIT = re.compile(r"\d")
_INNER_UPPER = re.compile(r"[a-z][A-Z]")


def _is_common(word: str, dictionary) -> bool:
    """这是不是个普通英文词?(普通词 ASR 本来就对,不该占提示词的位置)

    系统词典 /usr/share/dict/words 【不收词形变化】—— 有 deploy 没有 deployed。
    不还原词形的话,一堆过去式/进行时会被当成"专名"混进词表,把真正的专名【挤出】长度上限
    (上下文词排在最前,被挤掉的就是它们)。所以先剥常见后缀再查。"""
    if not dictionary:
        return False
    w = word.lower()
    if w in dictionary:
        return True
    for suf in ("ing", "ed", "es", "s", "ly", "er", "est"):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            stem = w[: -len(suf)]

            if stem in dictionary or stem + "e" in dictionary:
                return True
            if len(stem) >= 4 and stem[-1] == stem[-2] and stem[:-1] in dictionary:
                return True
    return False






_STOP_CAP = {
    "the", "a", "an", "and", "or", "but", "so", "if", "then", "this", "that", "these", "those",
    "i", "we", "you", "he", "she", "it", "they", "my", "our", "your", "his", "her", "its", "their",
    "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "can", "could", "will",
    "would", "shall", "should", "may", "might", "must", "have", "has", "had", "there", "here",
    "what", "when", "where", "who", "why", "how", "which", "not", "no", "yes", "ok", "okay",
    "for", "from", "with", "without", "to", "of", "in", "on", "at", "by", "as", "about", "after",
    "before", "now", "also", "just", "only", "very", "all", "some", "any", "each", "both",
    "let", "get", "make", "see", "note", "todo", "first", "next", "last", "one", "two", "three",
}


def is_distinctive(tok: str, dictionary=None) -> bool:
    """这个词值不值得喂给 ASR?—— 判据是"ASR 容易听错的那类词"。

    普通英文单词(the / because / deployed)ASR 本来就对,送了只是占提示词长度、
    还会把真专名挤出长度上限。真正会错的是:CamelCase、全大写缩写、带数字/下划线的标识符、专名。"""
    if len(tok) < _MIN_LEN:
        return False
    core = tok.strip("._-")
    if not core or not core[0].isalpha():
        return False
    if _INNER_UPPER.search(core):
        return True
    if core.isupper() and len(core) >= _MIN_LEN:
        return True
    if _HAS_DIGIT.search(core) or "_" in core or "." in core:
        return True
    if core[0].isupper():
        return core.lower() not in _STOP_CAP
    return not _is_common(core, dictionary)


def extract_terms(text: str, dictionary=None, limit: int = _MAX_TERMS) -> list:
    ""

    if not text:
        return []
    out, seen = [], set()
    for m in _TOKEN.finditer(text):
        tok = m.group(0).strip("._-")
        if not tok or tok.lower() in seen:
            continue
        if is_distinctive(tok, dictionary):
            seen.add(tok.lower())
            out.append(tok)
            if len(out) >= limit:
                break
    return out
