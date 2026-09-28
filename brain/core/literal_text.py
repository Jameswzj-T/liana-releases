"""清洗前隔离明确的字面片段；不解析代码，不猜未标注文字的含义。

所有普通规则共用一份隔离结果，避免数字层保住了内容，词库/空格层又改坏它。
这里只用于本地确定性清洗；恢复后的真实正文才可交给文字模型和 Validator。
"""
import re




_LITERAL = re.compile(
    r"(?<!`)(?P<ticks>`+)(?!`)[\s\S]*?(?<!`)(?P=ticks)(?!`)"
    r"|(?P<fence>~{3,})[^\n]*\n[\s\S]*?^[ \t]*(?P=fence)~*[ \t]*(?=\n|$)"
    r'|"(?:\\[^\n]|[^"\\\n])*"'
    r"|(?<![A-Za-z0-9_])'(?:\\[^\n]|[^'\\\n]|(?<=[A-Za-z])'(?=[A-Za-z]))*'(?![A-Za-z0-9_])"
    r"|“[^”]*”|‘(?:[^’]|(?<=[A-Za-z])’(?=[A-Za-z]))*’(?![A-Za-z0-9_])"
    r"|「[^」]*」|『[^』]*』|《[^》]*》"
    r"|(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*://[^\s<>\"'“”‘’「」『』《》`、，。；！？]+"
    r"|(?<![\w@])[\w.+%\-]+@[\w.-]+\.[A-Za-z]{2,}"
    r"|(?<![A-Za-z0-9_./:])(?:[A-Za-z]:[\\/]|\\\\|~?/|\.\.?/)"
    r"[^\s<>\"'“”‘’「」『』《》`、，。；！？,;]+"
    r"|(?<![\w./:])[\w.-]+/"
    r"[^\s<>\"'“”‘’「」『』《》`、，。；！？,;]+"
    r"|(?<![\w./-])[\w-]+(?:\.[\w-]+)*\.[^\W\d][\w-]*"
    r"|(?<![A-Za-z0-9_.])\.[^\W\d][\w-]*",
    re.MULTILINE,
)


class LiteralText:
    """可逆占位，只含私用区字符，不会被数字/英文字母/中英空格规则二次处理。"""

    def __init__(self, source: str):
        prefix = "\ue000"
        while prefix in source:
            prefix += "\ue000"
        self._held: dict[str, str] = {}

        def hold(match: re.Match) -> str:
            index = "".join(chr(0xE010 + int(char, 16)) for char in f"{len(self._held):x}")
            token = prefix + index + "\ue001"
            self._held[token] = match.group(0)
            return token

        self.masked = _LITERAL.sub(hold, source)
        self._token = re.compile(re.escape(prefix) + "[\ue010-\ue01f]+\ue001")

    @property
    def has_literals(self) -> bool:
        return bool(self._held)

    def restore(self, text: str) -> str:

        return self._token.sub(lambda match: self._held.get(match.group(0), match.group(0)), text)
