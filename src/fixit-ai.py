#!/usr/bin/env python3
"""fixit AI helpers.

Usage:
    fixit-ai.py extract KIND    # stdin: provider output -> one command on stdout
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
import shutil
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
