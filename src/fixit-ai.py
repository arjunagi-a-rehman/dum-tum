#!/usr/bin/env python3
"""fixit AI helpers.

Usage:
    fixit-ai.py extract KIND    # stdin: provider output -> one command on stdout
    fixit-ai.py secrets-detect  # stdin: text -> exit 0 when a known secret shape is found
    fixit-ai.py secrets-redact  # stdin: text -> redacted text on stdout
    fixit-ai.py timeout SECS CMD [ARG ...] # supervise a command and its process group
    fixit-ai.py body-openrouter # env FX_SYS, FX_USER, FX_MODEL -> OpenRouter JSON body
    fixit-ai.py body-openai     # env FX_SYS, FX_USER, FX_MODEL -> OpenAI JSON body
    fixit-ai.py body-anthropic  # env FX_SYS, FX_USER, FX_MODEL -> Anthropic messages JSON body
    fixit-ai.py body-gemini     # env FX_SYS, FX_USER -> Gemini generateContent JSON body
    fixit-ai.py body-antigravity # stdin prompt -> Antigravity stream-json user event
    fixit-ai.py rc-value NAME PATH # safely read an exported value from the dum-tum rc block
    fixit-ai.py proj            # print compact project hints for cwd (scripts, targets, markers)
"""

import json
import math
import os
import re
import signal
import shutil
import subprocess
import sys

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
        r'(?i)(["\'])(\b(?:proxy-)?authorization\s*:\s*)(?:AWS4-HMAC-SHA256|Digest)\s+(?:\\.|(?!\1)[^\r\n])*\1',
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
    sys.stderr.write(f"AI error: {msg}\n")


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
        sys.stderr.write(f"AI output error: unknown provider output kind: {provider}\n")
        return ""
    try:
        return parser(raw)
    except PayloadError as exc:
        sys.stderr.write(f"AI output error ({provider}): {exc}\n")
        return ""


def cmd_extract(provider: str = "plain") -> None:
    raw = sys.stdin.read()
    out = extract(parse_payload(raw, provider))
    if out:
        print(out)


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
        sys.stderr.buffer.write(stderr)
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
        sig for sig in (getattr(signal, "SIGTERM", None), getattr(signal, "SIGHUP", None))
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


PROJECT_MARKERS = (
    "docker-compose.yml", "docker-compose.yaml", "requirements.txt", "pyproject.toml",
    "go.mod", "Cargo.toml", "Gemfile", "manage.py", "composer.json",
)


def proj_hints(cwd: str = ".") -> list:
    """Compact facts about the project in cwd that help pick the right command."""
    hints = []
    pkg = os.path.join(cwd, "package.json")
    if os.path.isfile(pkg):
        try:
            with open(pkg, encoding="utf-8") as fh:
                scripts = (json.load(fh).get("scripts") or {})
        except Exception:
            scripts = {}
        if scripts:
            hints.append("package.json scripts: " + ", ".join(scripts))
    mk = os.path.join(cwd, "Makefile")
    if os.path.isfile(mk):
        try:
            with open(mk, encoding="utf-8", errors="replace") as fh:
                raw = fh.read()
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
    if mode == "proj":
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
    else:
        cmd_extract()


if __name__ == "__main__":
    main()
