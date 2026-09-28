""






















import difflib
import re
from dataclasses import dataclass, field

_CJK_ONE = re.compile(r"^[一-鿿]+$")
_SENTINEL = re.compile(r"⟦[A-Z]⟧")









_TOKEN = re.compile(r"[一-鿿]|[A-Za-z]+")

_LEAK_N = 6






_LEAK_FRAG = 7
_LEAK_COVER = 30





_MAX_VIOLATION = 6






_MAX_LEAD_SKIP = 20

















_MIN_RETAIN = 0.30
_RETAIN_MIN_TOKENS = 10


@dataclass
class Verdict:
    ok: bool
    violations: list = field(default_factory=list)
    mass: int = 0
    guesses: list = field(default_factory=list)

    @property
    def reason(self) -> str:
        return f"[越界{self.mass}] " + "; ".join(self.violations[:3]) if self.violations else ""

    @property
    def guess_note(self) -> str:
        """给日志/历史记录用:润色到底替他猜了什么。★不拦,但要让他看得见★
        (他 7/15 的决定:小的猜词放过 —— 猜对居多;但必须【可观测】,否则猜错了他也不知道。
         攒几周真实猜错率,再决定要不要收紧成"零容忍"。)"""
        return "润色猜词:" + " ".join(f"{a}→{b}" for a, b in self.guesses[:6]) if self.guesses else ""


def _tokens(s: str) -> list:
    """切成对齐用的 token:【每个汉字一个】+【每个英文单词一个】。哨兵/标点/数字/空白全丢掉。"""
    return _TOKEN.findall(_SENTINEL.sub("", s or ""))


def _readings(ch: str) -> set:
    """一个汉字的【全部】无声调读音。

    ★必须用全部读音,不能用 lazy_pinyin 的默认读音★ —— 多音字会毁掉整条判据:
    lazy_pinyin 给「地」返回 di、给「得」返回 de、给「的」返回 de
    → 「的→地」(最典型的合法纠错,他日志里 ×109)会被判成"不同音"当场拦掉。
    取【全部读音求交集】才对:的{de,di} ∩ 地{de,di} ≠ ∅ → 同音 ✅
    """
    from pypinyin import pinyin, Style
    return {p for group in pinyin(ch, style=Style.NORMAL, heteronym=True) for p in group}


def _same_sound(a: str, b: str) -> bool:
    """同音判定:逐字【读音集合有交集】。
    的/得/地 · 他/它 · 在/再 · 做/作 · 见/建 → True(合法纠错)
    死/准(si/zhun)· 好/考(hao/kao)→ False(编造)
    只对【纯汉字且等长】的替换有意义;拼音库缺失时保守判 False(宁可误拦,不可放编造)。"""
    if len(a) != len(b) or not (_CJK_ONE.match(a) and _CJK_ONE.match(b)):
        return False
    try:
        return all(_readings(x) & _readings(y) for x, y in zip(a, b))
    except ImportError:
        return False


_ME = ("我", "咱")
_YOU = ("你", "您")


def _swaps_stance(a: str, b: str) -> bool:
    """这次替换是不是把【我】和【你】对调了?—— 那是改变立场,不是纠错。

    "你整理一下发给我看" → "我整理一下发给你看":谁做事、发给谁全反了,等于偷偷替对方回话。
    记忆里记着的老灾难(polish-nondeterminism:"人称我↔你全反,同 temp=0 也偶发")。
    ★体量闸抓不住它★:我/你 同长不同音,只算 1 字体量 → 必须单独零容忍。

    注意别误伤合法的代词纠正:他→她(性别)、他→它(指物)—— 那些不涉及【我/你】,不进这条。
    """
    a_me, a_you = any(c in a for c in _ME), any(c in a for c in _YOU)
    b_me, b_you = any(c in b for c in _ME), any(c in b for c in _YOU)
    return (a_me and b_you and not b_me) or (a_you and b_me and not b_you)


