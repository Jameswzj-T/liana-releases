"""Isolated mixed-label candidate; no I/O and no semantic content rewriting.

The caller supplies the frozen V11 soft-line function. Apply only after a
successful automatic refinement. Explicit literal/label-description contexts
are preserved; this is not a general semantic classifier.
"""
import re

from core.literal_text import LiteralText

POLICY_ID = "explicit-ordinal-soft-lines-v5-neutral-labels-v4"
_QUOTE = re.compile(r"(?<![A-Za-z])['’]|['’](?![A-Za-z])")
_CODE_INDENT = re.compile(r"(?m)^(?: {4}|[ \t]*\t)")
_COUNT = re.compile(r"(?P<number>[0-9０-９零〇一二两三四五六七八九十百千万亿点.．]+)[ \t]*件事(?:情)?")
_LABEL = re.compile(
    r"^(?P<indent>[ \t]*)第(?P<number>[一二三四五六七八九十0-9]+)"
    r"(?P<unit>件事情|件事|个问题|个|件|点|项|条)?"
    r"(?P<punct>[，、,:：])(?P<body>.*)$"
)
_ANY_LABEL = re.compile(r"第[一二三四五六七八九十0-9]+(?:件事情|件事|个问题|个|件|点|项|条)?[，、,:：]")
_VALUES = {"一": 1, "二": 2, "三": 3, "1": 1, "2": 2, "3": 3}
_LABEL_OBJECT = r"(?:行首(?:的)?(?:标签|序号|编号|文字|字样)?|标签|序号|编号|称呼|写法|用词)"
_LABEL_META = re.compile(
    _LABEL_OBJECT + r"[^。！？\n]{0,20}(?:几个字|多少字|字数|[一二三四五六七八九十0-9]+个字|长度|字形|读音|含义|区别|差别)"
    r"|(?:讨论|说明|解释|比较|分析|保留|不要(?:改|变)|不(?:能|要)统一)[^。！？\n]{0,12}"
    + _LABEL_OBJECT
)
_LITERAL_REQUEST = re.compile(
    r"逐字|一字不(?:改|动)|原封不动|(?:原样|照原文)(?:保留|复制|输出|照抄|记录|呈现)"
    r"|(?:不要|别|不可)(?:改动|修改|更改|调整|统一)[^。！？\n]{0,8}(?:标签|序号|编号|名称|用词|称呼|写法)"
    r"|(?:命名|名称|名字|标题)[^。！？\n]{0,12}(?:保留|不变|原样|照抄)"
    r"|(?:三件事|三个(?:条目|项目))[^。！？\n]{0,12}(?:命名|名字|名称)"
    r"|(?:命名|名字|名称)[^。！？\n]{0,12}(?:三件事|三个(?:条目|项目))"
)


def protected(text):
    return bool(_QUOTE.search(text) or _CODE_INDENT.search(text)
                or LiteralText(text).has_literals
                or _LABEL_META.search(text) or _LITERAL_REQUEST.search(text))


def normalize(text, source_text=None):
    """Normalize three mixed labels only; retain bodies and paragraph bytes."""
    if not text or protected(text) or (source_text and protected(source_text)) or "\r" in text or any(
        char in text for char in '()（）[]【】{}<>《》`~"“”「」『』‘«»‹›'
    ):
        return text
    lines = text.splitlines(keepends=True)
    found = [(i, match) for i, line in enumerate(lines)
             if (match := _LABEL.fullmatch(line.removesuffix("\n")))]
    if len(found) != 3 or len(_ANY_LABEL.findall(text)) != 3:
        return text
    indexes = [i for i, _ in found]
    if indexes[0] == 0 or any(
        later-earlier > 2 or any(lines[gap].strip() for gap in range(earlier+1, later))
        for earlier, later in zip(indexes,indexes[1:])
    ):
        return text
    intro = indexes[0]-1
    if not lines[intro].strip():
        intro -= 1
    if intro < 0:
        return text
    counts = [m.group("number") for m in _COUNT.finditer(lines[intro])]
    if len(counts) != 1 or counts[0] not in {"三", "3", "３"}:
        return text
    matches = [m for _, m in found]
    if [_VALUES.get(m.group("number")) for m in matches] != [1,2,3]:
        return text
    if any(m.group("unit") not in {None,"个","件","件事","件事情"} for m in matches):
        return text
    if (len({m.group("unit") for m in matches}) == 1
        and len({m.group("punct") for m in matches}) == 1
        and len({m.group("number") in "一二三" for m in matches}) == 1):
        return text
    if len({m.group("indent") for m in matches}) != 1:
        return text
    if any(len(re.findall(r"[\u4e00-\u9fff]",m.group("body"))) < 2 for m in matches):
        return text
    punctuation = matches[0].group("punct") if len({m.group("punct") for m in matches}) == 1 else "，"
    for ordinal,(i,match) in enumerate(found):
        ending = "\n" if lines[i].endswith("\n") else ""
        lines[i] = f'{match.group("indent")}第{"一二三"[ordinal]}{punctuation}{match.group("body")}{ending}'
    return "".join(lines)


def format_after_refinement(text, source_text=None):
    """Source protection is checked before either soft lines or labels."""
    if protected(text) or (source_text and protected(source_text)):
        return text
    return normalize(_soft_linebreak(text), source_text=source_text)



_ORDINAL_LINE_BREAKS = "\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029"
_ORDINAL_LINE_TOKEN = (
    r"(?P<label>第(?P<zh>[零一二三四五六七八九十百千万\d]+)"
    r"(?:个问题|件事情|件事|部分|个|件|点|项|条|步)?(?:是)?"
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
    r"^[^\S\r\n]*第(?P<number>[一二三123])(?:件事情|件事|个问题|件|个|点|项|条)?"
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


def _soft_linebreak(text: str) -> str:
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
