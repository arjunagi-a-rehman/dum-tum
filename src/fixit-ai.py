#!/usr/bin/env python3
"""fixit AI helpers.

Usage:
    fixit-ai.py extract KIND    # stdin: provider output -> one command on stdout
    fixit-ai.py secrets-detect  # stdin: text -> exit 0 when a known secret shape is found
    fixit-ai.py secrets-redact  # stdin: text -> redacted text on stdout
    fixit-ai.py timeout SECS CMD [ARG ...] # supervise a command and its process group
    fixit-ai.py antigravity-request DIR OWNER SECS CMD [ARG ...] # reuse a session worker
    fixit-ai.py antigravity-stop DIR # stop a session worker and remove its directory
    fixit-ai.py body-openrouter # env FX_SYS, FX_USER, FX_MODEL -> OpenRouter JSON body
    fixit-ai.py body-openai     # env FX_SYS, FX_USER, FX_MODEL -> OpenAI JSON body
    fixit-ai.py body-anthropic  # env FX_SYS, FX_USER, FX_MODEL -> Anthropic messages JSON body
    fixit-ai.py body-gemini     # env FX_SYS, FX_USER -> Gemini generateContent JSON body
    fixit-ai.py body-antigravity # stdin prompt -> Antigravity stream-json user event
    fixit-ai.py rc-value NAME PATH # safely read an exported value from the dum-tum rc block
    fixit-ai.py proj            # print compact project hints for cwd (scripts, targets, markers)
    fixit-ai.py repair-line ... # stdin failed line -> span-preserving filename repair
"""

import json
import math
import os
import re
import selectors
import signal
import shutil
import socket
import stat
import subprocess
import shlex
import sys
import termios
import time
import unicodedata
from typing import Optional

HEADS = {
    "find", "ls", "cd", "cat", "grep", "rg", "fd", "mdfind", "locate", "open", "git",
    "npm", "brew", "echo", "pwd", "mkdir", "cp", "mv", "rm", "head", "tail", "wc", "du",
    "df", "ps", "curl", "ssh", "tar", "python", "python3", "node", "docker", "sed",
    "awk", "chmod", "touch", "which", "where", "type", "tree", "bat", "eza", "clear",
    "gls", "mdls", "xargs", "sort", "uniq", "zip", "unzip", "kill", "scp", "kubectl",
    "date", "whoami", "uname", "id", "true", "false", "history", "jobs", "fg", "bg",
    "sudo", "env", "source", "jq", "make", "go", "gh", "aws", "gcloud", "az", "helm",
    "cargo", "pip", "pip3", "yarn", "pnpm", "terraform", "systemctl", "apt", "apt-get",
    "dnf", "pacman", "gem", "bundle", "composer",
}

PROSE = re.compile(
    r"^(we |i |the |this |output|i.ll |i will|i need|presumably|"
    r"common |also |but |so |keep |reply |here |just |use )",
    re.I,
)

_SECRET_VALUE = (
    r'(?s:"(?P<double>(?:\\.|[^"\\\r\n])*)"|'
    r"'(?P<single>(?:\\.|[^'\\\r\n])*)'|"
    r'(?P<bare>[^\s;&|"\']+))'
)

_SECRET_VALUE_PATTERNS = (
    re.compile(
        r'(?i)(?P<prefix>\b(?!TOKEN_COUNT\b)(?:'
        r'(?:API_?KEY|ACCESS_?KEY(?:_ID)?|SECRET(?:_KEY)?|TOKEN|'
        r'PASS(?:WORD|WD)?|CREDENTIALS?)|'
        r'[A-Z_][A-Z0-9_]*(?:_KEY|_TOKEN|_SECRET|_PASS(?:WORD|WD)?|_CREDENTIALS?)'
        r')(?:_[A-Z0-9]+)*\b\s*=\s*)' + _SECRET_VALUE
    ),
    re.compile(
        r'(?i)(?P<prefix>--(?:api[-_]?key|apikey|access[-_]?key|client[-_]?secret|'
        r'password|passwd|token|secret)(?:\s*=\s*|\s+))' + _SECRET_VALUE
    ),
    re.compile(
        r'(?i)(?P<prefix>\b(?:'
        r'(?:proxy-)?authorization\s*:\s*(?:(?:bearer|basic|token)\s+|'
        r'(?!(?:bearer|basic|token)(?:\s|["\']|$)))|'
        r'(?:x-)?api[-_]?key\s*:\s*|'
        r'(?:x-)?(?:auth|access)[-_]?token\s*:\s*'
        r'))' + _SECRET_VALUE
    ),
    re.compile(
        r'(?i)(?<![A-Z0-9_])(?P<prefix>["\']?(?:'
        r'api[-_ ]?key|apikey|access[-_ ]?key|client[-_ ]?secret|password|passwd|'
        r'auth[-_ ]?token|token|secret|credentials?'
        r')["\']?\s*(?:=\s*|:\s+|:(?=["\'])))' + _SECRET_VALUE
    ),
)

_CREDENTIAL_URL = re.compile(
    r'(?i)(?P<prefix>\b[a-z][a-z0-9+.-]*://[^/@\s:"\']+:)'
    r'(?P<secret>[^/@\s"\']+)(?=@)'
)

_HIGH_CONFIDENCE_KEYS = re.compile(
    r'(?<![A-Za-z0-9_-])(?:'
    r'sk-[A-Za-z0-9_-]{8,}|'
    r'(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|'
    r'github_pat_[A-Za-z0-9_]{20,}|'
    r'gh[pousr]_[A-Za-z0-9]{20,}|'
    r'AKIA[0-9A-Z]{16}|'
    r'AIza[0-9A-Za-z_-]{30,}|'
    r'xox[baprs]-[A-Za-z0-9-]{10,}|'
    r'glpat-[A-Za-z0-9_-]{20,}'
    r')(?![A-Za-z0-9_-])'
)


def _redact_secret_value(match) -> str:
    prefix = match.group("prefix")
    if match.group("double") is not None:
        return f'{prefix}"[REDACTED]"'
    if match.group("single") is not None:
        return f"{prefix}'[REDACTED]'"
    return f"{prefix}[REDACTED]"


