#!/usr/bin/env python3
"""fixit AI helpers.

Usage:
    fixit-ai.py extract         # stdin: free text / JSON / JSONL -> one command on stdout
    fixit-ai.py body            # env FX_SYS, FX_USER, FX_MODEL -> OpenAI-compatible JSON body
    fixit-ai.py body-anthropic  # env FX_SYS, FX_USER, FX_MODEL -> Anthropic messages JSON body
    fixit-ai.py body-gemini     # env FX_SYS, FX_USER -> Gemini generateContent JSON body
    fixit-ai.py body-antigravity # stdin prompt -> Antigravity stream-json user event
    fixit-ai.py proj            # print compact project hints for cwd (scripts, targets, markers)
"""

import json
import os
import re
import sys
from typing import Any

HEADS = {
    "find", "ls", "cd", "cat", "grep", "rg", "fd", "mdfind", "locate", "open", "git",
    "npm", "brew", "echo", "pwd", "mkdir", "cp", "mv", "rm", "head", "tail", "wc", "du",
    "df", "ps", "curl", "ssh", "tar", "python", "python3", "node", "docker", "sed",
    "awk", "chmod", "touch", "which", "where", "type", "tree", "bat", "eza", "clear",
    "gls", "mdls", "xargs", "sort", "uniq", "zip", "unzip", "kill", "scp", "kubectl",
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


def extract(t: str) -> str:
    """Pull the single most plausible shell command out of free-form LLM text."""
    if not t:
        return ""
    t = re.sub(r"^```(?:\w+)?\s*", "", t.strip())
    t = re.sub(r"\s*```$", "", t).strip()
    for c in reversed(re.findall(r"`([^`\n]+)`", t)):
        c = c.strip().strip("\"'")
        if c and not c.startswith("http") and (head_of(c) in HEADS or " " in c):
            return c
    lines = [ln.strip().strip("`") for ln in t.splitlines() if ln.strip()]
    for i, ln in enumerate(lines):
        if ln.startswith("# DANGER:"):
            return "\n".join(lines[i:i + 2])
        if ln.startswith("#") or PROSE.match(ln):
            continue
        if head_of(ln) in HEADS or (
            len(ln.split()) >= 2 and re.match(r"^[a-zA-Z0-9_./~+-]+(\s|$)", ln)
        ):
            return ln
    return ""


def collect_text(obj: Any, parts: list) -> None:
    """Recursively gather text fragments from arbitrary JSON (CLI/JSONL output)."""
    if isinstance(obj, str):
        if obj.strip():
            parts.append(obj)
        return
    if isinstance(obj, list):
        for x in obj:
            collect_text(x, parts)
        return
    if not isinstance(obj, dict):
        return
    part = obj.get("part")
    if isinstance(part, dict):
        for k in ("text", "content"):
            v = part.get(k)
            if isinstance(v, str) and v.strip():
                parts.append(v)
    for k in ("text", "content", "message", "delta", "output", "response", "reasoning",
              "result", "candidates", "parts"):
        v = obj.get(k)
        if isinstance(v, str) and v.strip():
            parts.append(v)
        elif isinstance(v, (dict, list)):
            collect_text(v, parts)
    details = obj.get("reasoning_details")
    if isinstance(details, list):
        collect_text(details, parts)


def _report_error(ev: dict) -> bool:
    """Print an API error payload to stderr. Returns True if it was an error."""
    err = ev["error"]
    msg = err.get("message", err) if isinstance(err, dict) else err
    sys.stderr.write(f"AI error: {msg}\n")
    return True


def parse_payload(raw: str) -> str:
    """Normalize raw backend output (text, JSON, or JSONL) into plain text."""
    s = raw.strip()
    if not s:
        return ""
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    json_lines = 0
    parts: list = []
    for line in lines:
        if not (line.startswith("{") or line.startswith("[")):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        json_lines += 1
        if isinstance(ev, dict) and "error" in ev and "choices" not in ev:
            _report_error(ev)
            return ""
        collect_text(ev, parts)
    if json_lines >= 1 and parts:
        return "\n".join(parts)
    if json_lines >= 2:
        return ""
    if s.startswith("{") or s.startswith("["):
        try:
            r = json.loads(s)
        except Exception:
            return raw
        if isinstance(r, dict) and "error" in r and "choices" not in r:
            _report_error(r)
            return ""
        if isinstance(r, dict) and "choices" in r:
            msg = (r.get("choices") or [{}])[0].get("message") or {}
            t = msg.get("content")
            if isinstance(t, str) and t.strip():
                return t
            parts = []
            collect_text(msg, parts)
            return "\n".join(parts)
        parts = []
        collect_text(r, parts)
        return "\n".join(parts) if parts else raw
    return raw


def cmd_extract() -> None:
    raw = sys.stdin.read()
    t = parse_payload(raw)
    out = extract(t if isinstance(t, str) else "")
    if out:
        print(out)


def cmd_body() -> None:
    print(json.dumps({
        "model": os.environ["FX_MODEL"],
        "max_tokens": 800,
        "messages": [
            {"role": "system", "content": os.environ["FX_SYS"]},
            {"role": "user", "content": os.environ["FX_USER"]},
        ],
    }))


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
    elif mode == "body":
        cmd_body()
    elif mode == "body-anthropic":
        cmd_body_anthropic()
    elif mode == "body-gemini":
        cmd_body_gemini()
    elif mode == "body-antigravity":
        cmd_body_antigravity()
    else:
        cmd_extract()


if __name__ == "__main__":
    main()
