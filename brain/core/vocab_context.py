""








from __future__ import annotations

from collections import Counter
import re

from pypinyin import Style, pinyin


_CJK = re.compile(r"^[\u3400-\u9fff]+$")


def tone_key(text: str) -> tuple[str, ...] | None:
    """返回汉字词的逐字拼音(含数字声调)，非纯汉字或空串返回 None。

    例如：小律/小绿都是 ``("xiao3", "lv4")``，效率是
    ``("xiao4", "lv4")``。严格比较整组音节，不做编辑距离或近音吸附。
    """
    if not text or not _CJK.fullmatch(text):
        return None
    values = pinyin(text, style=Style.TONE3, heteronym=False, strict=False)
    return tuple(item[0] for item in values)


def same_pronunciation(left: str, right: str) -> bool:
    """判断两个纯汉字词是否逐字同音同调。"""
    left_key = tone_key(left)
    right_key = tone_key(right)
    return left_key is not None and left_key == right_key


def context_variant_counts(standard: str, context: str) -> dict[str, int]:
    ""




    key = tone_key(standard)
    if key is None or not context:
        return {}
    width = len(standard)
    counts: Counter[str] = Counter()
    for start in range(0, len(context) - width + 1):
        candidate = context[start : start + width]
        if candidate == standard:
            continue
        if tone_key(candidate) == key:
            counts[candidate] += 1
    return dict(counts)


def choose_spelling(
    candidate: str,
    standard: str,
    context: str = "",
    *,
    min_context_occurrences: int = 2,
) -> str:
    ""










    if not same_pronunciation(candidate, standard):
        return candidate

    variants = context_variant_counts(standard, context)
    eligible = {
        spelling: count
        for spelling, count in variants.items()
        if count >= max(1, min_context_occurrences)
    }
    if eligible:


        if context.count(standard) > 0:
            return candidate
        highest = max(eligible.values())
        winners = [s for s, count in eligible.items() if count == highest]
        if len(winners) == 1:
            return winners[0]
        return candidate
    return standard


def resolve_text(
    text: str,
    standards: list[str] | tuple[str, ...],
    context: str = "",
    *,
    min_context_occurrences: int = 2,
) -> str:
    ""






    if not text or not standards:
        return text


    by_key: dict[tuple[str, ...], str] = {}
    ambiguous: set[tuple[str, ...]] = set()
    for standard in standards:
        key = tone_key(standard)
        if key is None:
            continue
        previous = by_key.get(key)
        if previous is not None and previous != standard:
            ambiguous.add(key)
        else:
            by_key[key] = standard

    lengths = sorted({len(standard) for standard in by_key.values()}, reverse=True)
    if not lengths:
        return text

    output: list[str] = []
    index = 0
    while index < len(text):
        if not ("\u3400" <= text[index] <= "\u9fff"):
            output.append(text[index])
            index += 1
            continue

        match: tuple[str, str] | None = None
        for width in lengths:
            if index + width > len(text):
                continue
            candidate = text[index : index + width]
            key = tone_key(candidate)
            if key is None or key in ambiguous:
                continue
            standard = by_key.get(key)
            if standard is not None and _has_hard_boundary(text, index, index + width):
                match = (candidate, standard)
                break

        if match is None:
            output.append(text[index])
            index += 1
            continue

        candidate, standard = match
        output.append(
            choose_spelling(
                candidate,
                standard,
                context,
                min_context_occurrences=min_context_occurrences,
            )
        )
        index += len(candidate)

    return "".join(output)





_LATIN_TOKEN = re.compile(r"[A-Za-z][A-Za-z0-9]*(?:[._-][A-Za-z0-9]+)*|\d+")


def _latin_key(text: str) -> str:
    """忽略大小写、空格和 ASCII 标点，得到专名比较键。"""
    return "".join(
        char.casefold()
        for char in text
        if char.isascii() and char.isalnum()
    )


