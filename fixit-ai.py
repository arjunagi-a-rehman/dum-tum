#!/usr/bin/env python3
"""fixit AI helpers.

Usage:
  fixit-ai.py extract   # stdin: free text / JSON / JSONL -> one command on stdout
  fixit-ai.py body      # env FX_SYS, FX_USER, FX_MODEL -> OpenRouter JSON body on stdout
"""
import json
import os
import re
import sys

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


def head_of(s):
    s = s.strip()
    if s.startswith("sudo "):
        s = s[5:].lstrip()
    return s.split()[0].split("/")[-1] if s else ""


def extract(t):
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


def collect_text(obj, parts):
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
    for k in ("text", "content", "message", "delta", "output", "reasoning"):
        v = obj.get(k)
        if isinstance(v, str) and v.strip():
            parts.append(v)
        elif isinstance(v, (dict, list)):
            collect_text(v, parts)
    details = obj.get("reasoning_details")
    if isinstance(details, list):
        collect_text(details, parts)


def parse_payload(raw):
    s = raw.strip()
    if not s:
        return ""
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    json_lines = 0
    parts = []
    for line in lines:
        if not (line.startswith("{") or line.startswith("[")):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        json_lines += 1
        if isinstance(ev, dict) and "error" in ev and "choices" not in ev:
            err = ev["error"]
            msg = err.get("message", err) if isinstance(err, dict) else err
            sys.stderr.write(f"AI error: {msg}\n")
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
            err = r["error"]
            msg = err.get("message", err) if isinstance(err, dict) else err
            sys.stderr.write(f"AI error: {msg}\n")
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


def cmd_extract():
    raw = sys.stdin.read()
    t = parse_payload(raw)
    out = extract(t if isinstance(t, str) else "")
    if out:
        print(out)


def cmd_body():
    print(json.dumps({
        "model": os.environ["FX_MODEL"],
        "max_tokens": 800,
        "messages": [
            {"role": "system", "content": os.environ["FX_SYS"]},
            {"role": "user", "content": os.environ["FX_USER"]},
        ],
    }))


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "extract"
    if mode == "body":
        cmd_body()
    else:
        cmd_extract()