def redact_secrets(text: str) -> str:
    text = re.sub(
        r'(?i)(["\'])(\b(?:proxy-)?authorization\s*:\s*)(?:AWS4-HMAC-SHA256|Digest)\s+(?:\\.|(?!\1)[^\\\r\n])*\1',
        r'\1\2[REDACTED]\1', text,
    )
    text = re.sub(
        r'(?i)(\b(?:proxy-)?authorization\s*:\s*)(?:AWS4-HMAC-SHA256|Digest)\s+[^\r\n]+',
        r'\g<1>[REDACTED]', text,
    )
    for pattern in _SECRET_VALUE_PATTERNS:
        text = pattern.sub(_redact_secret_value, text)
    text = _CREDENTIAL_URL.sub(r'\g<prefix>[REDACTED]', text)
    return _HIGH_CONFIDENCE_KEYS.sub("[REDACTED-KEY]", text)


def has_secrets(text: str) -> bool:
    return redact_secrets(text) != text


def head_of(s: str) -> str:
    """Return the command head of a line, stripping sudo and path prefixes."""
    s = s.strip()
    if s.startswith("sudo "):
        s = s[5:].lstrip()
    return s.split()[0].split("/")[-1] if s else ""


def normalize_command(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "`\"'":
        s = s[1:-1].strip()
    return s


def is_command(s: str) -> bool:
    """Return whether a line begins with a plausible installed or known command."""
    s = normalize_command(s)
    if not s or s.startswith("http") or s.startswith("#") or PROSE.match(s):
        return False
    if not re.match(r"^[a-zA-Z0-9_./~+-]+(?:\s|$)", s):
        return False
    head = head_of(s)
    return head in os.environ.get("FX_COMMAND_NAMES", "").splitlines() or head in HEADS or shutil.which(head) is not None or s.startswith(("./", "../", "/", "~/"))


def extract(t: str) -> str:
    """Pull the single most plausible shell command out of free-form LLM text."""
    if not t:
        return ""
    t = re.sub(r"^```(?:\w+)?\s*", "", t.strip())
    t = re.sub(r"\s*```$", "", t).strip()
    lines = [ln.strip() for ln in t.splitlines() if ln.strip()]
    for i, ln in enumerate(lines):
        if not ln.startswith("# DANGER:"):
            continue
        if i + 1 >= len(lines) or lines[i + 1].startswith("# DANGER:"):
            return ""
        command = normalize_command(lines[i + 1])
        return f"{ln}\n{command}" if is_command(command) else ""
    for c in reversed(re.findall(r"`([^`\n]+)`", t)):
        c = normalize_command(c)
        if is_command(c):
            return c
    for raw_line in lines:
        if raw_line.startswith("```"):
            continue
        ln = normalize_command(raw_line)
        if ln.startswith("#") or PROSE.match(ln):
            continue
        if is_command(ln):
            return ln
    return ""


class PayloadError(ValueError):
    pass


def _report_error(err: object) -> None:
    msg = err.get("message", err) if isinstance(err, dict) else err
    sys.stderr.write(safe_terminal_text(f"AI error: {msg}\n"))


def _json(raw: str) -> object:
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise PayloadError("malformed JSON") from exc


def _object(value: object, name: str) -> dict:
    if not isinstance(value, dict):
        raise PayloadError(f"{name} must be an object")
    return value


def _visible_text(value: object, name: str) -> str:
    if isinstance(value, str):
        return value
    if not isinstance(value, list):
        raise PayloadError(f"{name} must be text or text parts")
    parts = []
    for item in value:
        block = _object(item, f"{name} part")
        if block.get("type") != "text":
            continue
        text = block.get("text")
        if not isinstance(text, str):
            raise PayloadError(f"{name} text part must contain text")
        parts.append(text)
    return "".join(parts)


def _check_api_error(payload: dict) -> bool:
    if "error" not in payload:
        return False
    _report_error(payload["error"])
    return True


def _parse_chat(raw: str) -> str:
    payload = _object(_json(raw), "chat response")
    if _check_api_error(payload):
        return ""
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise PayloadError("chat response has no choices")
    choice = _object(choices[0], "chat choice")
    message = _object(choice.get("message"), "chat message")
    return _visible_text(message.get("content"), "chat content")


def _parse_anthropic(raw: str) -> str:
    payload = _object(_json(raw), "Anthropic response")
    if _check_api_error(payload):
        return ""
    content = payload.get("content")
    if not isinstance(content, list):
        raise PayloadError("Anthropic content must be a list")
    parts = []
    for item in content:
        block = _object(item, "Anthropic content block")
        if block.get("type") != "text":
            continue
        text = block.get("text")
        if not isinstance(text, str):
            raise PayloadError("Anthropic text block must contain text")
        parts.append(text)
    return "".join(parts)


def _parse_gemini(raw: str) -> str:
    payload = _object(_json(raw), "Gemini response")
    if _check_api_error(payload):
        return ""
    candidates = payload.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise PayloadError("Gemini response has no candidates")
    candidate = _object(candidates[0], "Gemini candidate")
    content = _object(candidate.get("content"), "Gemini content")
    parts = content.get("parts")
    if not isinstance(parts, list):
        raise PayloadError("Gemini parts must be a list")
    visible = []
    for item in parts:
        part = _object(item, "Gemini part")
        if part.get("thought") is True or "text" not in part:
            continue
        text = part["text"]
        if not isinstance(text, str):
            raise PayloadError("Gemini text part must contain text")
        visible.append(text)
    return "".join(visible)


def _json_lines(raw: str, provider: str) -> list:
    events = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        event = _object(_json(line), f"{provider} event")
        if _check_api_error(event):
            return []
        events.append(event)
    return events


def _parse_opencode(raw: str) -> str:
    parts = []
    for event in _json_lines(raw, "OpenCode"):
        if event.get("type") != "text":
            continue
        part = _object(event.get("part"), "OpenCode text part")
        if part.get("type") not in (None, "text"):
            continue
        text = part.get("text")
        if not isinstance(text, str):
            raise PayloadError("OpenCode text part must contain text")
        parts.append(text)
    return "".join(parts)


def _parse_claude(raw: str) -> str:
    payload = _object(_json(raw), "Claude response")
    if _check_api_error(payload):
        return ""
    if payload.get("type") != "result":
        raise PayloadError("Claude response is not a result")
    result = payload.get("result")
    if payload.get("is_error") is True:
        _report_error(result)
        return ""
    if payload.get("subtype") != "success" or not isinstance(result, str):
        raise PayloadError("Claude result is malformed")
    return result


def _parse_antigravity(raw: str) -> str:
    results = []
    for event in _json_lines(raw, "Antigravity"):
        if event.get("event") != "result":
            continue
        result = _object(event.get("result"), "Antigravity result")
        if result.get("status") != "SUCCESS":
            _report_error(result.get("error") or result.get("response") or result.get("status"))
            return ""
        response = result.get("response")
        if not isinstance(response, str):
            raise PayloadError("Antigravity result must contain a response")
        results.append(response)
    if len(results) > 1:
        raise PayloadError("Antigravity returned multiple results")
    return results[0] if results else ""


PARSERS = {
    "chat": _parse_chat,
    "anthropic": _parse_anthropic,
    "gemini": _parse_gemini,
    "opencode": _parse_opencode,
    "claude": _parse_claude,
    "antigravity": _parse_antigravity,
}


def parse_payload(raw: str, provider: str = "plain") -> str:
    """Return only the documented visible response text for a provider."""
    if not raw.strip():
        return ""
    if provider == "plain":
        return raw
    parser = PARSERS.get(provider)
    if parser is None:
        sys.stderr.write(safe_terminal_text(f"AI output error: unknown provider output kind: {provider}\n"))
        return ""
    try:
        return parser(raw)
    except PayloadError as exc:
        sys.stderr.write(safe_terminal_text(f"AI output error ({provider}): {exc}\n"))
        return ""


def cmd_extract(provider: str = "plain") -> None:
    raw = sys.stdin.read()
    out = extract(parse_payload(raw, provider))
    if out:
        print(out)


def safe_terminal_text(text: str) -> str:
    return "".join(
        char if char in "\n\t" or not unicodedata.category(char).startswith("C")
        else (f"\\x{ord(char):02x}" if ord(char) < 256 else f"\\u{ord(char):04x}")
        for char in text
    )


def command_is_display_safe(text: str) -> bool:
    lines = text.split("\n")
    if len(lines) > 1 and not (len(lines) == 2 and lines[0].startswith("# DANGER:")):
        return False
    if not text or any(unicodedata.category(char).startswith("C")
                       for char in text if char != "\n"):
        return False
    for index, char in enumerate(text):
        if char != "!":
            continue
        preceding = index - 1
        while preceding >= 0 and text[preceding] == "\\":
            preceding -= 1
        if (index - preceding - 1) % 2:
            continue
        following = text[index + 1:index + 2]
        if following and not following.isspace() and following != "=":
            return False
    return True


def cmd_tty_choice() -> None:
    message = safe_terminal_text(sys.stdin.read())
    fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    original = termios.tcgetattr(fd)
    try:
        settings = termios.tcgetattr(fd)
        settings[3] &= ~(termios.ICANON | termios.ECHO)
        settings[6][termios.VMIN] = 1
        settings[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSAFLUSH, settings)
        os.write(fd, b"\x1b[0m" + message.encode())
        choice = os.read(fd, 1)
        os.write(fd, b"\n")
        if not choice:
            raise SystemExit(1)
        sys.stdout.write(choice.decode(errors="replace"))
    finally:
        termios.tcsetattr(fd, termios.TCSAFLUSH, original)
        os.close(fd)


def cmd_payload() -> None:
    payload = {"os": os.uname().sysname, "shell": os.environ.get("FX_SHELL_NAME", ""),
               "task": redact_secrets(os.environ.get("FX_TASK", ""))}
    context = {"cwd": redact_secrets(os.getcwd()), "entries": [],
               "project": proj_hints(),
               "aliases": redact_secrets(os.environ.get("FX_ALIAS_HINTS", "")[:3000])}
    with os.scandir() as entries:
        for entry in entries:
            context["entries"].append(redact_secrets(entry.name))
            if len(context["entries"]) >= 20:
                break
    payload["untrusted_context"] = context
    print(json.dumps(payload, ensure_ascii=True))


def cmd_secrets_detect() -> None:
    raise SystemExit(0 if has_secrets(sys.stdin.read()) else 1)


def cmd_secrets_redact() -> None:
    sys.stdout.write(redact_secrets(sys.stdin.read()))


def _shell_literal(text: str, start: int) -> str:
    value = []
    index = start
    while index < len(text):
        char = text[index]
        if char == "\n":
            break
        if char == "'":
            end = text.find("'", index + 1)
            if end < 0:
                break
            value.append(text[index + 1:end])
            index = end + 1
            continue
        if char == "\\" and index + 1 < len(text):
            value.append(text[index + 1])
            index += 2
            continue
        if char == '"':
            index += 1
            while index < len(text) and text[index] != '"':
                if text[index] == "\\" and index + 1 < len(text):
                    if text[index + 1] in '\\"$`':
                        index += 1
                value.append(text[index])
                index += 1
            index += index < len(text)
            continue
        value.append(char)
        index += 1
    return "".join(value)


def rc_export_value(text: str, name: str) -> str:
    begin = "# >>> fixit.zsh >>>"
    end = "# <<< fixit.zsh <<<"
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines) if line == begin]
    ends = [index for index, line in enumerate(lines) if line == end]
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        return ""
    text = "\n".join(lines[starts[0] + 1:ends[0]])
    pattern = re.compile(r"(?m)^[ \t]*export[ \t]+" + re.escape(name) + r"=")
    quote = None
    escaped = False
    escaped_outside = False
    line_start = True
    index = 0
    while index < len(text):
        if line_start and quote is None:
            match = pattern.match(text, index)
            if match:
                return _shell_literal(text, match.end())
        char = text[index]
        if quote == "'":
            if char == "'":
                quote = None
        elif quote == '"':
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quote = None
        elif escaped_outside:
            escaped_outside = False
        elif char == "\\":
            escaped_outside = True
        elif char in "'\"":
            quote = char
        elif char == "#" and line_start:
            newline = text.find("\n", index)
            if newline < 0:
                break
            index = newline
            char = "\n"
        line_start = char == "\n" or (line_start and char in " \t")
        index += 1
    return ""


