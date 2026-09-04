#!/usr/bin/env python3
"""fixit AI helpers.

Usage:
    fixit-ai.py extract         # stdin: free text / JSON / JSONL -> one command on stdout
    fixit-ai.py body            # env FX_SYS, FX_USER, FX_MODEL -> OpenAI-compatible JSON body
    fixit-ai.py body-anthropic  # env FX_SYS, FX_USER, FX_MODEL -> Anthropic messages JSON body
    fixit-ai.py body-gemini     # env FX_SYS, FX_USER -> Gemini generateContent JSON body
    fixit-ai.py body-antigravity # stdin prompt -> Antigravity stream-json user event
    fixit-ai.py proj            # print compact project hints for cwd (scripts, targets, markers)
    fixit-ai.py repair-line ... # stdin failed line -> span-preserving filename repair
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
        raw_word = line[start:end]
        if raw_word.count(value) != 1:
            return "edit", value, best, line
        replacement = raw_word.replace(value, best, 1)
        repaired = line[:start] + replacement + line[end:]
        if not has_assignments and not re.search(r'''['"\\|&;<>()$`*?\[\]{}#!~\n]''', line):
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
    elif mode == "repair-line":
        cmd_repair_line()
    else:
        cmd_extract()


if __name__ == "__main__":
    main()
