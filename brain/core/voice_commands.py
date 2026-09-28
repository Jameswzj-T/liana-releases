""














import re


_P = "⟦P⟧"
_N = "⟦N⟧"
SENTINELS = (_P, _N)


_CP = r"，。、；：,.;:!?！？…"





_BREAK = (
    (_P, ("新段落", "另起一段", "下一段", "new paragraph")),
    (_N, ("换行", "另起一行", "new line")),
)



_BULLET_DROP = ("项目符号", "bullet point")



_PUNCT = (
    ("。", ("句号",)), ("，", ("逗号",)), ("？", ("问号",)), ("！", ("感叹号", "叹号")),
    ("：", ("冒号",)), ("；", ("分号",)),
)




_AFTER_NOT_CMD = r"(?!的|地|得|了|时|之后|以后|以前|之前|符号|键|吧|呢|啊|嘛|了)"





_PUNCT_PRE_NOT_CMD = "理用加打写改说谈提放补删换调标"
_PUNCT_PRE_SKIP = " \t\n个了的下些点"


def _sub_break(text: str, phrase: str, repl: str) -> str:
    """断行命令 → 哨兵。单边放宽只接受左侧真实子句标点；句首或仅右侧标点宁漏勿误。"""
    flags = re.IGNORECASE if phrase.isascii() else 0
    esc = re.escape(phrase)
    pat = (r"([" + _CP + r"])\s*" + esc
           + r"\s*(?=$|[" + _CP + r"]|" + _AFTER_NOT_CMD + r")")
    return re.sub(pat, lambda m: m.group(1) + repl, text, flags=flags)


def _sub_prefix(text: str, phrase: str, repl: str) -> str:
    ""













    flags = re.IGNORECASE if phrase.isascii() else 0
    esc = re.escape(phrase)
    pat = (r"(?:([" + _CP + r"])\s*)?" + esc
           + r"\s*(?:[" + _CP + r"][ \t]*|$)")

    def _rep(m):
        if not text[:m.start()].strip():
            return m.group(0)




        if m.group(1) is None and m.start() > 0:
            prev = ""
            i = m.start() - 1
            while i >= 0 and len(prev) < 2:
                if text[i] not in _PUNCT_PRE_SKIP:
                    prev = text[i] + prev
                i -= 1
            if prev and any(c in _PUNCT_PRE_NOT_CMD for c in prev):
                return m.group(0)
        return repl
    return re.sub(pat, _rep, text, flags=flags)


def _drop_prefix_command(text: str, phrase: str) -> str:
    """路线 B:删掉命令位置的短语(前导须是子句标点),连它后随的停顿标点/空白一起吸掉 —— 交给模型自动排版。
    只在【自成命令】处触发(前面是子句标点),句首/句中的字面内容不碰(宁漏勿误删)。"""
    flags = re.IGNORECASE if phrase.isascii() else 0
    pat = r"([" + _CP + r"])\s*" + re.escape(phrase) + r"[，,、。.；;：: \t]*"
    return re.sub(pat, lambda m: m.group(1), text, flags=flags)


def to_sentinels(text: str, config=None) -> str:
    """润色【前】:命令短语 → 哨兵。长短语先替(另起一段 先于 一段)避免子串先吃。
    config.voice_punct 为真时,额外把'句号/逗号'等换成真标点(默认关)。"""
    if not text:
        return text
    breaks = sorted(((r, p) for r, ps in _BREAK for p in ps), key=lambda rp: len(rp[1]), reverse=True)
    for repl, phrase in breaks:
        text = _sub_break(text, phrase, repl)
    for phrase in sorted(_BULLET_DROP, key=len, reverse=True):
        text = _drop_prefix_command(text, phrase)
    if getattr(config, "voice_punct", False):
        for repl, phrases in _PUNCT:
            for phrase in phrases:
                text = _sub_prefix(text, phrase, repl)
    return text


def _to_format(s: str) -> str:

    s = re.sub(r"[ \t\n]*" + re.escape(_P) + r"[ \t\n]*", "\n\n", s)
    return re.sub(r"[ \t\n]*" + re.escape(_N) + r"[ \t\n]*", "\n", s)


class StreamDesentinelizer:
    """流式:把润色 delta 里的哨兵实时转成排版,让 app 逐块敲字时永不看到哨兵(不碰粘贴层)。
    缓冲尾部【未闭合的哨兵前缀】(⟦…还没等到 ⟧),完整了再转、再放行。
    流式不做标点吸收(前文已敲出、回不去),只做哨兵→排版直替;断行处可能残留一个停顿标点,可接受
    (最终 full 仍走 from_sentinels 做干净版,用于返回/落日志)。"""

    def __init__(self):
        self._buf = ""

    def feed(self, chunk: str) -> str:
        self._buf += chunk
        i = self._buf.rfind("⟦")
        if i != -1 and "⟧" not in self._buf[i:]:
            head, tail = self._buf[:i], self._buf[i:]
        else:
            head, tail = self._buf, ""
        out = _to_format(head)
        m = re.search(r"[ \t\n]+$", out)
        if m:
            tail = out[m.start():] + tail
            out = out[:m.start()]
        self._buf = tail
        return out

    def flush(self) -> str:
        out, self._buf = _to_format(self._buf), ""
        return out


def from_sentinels(text: str) -> str:
    ""


    if not text or not any(s in text for s in SENTINELS):
        return text
    _SENT_PUNCTS = "。.；;：:!?！？…"
    pause = r"[，,、。.；;：:!?！？…\s]*"

    def _repl(sep: str, out: str):
        def f(m):
            pre = m.group(0).split(sep)[0]
            last = ""
            for ch in pre:
                if ch in _SENT_PUNCTS:
                    last = ch
            return last + out
        return f

    text = re.sub(pause + re.escape(_P) + pause, _repl(_P, "\n\n"), text)
    text = re.sub(pause + re.escape(_N) + pause, _repl(_N, "\n"), text)
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()