def _latin_is_distinctive(standard: str) -> bool:
    """只允许有明确专名信号的词条进入自动规范化。"""
    tokens = _LATIN_TOKEN.findall(standard)
    if not tokens:
        return False
    for token in tokens:
        if re.search(r"[a-z][A-Z]", token):
            return True
        if token.isupper() and len(token) >= 2:
            return True
        if any(char.isdigit() for char in token):
            return True
        if any(char in "._-" for char in token):
            return True


    if len(tokens) == 1 and tokens[0] and tokens[0][:1].isupper() and not tokens[0].isupper():
        return True

    return len(tokens) >= 2 and sum(token[:1].isupper() for token in tokens) >= 2


def _latin_canonical_map(standards: list[str] | tuple[str, ...]) -> dict[str, str]:
    """构造无歧义的标准写法表；同一 key 有多个写法时宁可跳过。"""
    candidates: dict[str, set[str]] = {}
    for standard in standards:
        standard = (standard or "").strip()
        key = _latin_key(standard)
        if not key:
            continue
        candidates.setdefault(key, set()).add(standard)
    return {
        key: next(iter(values))
        for key, values in candidates.items()
        if len(values) == 1 and _latin_is_distinctive(next(iter(values)))
    }


def canonical_latin_term(term: str, standards: list[str] | tuple[str, ...]) -> str:
    """按明确登记的标准写法规范一个屏幕专名；不做模糊匹配。"""
    canonical = _latin_canonical_map(standards)
    return canonical.get(_latin_key(term), term)


def resolve_latin_text(
    text: str,
    standards: list[str] | tuple[str, ...],
    *,
    require_internal_space: bool = False,
    alphanumeric_standards: list[str] | tuple[str, ...] | None = None,
) -> str:
    """把英文专名的大小写/空格变体收回用户登记的写法。

    只匹配 ASCII token 的连续空格序列，且标准词必须有专名信号；不做编辑距离、
    同音或语义替换。因此 ``chat GPT``→``ChatGPT``、``codex``→``CodeX`` 可以修，
    但 ``cloud code``→``Claude Code``、``Human Three``→``Qwen3`` 不会被猜改。
    ``require_internal_space`` 用于内置标准：只收 ``I T`` / ``Power HA`` 这类拆写，
    不顺手改变用户原本未拆开的大小写。
    """
    if not text or not standards:
        return text


    text = resolve_spoken_latin_alphanumeric_terms(
        text, standards if alphanumeric_standards is None else alphanumeric_standards,
        require_internal_space=require_internal_space,
    )
    canonical = {
        key: value for key, value in _latin_canonical_map(standards).items()
        if not _ALPHANUMERIC_STANDARD.fullmatch(value)
    }
    if not canonical:
        return text

    tokens = list(_LATIN_TOKEN.finditer(text))
    if not tokens:
        return text


    max_width = max(4, max(len(_LATIN_TOKEN.findall(standard)) for standard in canonical.values()))
    output: list[str] = []
    cursor = 0
    index = 0
    changed = False
    while index < len(tokens):
        best: tuple[int, int, str, int] | None = None
        upper = min(len(tokens), index + max_width)
        for end in range(upper, index, -1):

            if any(
                not text[tokens[pos].end() : tokens[pos + 1].start()].isspace()
                for pos in range(index, end - 1)
            ):
                continue
            start_pos = tokens[index].start()
            end_pos = tokens[end - 1].end()
            raw = text[start_pos:end_pos]
            if require_internal_space and not any(char.isspace() for char in raw):
                continue
            replacement = canonical.get(_latin_key(raw))
            if replacement is not None and replacement != raw:
                best = (start_pos, end_pos, replacement, end)
                break
        if best is None:
            index += 1
            continue
        start_pos, end_pos, replacement, next_index = best
        output.append(text[cursor:start_pos])
        output.append(replacement)
        cursor = end_pos
        index = next_index
        changed = True
    if not changed:
        return text
    output.append(text[cursor:])
    return "".join(output)