def review(src: str, out: str, known=None, partial: bool = False) -> Verdict:
    """润色输出 out 相对输入 src,有没有越界?

    known = 用户词库 + 纠错表里的词(小写)。词库替换(cloud→Claude)是【用户主动登记过的】,
    有明确的"他关心这个词"的证据 → 放行,不算编造。

    partial=True:out 只是【开头一段】(流式审头用),src 仍是整段。
    """
    known = {k.lower() for k in (known or ())}
    a, b = _tokens(src), _tokens(out)
    if not a:
        return Verdict(ok=True)
    if partial and b:






        blocks = [m for m in difflib.SequenceMatcher(None, a, b, autojunk=False)
                  .get_matching_blocks() if m.size]
        if blocks:
            a = a[:blocks[-1].a + blocks[-1].size]

    def _pair_ok(x: str, y: str) -> bool:
        """一对 token 的替换合不合法。"""
        return (x.lower() == y.lower()
                or y.lower() in known
                or _same_sound(x, y))

    viol, mass, guesses, hard = [], 0, [], []

    if not partial and len(a) >= _RETAIN_MIN_TOKENS and len(b) / len(a) < _MIN_RETAIN:
        hard.append(f"吞掉{100 - int(100 * len(b) / len(a))}%的话({len(a)}→{len(b)}字)")
    ops = difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes()


    if ops and ops[0][0] == "delete" and (ops[0][2] - ops[0][1]) > _MAX_LEAD_SKIP:
        hard.append(f"吃掉开头「{''.join(a[ops[0][1]:ops[0][2]])[:14]}…」{ops[0][2]-ops[0][1]}字")
    for tag, i1, i2, j1, j2 in ops:
        if tag in ("equal", "delete"):
            continue
        fa, fb = a[i1:i2], b[j1:j2]
        sa, sb = "".join(fa), "".join(fb)
        if tag == "insert":
            if sb.lower() in known:
                continue
            viol.append(f"凭空插入「{sb[:12]}」")
            mass += len(fb)
        elif tag == "replace":
            if sb.lower() in known:
                continue
            if len(fa) == len(fb) and all(_pair_ok(x, y) for x, y in zip(fa, fb)):
                continue
            if _swaps_stance(sa, sb):




                hard.append(f"人称对调「{sa[:8]}」→「{sb[:8]}」")
                continue
            if _CJK_ONE.match(sa) and _CJK_ONE.match(sb):
                kind = "变长改写" if len(fa) != len(fb) else "不同音改写"
            else:
                kind = "英文改写"
            viol.append(f"{kind}「{sa[:8]}」→「{sb[:12]}」")
            mass += max(len(fa), len(fb))
            guesses.append((sa, sb))




    return Verdict(ok=(not hard) and mass <= _MAX_VIOLATION,
                   violations=hard + viol, mass=mass, guesses=guesses)


_RUNAWAY_RATIO = 1.5
_RUNAWAY_FLOOR = 8


def looks_like_runaway(src: str, out: str) -> bool:
    """out 的【token 数】相对 src 是否暴涨到"执行指令 / 生成一整段新文档"的程度。★流式"边敲边审"用★

    - 正常润色【只删不加】→ 输出 token 数 ≤ 输入(即便为通顺改写"应该→基本解决了",也被别处删口水抵掉,不显著变长)→ False。
    - 执行编造 = 凭空生成一大段新内容 → 输出 token 数远超输入 → True。
    ★为什么用长度、不用 difflib 的 insert 体量★:流式中途,输入还有【没产出的尾巴】,
    编造会被 difflib 当成"替换那条尾巴"(insert=0)而【漏判】;长度不受对齐影响,稳。
    比例(×1.5)管长输入,地板(+8 token)防短输入误伤。src 先剥哨兵再数(⟦P⟧ 等不算内容)。"""
    ns = len(_tokens(_SENTINEL.sub("", src)))
    no = len(_tokens(out))
    return no > ns * _RUNAWAY_RATIO + _RUNAWAY_FLOOR











_REPEAT_MIN = 16