def cmd_rc_value(name: str, path: str) -> None:
    try:
        with open(path, encoding="utf-8", errors="replace") as rc_file:
            value = rc_export_value(rc_file.read(), name)
    except OSError:
        return
    sys.stdout.write(value)


def _help_option_declaration(line: str):
    stripped = line.lstrip(" \t")
    if not re.match(r"^--?[A-Za-z0-9]", stripped):
        return None
    head = re.split(r"(?: {2,}|\t+)", stripped, maxsplit=1)[0]
    declared = re.findall(r"(?<![A-Za-z0-9_-])--?[A-Za-z0-9][A-Za-z0-9_-]*", head)
    if not declared:
        return None
    if len(declared) > 1 and "," not in head:
        return None
    remainder = re.sub(
        r"(?<![A-Za-z0-9_-])--?[A-Za-z0-9][A-Za-z0-9_-]*", "", head
    )
    remainder = re.sub(r"<[^>]*>|\[[^\]]*\]|\b[A-Z][A-Z0-9_-]*\b", "", remainder)
    if remainder.replace(",", "").strip():
        return None
    indent = len(line[: len(line) - len(stripped)].expandtabs(8))
    return indent, set(declared)


def cmd_help_options(options: list) -> int:
    lines = sys.stdin.read().splitlines()
    declared_lines = []
    declarations_by_line = {}
    section = ""
    for index, line in enumerate(lines):
        stripped = line.strip()
        if line == line.lstrip(" \t") and stripped.endswith(":"):
            section = stripped[:-1].lower()
        declaration = _help_option_declaration(line)
        if declaration is not None and not section.startswith("example"):
            declared_lines.append((line, declaration))
            declarations_by_line[index] = declaration
    if not declared_lines:
        return 1
    base_indent = min(indent for _, (indent, _) in declared_lines)
    allowed_indents = {base_indent}
    if any(
        indent == base_indent and re.match(r"^\s*-[A-Za-z0-9]\s*,", line)
        for line, (indent, _) in declared_lines
    ):
        allowed_indents.add(base_indent + 4)

    blocks = []
    current_lines = []
    current_options = set()
    for index, line in enumerate(lines):
        declaration = declarations_by_line.get(index)
        if declaration is not None:
            if current_lines:
                blocks.append((current_options, "\n".join(current_lines)))
            if declaration[0] in allowed_indents:
                current_options = declaration[1]
                current_lines = [line.strip()]
            else:
                current_options = set()
                current_lines = []
        elif current_lines and (line.startswith(" ") or line.startswith("\t")):
            current_lines.append(line.strip())
        elif current_lines:
            blocks.append((current_options, "\n".join(current_lines)))
            current_options = set()
            current_lines = []
    if current_lines:
        blocks.append((current_options, "\n".join(current_lines)))

    for requirement in options:
        option, separator, value = requirement.partition("=")
        candidates = [text for declared, text in blocks if option in declared]
        if not candidates:
            return 1
        if separator:
            value_re = re.compile(rf"(?<![A-Za-z0-9_-]){re.escape(value)}(?![A-Za-z0-9_-])")
            if not any(value_re.search(block) for block in candidates):
                return 1
    return 0