_EN_SINGLE_DIGIT_WORDS = {
    "zero": "0",
    "one": "1",
    "two": "2",
    "three": "3",
    "four": "4",
    "five": "5",
    "six": "6",
    "seven": "7",
    "eight": "8",
    "nine": "9",
}
_LATIN_NUMERIC_SUFFIX_STANDARD = re.compile(
    r"^(?P<base>[A-Za-z]+(?:[._-][A-Za-z]+)*)(?P<digit>[0-9])$"
)
_EN_MODEL_SUFFIX_CUE = re.compile(
    r"^[ \t]+(?:model|version|release|series|engine|system|platform|product|device|"
    r"console|generation|variant|checkpoint)\b",
    re.IGNORECASE,
)
_ZH_MODEL_SUFFIX_CUE = re.compile(
    r"^[ \t]*(?:模型|版本|发布|候选|系统|平台|产品|设备|主机|系列|型号|代|版|型|款|"
    r"来|去|在|是|用于|进行|，|。|！|？|；|：|$)"
)

_ZH_SINGLE_DIGIT_CHARS = {
    "0": "零〇",
    "1": "一幺",
    "2": "二两",
    "3": "三",
    "4": "四",
    "5": "五",
    "6": "六",
    "7": "七",
    "8": "八",
    "9": "九",
}
_LATIN_DIGIT_DASH_STANDARD = re.compile(
    r"^(?P<base>[A-Za-z]+(?:[._+][A-Za-z]+)*)(?P<digit>[0-9])-"
    r"(?P<suffix>[A-Za-z][A-Za-z0-9._+]*)$"
)


def _spaced_ascii_literal(value: str) -> str:
    """允许 ASR 在一个已登记拉丁片段内部插入空格。"""
    return r"[ \t]*".join(re.escape(char) for char in value)


def resolve_spoken_latin_structured_terms(
    text: str,
    standards: list[str] | tuple[str, ...],
) -> str:
    """恢复已登记的“拉丁词干 + 口述数字 + 横杠 + 拉丁后缀”。

    规则完全由标准写法反推。例如只有登记 ``Qwen3-ASR`` 后，
    ``Qwen 三杠 ASR`` 才会收成标准写法。词干、数字或后缀有任一项不符都
    保持原文；同一结构登记了多个大小写版本时也跳过，不做模糊或语义猜测。
    """
    if not text or not standards:
        return text

    candidates: dict[tuple[str, str, str], set[str]] = {}
    for standard in _latin_canonical_map(standards).values():
        match = _LATIN_DIGIT_DASH_STANDARD.fullmatch(standard)
        if match is None:
            continue
        signature = (
            match.group("base").casefold(),
            match.group("digit"),
            match.group("suffix").casefold(),
        )
        candidates.setdefault(signature, set()).add(standard)

    for (base, digit, suffix), values in sorted(
        candidates.items(),
        key=lambda item: len(item[0][0]) + len(item[0][2]),
        reverse=True,
    ):
        if len(values) != 1:
            continue
        standard = next(iter(values))
        digit_forms = re.escape(digit + _ZH_SINGLE_DIGIT_CHARS.get(digit, ""))
        pattern = re.compile(
            r"(?<![A-Za-z0-9_])"
            + _spaced_ascii_literal(base)
            + r"[ \t]*(?:["
            + digit_forms
            + r"])[ \t]*(?:杠|横杠|短横线|连字符)[ \t]*"
            + _spaced_ascii_literal(suffix)
            + r"(?![A-Za-z0-9_])",
            re.IGNORECASE,
        )
        text = pattern.sub(standard, text)
    return text


