"""确定性文本清洗。

这里的每条规则都能被 test_postprocess.py 精确验证(机器能判断对错),
是确定性测试最干净的目标。"""
import re
from collections.abc import Callable

from core.literal_text import LiteralText





























FILLER_WORDS: list[str] = []








_DASH_RANGE = re.compile(r"(?<=\d)\s*[—–―]\s*(?=\d)")


_DASH_CLAUSE = re.compile(r"\s*[—―–]+\s*")
_DUP_PUNCT = re.compile(r"([,;:.!?])\s*,\s*")



_REDUNDANT_COMMA_AFTER_STRONG_PUNCT = re.compile(r"([。！？!?；;：:])(?:[ \t]*[，,])+")


_COMMA_BEFORE_CLOSE = re.compile(r",\s+([”’)\]】》\"'])")


def _normalize_dashes(s: str) -> str:
    s = _DASH_RANGE.sub("-", s)
    s = _DASH_CLAUSE.sub(", ", s)
    s = _DUP_PUNCT.sub(r"\1 ", s)
    return _COMMA_BEFORE_CLOSE.sub(r"\1", s)


def normalize_punct(s: str) -> str:
    ""

    return _normalize_dashes(s)


def drop_redundant_comma_after_strong_punct(s: str) -> str:
    """删除强标点后重复出现的逗号，保留强标点本身。

    这是模型输出的窄范围格式修复：例如 ``问题：，就是说`` → ``问题：就是说``。
    不把它扩展成全局“相邻标点都合并”，避免误伤有意义的 ``？！``、``……`` 等组合。
    """
    if not s:
        return s
    return _REDUNDANT_COMMA_AFTER_STRONG_PUNCT.sub(r"\1", s)








_TECH_LETTER_SEPARATOR = r"[ \t、，,]+"
_TECH_LETTER_SEPARATOR_RE = re.compile(_TECH_LETTER_SEPARATOR)
_TECH_LATIN_PART = (
    r"(?:[A-Za-z](?:" + _TECH_LETTER_SEPARATOR + r"[A-Za-z]){1,15}|"
    r"[A-Za-z][A-Za-z0-9_-]*)"
)
_SPOKEN_INFIX_DOT = re.compile(
    r"(?<![A-Za-z0-9])(?P<left>" + _TECH_LATIN_PART + r")"
    r"[ \t]*点[ \t]*(?P<right>" + _TECH_LATIN_PART + r")"
    r"(?![A-Za-z0-9])"
)
_SPOKEN_LEADING_DOT = re.compile(
    r"(?<![A-Za-z0-9.])点[ \t]*(?P<name>" + _TECH_LATIN_PART + r")"
    r"(?![A-Za-z0-9])"
)
_SPOKEN_REDUNDANT_LEADING_DOT = re.compile(
    r"(?<![A-Za-z0-9.])点[ \t]*(?P<name>\.[A-Za-z][A-Za-z0-9_-]*)"
    r"(?![A-Za-z0-9])"
)
_DOTFILE_OPERATION_BEFORE = re.compile(
    r"(?:打开|编辑|检查|读取|查看|修改|创建|新建|删除|加载|导入|导出)[ \t]*$"
)
_DOTFILE_CLICK_BEFORE = re.compile(
    r"(?:请|你|您|我|我们|咱们|他|她|他们|大家|先|再|然后|接着|直接|去|要|"
    r"需要|可以|应该|帮我|帮忙|鼠标|用鼠标)[ \t，,：:]*$"
)
_DOTFILE_MENTION_BEFORE = re.compile(
    r"(?:这是|这个|那个|所谓|是|为|叫|叫做|名称是|文件名是|名为|"
    r"说的是|指的是|写的是|例如|比如|像)"
    r"[ \t，,：:]*$"
)
_DOTFILE_CLAUSE_BOUNDARIES = "。！？!?；;：:，,、\n“‘（(【["


def _technical_ascii_key(text: str) -> str:
    return "".join(
        char.casefold()
        for char in text
        if char.isascii() and char.isalnum()
    )


def _compact_technical_part(text: str) -> str:
    return _TECH_LETTER_SEPARATOR_RE.sub("", text)


def _dotfile_clause_start(before: str) -> bool:
    stripped = before.rstrip(" \t")
    return not stripped or stripped[-1] in _DOTFILE_CLAUSE_BOUNDARIES


def _unique_dotted_spellings(
    standards: list[str] | tuple[str, ...],
) -> tuple[dict[str, str], dict[str, str]]:
    dotted: dict[str, set[str]] = {}
    leading: dict[str, set[str]] = {}
    for raw in standards or ():
        standard = (raw or "").strip()
        if "." not in standard:
            continue
        key = _technical_ascii_key(standard)
        if not key:
            continue
        dotted.setdefault(key, set()).add(standard)
        if standard.startswith("."):
            leading.setdefault(key, set()).add(standard)
    return (
        {key: next(iter(values)) for key, values in dotted.items() if len(values) == 1},
        {key: next(iter(values)) for key, values in leading.items() if len(values) == 1},
    )


def normalize_spoken_technical_notation(
    text: str,
    standards: list[str] | tuple[str, ...] = (),
) -> str:
    """把有英文与语境证据的口述“点”收成技术标识符。"""
    if not text or "点" not in text:
        return text
    dotted, leading = _unique_dotted_spellings(standards)

    def _infix(match: re.Match) -> str:
        left = _compact_technical_part(match.group("left"))
        right = _compact_technical_part(match.group("right"))

        if len(left) == 1 and len(right) == 1:
            return match.group(0)
        candidate = f"{left}.{right}"
        return dotted.get(_technical_ascii_key(candidate), candidate)

    def _leading(match: re.Match) -> str:
        name = _compact_technical_part(match.group("name"))
        before_all = text[:match.start()]
        before = before_all[-16:]

        if _DOTFILE_CLICK_BEFORE.search(before):
            return match.group(0)

        has_notation_context = bool(
            _DOTFILE_OPERATION_BEFORE.search(before)
            or _DOTFILE_MENTION_BEFORE.search(before)
            or _dotfile_clause_start(before_all)
        )
        if not has_notation_context:
            return match.group(0)

        canonical = leading.get(_technical_ascii_key(name))
        if canonical is not None:
            return canonical

        if len(name) >= 2:
            return "." + name
        return match.group(0)

    def _redundant_leading(match: re.Match) -> str:
        """云 ASR 偶尔既保留口述“点”，又自行写出点文件名：``点 .env``。"""
        name = match.group("name")
        before_all = text[:match.start()]
        before = before_all[-16:]

        if _DOTFILE_CLICK_BEFORE.search(before):
            return match.group(0)
        has_notation_context = bool(
            _DOTFILE_OPERATION_BEFORE.search(before)
            or _DOTFILE_MENTION_BEFORE.search(before)
            or _dotfile_clause_start(before_all)
        )
        if not has_notation_context:
            return match.group(0)
        return leading.get(_technical_ascii_key(name), match.group(0))

    text = _SPOKEN_REDUNDANT_LEADING_DOT.sub(_redundant_leading, text)
    text = _SPOKEN_INFIX_DOT.sub(_infix, text)
    return _SPOKEN_LEADING_DOT.sub(_leading, text)





_SPACED_INITIALISM = re.compile(
    r"(?<![A-Za-z0-9])(?P<term>[A-Z](?:[ \t]+[A-Z]){1,5})(?![A-Za-z0-9])"
)
_INITIALISM_ENUM_AFTER = re.compile(
    r"^[ \t]*(?:分别|依次|各自|[两三四五六七八九十0-9]+个|几个|字母|选项|等级|项目|[两三四五六七八九十0-9]+项)"
)
_INITIALISM_ENUM_BEFORE = re.compile(
    r"(?:字母|选项|等级|分别|依次|各自|逐字|拼写|重复一遍|一个一个|按顺序|输入|写下|列出)"
    r"[ \t：:、,]*$"
)
_ENGLISH_RESTART_AFTER = re.compile(r"^[ \t]+[a-z]+(?:['’-][a-z]+)?\b")


def normalize_spaced_initialisms(text: str) -> str:
    """默认合并 `T U I`，但保留有明确证据的逐字拼写或字母列表。"""
    if not text:
        return text
    matches = list(_SPACED_INITIALISM.finditer(text))
    if not matches:
        return text

    blocked: set[str] = set()
    for match in matches:
        key = re.sub(r"[ \t]+", "", match.group("term"))
        before = text[max(0, match.start() - 18) : match.start()]
        after = text[match.end() : match.end() + 18]
        if _INITIALISM_ENUM_BEFORE.search(before) or _INITIALISM_ENUM_AFTER.match(after):
            blocked.add(key)

    def _replace(match: re.Match) -> str:
        raw = match.group("term")
        key = re.sub(r"[ \t]+", "", raw)
        if key in blocked:
            return raw



        if len(key) >= 2 and set(key) == {"I"}:
            after = text[match.end() : match.end() + 24]
            if _ENGLISH_RESTART_AFTER.match(after):
                return raw
        return key

    return _SPACED_INITIALISM.sub(_replace, text)






