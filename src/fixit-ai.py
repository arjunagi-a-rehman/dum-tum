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
    fixit-ai.py proj            # print compact project hints for cwd (scripts, targets, markers)
"""

import json
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
        r'(?i)(?P<prefix>\b(?:'
        r'(?:API_?KEY|ACCESS_?KEY(?:_ID)?|SECRET(?:_KEY)?|TOKEN|'
        r'PASS(?:WORD|WD)?|CREDENTIALS?)|'
        r'[A-Z_][A-Z0-9_]*(?:_KEY|_TOKEN|_SECRET|_PASS(?:WORD|WD)?|_CREDENTIALS?)'
        r')\b\s*=\s*)' + _SECRET_VALUE
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
        r')["\']?\s*[:=]\s*)' + _SECRET_VALUE
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


def _redact_secret_value(match: re.Match) -> str:
    prefix = match.group("prefix")
    if match.group("double") is not None:
        return f'{prefix}"[REDACTED]"'
    if match.group("single") is not None:
        return f"{prefix}'[REDACTED]'"
    return f"{prefix}[REDACTED]"


def redact_secrets(text: str) -> str:
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


def is_command(s: str) -> bool:
    """Return whether a line begins with a plausible installed or known command."""
    s = s.strip().strip("`").strip('"\'')
    if not s or s.startswith("http") or s.startswith("#") or PROSE.match(s):
        return False
    if not re.match(r"^[a-zA-Z0-9_./~+-]+(?:\s|$)", s):
        return False
    head = head_of(s)
    return head in HEADS or shutil.which(head) is not None or s.startswith(("./", "../", "/", "~/"))


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
        command = lines[i + 1].strip("`").strip('"\'')
        return f"{ln}\n{command}" if is_command(command) else ""
    for c in reversed(re.findall(r"`([^`\n]+)`", t)):
        c = c.strip().strip("\"'")
        if is_command(c):
            return c
    for raw_line in lines:
        if raw_line.startswith("```"):
            continue
        ln = raw_line.strip("`")
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


def _kill_process_group(process: subprocess.Popen, sig: int) -> None:
    try:
        os.killpg(process.pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def _write_process_output(stdout: bytes, stderr: bytes) -> None:
    if stdout:
        sys.stdout.buffer.write(stdout)
        sys.stdout.buffer.flush()
    if stderr:
        sys.stderr.buffer.write(stderr)
        sys.stderr.buffer.flush()


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

    timed_out = False
    interrupted = 0
    previous_handlers = {}

    def interrupt(signum, frame):
        raise KeyboardInterrupt(signum)

    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(signum, interrupt)
    try:
        stdout, stderr = process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        _kill_process_group(process, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=0.5)
        except subprocess.TimeoutExpired:
            _kill_process_group(process, signal.SIGKILL)
            stdout, stderr = process.communicate()
        else:
            _kill_process_group(process, signal.SIGKILL)

    except KeyboardInterrupt as exc:
        interrupted = exc.args[0] if exc.args else signal.SIGINT
        for signum in previous_handlers:
            signal.signal(signum, signal.SIG_IGN)
        _kill_process_group(process, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=0.5)
        except subprocess.TimeoutExpired:
            _kill_process_group(process, signal.SIGKILL)
            stdout, stderr = process.communicate()
        _kill_process_group(process, signal.SIGKILL)
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)

    _write_process_output(stdout, stderr)
    if interrupted:
        return 128 + interrupted
    if timed_out:
        return 124
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
    if seconds < 0:
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