def resolve_spoken_latin_numeric_suffixes(
    text: str,
    standards: list[str] | tuple[str, ...],
) -> str:
    """收登记专名末尾的单个中英文口述数字，不猜错听的专名词干。

    只从标准词里推导，例如登记 ``Qwen3`` 后，``Qwen three model``、
    ``Qwen 三模型`` 与 ``Qwen Three,`` 可收成 ``Qwen3``。数字后必须是
    句末/标点或明确型号/使用语境；``Qwen three times``、``Qwen 三次运行``、
    ``Qwen three Python tools`` 保持数量含义。
    词干必须逐字匹配，因此不会把 ``QN Three``、``Q One Three``、
    ``Human Three`` 猜成 ``Qwen3``，也不跨越模型误放的逗号。
    """
    if not text or not standards:
        return text

    candidates: dict[tuple[str, str], set[str]] = {}
    for standard in _latin_canonical_map(standards).values():
        match = _LATIN_NUMERIC_SUFFIX_STANDARD.fullmatch(standard)
        if match is None:
            continue
        spoken = next(
            (word for word, digit in _EN_SINGLE_DIGIT_WORDS.items()
             if digit == match.group("digit")),
            None,
        )
        if spoken is None:
            continue
        forms = {spoken, match.group("digit")}
        forms.update(_ZH_SINGLE_DIGIT_CHARS.get(match.group("digit"), ""))
        for form in forms:
            key = (match.group("base").casefold(), form.casefold())
            candidates.setdefault(key, set()).add(standard)

    unambiguous = {
        key: next(iter(values))
        for key, values in candidates.items()
        if len(values) == 1
    }
    if not unambiguous:
        return text

    bases = sorted({key[0] for key in unambiguous}, key=len, reverse=True)
    number_forms = sorted({key[1] for key in unambiguous}, key=len, reverse=True)
    pattern = re.compile(
        r"(?<![A-Za-z0-9_])(?P<base>"
        + "|".join(re.escape(base) for base in bases)
        + r")[ \t]*(?P<number>"
        + "|".join(re.escape(form) for form in number_forms)
        + r")"
        + r"(?![A-Za-z0-9_])",
        re.IGNORECASE,
    )

    def _replace(match: re.Match) -> str:
        key = (match.group("base").casefold(), match.group("number").casefold())
        standard = unambiguous.get(key)
        if standard is None:
            return match.group(0)
        tail = text[match.end():]
        if not tail or tail[0] in ",.!?;:":
            return standard
        if _EN_MODEL_SUFFIX_CUE.match(tail):
            return standard
        if _ZH_MODEL_SUFFIX_CUE.match(tail):
            return standard
        return match.group(0)

    return pattern.sub(_replace, text)


_ALPHANUMERIC_STANDARD = re.compile(r"(?=.{3,32}$)[A-Za-z]+(?:[0-9]+[A-Za-z]+)+$")
_ALPHANUMERIC_LITERAL = re.compile(r"```[\s\S]*?(?:```|\Z)|`[^`\n]*`")
_ALPHANUMERIC_ENUM_BEFORE = re.compile(
    r"(?:\b(?:spell(?:ing)?(?:[ \t]+out)?|letters?|characters?|separately|one[ \t]+by[ \t]+one)|"
    r"字母|字符|逐字|拼写|分别(?:输入|写下|列出)?|依次(?:输入|写下|列出)?|一个一个|按顺序)"
    r"[ \t:：、,]*$", re.IGNORECASE,
)
_ALPHANUMERIC_ENUM_AFTER = re.compile(
    r"^[ \t]*(?:分别|依次|各自|(?:are|as)[ \t]+(?:separate[ \t]+)?(?:letters|characters|options)\b)",
    re.IGNORECASE,
)
_ALPHANUMERIC_COMPONENT = r"(?:[A-Za-z0-9]|zero|one|two|three|four|five|six|seven|eight|nine)"
_ALPHANUMERIC_EXTRA_BEFORE = re.compile(
    r"(?<![A-Za-z0-9_])" + _ALPHANUMERIC_COMPONENT + r"[ \t]+$", re.IGNORECASE,
)
_ALPHANUMERIC_EXTRA_AFTER = re.compile(
    r"^[ \t]+" + _ALPHANUMERIC_COMPONENT + r"(?![A-Za-z0-9_])", re.IGNORECASE,
)