def _all_policy_values(value, required) -> bool:
    if isinstance(value, dict):
        return bool(value) and all(_all_policy_values(item, required) for item in value.values())
    if isinstance(required, bool):
        return value is required
    return value == required


def _nested_policies_are_safe(value) -> bool:
    if isinstance(value, list):
        return all(_nested_policies_are_safe(item) for item in value)
    if not isinstance(value, dict):
        return True
    for key, item in value.items():
        if key == "permission" and not _all_policy_values(item, "deny"):
            return False
        if key == "tools" and not _all_policy_values(item, False):
            return False
        if not _nested_policies_are_safe(item):
            return False
    return True


def cmd_opencode_config_deny() -> int:
    try:
        config = json.load(sys.stdin)
    except (json.JSONDecodeError, TypeError):
        return 1
    if not isinstance(config, dict) or config.get("plugin") != []:
        return 1
    permissions = config.get("permission")
    tools = config.get("tools")
    if not isinstance(permissions, dict) or permissions.get("*") != "deny":
        return 1
    if not isinstance(tools, dict) or tools.get("*") is not False:
        return 1
    if not _all_policy_values(permissions, "deny") or not _all_policy_values(tools, False):
        return 1
    if any(scope in config and not isinstance(config[scope], dict) for scope in ("agent", "mode")):
        return 1
    if not _nested_policies_are_safe(config):
        return 1
    return 0


def _signal_process(process: subprocess.Popen, sig: int) -> None:
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        try:
            process.send_signal(sig)
        except ProcessLookupError:
            pass


def _stop_process(process: subprocess.Popen) -> tuple:
    _signal_process(process, signal.SIGTERM)
    try:
        output = process.communicate(timeout=0.5)
        _signal_process(process, signal.SIGKILL)
        return output
    except subprocess.TimeoutExpired:
        _signal_process(process, signal.SIGKILL)
        try:
            return process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            return process.communicate(timeout=2)


def _cleanup_process(process: subprocess.Popen) -> None:
    try:
        _stop_process(process)
        return
    except BaseException:
        pass
    try:
        _signal_process(process, signal.SIGKILL)
    except BaseException:
        pass
    try:
        process.kill()
    except (ProcessLookupError, PermissionError):
        pass
    try:
        process.communicate(timeout=2)
    except BaseException:
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass


def _write_process_output(stdout: bytes, stderr: bytes) -> None:
    if stdout:
        sys.stdout.buffer.write(stdout)
        sys.stdout.buffer.flush()
    if stderr:
        sys.stderr.buffer.write(safe_terminal_text(stderr.decode(errors="replace")).encode())
        sys.stderr.buffer.flush()


class _SupervisorSignal(Exception):
    def __init__(self, signum: int):
        self.signum = signum