_CN_D = {"零": 0, "〇": 0, "一": 1, "幺": 1, "二": 2, "两": 2, "三": 3, "四": 4,
         "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
_CN_U = {"十": 10, "百": 100, "千": 1000}
_CN_NUM_CHARS = "".join(_CN_D) + "".join(_CN_U)

_CN_ID_DIGITS = "零〇一幺二三四五六七八九两"






_EN_ID_DIGITS = {
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
    "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
}
_PARALLEL_LATIN_NUMBER = (
    r"(?:[0-9]+|[" + _CN_NUM_CHARS + r"]{1,8}|"
    + "|".join(_EN_ID_DIGITS)
    + r")"
)
_PARALLEL_LATIN_NUMBERED_ITEM = re.compile(
    r"(?<![A-Za-z0-9_])"
    r"(?P<base>[A-Za-z][A-Za-z0-9._+\-]{0,31})"
    r"[ \t]*(?P<number>" + _PARALLEL_LATIN_NUMBER + r")"
    r"(?![A-Za-z0-9_])",
    re.IGNORECASE,
)
_PARALLEL_LATIN_CONNECTOR = re.compile(
    r"^[ \t]*(?:和|与|及|或|以及|或者|、|，|,|/|and|or|vs\.?|versus)[ \t]*$",
    re.IGNORECASE,
)
_AMBIGUOUS_AFTER_LATIN_NUMBER = re.compile(
    r"(?:[ \t]*(?:点(?![0-9" + _CN_NUM_CHARS + r"])|进制|个|次|遍|回|下|方面|种|类|项|人|天|年|月|周|步|条|件|本|台|家|"
    r"些|样|共|般|边|直|起|定|旦|路|块|份)|[ \t]+[A-Za-z])"
)


def _cn_to_int(s: str):
    """中文数字串 → int；无法解析返回 None。

    纯数字位(如二零二六)按位拼接；含十/百/千时按中文数值规则计算。
    刻意不处理“万/亿”，避免在缺少上下文的免费路线里扩大误判面。
    """
    if not s or any(char not in _CN_NUM_CHARS for char in s):
        return None
    if all(char in _CN_D for char in s):
        return int("".join(str(_CN_D[char]) for char in s))
    total, current = 0, 0
    for char in s:
        if char in _CN_D:
            current = _CN_D[char]
        else:
            total += (current or 1) * _CN_U[char]
            current = 0
    return total + current


def _to_arabic(s: str) -> str:

    if s and all(char in _CN_D for char in s):
        return _cn_digits_to_string(s)
    value = _cn_to_int(s)
    return str(value) if value is not None else s


def _looks_like_latin_identifier(base: str) -> bool:
    """仅判断标识形状；全大写也可能是普通词，不能单独作为转换证据。"""
    letters = [char for char in base if char.isalpha()]
    if not letters:
        return False
    if all(char.isupper() for char in letters):
        return True
    if any(char.isdigit() or char in "._+-" for char in base):
        return True

    return any(char.isupper() for char in base[1:])


def _parallel_latin_number_to_ascii(raw: str) -> str | None:
    if raw.isascii() and raw.isdigit():
        return raw
    english = _EN_ID_DIGITS.get(raw.casefold())
    if english is not None:
        return english
    if raw and all(char in _CN_D for char in raw):
        return "".join(str(_CN_D[char]) for char in raw)
    value = _cn_to_int(raw)

    if value is None or not 0 <= value <= 9999:
        return None
    normalized = raw.replace("两", "二")
    return str(value) if _int_to_cn(value) == normalized else None


def normalize_parallel_latin_numbered_labels(text: str) -> str:
    """原子归一同一拉丁标识的并列编号，不猜单个、未登记的模糊后缀。

    例如 ``RC 一和 RC 二``、``API one / API two`` 会转；
    ``MOVE one or MOVE two steps`` 也保持原文；英文续句不足以排除数量。
    """
    return _normalize_parallel_latin_numbered_labels(text, lambda value: value)


def _normalize_parallel_latin_numbered_labels(
    text: str, keep_ambiguous: Callable[[str], str],
) -> str:
    """同一判断供单步和数字流水线共用；后者占位保护被拒绝的完整组。"""
    if not text:
        return text

    groups: list[list[re.Match]] = []
    for match in _PARALLEL_LATIN_NUMBERED_ITEM.finditer(text):
        previous = groups[-1][-1] if groups else None
        if (
            previous is not None
            and previous.group("base").casefold() == match.group("base").casefold()
            and _PARALLEL_LATIN_CONNECTOR.fullmatch(text[previous.end():match.start()])
        ):
            groups[-1].append(match)
        else:
            groups.append([match])

    output: list[str] = []
    cursor = 0
    for group in groups:
        if len(group) < 2:
            continue
        start, end = group[0].start(), group[-1].end()
        numbers = [_parallel_latin_number_to_ascii(match.group("number")) for match in group]
        accepted = (
            all(_looks_like_latin_identifier(match.group("base")) for match in group)
            and _AMBIGUOUS_AFTER_LATIN_NUMBER.match(text, end) is None
            and all(number is not None for number in numbers)
        )
        output.append(text[cursor:start])
        if accepted:
            part_start = start
            for match, number in zip(group, numbers):
                output.append(text[part_start:match.start()])
                output.append(match.group("base") + number)
                part_start = match.end()
        else:
            output.append(keep_ambiguous(text[start:end]))
        cursor = end
    output.append(text[cursor:])
    return "".join(output)


def _int_to_cn(n: int) -> str:
    """int → 中文数值（支持到千位）；十位开头的“一十”省略“一”。

    只用于反向校验：换算回来必须和原文一致，才认为原文是精确数值而非概数/成语。
    """
    if n == 0:
        return "零"
    digits = "零一二三四五六七八九"
    out: list[str] = []
    if n >= 1000:
        out.append(digits[n // 1000] + "千")
        n %= 1000
        if n and n < 100:
            out.append("零")
    if n >= 100:
        out.append(digits[n // 100] + "百")
        n %= 100
        if n and n < 10:
            out.append("零")
    if n >= 10:
        lead = digits[n // 10] if n // 10 != 1 else ""
        out.append(lead + "十")
        n %= 10
    if n:
        out.append(digits[n])
    return "".join(out)






_PERCENT_VALUE_PATTERN = (
    r"(?:"
    r"\d+(?:\.\d+)?"
    r"|\d+点[" + _CN_ID_DIGITS + r"]+"
    r"|[" + _CN_NUM_CHARS + r"]+(?:点(?:[" + _CN_ID_DIGITS + r"]+|\d+))?"
    r")"
)
_PERCENT_RANGE_SEPARATOR = r"[到至—–―~～-]"
_PERCENT_NUMBER_CONTINUATION = "0123456789" + _CN_NUM_CHARS + "万亿点多几"
_PERCENT_SINGLE_CONTINUATION = _PERCENT_NUMBER_CONTINUATION + "到至—–―~～-"
_RE_EXACT_PERCENT_RANGE = re.compile(
    r"百分之(?P<start>" + _PERCENT_VALUE_PATTERN + r")"
    r"(?P<separator>[ \t]*" + _PERCENT_RANGE_SEPARATOR + r"[ \t]*)"
    r"(?:百分之)?(?P<end>" + _PERCENT_VALUE_PATTERN + r")"
    r"(?![" + re.escape(_PERCENT_NUMBER_CONTINUATION) + r"])(?!个百分点)")
_RE_EXACT_PERCENT = re.compile(
    r"百分之(?P<value>" + _PERCENT_VALUE_PATTERN + r")"
    r"(?![" + re.escape(_PERCENT_SINGLE_CONTINUATION) + r"])(?!个百分点)")
_PERCENT_UNRESOLVED_VALUE = (
    r"(?:多少|几|[" + _CN_NUM_CHARS + r"万亿]+(?:点[" + _CN_ID_DIGITS + r"]+)?(?:多|几)?|"
    r"\d+(?:\.\d+)?(?:多|几)?)"
)
_RE_UNRESOLVED_PERCENT = re.compile(
    r"百分之" + _PERCENT_UNRESOLVED_VALUE
    + r"(?:[ \t]*" + _PERCENT_RANGE_SEPARATOR + r"[ \t]*(?:百分之)?"
    + _PERCENT_UNRESOLVED_VALUE + r")?"
)


def _percentage_integer_to_ascii(raw: str) -> str | None:
    """只接收能唯一解释的百分比整数；并列概数“一二/八九”返回 None。"""
    if raw.isascii() and raw.isdigit():
        return raw
    if not raw or any(char not in _CN_NUM_CHARS for char in raw):
        return None
    if all(char in _CN_D for char in raw):
        return str(_CN_D[raw]) if len(raw) == 1 else None
    value = _cn_to_int(raw)
    if value is None:
        return None
    normalized = raw.replace("两", "二")
    canonical = _int_to_cn(value)
    if canonical == normalized or (
        normalized in {"百", "千"} and canonical == "一" + normalized
    ):
        return str(value)
    return None


def _percentage_value_to_ascii(raw: str) -> str | None:
    """解析明确的整数/小数百分比，保留小数部分的逐位零。"""
    if "." in raw:
        whole, fraction = raw.split(".", 1)
        return raw if whole.isdigit() and fraction.isdigit() else None
    if "点" not in raw:
        return _percentage_integer_to_ascii(raw)
    whole, fraction = raw.split("点", 1)
    whole_ascii = _percentage_integer_to_ascii(whole)
    if whole_ascii is None or not fraction:
        return None
    if fraction.isascii() and fraction.isdigit():
        fraction_ascii = fraction
    elif all(char in _CN_D for char in fraction):
        fraction_ascii = "".join(str(_CN_D[char]) for char in fraction)
    else:
        return None
    return f"{whole_ascii}.{fraction_ascii}"


def _replace_exact_percent_range(match: re.Match) -> str:
    start = _percentage_value_to_ascii(match.group("start"))
    end = _percentage_value_to_ascii(match.group("end"))
    if start is None or end is None:
        return match.group(0)
    return f"{start}%{match.group('separator')}{end}%"


def _replace_exact_percent(match: re.Match) -> str:
    value = _percentage_value_to_ascii(match.group("value"))
    return match.group(0) if value is None else f"{value}%"




_NUMBER_RANGE_VALUE_PATTERN = (
    r"(?:\d+(?:\.\d+)?|[" + _CN_NUM_CHARS + r"万亿]+)"
    r"(?:点[" + _CN_NUM_CHARS + r"万亿0-9]+)*"
    r"(?:多|几|余|来|左右|上下)?"
)
_NUMBER_RANGE_BOUNDARY = "0123456789." + _CN_NUM_CHARS + "万亿点多几余来左右上下"
_RE_NUMBER_RANGE = re.compile(
    r"(?<![" + re.escape(_NUMBER_RANGE_BOUNDARY) + r"])(?P<start>"
    + _NUMBER_RANGE_VALUE_PATTERN
    + r")(?P<separator>[ \t]*(?:到|至|[—–―~～-])[ \t]*)(?P<end>"
    + _NUMBER_RANGE_VALUE_PATTERN
    + r")(?![" + re.escape(_NUMBER_RANGE_BOUNDARY) + r"])"
)


def _exact_number_range_to_ascii(match: re.Match) -> str | None:


    if (
        re.fullmatch(r"[一二两三四五六七八九1-9]", match.group("start"))
        and any(char in match.group("end") for char in "十百千万亿")
    ):
        return None
    start = _percentage_value_to_ascii(match.group("start"))
    end = _percentage_value_to_ascii(match.group("end"))
    if start is None or end is None:
        return None
    return f"{start}{match.group('separator')}{end}"





_RE_NUMERIC_VALUE = re.compile(
    r"(?=[零〇一二两三四五六七八九十百千万]{0,24}[十百千万])"
    r"[零〇一二两三四五六七八九十百千万]{2,}"
)





_SAFE_UNIT = "年月日号位名次遍条张本只台部辆件岁元块米页章节层楼周天步杯瓶家种排组双对份届期批克秒"
_NUM = r"[" + _CN_NUM_CHARS + r"]+"


_CN_DOTTED_CHARS = "0123456789" + _CN_NUM_CHARS + "万亿"
_CN_DOTTED_PART = r"[" + _CN_DOTTED_CHARS + r"]+"
_RE_CN_DOTTED_VALUE = re.compile(
    r"(?<![" + _CN_DOTTED_CHARS + r".点])"
    + _CN_DOTTED_PART + r"(?:点" + _CN_DOTTED_PART + r")+"
    + r"(?![" + _CN_DOTTED_CHARS + r".点])"
)
_RE_CN_CLOCK_PREFIX = re.compile(r"(?:凌晨|清晨|早上|上午|中午|下午|傍晚|晚上|夜里)[ \t]*$")
_RE_CN_CLOCK_SUFFIX = re.compile(r"^[ \t]*(?:分(?!之)|秒|钟)")
_RE_CN_VERSION_PREFIX = re.compile(r"版本(?:号)?[ \t]*(?:是|为|:|：)?[ \t]*$")


_COMPOUND_QUANTITY_ATOM = (
    r"[" + _CN_NUM_CHARS + r"万亿0-9]+(?:[.点][" + _CN_NUM_CHARS + r"万亿0-9]+)?"
    r"(?:多|几|余|来|左右|上下)?"
)
_COMPOUND_QUANTITY_VALUE = (
    _COMPOUND_QUANTITY_ATOM
    + r"(?:[ \t]*" + _PERCENT_RANGE_SEPARATOR + r"[ \t]*"
    + _COMPOUND_QUANTITY_ATOM + r")?"
)
_RE_COMPOUND_QUANTITY = re.compile(
    r"(?<![" + re.escape(_NUMBER_RANGE_BOUNDARY) + r"])(?:"
    + "|".join(
        _COMPOUND_QUANTITY_VALUE + r"[ \t]*(?:" + first_unit + r")"
        + r"(?:[ \t]*(?:又[ \t]*)?" + _COMPOUND_QUANTITY_VALUE
        + r"[ \t]*(?:" + next_unit + r"))+"
        for first_unit, next_unit in (
            (r"个?小时|时|点|分钟|分", r"分钟|分|秒"),
            (r"(?:元|块|角|毛)钱?", r"(?:角|毛|分)钱?|(?=$|[，。！？!?；;\n]|钱)"),
        )
    ) + r")"
)
_RE_ORDINAL = re.compile(r"第(" + _NUM + r")")
_RE_UNIT = re.compile(r"(" + _NUM + r")([" + _SAFE_UNIT + r"])")



_RE_EN_DIGIT_SEQUENCE = re.compile(
    r"([A-Za-z])[ \t]*([" + _CN_ID_DIGITS + r"]{2,})"
)








_LATIN_MODEL_SUFFIX = (
    r"(?:的|代|版|型|款|系列|型号|版本|主机|游戏|产品|设备|平台|系统|模型|"
    r"处理器|芯片|相机|手机|电脑|机器|来|去|用于|进行|在|是|和|与|、|，|。|！|？|!|\?|；|;|：|:|$)"
)
_RE_LATIN_MODEL_SINGLE_DIGIT = re.compile(
    r"(?<![A-Za-z0-9])"
    r"(?P<latin>(?:[A-Z](?:[ \t]+[A-Z]){1,}|"
    r"[A-Z][A-Za-z0-9]{1,}(?:[._-][A-Za-z0-9]+)*))"
    r"[ \t]*(?P<num>[" + _CN_ID_DIGITS + r"])(?=" + _LATIN_MODEL_SUFFIX + r")"
)




_RE_EN_CN_NUM = re.compile(
    r"([A-Za-z])[ \t]?(" + _NUM + r")(?![一-鿿])"
)
_RE_NUM_EN = re.compile(r"(" + _NUM + r")[ \t]?([A-Za-z])")



_RE_EXPLICIT_LATIN_MODEL_NUMBER = re.compile(
    r"(?<![A-Za-z0-9_])(?P<latin>[A-Z][A-Za-z]*(?:[._-][A-Za-z]+)*)"
    r"[ \t]*(?P<num>[" + _CN_NUM_CHARS + r"]{1,8}|[0-9]{1,8})"
    r"(?![" + _CN_NUM_CHARS + r"0-9])"
)
_MODEL_DEVICE_SUFFIX = re.compile(r"^[ \t]*(?:的[ \t]*)?(?:芯片|处理器|电脑|手机|相机|主机|模型)")
_MODEL_NUMBER_PREFIX = re.compile(r"(?:型号|版本号)[ \t]*(?:是|为|[:：])?[ \t]*\Z")
_MODEL_NUMBER_END = re.compile(r"^[ \t]*(?:[，。！？!?；;：:,.)）]|$)")
_ONE_WORD_SUFFIX = re.compile(r"^[ \t]*(?:来|去|是|系列|款)")


def normalize_explicit_latin_model_numbers(text: str, *, protect_literals: bool = True) -> str:
    """窄型号格式：中文整数，或明确编号提示下的大写字母＋ASCII整数。"""
    if protect_literals:
        literals = LiteralText(text)
        return literals.restore(normalize_explicit_latin_model_numbers(
            literals.masked, protect_literals=False,
        ))

    def replace(match: re.Match) -> str:
        latin, raw = match.group("latin"), match.group("num")
        tail = text[match.end():]
        if raw.isascii():



            if (re.fullmatch(r"[A-Z]{1,6}", latin)
                    and _MODEL_NUMBER_PREFIX.search(text[:match.start()])
                    and _MODEL_NUMBER_END.match(tail)
                    and not tail.lstrip(" \t").startswith((":", "："))
                    and not re.match(r"[ \t]*[.,，．٫٬][ \t]*\d", tail)):
                return latin + raw
            return match.group(0)

        if (_AMBIGUOUS_AFTER_LATIN_NUMBER.match(tail)
                or (raw == "一" and _ONE_WORD_SUFFIX.match(tail))):
            return match.group(0)
        clear = (
            _MODEL_DEVICE_SUFFIX.match(tail)
            or (_MODEL_NUMBER_PREFIX.search(text[:match.start()]) and _MODEL_NUMBER_END.match(tail))
            or (len(latin) >= 2 and re.match(r"^[ \t]*(?:版本|型号)", tail))
            or text.strip().rstrip("。.!！?？") == match.group(0)
        )
        number = _parallel_latin_number_to_ascii(raw) if clear else None
        return latin + number if number is not None else match.group(0)

    return _RE_EXPLICIT_LATIN_MODEL_NUMBER.sub(replace, text)





_ID_CUE = r"(?:application|app|应用|版本|编号|文件|目录|路径|截图|照片|原型|构建|build)"
_RE_ID_NUMBER = re.compile(
    r"(?P<num>[" + _CN_ID_DIGITS + r"]{4,})"
    r"(?=(?:[^，。！？!?\n]{0,12})" + _ID_CUE + r")",
    re.IGNORECASE,
)



_ID_PREFIX_CUE = r"(?:打开|启动|运行|切到|版本|构建|应用|编号|照片|显示(?:的)?是|application|app)"
_RE_ID_NUMBER_AFTER_CUE = re.compile(
    r"(?P<cue>" + _ID_PREFIX_CUE + r")"
    r"(?P<gap>[^，。！？!?\n]{0,6}?)"
    r"(?P<num>[" + _CN_ID_DIGITS + r"]{4,})",
    re.IGNORECASE,
)



_RE_STANDALONE_ID_NUMBER = re.compile(
    r"(?<![一-鿿A-Za-z0-9])(?P<num>[" + _CN_ID_DIGITS + r"]{4,})"
    r"(?=[，。！？!?；;：:\n]|$)"
)




_IDIOM_HOLDS = ("一五一十", "三三两两", "三六九等", "九九八十一")
_RE_DIGIT_RUN_GLOBAL = re.compile(
    r"(?P<num>[" + _CN_ID_DIGITS + r"]{3,})"
)


def _cn_digits_to_string(s: str) -> str:
    """逐位中文数字转 ASCII，保留标识符中的前导零。"""
    return "".join(str(_CN_D.get(char, char)) for char in s)


def _cn_dotted_value_to_ascii(raw: str, *, is_version: bool = False) -> str | None:
    pieces = raw.split("点")
    if len(pieces) > 2 and not is_version:
        return None
    values: list[str] = []
    for index, piece in enumerate(pieces):
        if piece and all(char in _CN_ID_DIGITS + "0123456789" for char in piece):
            values.append(_cn_digits_to_string(piece))
        elif index == 0 or is_version:
            value = _percentage_integer_to_ascii(piece)
            if value is None:
                return None
            values.append(value)
        else:
            return None
    return ".".join(values)


def _keep_natural_quantity(number: str, unit: str) -> bool:
    """保留普通量词里的自然数量和概数，不把它们误写成精确整数。

    `往上走一步` 是自然量词，不是编号；写成 `1步` 会把普通叙述突兀改成排版数字。
    `一两天/三五天/八九位` 的两个并列数字表示范围，也不能拼成 `12/35/89`。
    年月日号允许 `一八年→18年` 这类逐位短写；其中带“两”的 `一两年/两三年`
    仍是强概数信号。含十百千但反向校验不成立的 `三五百元` 同样保留。
    明确数值（如“十二天/九十位”）继续转换。
    序数（`第一步`/`第三步`）不走这里，由上面的 `_RE_ORDINAL` 单独处理。
    """
    if number == "一":
        return True
    if len(number) == 2 and all(char in _CN_D for char in number):
        if "两" in number or unit not in "年月日号":
            return True
    if any(char in _CN_U for char in number):
        value = _cn_to_int(number)
        normalized = number.replace("两", "二")
        if value is not None and _int_to_cn(value) != normalized:
            return True
    return False


def normalize_numbers(text: str, *, protect_literals: bool = True) -> str:
    """只把明确数字上下文里的中文数字转成阿拉伯数字。

    处理小数、序数、明确量词/日期，以及紧贴英文标识符的数字；不对孤立数字、通用"个"和成语式用法猜测。
    例如：`第三个`→`第3个`、`二零二六年十月`→`2026年10月`、`四点八`→`4.8`。
    """
    if not text:
        return text
    if protect_literals:
        literals = LiteralText(text)
        return literals.restore(normalize_numbers(literals.masked, protect_literals=False))
    held: list[tuple[int, str]] = []

    hold_prefix = "\u27e6I"
    while hold_prefix in text:
        hold_prefix += "I"

    def _hold(value: str) -> str:
        index = len(held)
        held.append((index, value))
        return f"{hold_prefix}{index}\u27e7"


    text = _normalize_parallel_latin_numbered_labels(text, _hold)
    for idiom in _IDIOM_HOLDS:
        if idiom in text:
            text = text.replace(idiom, _hold(idiom))
    text = _RE_COMPOUND_QUANTITY.sub(lambda match: _hold(match.group(0)), text)
    text = normalize_explicit_latin_model_numbers(text, protect_literals=False)

    def _restore_held(value: str) -> str:
        for index, idiom in held:
            value = value.replace(f"{hold_prefix}{index}\u27e7", idiom)
        return value

    def _convert_numeric_value(match: re.Match) -> str:
        raw = match.group(0)
        value = _cn_to_int(raw)
        if value is None:
            return raw
        norm = raw.replace("两", "二")
        return str(value) if _int_to_cn(value) == norm else raw

    text = _RE_EXACT_PERCENT_RANGE.sub(_replace_exact_percent_range, text)
    text = _RE_EXACT_PERCENT.sub(_replace_exact_percent, text)


    text = _RE_UNRESOLVED_PERCENT.sub(lambda match: _hold(match.group(0)), text)
    range_source = text

    def _convert_range(match: re.Match) -> str:
        raw = match.group(0)
        before, after = range_source[:match.start()], range_source[match.end():]
        if "点" in raw:
            if _RE_CN_CLOCK_PREFIX.search(before) or _RE_CN_CLOCK_SUFFIX.match(after):
                return _hold(raw)
            if _RE_CN_VERSION_PREFIX.search(before):
                start = _cn_dotted_value_to_ascii(match.group("start"), is_version=True)
                end = _cn_dotted_value_to_ascii(match.group("end"), is_version=True)
                if start is not None and end is not None:
                    return start + match.group("separator") + end
                return _hold(raw)
        return _exact_number_range_to_ascii(match) or _hold(raw)

    text = _RE_NUMBER_RANGE.sub(_convert_range, text)
    dotted_source = text

    def _convert_dotted_value(match: re.Match) -> str:
        raw = match.group(0)
        before, after = dotted_source[:match.start()], dotted_source[match.end():]

        if _RE_CN_CLOCK_PREFIX.search(before) or _RE_CN_CLOCK_SUFFIX.match(after):
            return _hold(raw)
        is_version = _RE_CN_VERSION_PREFIX.search(before) is not None
        return _cn_dotted_value_to_ascii(raw, is_version=is_version) or _hold(raw)

    text = _RE_CN_DOTTED_VALUE.sub(_convert_dotted_value, text)
    text = _RE_NUMERIC_VALUE.sub(_convert_numeric_value, text)
    text = _RE_ORDINAL.sub(lambda match: "第" + _to_arabic(match.group(1)), text)
    text = _RE_UNIT.sub(
        lambda match: (
            match.group(0)
            if _keep_natural_quantity(match.group(1), match.group(2))
            else _to_arabic(match.group(1)) + match.group(2)
        ),
        text,
    )
    text = _RE_LATIN_MODEL_SINGLE_DIGIT.sub(
        lambda match: (
            match.group(0)
            if match.group("num") == "一" and _ONE_WORD_SUFFIX.match(text[match.end():])
            else
            re.sub(r"[ \t]+", "", match.group("latin"))
            + _cn_digits_to_string(match.group("num"))
        ),
        text,
    )
    text = _RE_EN_DIGIT_SEQUENCE.sub(
        lambda match: (
            match.group(0)
            if re.match(r"[ \t]*(?:[" + _SAFE_UNIT + r"十百千]|个|分钟)", text[match.end():])
            else match.group(1) + _cn_digits_to_string(match.group(2))
        ), text
    )
    text = _RE_EN_CN_NUM.sub(lambda match: match.group(1) + _to_arabic(match.group(2)), text)
    text = _RE_NUM_EN.sub(lambda match: _to_arabic(match.group(1)) + match.group(2), text)
    text = _RE_ID_NUMBER.sub(lambda match: _cn_digits_to_string(match.group("num")), text)
    text = _RE_ID_NUMBER_AFTER_CUE.sub(
        lambda match: (
            match.group("cue")
            + match.group("gap")
            + _cn_digits_to_string(match.group("num"))
        ),
        text,
    )
    text = _RE_STANDALONE_ID_NUMBER.sub(
        lambda match: _cn_digits_to_string(match.group("num")), text
    )
    text = _RE_DIGIT_RUN_GLOBAL.sub(
        lambda match: _cn_digits_to_string(match.group("num")), text
    )
    return _restore_held(text)








_EN_NUMBER_VALUES = {
    "zero": 0,
    "oh": 0,
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
    "eleven": 11,
    "twelve": 12,
    "thirteen": 13,
    "fourteen": 14,
    "fifteen": 15,
    "sixteen": 16,
    "seventeen": 17,
    "eighteen": 18,
    "nineteen": 19,
}
_EN_TENS_VALUES = {
    "twenty": 20,
    "thirty": 30,
    "forty": 40,
    "fifty": 50,
    "sixty": 60,
    "seventy": 70,
    "eighty": 80,
    "ninety": 90,
}
_EN_NUMBER_WORDS = tuple(
    _EN_NUMBER_VALUES
) + tuple(_EN_TENS_VALUES) + ("hundred", "thousand")
_EN_NUMBER_WORD_PATTERN = "(?:" + "|".join(_EN_NUMBER_WORDS) + ")"
_EN_NUMBER_PHRASE = (
    _EN_NUMBER_WORD_PATTERN

    + r"(?:[ \t-]+(?:and[ \t]+)?"
    + _EN_NUMBER_WORD_PATTERN
    + r")*"
)
_EN_MONTH = (
    r"(?:January|February|March|April|May|June|July|August|September|October|November|December)"
)
_RE_EN_MONTH_YEAR = re.compile(
    r"(?P<month>\b" + _EN_MONTH + r"\b)(?P<gap>[ \t]+)(?P<year>" + _EN_NUMBER_PHRASE + r")\b",
    re.IGNORECASE,
)
_RE_EN_VERSION = re.compile(
    r"(?P<label>\bversion\b)(?P<gap>[ \t]+)(?P<value>"
    + _EN_NUMBER_PHRASE
    + r"(?:[ \t]+(?:dot|point)[ \t]+"
    + _EN_NUMBER_PHRASE
    + r")+)\b",
    re.IGNORECASE,
)
_RE_EN_PERCENT = re.compile(


    r"(?<![\w.\-\u2010-\u2015])(?P<value>(?:"
    + _EN_NUMBER_WORD_PATTERN
    + r"|point|dot)\b(?:[ \t\-\u2010-\u2015]+(?!percent\b)"
    + r"[A-Za-z0-9]+(?:\.[0-9]+)*)*)"

    + r"(?P<percent>[ \t]+percent\b)?",
    re.IGNORECASE,
)


def _parse_english_under_hundred(tokens: list[str]) -> int | None:
    if len(tokens) == 1:
        if tokens[0] in _EN_NUMBER_VALUES:
            return _EN_NUMBER_VALUES[tokens[0]]
        return _EN_TENS_VALUES.get(tokens[0])
    if (
        len(tokens) == 2
        and tokens[0] in _EN_TENS_VALUES
        and tokens[1] in _EN_NUMBER_VALUES
        and 0 < _EN_NUMBER_VALUES[tokens[1]] < 10
    ):
        return _EN_TENS_VALUES[tokens[0]] + _EN_NUMBER_VALUES[tokens[1]]
    return None


def _parse_english_under_thousand(tokens: list[str]) -> int | None:
    if "hundred" not in tokens:
        return _parse_english_under_hundred(tokens)
    if tokens.count("hundred") != 1:
        return None
    index = tokens.index("hundred")
    if index != 1 or tokens[0] not in _EN_NUMBER_VALUES:
        return None
    hundreds = _EN_NUMBER_VALUES[tokens[0]]
    if not 0 < hundreds < 10:
        return None
    tail = tokens[index + 1 :]
    if not tail:
        return hundreds * 100
    remainder = _parse_english_under_hundred(tail)
    return None if remainder is None else hundreds * 100 + remainder


def _english_number_tokens(raw: str) -> list[str]:

    tokens = re.findall(r"[^ \t-]+", (raw or "").casefold())


    for index, token in enumerate(tokens):
        if token == "and" and (
            index == 0 or index == len(tokens) - 1
            or tokens[index - 1] not in {"hundred", "thousand"}
        ):
            return []
    return [token for token in tokens if token != "and"]


def _parse_english_cardinal(raw: str) -> int | None:
    tokens = _english_number_tokens(raw)
    if not tokens:
        return None
    if "thousand" not in tokens:
        return _parse_english_under_thousand(tokens)
    if tokens.count("thousand") != 1:
        return None
    index = tokens.index("thousand")
    left = _parse_english_under_thousand(tokens[:index])
    if left is None or left <= 0:
        return None
    tail = tokens[index + 1 :]
    right = 0 if not tail else _parse_english_under_thousand(tail)
    if right is None:
        return None
    value = left * 1000 + right
    return value if value <= 9999 else None


def _parse_english_decimal(raw: str) -> str | None:
    parts = re.split(r"[ \t]+(?:dot|point)[ \t]+", raw, flags=re.IGNORECASE)
    if len(parts) == 1:
        value = _parse_english_cardinal(parts[0])
        return None if value is None else str(value)
    if len(parts) != 2:
        return None
    whole = _parse_english_cardinal(parts[0])
    fraction_tokens = _english_number_tokens(parts[1])
    if whole is None or not fraction_tokens:
        return None
    if all(token in _EN_NUMBER_VALUES and _EN_NUMBER_VALUES[token] < 10 for token in fraction_tokens):
        fraction = "".join(str(_EN_NUMBER_VALUES[token]) for token in fraction_tokens)
    else:
        fraction_value = _parse_english_cardinal(parts[1])
        if fraction_value is None:
            return None
        fraction = str(fraction_value)
    return f"{whole}.{fraction}"


def _parse_spoken_english_year(raw: str) -> int | None:
    tokens = _english_number_tokens(raw)
    if not tokens:
        return None
    cardinal = _parse_english_cardinal(raw)
    if cardinal is not None and 1000 <= cardinal <= 2999:
        return cardinal
    if tokens[0] not in {"nineteen", "twenty"} or len(tokens) < 2:
        return None
    prefix = 1900 if tokens[0] == "nineteen" else 2000
    tail = tokens[1:]
    if tail[0] == "oh" and len(tail) >= 2 and all(
        token in _EN_NUMBER_VALUES and _EN_NUMBER_VALUES[token] < 10
        for token in tail[1:]
    ):
        suffix = int("".join(str(_EN_NUMBER_VALUES[token]) for token in tail[1:]))
    else:
        suffix = _parse_english_under_hundred(tail)
    if suffix is None:
        return None


    if tokens[0] == "twenty" and len(tail) == 1 and suffix < 10:
        return None
    return prefix + suffix


def normalize_english_contextual_numbers(text: str, *, protect_literals: bool = True) -> str:
    """只格式化有月份、版本号或百分比强锚点的英文口述数字。"""
    if not text:
        return text
    if protect_literals:
        literals = LiteralText(text)
        return literals.restore(normalize_english_contextual_numbers(
            literals.masked, protect_literals=False,
        ))

    source = text

    def _month_year(match: re.Match) -> str:

        if match.end() < len(source) and source[match.end()] == "-":
            return match.group(0)
        value = _parse_spoken_english_year(match.group("year"))
        if value is None:
            return match.group(0)
        return f"{match.group('month')}{match.group('gap')}{value}"

    text = _RE_EN_MONTH_YEAR.sub(_month_year, text)

    def _version(match: re.Match) -> str:
        pieces = re.split(
            r"[ \t]+(?:dot|point)[ \t]+",
            match.group("value"),
            flags=re.IGNORECASE,
        )
        values = [_parse_english_cardinal(piece) for piece in pieces]
        if any(value is None for value in values):
            return match.group(0)
        return f"{match.group('label')}{match.group('gap')}" + ".".join(
            str(value) for value in values
        )

    text = _RE_EN_VERSION.sub(_version, text)

    def _percent(match: re.Match) -> str:
        if match.group("percent") is None:
            return match.group(0)
        value = _parse_english_decimal(match.group("value"))
        return match.group(0) if value is None else f"{value}%"

    return _RE_EN_PERCENT.sub(_percent, text)


_PSENTINEL = "⟦N⟧"


_LIST_ANCHOR_PAT = (
    r"(?:第[一二三四五六七八九十0-9]+[点件条步项个阶段部分章节]|"
    r"首先|其次|最后|一是|二是|三是|四是|五是|其一|其二|其三|另外|除此之外)")
_LIST_ANCHOR = re.compile(r"^" + _LIST_ANCHOR_PAT)


_RE_ANCHOR_AFTER_COMMA = re.compile(r"，\s*(" + _LIST_ANCHOR_PAT + r")")


def paragraphize_sentinel(text: str) -> str:
    """语义分段:长文本里列表锚点(句首或逗号后) → 锚点处另起一段(插 ⟦P⟧ 哨兵)。
    纯函数,可测。"""
    if not text or len(text) <= 120:
        return text
    text = _RE_ANCHOR_AFTER_COMMA.sub(lambda m: "。" + m.group(1), text)
    parts = [p for p in re.split(r"(?<=[。！？!?])", text) if p.strip()]
    if len(parts) < 3:
        return text
    out = []
    for i, p in enumerate(parts):
        if i > 0 and _LIST_ANCHOR.match(p.strip()):
            out.append(_PSENTINEL)
        out.append(p)
    return "".join(out)





EXPLICIT_LIST_LAYOUT_ID = "explicit-ordinal-soft-lines-v5"
_ORDINAL_LINE_BREAKS = "\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029"
_ORDINAL_LINE_TOKEN = (
    r"(?P<label>第(?P<zh>[零一二三四五六七八九十百千万\d]+)"
    r"(?:个问题|件事|部分|个|件|点|项|条|步)?(?:是)?"
    r"|(?P<en>first|second|third|[a-z]+(?:-[a-z]+)*th|[a-z]+-(?:first|second|third)|\d+(?:st|nd|rd|th))(?:ly)?)"
    r"[^\S\r\n]*[，、,:：]"
)
_ORDINAL_LINE_BOUNDARY = re.compile(
    r"(?:^|[。！？!?；;:.：])[^\S\r\n]*" + _ORDINAL_LINE_TOKEN,
    re.IGNORECASE | re.MULTILINE,
)
_ORDINAL_LINE_ANYWHERE = re.compile(
    r"(?<![A-Za-z0-9_])" + _ORDINAL_LINE_TOKEN, re.IGNORECASE,
)
_ORDINAL_LINE_VALUES = dict(zip(
    "first second third fourth fifth sixth seventh eighth ninth tenth".split(), range(1, 11),
))
_ORDINAL_LINE_VALUES.update(zip("一二三四五六七八九十", range(1, 11)))
_ORDINAL_LINE_VALUES.update((str(i), i) for i in range(1, 11))
_EN_LIST_COUNT_VALUES = dict(zip(
    "one two three four five six seven eight nine ten".split(), range(1, 11),
))
_THREE_ITEM_LINE_START = re.compile(
    r"^[^\S\r\n]*第(?P<number>[一二三123])(?:件事|个问题|件|个|点|项|条)?"
    r"[^\S\r\n]*(?:[，、,:：]|是)"
)
_LATER_ITEM_IN_LAST_LINE = re.compile(
    r"第(?:[一二三四五六七八九十]|10|[1-9])(?:件事|个问题|件|个|点|项|条)?"
    r"[^\S\r\n]*(?:[，、,:：]|是)"
)
_CONFIRMATION_QUESTION = (
    r"(?:(?:大家|你们|各位)?(?:有没有)?听(?:明白|懂)(?:了吗|没有|吗)?"
    r"|(?:大家|你们|各位)?明白了吗)[？?]"
)
_STANDALONE_CONFIRMATION = re.compile(
    r"[。.!！][ \t]*(?P<question>" + _CONFIRMATION_QUESTION + r")[ \t]*$"
)
_COMMA_CONFIRMATION = re.compile(
    r"[，,][ \t]*(?P<question>" + _CONFIRMATION_QUESTION + r")[ \t]*$"
)
_BARE_THREE_COUNT_INTRO = re.compile(
    r"(?:三|3|３)[ \t]*(?P<unit>件事(?:情)?|件|个问题|点|项|条)"
    r"[^。！？!?]{0,80}[。！？!?][ \t]*$"
)
_BARE_ORDINAL_TOKEN = (
    r"(?P<label>第(?P<number>[一二三123])(?P<unit>件事情|件事|个问题|件|点|项|条))"
)
_BARE_ORDINAL_LINE_START = re.compile(r"^[^\S\r\n]*" + _BARE_ORDINAL_TOKEN)
_BARE_ORDINAL_AT_BOUNDARY = re.compile(
    r"(?P<separator>^|[。！？!?；;，,])[ \t]*" + _BARE_ORDINAL_TOKEN, re.MULTILINE,
)
_BARE_ORDINAL_ANYWHERE = re.compile(
    r"第(?:[一二三四五六七八九十]|10|[1-9])(?:件事情|件事|个问题|件|点|项|条)"
)
_EXISTING_STRUCTURED_LINE = re.compile(
    r"^(?:[ \t]{4}|[ \t]*\t|[^\S\r\n]*(?:[-+*•·][ \t]+|\d+[.)][ \t]+|#{1,6}[ \t]+|[>|]))",
    re.MULTILINE,
)
_ORDINAL_LINE_START = re.compile(r"^[^\S\r\n]*" + _ORDINAL_LINE_TOKEN, re.IGNORECASE)
_EXPLICIT_WHOLE_LIST_TAIL = re.compile(
    r"[。！？!?；;.][ \t]*(?P<cue>"
    r"(?:以上|上述|这)(?P<zh_count>[一二三四五六七八九十\d]+)(?:点|项|件事|条|个问题)"
    r"|These[ \t]+(?:checks|items|points|steps)\b"
    r"|All[ \t]+(?P<en_count>three|four|five|six|seven|eight|nine|ten)"
    r"[ \t]+(?:checks|items|points|steps)\b"
    r")",
    re.IGNORECASE,
)


def _insert_missing_soft_lines(text: str, positions: set[int]) -> str:
    """只在同一行尚有前文时插LF；已有换行、空行和行首空格逐字保留。"""
    cuts = {pos for pos in positions if text[text.rfind("\n", 0, pos) + 1:pos].strip()}
    return "".join(("\n" if index in cuts else "") + char for index, char in enumerate(text))


def _linebreak_explicit_whole_list_tail(text: str, item_count: int) -> str:
    """只把整组指称明确且数量相符的尾句另起段；不猜指代不明的问句。"""
    last_line = text.rsplit("\n", 1)[-1]
    label = _ORDINAL_LINE_START.match(last_line) or _BARE_ORDINAL_LINE_START.match(last_line)
    if not label:
        return text
    for match in _EXPLICIT_WHOLE_LIST_TAIL.finditer(last_line, label.end()):
        zh_count = match.group("zh_count")
        en_count = match.group("en_count")
        if zh_count and _ORDINAL_LINE_VALUES.get(zh_count) != item_count:
            continue
        if en_count and _EN_LIST_COUNT_VALUES.get(en_count.lower()) != item_count:
            continue
        cut = len(text) - len(last_line) + match.start("cue")
        return text[:cut] + "\n\n" + text[cut:]
    return text


def _linebreak_standalone_list_confirmation(text: str) -> str:
    """只把完整三项之后的独立确认问句与第三项分开；不猜普通尾句。"""
    if (
        LiteralText(text).has_literals
        or any(ch in text for ch in '()（）[]【】{}<>《》`~"“”「」『』‘«»‹›')
        or re.search(r"(?<![A-Za-z])['’]|['’](?![A-Za-z])", text)
    ):
        return text
    lines = text.split("\n")
    if len(lines) < 3:
        return text
    numbered = []
    for index, line in enumerate(lines):
        if match := _THREE_ITEM_LINE_START.match(line):
            numbered.append((index, _ORDINAL_LINE_VALUES.get(match.group("number"))))
    if [value for _, value in numbered] != [1, 2, 3] or numbered[-1][0] != len(lines) - 1:
        return text
    last_label = _THREE_ITEM_LINE_START.match(lines[-1])
    if _LATER_ITEM_IN_LAST_LINE.search(lines[-1], last_label.end()):
        return text
    if not (match := _STANDALONE_CONFIRMATION.search(lines[-1])):
        return text
    cut = text.rfind("\n") + 1 + match.start("question")
    return text[:cut] + "\n" + text[cut:]


def _linebreak_unpunctuated_three_item_list(text: str) -> str:
    """明确报出三件事、完整顺序和词界时，容忍模型漏掉序号后的标点。"""
    matches = list(_BARE_ORDINAL_AT_BOUNDARY.finditer(text))
    if len(matches) != 3:
        return text
    positions = [match.start("label") for match in matches]
    if positions != [match.start() for match in _BARE_ORDINAL_ANYWHERE.finditer(text)]:
        return text
    if [_ORDINAL_LINE_VALUES.get(match.group("number")) for match in matches] != [1, 2, 3]:
        return text
    units = ["件" if match.group("unit").startswith("件") else match.group("unit") for match in matches]
    if len(set(units)) != 1:
        return text
    intro = _BARE_THREE_COUNT_INTRO.search(text[:positions[0]].rstrip(" \t\n"))
    if not intro or ("件" if intro.group("unit").startswith("件") else intro.group("unit")) != units[0]:
        return text
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index < 2 else len(text)
        body = text[match.end("label"):end].strip(" \t，,；;。.!！？、:：")
        if len(re.findall(r"[\u4e00-\u9fff]", body)) < 2 or any(ch in body for ch in ":："):
            return text
    cuts = set(positions)
    if confirmation := (_STANDALONE_CONFIRMATION.search(text) or _COMMA_CONFIRMATION.search(text)):
        third_body = text[matches[2].end("label"):confirmation.start()]

        if not re.search(r"(?:问|询问|确认|检查|了解)(?:一下)?(?:大家|他们)?[ \t]*$", third_body):
            cuts.add(confirmation.start("question"))
    return _linebreak_explicit_whole_list_tail(_insert_missing_soft_lines(text, cuts), 3)


def linebreak_explicit_ordinals(text: str) -> str:
    """完整列表只在原序号前加LF；明确整组尾句和独立确认另起段。

    保留已有段落，只补齐缺失的序号换行；拒绝字面内容、嵌套、空项、缺号及重号改口。
    不把“存在一个换行”当成“整个列表已完成排版”。只插换行，
    不猜普通解释或条件的归属；去掉新增LF必须逐字等于输入。
    """
    if not text:
        return text
    if any(ch in text for ch in _ORDINAL_LINE_BREAKS if ch != "\n"):
        return text
    if (
        LiteralText(text).has_literals
        or any(ch in text for ch in '()（）[]【】{}<>《》`~"“”「」『』‘«»‹›')
        or re.search(r"(?<![A-Za-z])['’]|['’](?![A-Za-z])", text)
    ):
        return text
    if "\n" in text and _EXISTING_STRUCTURED_LINE.search(text):
        return text
    matches = list(_ORDINAL_LINE_BOUNDARY.finditer(text))
    if not 3 <= len(matches) <= 10:
        return _linebreak_standalone_list_confirmation(_linebreak_unpunctuated_three_item_list(text))

    if [m.start("label") for m in _ORDINAL_LINE_ANYWHERE.finditer(text)] != [m.start("label") for m in matches]:
        return text
    values = [_ORDINAL_LINE_VALUES.get((m.group("zh") or m.group("en")).lower()) for m in matches]
    if values != list(range(1, len(matches) + 1)):
        return text
    for i, match in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        body = text[match.end():end]
        if not re.search(r"\w", body) or any(ch in body for ch in ":："):
            return text
    output = _insert_missing_soft_lines(text, {m.start("label") for m in matches})
    output = _linebreak_explicit_whole_list_tail(output, len(matches))
    return _linebreak_standalone_list_confirmation(output)









_SEAM = re.compile(r"([。！？])[ \t]+(?=[一-鿿])")


def fix_chunk_seam(text: str) -> str:
    """只删除中文句末标点后的非法空格;没有真实块边界元数据时不猜测句号对错。"""
    return _SEAM.sub(lambda m: m.group(1), text)


def clean(text: str) -> str:
    """去口水词 + 规整空白 + 全角标点归半角(统一用英文标点)。"""
    for w in FILLER_WORDS:
        text = text.replace(w, "")

    text = re.sub(r"\s+", " ", text)

    text = re.sub(r"^[\s,，。、；;]+", "", text)
    return normalize_punct(text.strip())

















_MARKER_START = frozenset("0123456789-•·*[")



_ZH_LIST_LINE = re.compile(
    r"^(?:"
    r"第(?:[0-9]+|[一二三四五六七八九十百千万两]+)"
    r"(?:件|个|条|项|步|阶段|部分|章节|点|是)"
    r"|(?:首先|其次|再次|最后|一是|二是|三是|四是|五是|六是|七是|八是|九是|十是|"
    r"其一|其二|其三|其四)"
    r")"
)


_LIST_INTRO_TAIL = re.compile(
    r"(?:[一二三四五六七八九十百千万两0-9]+点|"
    r"[一二三四五六七八九十百千万两0-9]+件事情?|"
    r"[一二三四五六七八九十百千万两0-9]+个问题|"
    r"几个问题|多个问题|以下|如下|分别)$"
)


_ZH_NUMBERED_ITEM = re.compile(
    r"(?:^|[，,、：:])第(?:[0-9]+|[一二三四五六七八九十百千万两]+)"
    r"(?:件|个|条|项|步|阶段|部分|章节|点|是)"
)


def _first_visible(s: str) -> str:
    """s 去掉行首空格/制表后的第一个字符;空则空串。"""
    t = s.lstrip(" \t")
    return t[:1]


def _is_marker_line(line: str) -> bool:
    """这一行开头是不是列表标记(ASCII 标记或明确的中文列表锚点)。"""
    visible = line.lstrip(" \t")
    return _first_visible(visible) in _MARKER_START or bool(_ZH_LIST_LINE.match(visible))


def _is_marker_prefix(line: str) -> bool:
    """流式判定时，这一行是否还可能长成中文列表锚点。

    ASCII 标记一个字符就能确定；“第1件/首先/一是”需要等到第二、三个字。
    若在半个词时就把换行收掉，整段版和流式版会分叉，所以只短暂扣住这些前缀。
    """
    visible = line.lstrip(" \t")
    if not visible or _is_marker_line(visible):
        return False
    if visible.startswith("第"):
        return bool(re.fullmatch(r"第[零〇一二两三四五六七八九十百千万0-9]*", visible))
    return any(prefix.startswith(visible) for prefix in (
        "首先", "其次", "再次", "最后",
        "一是", "二是", "三是", "四是", "五是", "六是", "七是", "八是", "九是", "十是",
        "其一", "其二", "其三", "其四",
    ))


def _prose_join(prev_char: str, next_char: str) -> str:
    """收掉散文换行后接不接空格:【下一段】以拉丁字母/数字开头 → 一个空格(英文词之间要空格,
    否则 foo.\\nbar 会粘成 foo.bar);否则不加(中文不用空格)。行尾多是标点,故只看下一段首字符。"""
    return " " if (next_char and next_char.isascii() and next_char.isalnum()) else ""


def collapse_prose_newlines(text: str) -> str:
    """整段版:把模型的【散文换行】收成整段,【列表换行】保留。只改 \n、非空白内容一字不动。
    哨兵(⟦⟧,不含 \n)天然不受影响 → 命令分段(换行/新段落/项目符号)不会被误收。"""
    if "\n" not in text:
        return text
    lines = text.split("\n")
    out = lines[0]
    prev_marker = _is_marker_line(lines[0])
    for line in lines[1:]:
        cur_marker = _is_marker_line(line)
        if prev_marker or cur_marker:
            out += "\n" + line
        else:
            body = line.lstrip(" \t")
            out += _prose_join(out[-1:], body[:1]) + body
        prev_marker = cur_marker
    return out


def punctuate_explicit_list_breaks(text: str) -> str:
    """给明确编号列表项之间的裸换行补 ``；``。

    Qwen3 有时会用换行表达“第1是…… / 第2个是……”的列表边界,但不同时输出标点。
    这里不对普通换行猜逗号/分号:只有下一行是明确的中文列表锚点、且上一行本身已经
    出现了编号项正文时才补分号。列表引导句(“另外2件事情”)仍由
    :func:`add_list_intro_colons` 补冒号,避免把冒号写成分号。
    """
    if "\n" not in text:
        return text
    lines = text.split("\n")
    for i in range(1, len(lines)):
        if not _is_marker_line(lines[i]):
            continue
        previous = lines[i - 1].rstrip(" \t")
        if not previous or previous[-1] in "。！？!?；;：:,，、:":
            continue
        if not _ZH_NUMBERED_ITEM.search(previous):
            continue
        lines[i - 1] = previous + "；"
    return "\n".join(lines)


def add_list_intro_colons(text: str) -> str:
    """给明确的列表引导句补一个结构性冒号。

    例如 ``另外2件事情\\n第1件是……`` → ``另外2件事情：\\n第1件是……``。
    这里只处理“引导尾部 + 明确列表行首”这一可判定结构；普通的无标点换行
    不猜是逗号还是分号，交给后续具备上下文能力的润色路径。
    """
    if "\n" not in text:
        return text
    lines = text.split("\n")
    for i in range(1, len(lines)):
        if not _is_marker_line(lines[i]):
            continue
        previous = lines[i - 1].rstrip(" \t")
        if not previous or previous[-1] in "。！？!?；;：:,，、:":
            continue
        if _LIST_INTRO_TAIL.search(previous):
            lines[i - 1] = previous + "："
    return "\n".join(lines)






_QUESTION_MARKERS = (
    "是不是", "有没有", "能不能", "会不会", "行不行", "好不好", "要不要",
    "可不可以", "是否", "为什么", "怎么", "什么", "哪个", "哪些", "哪里", "哪儿",
    "哪种", "哪项", "谁", "干嘛", "怎样", "如何", "你觉得", "您觉得", "你明白",
    "您明白", "你知道", "您知道", "你认为", "您认为", "是在", "是否需要",
    "需不需要", "有没有必要",
)


def ma_to_question(text: str) -> str:
    """把疑问语境的句尾“嘛”收成“吗？”，不改普通陈述语气。"""
    if not text or "嘛" not in text:
        return text
    out, buf = [], ""
    for char in text:
        if char in "。！？!?":
            out.append(_fix_ma(buf + char))
            buf = ""
        elif char == "\n":

            out.append(_fix_ma(buf))
            out.append(char)
            buf = ""
        else:
            buf += char
    if buf:
        out.append(_fix_ma(buf))
    return "".join(out)


def _fix_ma(sentence: str) -> str:


    match = re.search(r"嘛(?=(?:[，,。.；;：:！？!?]?)[ \t]*(?:[，,。.；;：:！？!?]|$))", sentence)
    has_question_evidence = (
        "？" in sentence or "?" in sentence
        or any(marker in sentence for marker in _QUESTION_MARKERS)
    )
    if not match or not has_question_evidence:
        return sentence
    tail = re.match(r"[，,。.；;：:！？!? \t]*", sentence[match.end():])
    cut = match.end() + (tail.end() if tail else 0)
    return sentence[:match.start()] + "吗？" + sentence[cut:]













_RE_LIST_MARKER = re.compile(r"^([ \t]*)([0-9]{1,3})([.、)])(?![0-9])")

_RE_MARKER_MAYBE = re.compile(r"^[ \t]*[0-9]{0,3}[.、)]?$")


def renumber_lists(text: str) -> str:
    """把连续编号行的序号改成连贯的(1.2.2. → 1.2.3.)。只改数字本身,正文一字不动。"""
    if "\n" not in text and not _RE_LIST_MARKER.match(text):
        return text
    out, expect = [], None
    for line in text.split("\n"):
        m = _RE_LIST_MARKER.match(line)
        if not m:
            out.append(line)
            expect = None
            continue
        if expect is None:
            expect = int(m.group(2))
        out.append(f"{m.group(1)}{expect}{m.group(3)}{line[m.end():]}")
        expect += 1
    return "\n".join(out)





















_EN_ZH = {
    "pull request": ("拉取请求", "合并请求"),
    "integration test": ("集成测试",),
    "unit test": ("单元测试",),
    "stack trace": ("堆栈", "调用栈"),
    "return value": ("返回值",),
    "state management": ("状态管理",),
    "database": ("数据库",),
    "dependency": ("依赖项",),
    "performance": ("性能",),
    "component": ("组件",),
    "endpoint": ("端点",),
    "migration": ("迁移脚本",),
    "refactor": ("重构",),
    "rollback": ("回滚",),
    "frontend": ("前端",),
    "backend": ("后端",),
    "feedback": ("反馈",),
    "timeout": ("超时",),
    "deploy": ("部署",),
    "commit": ("提交",),
    "config": ("配置",),
    "schema": ("表结构",),
    "staging": ("预发",),
    "render": ("渲染",),
    "branch": ("分支",),
    "cache": ("缓存",),
    "index": ("索引",),
    "query": ("查询",),
    "token": ("令牌",),
    "merge": ("合并",),
    "prompt": ("提示词",),
    "code": ("代码",),
    "log": ("日志",),
}




_RE_EN_PHRASE = re.compile(r"(?<![A-Za-z])[A-Za-z]{2,}(?: [A-Za-z]{2,}){1,2}(?![A-Za-z])")


def english_repairs(src: str) -> list:
    """按【这次的原话】预先算出要还原的 (中文对译 → 他原本说的英文词)。返回空 = 这次不用管。

    在流开始前算一次就够 —— 四个判据里的 ①④ 只看原话,②③ 由替换本身天然满足
    (英文还在就没有中文对译可替;中文对译没出现,replace 就是空操作)。"""
    low = src.lower()
    out = []
    for en, zhs in _EN_ZH.items():
        i = low.find(en)
        if i < 0:
            continue
        spelled = src[i:i + len(en)]
        for zh in zhs:
            if zh in src:
                continue
            out.append((zh, spelled))


    for m in _RE_EN_PHRASE.finditer(src):
        phrase = m.group(0)
        squashed = phrase.replace(" ", "")
        if squashed != phrase:
            out.append((squashed, phrase))
    out.sort(key=lambda p: -len(p[0]))
    return out


def restore_english(text: str, repairs: list) -> str:
    """把被翻译掉的英文词换回来。repairs 空 → 原样返回。
    (空格不在这里管 —— 交给下面的 space_cjk_en 统一补,少一处重复逻辑。)"""
    for zh, en in repairs:
        text = text.replace(zh, en)
    return text











_CJK = re.compile(r"[一-鿿]")
_RE_CJK_EN = re.compile(r"([一-鿿])([A-Za-z])")
_RE_EN_CJK = re.compile(r"([A-Za-z])([一-鿿])")








_RE_CJK_GAP = re.compile(r"(?<=[一-鿿])[ \t]+(?=[一-鿿])")


def space_cjk_en(text: str) -> str:
    """汉字和英文字母紧贴时插一个空格;汉字之间的空格删掉。已有空格/标点/数字一概不动。"""
    text = _RE_CJK_GAP.sub("", text)
    text = _RE_CJK_EN.sub(r"\1 \2", text)
    return _RE_EN_CJK.sub(r"\1 \2", text)


def fix_english(text: str, repairs: list) -> str:
    """英文两件事一起做:还原被翻译的词 + 补中英空格。"""
    return space_cjk_en(restore_english(text, repairs))


class StreamEnglishFixer:
    ""









    def __init__(self, repairs: list):
        self._r = repairs or []
        self._raw = ""


        self._prev = ""

    def _safe_cut(self, raw: str) -> int:




        keep = 1 if raw and (_CJK.match(raw[-1]) or (raw[-1].isascii() and raw[-1].isalpha())) else 0


        if raw and raw[-1] in " \t":
            keep = max(keep, len(raw) - len(raw.rstrip(" \t")))
        for zh, _ in self._r:
            if raw.endswith(zh):
                keep = max(keep, len(zh))
                continue
            for k in range(len(zh) - 1, 0, -1):
                if raw.endswith(zh[:k]):
                    keep = max(keep, k)
                    break
        cut = len(raw) - keep



        while cut > 0 and raw[cut - 1] in " \t":
            cut -= 1
        return cut

    def _emit(self, seg: str) -> str:
        """把 seg 连着左上下文一起处理,只吐 seg 那一段(左邻只用来判空格,不重复发出)。
        _prev 只有 1 个字、最短对译词 2 个字 → 它自己绝不会被替换,下标偏移是安全的。"""
        if not seg:
            return ""
        fixed = fix_english(self._prev + seg, self._r)
        out = fixed[len(self._prev):]
        if out:
            self._prev = out[-1]
        return out

    def feed(self, chunk: str) -> str:
        self._raw += chunk
        cut = self._safe_cut(self._raw)
        if cut <= 0:
            return ""
        head, self._raw = self._raw[:cut], self._raw[cut:]
        return self._emit(head)

    def flush(self) -> str:
        out, self._raw = self._emit(self._raw), ""
        return out


class StreamProseNewlineCollapser:
    """collapse_prose_newlines 的流式版:逐块喂,行内容实时放行、只在换行处短暂扣一下(等下一行首字符判定)。
    与整段版对【任意分块】结果一致(性质测试守着)。只改 \n、不丢任何非空白字符。"""

    def __init__(self):
        self._buf = ""
        self._pending = False
        self._prev_marker = False
        self._cur_open = False
        self._last = ""

    def feed(self, chunk: str) -> str:
        self._buf += chunk
        return "".join(self._drain(final=False))

    def flush(self) -> str:
        return "".join(self._drain(final=True))

    def _drain(self, final: bool):
        out = []
        while True:
            if self._pending:
                nb = self._buf.lstrip(" \t")
                if nb == "":
                    if not final:
                        break
                    self._buf = ""
                    self._pending = False
                    break
                if not final and _is_marker_prefix(nb):
                    break
                if self._prev_marker or _is_marker_line(nb):
                    out.append("\n")
                else:
                    out.append(_prose_join(self._last, nb[0]))
                    self._buf = nb
                self._pending = False
                self._cur_open = False
                continue
            if not self._cur_open:
                nb = self._buf.lstrip(" \t")
                if nb == "":
                    if not final:
                        break
                    out.append(self._buf)
                    self._buf = ""
                    break
                if not final and _is_marker_prefix(nb):
                    break
                self._cur_marker = _is_marker_line(nb)
                self._cur_open = True
            nl = self._buf.find("\n")
            if nl == -1:
                if self._buf:
                    out.append(self._buf)
                    stripped = self._buf.rstrip(" \t")
                    if stripped:
                        self._last = stripped[-1]
                    self._buf = ""
                break
            if nl > 0:
                seg = self._buf[:nl]
                out.append(seg)
                stripped = seg.rstrip(" \t")
                if stripped:
                    self._last = stripped[-1]
            self._prev_marker = self._cur_marker
            self._pending = True
            self._buf = self._buf[nl + 1:]
        return out


class StreamListRenumberer:
    """renumber_lists 的流式版:只在【行首】扣住"缩进+数字+分隔符"那几个字符,其余实时放行。
    与整段版对【任意分块】结果一致(性质测试守着);除了编号数字本身,一个字符都不改、不丢。

    之所以只需要扣这么一点点:编号锚在每段的第一项 → 认出标记的那一刻就知道该写几,
    不用等下一行(见 renumber_lists 上面的说明)。唯一的等待是确认分隔符后面不是数字(「4.8」不是列表)。"""

    def __init__(self):
        self._buf = ""
        self._at_line_start = True
        self._expect = None

    def feed(self, chunk: str) -> str:
        self._buf += chunk
        return self._drain(final=False)

    def flush(self) -> str:
        return self._drain(final=True)

    def _drain(self, final: bool) -> str:
        out = []
        while True:
            if self._at_line_start:
                m = _RE_LIST_MARKER.match(self._buf)

                if m and (final or m.end() < len(self._buf)):
                    if self._expect is None:
                        self._expect = int(m.group(2))
                    out.append(f"{m.group(1)}{self._expect}{m.group(3)}")
                    self._expect += 1
                    self._buf = self._buf[m.end():]
                    self._at_line_start = False
                    continue
                if not final and _RE_MARKER_MAYBE.match(self._buf):
                    break
                self._expect = None
                self._at_line_start = False
                continue
            nl = self._buf.find("\n")
            if nl == -1:
                out.append(self._buf)
                self._buf = ""
                break
            out.append(self._buf[:nl + 1])
            self._buf = self._buf[nl + 1:]
            self._at_line_start = True
        return "".join(out)



_HARD_BREAK = re.compile(r"[ \t]+(?=\n)")


def strip_hard_breaks(text: str) -> str:
    """砍掉【润色输出】里行尾的空格/制表符。

    ★为什么必须用确定性手段兜、不能靠提示词★
    _CLEAN 提示词里已经【明令禁止】这种硬换行写法,润色模型照样犯 —— 同一段输入跑 3 次,
    2 次带尾随空格。这就是提示词的天花板(见记忆 polish-nondeterminism)。
    确定性能解决的事,就该用确定性手段解决,别拿提示词赌。

    后果不是"不好看":那些空格粘进微信/备忘录/代码里,就是一串没用的尾随空白,得手动删。

    流式安全:StreamDesentinelizer 会缓冲块尾空白 → 它吐出的每一块都不以空白结尾,
    所以"空格+换行"必然完整落在同一块里,逐块调用本函数不会漏切。"""
    if not text:
        return text
    return _HARD_BREAK.sub("", text)