def alphanumeric_standard_variants(standards: list[str] | tuple[str, ...]) -> tuple[str, ...]:
    """只选本次新规则涉及的标准及冲突写法，不扩大其他个人词的校验范围。"""
    keys = {
        _latin_key(term) for term in standards
        if _ALPHANUMERIC_STANDARD.fullmatch((term or "").strip())
    }

    return tuple(term for term in standards if _latin_key(term) in keys)


def resolve_spoken_latin_alphanumeric_terms(
    text: str,
    standards: list[str] | tuple[str, ...],
    *,
    require_internal_space: bool = False,
) -> str:
    """完整登记的字母数字交错名称，逐字符恢复拼读而不猜词。

    支持单个数字的中英文读法及逐位数字；不接纳 to/too、字母读音近似、
    跨标点/换行或未知组件。数字后缀型号仍归旧的专门规则处理。
    这同一函数也供 Validator 做等价投影；标准表不是模型提示词。
    """
    if not text or not standards:
        return text
    candidates = [
        value for value in _latin_canonical_map(standards).values()
        if _ALPHANUMERIC_STANDARD.fullmatch(value)
    ]
    english_digits = {digit: word for word, digit in _EN_SINGLE_DIGIT_WORDS.items()}
    for standard in sorted(candidates, key=len, reverse=True):
        parts = []
        for char in standard:
            if char.isdigit():

                parts.append(
                    "(?:[" + char + _ZH_SINGLE_DIGIT_CHARS[char] + "]|"
                    r"(?<=[ \t])" + english_digits[char] + r"(?=[ \t]))"
                )
            else:
                parts.append(re.escape(char))
        pattern = re.compile(
            r"(?<![A-Za-z0-9_./@+\-])" + r"[ \t]*".join(parts)
            + r"(?![A-Za-z0-9_/@+\-]|\.[A-Za-z0-9])", re.IGNORECASE | re.ASCII,
        )
        literal_spans = [match.span() for match in _ALPHANUMERIC_LITERAL.finditer(text)]

        def replace(match: re.Match) -> str:
            raw = match.group(0)
            if require_internal_space and not re.search(r"[ \t]", raw):
                return raw
            if any(start <= match.start() < end for start, end in literal_spans):
                return raw
            before, after = text[:match.start()], text[match.end():]
            if (
                _ALPHANUMERIC_ENUM_BEFORE.search(before)
                or _ALPHANUMERIC_ENUM_AFTER.match(after)
                or _ALPHANUMERIC_EXTRA_BEFORE.search(before)
                or (
                    _ALPHANUMERIC_EXTRA_AFTER.match(after)

                    and not re.match(r"^[ \t]+a[ \t]+[a-z]{2,}\b", after)
                )
            ):
                return raw
            return standard

        text = pattern.sub(replace, text)
    return text


def _has_hard_boundary(text: str, start: int, end: int) -> bool:
    """只接受词条两侧非汉字/文本边界，避免在中文复合词中滑窗误替换。"""
    before = text[start - 1] if start else ""
    after = text[end] if end < len(text) else ""
    return (not before or not ("\u3400" <= before <= "\u9fff")) and (
        not after or not ("\u3400" <= after <= "\u9fff")
    )


_PRODUCT_ALIAS_LEFT = re.compile(
    r"(?:(?:使用|打开|启动|运行|测试|检查|安装|卸载|更新|升级|重启|退出|关闭|配置)|"
    r"(?:use|open|launch|run|test|check|install|uninstall|update|upgrade|restart|quit|close|configure))\s*$",
    re.IGNORECASE,
)
_PRODUCT_ALIAS_RIGHT = re.compile(
    r"^\s*(?:(?:软件|工具|应用|程序|客户端|版本|项目|模型|系统)|"
    r"(?:software|tool|app|application|client|version|project|model|system)\b)",
    re.IGNORECASE,
)
_PRODUCT_ALIAS_COORDINATED_RIGHT = re.compile(
    r"^\s*(?:(?:和|与|及|以及)|、|(?:and|or)\b|&)\s*"
    r"[A-Za-z](?:[A-Za-z0-9._+-]|[ \t]+[A-Za-z0-9])*(?![A-Za-z0-9_])",
    re.IGNORECASE,
)
_BUILTIN_SPELLING_CORRECTIONS = (("CodeX", "Codex"),)