def run_with_timeout(seconds: float, command: list) -> int:
    child_stdin = subprocess.DEVNULL if sys.stdin.isatty() else sys.stdin.buffer
    try:
        process = subprocess.Popen(
            command,
            stdin=child_stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except FileNotFoundError:
        sys.stderr.write(f"{command[0]}: command not found\n")
        return 127
    except PermissionError:
        sys.stderr.write(f"{command[0]}: permission denied\n")
        return 126

    handled_signals = tuple(
        sig for sig in (getattr(signal, "SIGTERM", None), getattr(signal, "SIGHUP", None), getattr(signal, "SIGINT", None))
        if sig is not None
    )
    previous_handlers = {sig: signal.getsignal(sig) for sig in handled_signals}

    def forward_signal(signum, _frame):
        _signal_process(process, signum)
        raise _SupervisorSignal(signum)

    try:
        for sig in handled_signals:
            signal.signal(sig, forward_signal)
        try:
            stdout, stderr = process.communicate(timeout=seconds)
        except subprocess.TimeoutExpired:
            stdout, stderr = _stop_process(process)
            _write_process_output(stdout, stderr)
            return 124
    except _SupervisorSignal as exc:
        _cleanup_process(process)
        return 128 + exc.signum
    except BaseException:
        _cleanup_process(process)
        raise
    finally:
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)

    _write_process_output(stdout, stderr)
    return process.returncode if process.returncode >= 0 else 128 - process.returncode


def cmd_timeout(args: list) -> int:
    if len(args) < 2:
        sys.stderr.write("usage: fixit-ai.py timeout SECS CMD [ARG ...]\n")
        return 2
    try:
        seconds = float(args[0])
    except ValueError:
        sys.stderr.write(f"invalid timeout: {args[0]}\n")
        return 2
    if not math.isfinite(seconds) or seconds < 0:
        sys.stderr.write(f"invalid timeout: {args[0]}\n")
        return 2
    return run_with_timeout(seconds, args[1:])


def _session_seconds(value) -> float:
    try:
        seconds = float(value)
    except (TypeError, ValueError) as exc:
        raise PayloadError(f"invalid timeout: {value}") from exc
    if not math.isfinite(seconds) or seconds < 0:
        raise PayloadError(f"invalid timeout: {value}")
    return seconds


def _session_directory(path: str) -> str:
    path = os.path.abspath(path)
    info = os.lstat(path)
    if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid != os.getuid() or info.st_mode & 0o077
            or not os.path.basename(path).startswith("fixit-agy.")):
        raise PayloadError("invalid Antigravity session directory")
    return path


def _socket_message(connection: socket.socket) -> dict:
    data = bytearray()
    while not data.endswith(b"\n"):
        chunk = connection.recv(65536)
        if not chunk:
            break
        data.extend(chunk)
        if len(data) > 16 * 1024 * 1024:
            raise PayloadError("Antigravity session message is too large")
    if not data:
        raise PayloadError("empty Antigravity session message")
    return _object(_json(data.decode("utf-8")), "Antigravity session message")


def _send_socket_message(connection: socket.socket, message: dict) -> None:
    connection.sendall(json.dumps(message).encode("utf-8") + b"\n")


def _session_response(status: int, stdout: str = "", stderr: str = "") -> dict:
    return {"status": status, "stdout": stdout, "stderr": stderr}


def _owner_alive(owner: int) -> bool:
    try:
        os.kill(owner, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _launch_session_worker(session_dir: str, owner: int) -> None:
    subprocess.Popen(
        [
            sys.executable,
            os.path.abspath(__file__),
            "antigravity-worker",
            session_dir,
            str(owner),
            os.environ.get("FX_AGY_IDLE_TIMEOUT", "300"),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )


def _connect_session(session_dir: str, owner: int, deadline: float) -> socket.socket:
    socket_path = os.path.join(session_dir, "session.sock")
    launched = False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Antigravity request timed out")
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(remaining)
        try:
            connection.connect(socket_path)
            return connection
        except (FileNotFoundError, ConnectionRefusedError):
            connection.close()
            if not launched:
                try:
                    os.unlink(socket_path)
                except FileNotFoundError:
                    pass
                _launch_session_worker(session_dir, owner)
                launched = True
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))


def cmd_antigravity_request(args: list) -> int:
    if len(args) < 4:
        sys.stderr.write("usage: fixit-ai.py antigravity-request DIR OWNER SECS CMD [ARG ...]\n")
        return 2
    try:
        session_dir = _session_directory(args[0])
        owner = int(args[1])
        if owner <= 0:
            raise PayloadError("invalid Antigravity session owner")
        seconds = _session_seconds(args[2])
        body = sys.stdin.read()
        deadline = time.monotonic() + seconds
        connection = _connect_session(session_dir, owner, deadline)
        with connection:
            remaining = max(0, deadline - time.monotonic())
            connection.settimeout(remaining)
            _send_socket_message(connection, {
                "body": body,
                "command": args[3:],
                "timeout": remaining,
            })
            connection.settimeout(remaining + 3)
            response = _socket_message(connection)
        status = response.get("status")
        stdout = response.get("stdout")
        stderr = response.get("stderr")
        if not isinstance(status, int) or not isinstance(stdout, str) or not isinstance(stderr, str):
            raise PayloadError("malformed Antigravity session response")
        sys.stdout.write(stdout)
        sys.stdout.flush()
        sys.stderr.write(safe_terminal_text(stderr))
        sys.stderr.flush()
        return status
    except TimeoutError:
        sys.stderr.write("Antigravity request timed out\n")
        return 124
    except KeyboardInterrupt:
        return 130
    except (OSError, PayloadError, ValueError) as exc:
        sys.stderr.write(f"Antigravity session error: {exc}\n")
        return 1


def cmd_antigravity_stop(args: list) -> int:
    if len(args) != 1:
        sys.stderr.write("usage: fixit-ai.py antigravity-stop DIR\n")
        return 2
    try:
        session_dir = _session_directory(args[0])
    except FileNotFoundError:
        return 0
    except (OSError, PayloadError) as exc:
        sys.stderr.write(f"Antigravity session error: {exc}\n")
        return 1
    socket_path = os.path.join(session_dir, "session.sock")
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(1)
    try:
        connection.connect(socket_path)
    except (FileNotFoundError, ConnectionRefusedError):
        connection.close()
        shutil.rmtree(session_dir, ignore_errors=True)
        return 0
    except OSError as exc:
        connection.close()
        sys.stderr.write(f"Antigravity session error: {exc}\n")
        return 1
    try:
        with connection:
            _send_socket_message(connection, {"stop": True})
            response = _socket_message(connection)
        if response.get("status") != 0:
            return 1
        deadline = time.monotonic() + 5
        while os.path.exists(session_dir) and time.monotonic() < deadline:
            time.sleep(0.05)
        return 0 if not os.path.exists(session_dir) else 1
    except (OSError, PayloadError) as exc:
        sys.stderr.write(f"Antigravity session error: {exc}\n")
        return 1