def looks_like_repeat(out: str) -> str:
    """输出末尾有没有一整段【前面已经出现过】的长片段 = 模型陷进复读循环了。
    返回那段重复的文本(空 = 没复读)。★流式"边敲边审"用★:逮到就停敲,别让它一直复读下去。"""
    t = (out or "").rstrip("。！？.!? \n")
    for n in range(len(t) // 2, _REPEAT_MIN - 1, -1):
        if t[-n:] in t[:-n]:
            return t[-n:]
    return ""








_CYCLE_MIN_UNIT = 2
_CYCLE_MIN_TIMES = 3
_CYCLE_MIN_TOTAL = 24


def looks_like_cycle(out: str) -> str:
    """末尾是不是由同一小段【连续重复】堆成的 = 模型陷进了复读循环。
    返回那一串重复(空 = 没有)。判据三条同时满足:周期≥2 字、连着≥3 遍、总长≥24 字。

    ★宁可漏、不可误★:润色输出本来就该高度保留原话,中文合法重复极多;
    误拦一次 = 把他正常的话掐掉半截,比漏掉一次复读难受得多。
    """
    t = (out or "").rstrip("。！？.!? \n")
    n = len(t)
    for p in range(_CYCLE_MIN_UNIT, n // _CYCLE_MIN_TIMES + 1):
        unit = t[n - p:]
        k = 1
        while (k + 1) * p <= n and t[n - (k + 1) * p: n - k * p] == unit:
            k += 1
        if k >= _CYCLE_MIN_TIMES and k * p >= _CYCLE_MIN_TOTAL:
            return unit * k
    return ""


def token_count(s: str) -> int:
    """token 数(汉字逐字、英文整词;先剥哨兵)。保留率/吞话判据统一走它。"""
    return len(_tokens(_SENTINEL.sub("", s or "")))


def retention(src: str, out: str) -> float:
    """润色输出保留了输入多大比例(token 计)。<1 = 变短(删口水 或 吞话);观测 + 吞话闸共用。"""
    n = token_count(src)
    return token_count(out) / n if n else 1.0


def suspect_eaten(src: str, out: str) -> bool:
    """★吞话·灾难级★ 输出短到 _MIN_RETAIN(0.30)线以下、且输入够长(≥10 token)。
    ★专给【开闸后·字已敲出·退不回】的长输出用★ —— 上层只能【警告用户核对】,不能退回原文
    (退回会叠在已敲的字后头)。短输出的吞话在 review(partial=False) 里【敲字前】就拦下、直接退原文,不走这条。
    ★只逮灾难(→『好的』那种 0.14)★:0.30~1.0 的中度压缩(如漏掉一句)【不在这里拦】——那要靠观测攒数据再设计精准探测器,
    别用这根为『好的』标定的粗线去误伤正常删口水。"""
    return token_count(src) >= _RETAIN_MIN_TOKENS and retention(src, out) < _MIN_RETAIN







_RULE_MARK = re.compile(r"绝不|铁律|不许|务必|一律|只输出")


def suspect_prompt_leak(prompt: str, src: str, out: str) -> str:
    ""









    if not prompt or not out:
        return ""
    hits, seen = [], set()
    for i in range(len(out) - _LEAK_N + 1):
        frag = out[i:i + _LEAK_N]
        if frag in seen or not _RULE_MARK.search(frag):
            continue
        if frag in prompt and frag not in src:
            seen.add(frag)
            hits.append(frag)
    if not hits:

        covered = [False] * len(out)
        for i in range(len(out) - _LEAK_FRAG + 1):
            frag = out[i:i + _LEAK_FRAG]
            if frag in prompt and frag not in src:
                for k in range(i, i + _LEAK_FRAG):
                    covered[k] = True
        n = sum(covered)
        if n >= _LEAK_COVER:
            return f"复述提示词: {n} 字抄自提示词(散在多处)"
    return "复述提示词: " + " / ".join(hits[:3]) if hits else ""









_BOUNDARY = re.compile(r"[!?！？。]|(?<!\d)\.(?![0-9A-Za-z])")


_MIN_HEAD = 12


def split_head(buf: str, cap: int):
    ""













    for m in _BOUNDARY.finditer(buf):
        if m.end() < _MIN_HEAD:
            continue
        if m.end() <= cap:
            return buf[:m.end()], buf[m.end():]
        break
    if len(buf) >= cap:




        cut = buf.rfind(" ", 0, cap + 1)
        if cut <= 0:
            cut = cap
        return buf[:cut], buf[cut:]
    return None, buf