def _cjk_to_latin_product_context(text: str, start: int, end: int, wrong: str, right: str) -> bool:
    """允许用户确认的中文音译在明确软件语境中还原为拉丁品牌名。

    中文没有空格词界，不能把 ``李安娜→Liana`` 无条件套进所有句子。这里只接受：左侧是明确
    的软件操作动词，且右侧已结束/遇到标点；或右侧直接说明它是软件、工具、应用等。人物语境
    （如“我认识李安娜”“演员李安娜”）继续保护。
    """
    if not wrong or not all("\u3400" <= char <= "\u9fff" for char in wrong):
        return False
    if not re.search(r"[A-Za-z]", right):
        return False
    left = text[max(0, start - 12):start]
    tail = text[end:end + 10]
    if _PRODUCT_ALIAS_RIGHT.match(tail):
        return True
    if not _PRODUCT_ALIAS_LEFT.search(left):
        return False


    if _PRODUCT_ALIAS_COORDINATED_RIGHT.match(tail):
        return True
    return not tail or tail[0].isspace() or tail[0] in "，。！？；：,.!?;:"


def _correction_boundary(text: str, start: int, end: int, wrong: str, right: str) -> bool:
    """给用户明确登记的错→对映射加最小边界保护。

    英文映射只在独立英文词上命中；纯中文映射只在汉字硬边界上命中，避免把
    ``小绿→小律`` 误套进 ``小绿帽``。明确映射仍比模糊词库强，但不允许跨词污染。
    """
    before = text[start - 1] if start else ""
    after = text[end] if end < len(text) else ""
    has_cjk = any("\u3400" <= char <= "\u9fff" for char in wrong)
    if has_cjk:
        hard_boundary = (not before or not ("\u3400" <= before <= "\u9fff")) and (
            not after or not ("\u3400" <= after <= "\u9fff")
        )
        return hard_boundary or _cjk_to_latin_product_context(text, start, end, wrong, right)
    return (not before or not (before.isascii() and (before.isalnum() or before == "_"))) and (
        not after or not (after.isascii() and (after.isalnum() or after == "_"))
    )


def _replace_pair_when(text: str, wrong: str, right: str, allowed) -> str:
    """只在 ``allowed(text, start, end)`` 为真时替换一对固定写法。"""
    chunks: list[str] = []
    cursor = 0
    search_from = 0
    while True:
        found = text.find(wrong, search_from)
        if found < 0:
            chunks.append(text[cursor:])
            break
        end = found + len(wrong)
        if not allowed(text, found, end):
            search_from = end
            continue
        chunks.append(text[cursor:found])
        chunks.append(right)
        cursor = end
        search_from = end
    return "".join(chunks)


def apply_exact_corrections(text: str, pairs: list[tuple[str, str]] | tuple[tuple[str, str], ...]) -> str:
    """应用用户确认的错→对映射；不调用模型、不做模糊匹配。

    长映射先处理，替换后的文字不会在同一条映射里再次循环匹配。
    """
    if not text or not pairs:
        return text
    result = text
    for wrong, right in sorted(pairs, key=lambda pair: len(pair[0]), reverse=True):
        if not wrong or wrong == right:
            continue
        result = _replace_pair_when(
            result,
            wrong,
            right,
            lambda current, start, end: _correction_boundary(current, start, end, wrong, right),
        )
    return result


def apply_builtin_product_corrections(text: str) -> str:
    """应用不依赖个人数据的极窄产品写法规则。

    当前只保留 ``CodeX→Codex`` 这一项客观大小写归一。Liana 的音译/近音变体和
    ``Cloud Code→Claude Code`` 都需要猜用户本意，只能由用户自己的 Learned edit 决定，
    不进入干净安装的公共规则。
    """
    return apply_exact_corrections(text, _BUILTIN_SPELLING_CORRECTIONS)