def _provider_diagnostics(provider: dict) -> str:
    return bytes(provider["stderr"]).decode("utf-8", errors="replace")


def _stop_provider(provider: dict) -> None:
    process = provider["process"]
    if process is not None:
        _cleanup_process(process)
    provider["process"] = None


def _start_provider(provider: dict, command: list, workdir: str) -> None:
    _stop_provider(provider)
    provider["stdout"] = b""
    provider["stderr"] = bytearray()
    provider["process"] = subprocess.Popen(
        command,
        cwd=workdir,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )


def _provider_failure(provider: dict, status: int, stdout: str = "") -> dict:
    process = provider["process"]
    if process is not None:
        _, stderr = _stop_process(process)
        provider["stderr"].extend(stderr)
    provider["process"] = None
    return _session_response(status, stdout, _provider_diagnostics(provider))


def _antigravity_turn(provider: dict, body: str, timeout: float, workdir: str, owner: int,
                      client: Optional[socket.socket] = None) -> dict:
    command = provider["command"]
    if provider["process"] is None or provider["process"].poll() is not None:
        try:
            _start_provider(provider, command, workdir)
        except FileNotFoundError:
            return _session_response(127, "", f"{command[0]}: command not found\n")
        except PermissionError:
            return _session_response(126, "", f"{command[0]}: permission denied\n")
        except OSError as exc:
            return _session_response(1, "", f"{command[0]}: {exc}\n")
    provider["stderr"] = bytearray()
    process = provider["process"]
    body = body.strip()
    try:
        request = _object(_json(body), "Antigravity request")
        if request.get("event") != "user":
            raise PayloadError("Antigravity request is not a user event")
    except PayloadError as exc:
        return _session_response(2, "", f"Antigravity request error: {exc}\n")

    payload = memoryview(body.encode("utf-8") + b"\n")
    deadline = time.monotonic() + timeout
    events = []
    selector = selectors.DefaultSelector()
    os.set_blocking(process.stdin.fileno(), False)
    selector.register(process.stdin, selectors.EVENT_WRITE, "stdin")
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    if client is not None:
        selector.register(client, selectors.EVENT_READ, "client")
    try:
        while True:
            if (not any(key.data in ("stdout", "stderr") for key in selector.get_map().values())
                    and process.poll() is not None):
                break
            if not _owner_alive(owner):
                raise _SupervisorSignal(signal.SIGTERM)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return _provider_failure(provider, 124)
            for key, _ in selector.select(min(1, remaining)):
                if key.data == "client":
                    try:
                        disconnected = not client.recv(1, socket.MSG_PEEK)
                    except (BlockingIOError, socket.timeout):
                        disconnected = False
                    except OSError:
                        disconnected = True
                    if disconnected:
                        return _provider_failure(provider, 130)
                    continue
                if key.data == "stdin":
                    try:
                        written = os.write(key.fileobj.fileno(), payload)
                    except BlockingIOError:
                        continue
                    except OSError:
                        status = process.poll()
                        return _provider_failure(provider, status if status not in (None, 0) else 1)
                    payload = payload[written:]
                    if not payload:
                        selector.unregister(key.fileobj)
                    continue
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if key.data == "stderr":
                    provider["stderr"].extend(chunk)
                    if len(provider["stderr"]) > 65536:
                        del provider["stderr"][:-65536]
                    continue
                provider["stdout"] += chunk
                while b"\n" in provider["stdout"]:
                    line, provider["stdout"] = provider["stdout"].split(b"\n", 1)
                    events.append(line.decode("utf-8", errors="replace"))
                    try:
                        event = _object(_json(line.decode("utf-8")), "Antigravity event")
                    except (PayloadError, UnicodeDecodeError):
                        return _provider_failure(provider, 1, "")
                    if event.get("event") == "result":
                        return _session_response(
                            0,
                            "\n".join(events) + "\n",
                            _provider_diagnostics(provider),
                        )
        status = process.wait()
        output = "\n".join(events)
        if provider["stdout"]:
            output += provider["stdout"].decode("utf-8", errors="replace")
        if output:
            output += "\n"
        return _provider_failure(provider, status, output if status == 0 else "")
    finally:
        selector.close()


def _antigravity_worker(session_dir: str, owner: int, idle_timeout: float) -> int:
    session_dir = _session_directory(session_dir)
    socket_path = os.path.join(session_dir, "session.sock")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(socket_path)
        os.chmod(socket_path, 0o600)
        server.listen(8)
    except OSError:
        server.close()
        return 1
    workdir = os.path.join(session_dir, "work")
    os.makedirs(workdir, mode=0o700, exist_ok=True)
    provider = {"process": None, "command": None, "stdout": b"", "stderr": bytearray()}
    handled_signals = tuple(
        sig for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
        if sig is not None
    )
    previous_handlers = {sig: signal.getsignal(sig) for sig in handled_signals}

    def stop_worker(signum, _frame):
        raise _SupervisorSignal(signum)

    status = 0
    last_request = time.monotonic()
    try:
        for sig in handled_signals:
            signal.signal(sig, stop_worker)
        while True:
            idle_remaining = idle_timeout - (time.monotonic() - last_request)
            if idle_remaining <= 0 or not _owner_alive(owner):
                break
            server.settimeout(min(1, idle_remaining))
            try:
                connection, _ = server.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(5)
                try:
                    request = _socket_message(connection)
                    if request.get("stop") is True:
                        try:
                            _send_socket_message(connection, _session_response(0))
                        except OSError:
                            pass
                        break
                    body = request.get("body")
                    command = request.get("command")
                    timeout = _session_seconds(request.get("timeout"))
                    if not isinstance(body, str) or not isinstance(command, list) or not command:
                        raise PayloadError("malformed Antigravity worker request")
                    if not all(isinstance(part, str) for part in command):
                        raise PayloadError("malformed Antigravity worker command")
                    if provider["command"] is not None and command != provider["command"]:
                        _stop_provider(provider)
                    provider["command"] = command
                    response = _antigravity_turn(provider, body, timeout, workdir, owner, connection)
                except _SupervisorSignal:
                    raise
                except (OSError, PayloadError, ValueError) as exc:
                    response = _session_response(2, "", f"Antigravity worker error: {exc}\n")
                try:
                    _send_socket_message(connection, response)
                except OSError:
                    pass
            last_request = time.monotonic()
    except _SupervisorSignal as exc:
        status = 128 + exc.signum
    finally:
        server.close()
        _stop_provider(provider)
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass
        shutil.rmtree(session_dir, ignore_errors=True)
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
    return status


def cmd_antigravity_worker(args: list) -> int:
    if len(args) != 3:
        return 2
    try:
        return _antigravity_worker(args[0], int(args[1]), _session_seconds(args[2]))
    except (OSError, PayloadError, ValueError):
        return 1


def _chat_body(token_field: str) -> dict:
    return {
        "model": os.environ["FX_MODEL"],
        token_field: 800,
        "messages": [
            {"role": "system", "content": os.environ["FX_SYS"]},
            {"role": "user", "content": os.environ["FX_USER"]},
        ],
    }


def cmd_body_openrouter() -> None:
    print(json.dumps(_chat_body("max_tokens")))


def cmd_body_openai() -> None:
    print(json.dumps(_chat_body("max_completion_tokens")))


def cmd_body_anthropic() -> None:
    print(json.dumps({
        "model": os.environ["FX_MODEL"],
        "max_tokens": 800,
        "system": os.environ["FX_SYS"],
        "messages": [
            {"role": "user", "content": os.environ["FX_USER"]},
        ],
    }))


def cmd_body_gemini() -> None:
    print(json.dumps({
        "system_instruction": {"parts": [{"text": os.environ["FX_SYS"]}]},
        "contents": [
            {"role": "user", "parts": [{"text": os.environ["FX_USER"]}]},
        ],
    }))


def cmd_body_antigravity() -> None:
    """Print an Antigravity stream-json user event from stdin."""
    print(json.dumps({
        "event": "user",
        "message": {"content": sys.stdin.read()},
    }))


def _skip_balanced(line: str, index: int, opener: str, closer: str) -> int:
    depth = 1
    quote = ""
    while index < len(line) and depth:
        char = line[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in "'\"`":
            quote = char
        elif char == "\\":
            index += 2
            continue
        elif char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
        index += 1
    return index


def _skip_dollar(line: str, index: int) -> int:
    index += 1
    if index >= len(line):
        return index
    if line[index] == "(":
        return _skip_balanced(line, index + 1, "(", ")")
    if line[index] == "{":
        return _skip_balanced(line, index + 1, "{", "}")
    if line[index].isalpha() or line[index] == "_":
        index += 1
        while index < len(line) and (line[index].isalnum() or line[index] == "_"):
            index += 1
        return index
    return index + 1


def shell_words(line: str) -> list:
    words = []
    index = 0
    while index < len(line):
        if line[index] == "\n":
            words.append(("operator", index, index + 1, "\n", False))
            index += 1
            continue
        if line[index].isspace():
            index += 1
            continue
        if line[index] == "#":
            break
        if line[index] in "|&;<>()":
            start = index
            char = line[index]
            index += 1
            while index < len(line) and line[index] == char:
                index += 1
            words.append(("operator", start, index, line[start:index], False))
            continue

        start = index
        value = []
        literal = True
        while index < len(line):
            char = line[index]
            if char == "\n" or char.isspace() or char in "|&;<>()":
                break
            if char == "'":
                end = line.find("'", index + 1)
                if end < 0:
                    literal = False
                    index = len(line)
                    break
                value.append(line[index + 1:end])
                index = end + 1
                continue
            if char == '"':
                index += 1
                closed = False
                while index < len(line):
                    char = line[index]
                    if char == '"':
                        index += 1
                        closed = True
                        break
                    if char == "$":
                        literal = False
                        index = _skip_dollar(line, index)
                        continue
                    if char == "`":
                        literal = False
                        end = index + 1
                        while end < len(line):
                            if line[end] == "\\":
                                end += 2
                            elif line[end] == "`":
                                end += 1
                                break
                            else:
                                end += 1
                        index = end
                        continue
                    if char == "\\" and index + 1 < len(line):
                        value.append(line[index + 1])
                        index += 2
                        continue
                    value.append(char)
                    index += 1
                if not closed:
                    literal = False
                continue
            if char == "$":
                literal = False
                index = _skip_dollar(line, index)
                continue
            if char == "`":
                literal = False
                end = index + 1
                while end < len(line):
                    if line[end] == "\\":
                        end += 2
                    elif line[end] == "`":
                        end += 1
                        break
                    else:
                        end += 1
                index = end
                continue
            if char == "\\" and index + 1 < len(line):
                value.append(line[index + 1])
                index += 2
                continue
            if char in "*?[{}]":
                literal = False
            value.append(char)
            index += 1
        words.append(("word", start, index, "".join(value), literal))
    return words


def _distance(left: str, right: str) -> int:
    if abs(len(left) - len(right)) > 2:
        return 99
    rows = [[0] * (len(right) + 1) for _ in range(len(left) + 1)]
    for row in range(len(left) + 1):
        rows[row][0] = row
    for column in range(len(right) + 1):
        rows[0][column] = column
    for row in range(1, len(left) + 1):
        for column in range(1, len(right) + 1):
            cost = left[row - 1].lower() != right[column - 1].lower()
            rows[row][column] = min(
                rows[row - 1][column] + 1,
                rows[row][column - 1] + 1,
                rows[row - 1][column - 1] + cost,
            )
            if (row > 1 and column > 1
                    and left[row - 1].lower() == right[column - 2].lower()
                    and left[row - 2].lower() == right[column - 1].lower()):
                rows[row][column] = min(rows[row][column], rows[row - 2][column - 2] + 1)
    return rows[-1][-1]


def _repair_candidates(cwd: str) -> list:
    candidates = []
    try:
        first_level = list(os.scandir(cwd))
    except OSError:
        return candidates
    for entry in first_level:
        if entry.name.startswith(".git"):
            continue
        candidates.append(entry.name)
        if not entry.is_dir(follow_symlinks=False):
            continue
        try:
            candidates.extend(f"{entry.name}/{child.name}" for child in os.scandir(entry.path)
                              if not child.name.startswith(".git"))
        except OSError:
            pass
    return candidates


def repair_failed_line(line: str, safe_heads: list, candidates=None, cwd: str = "."):
    tokens = shell_words(line)
    head = ""
    has_assignments = False
    arguments = []
    for token in tokens:
        kind, _, _, value, literal = token
        if kind == "operator":
            if value[0] in "|&;()" or value == "\n":
                break
            continue
        if not head:
            if not literal:
                return None
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", value):
                has_assignments = True
                continue
            head = value
            continue
        arguments.append(token)
    if head not in safe_heads:
        return None

    choices = _repair_candidates(cwd) if candidates is None else candidates
    for _, start, end, value, literal in arguments:
        if not literal or not value or value.startswith("-") or "\t" in value or "\n" in value:
            continue
        if os.path.exists(os.path.join(cwd, value)):
            continue
        best = ""
        best_distance = 99
        for candidate in choices:
            if "\t" in candidate or "\n" in candidate:
                continue
            distance = _distance(value, candidate)
            if distance < best_distance or (
                    distance == best_distance and best and len(candidate) < len(best)):
                best = candidate
                best_distance = distance
        if not best or best_distance > 2 or best_distance * 2 >= len(value) + 2:
            continue
        if best.startswith("-") or not re.fullmatch(r"[A-Za-z0-9_./+-]+", best):
            return "edit", value, best, line
        raw_word = line[start:end]
        if raw_word.count(value) != 1:
            return "edit", value, best, line
        if raw_word == '"' + value + '"':
            replacement = '"' + re.sub(r'([\\"$`])', r'\\\1', best) + '"'
        elif raw_word == "'" + value + "'":
            replacement = "'" + best.replace("'", "'\\''") + "'"
        elif raw_word == value:
            replacement = shlex.quote(best)
        else:
            return "edit", value, best, line
        repaired = line[:start] + replacement + line[end:]
        if not has_assignments and not re.search(r'''['"\\|&;<>()$`*?\[\]{}#!~\n]''', repaired):
            return "argv", value, best, repaired
        return "run", value, best, repaired
    return None


def cmd_repair_line() -> None:
    repaired = repair_failed_line(sys.stdin.read(), sys.argv[2:])
    if repaired:
        print("\t".join(repaired))


PROJECT_MARKERS = (
    "docker-compose.yml", "docker-compose.yaml", "requirements.txt", "pyproject.toml",
    "go.mod", "Cargo.toml", "Gemfile", "manage.py", "composer.json",
)


def proj_hints(cwd: str = ".") -> list:
    """Compact facts about the project in cwd that help pick the right command."""
    hints = []
    pkg = os.path.join(cwd, "package.json")
    if os.path.isfile(pkg) and not os.path.islink(pkg):
        try:
            with open(pkg, encoding="utf-8") as fh:
                scripts = (json.loads(fh.read(1024 * 1024)).get("scripts") or {})
        except Exception:
            scripts = {}
        if scripts:
            names = [name for name in scripts if isinstance(name, str) and
                     re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}", name)][:12]
            if names:
                hints.append("package.json scripts: " + ", ".join(names))
    mk = os.path.join(cwd, "Makefile")
    if os.path.isfile(mk) and not os.path.islink(mk):
        try:
            with open(mk, encoding="utf-8", errors="replace") as fh:
                raw = fh.read(1024 * 1024)
            targets = [t for t in re.findall(r"^([a-zA-Z0-9_.-]+):", raw, re.M)
                       if not t.startswith(".")]
            targets = list(dict.fromkeys(targets))[:12]
        except Exception:
            targets = []
        if targets:
            hints.append("make targets: " + ", ".join(targets))
    found = [m for m in PROJECT_MARKERS if os.path.isfile(os.path.join(cwd, m))]
    if found:
        hints.append("project files: " + ", ".join(found))
    return hints


def cmd_proj() -> None:
    print("\n".join(proj_hints()))


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "extract"
    if mode == "tty-choice":
        cmd_tty_choice()
    elif mode == "command-check":
        raise SystemExit(0 if command_is_display_safe(sys.stdin.read()) else 1)
    elif mode == "payload":
        cmd_payload()
    elif mode == "proj":
        cmd_proj()
    elif mode == "secrets-detect":
        cmd_secrets_detect()
    elif mode == "secrets-redact":
        cmd_secrets_redact()
    elif mode == "rc-value" and len(sys.argv) == 4:
        cmd_rc_value(sys.argv[2], sys.argv[3])
    elif mode == "help-options":
        raise SystemExit(cmd_help_options(sys.argv[2:]))
    elif mode == "opencode-config-deny":
        raise SystemExit(cmd_opencode_config_deny())
    elif mode == "timeout":
        raise SystemExit(cmd_timeout(sys.argv[2:]))
    elif mode == "antigravity-request":
        raise SystemExit(cmd_antigravity_request(sys.argv[2:]))
    elif mode == "antigravity-stop":
        raise SystemExit(cmd_antigravity_stop(sys.argv[2:]))
    elif mode == "antigravity-worker":
        raise SystemExit(cmd_antigravity_worker(sys.argv[2:]))
    elif mode in ("body", "body-openrouter"):
        cmd_body_openrouter()
    elif mode == "body-openai":
        cmd_body_openai()
    elif mode == "body-anthropic":
        cmd_body_anthropic()
    elif mode == "body-gemini":
        cmd_body_gemini()
    elif mode == "body-antigravity":
        cmd_body_antigravity()
    elif mode == "extract":
        cmd_extract(sys.argv[2] if len(sys.argv) > 2 else "plain")
    elif mode == "repair-line":
        cmd_repair_line()
    else:
        cmd_extract()


if __name__ == "__main__":
    main()
