# fixit.zsh — Stage 1: the obvious-fix layer
# type → runs like plain terminal; only failures wake this up.
#   obvious (nothing executed): auto-fix + auto-run, shows "↻"
#   non-obvious: suggest (stage 2 adds AI here)

# ---------- best-match: edit distance over candidates on stdin ----------
# prints "distance<TAB>candidate" for the closest one
_fx_best() { python3 -c '
import sys
t=sys.argv[1].lower()
def dist(a,b):
    if abs(len(a)-len(b))>2: return 99
    m,n=len(a),len(b)
    D=[[0]*(n+1) for _ in range(m+1)]
    for i in range(m+1): D[i][0]=i
    for j in range(n+1): D[0][j]=j
    for i in range(1,m+1):
        for j in range(1,n+1):
            c=(a[i-1]!=b[j-1])
            D[i][j]=min(D[i-1][j]+1,D[i][j-1]+1,D[i-1][j-1]+c)
            if i>1 and j>1 and a[i-1]==b[j-2] and a[i-2]==b[j-1]:
                D[i][j]=min(D[i][j],D[i-2][j-2]+1)
    return D[m][n]
best,bd=None,99
for line in sys.stdin:
    c=line.strip()
    if not c: continue
    dd=dist(t,c.lower())
    if dd<bd or (dd==bd and best and len(c)<len(best)): best,bd=c,dd
    if bd==0: break
print(str(bd)+"\t"+(best or ""))' "$1"
}

_fx_ok() { (( $1 <= ${3:-1} && $1 * 2 < $2 + 2 )) }  # $1=dist $2=len $3=max dist

# ---------- A. unknown command → fix / suggest / defer ----------
# Never auto-run these — too destructive if the fuzzy match picks wrong.
_FX_DANGEROUS=(rm rmdir dd kill pkill killall shutdown reboot halt mkfs fdisk diskutil sudo su chmod chown shred)

# True when every arg looks like plain English (not a flag/path/existing file).
# Used to detect natural-language intent like "list all the files".
_fx_looks_like_nl() {
  (( $# == 0 )) && return 1
  local a
  for a in "$@"; do
    [[ "$a" == -* || "$a" == */* || -e "$a" ]] && return 1
  done
  return 0
}

# Builtins/commands that are also common English words. "where is reno folder"
# would otherwise run the `where` builtin instead of the AI.
_FX_EN_CMDS=(where which who what find open type time help locate why how show get)

# Full-line English detector for the accept-line hook (3+ plain words, no shell syntax).
_fx_is_english_line() {
  local line="${1#"${1%%[![:space:]]*}"}"  # trim leading
  line="${line%"${line##*[![:space:]]}"}"  # trim trailing
  [[ -z "$line" ]] && return 1
  # reject shell operators / expansions / paths-with-slash in the raw line
  [[ "$line" == *['|><;&$()`\\']* || "$line" == */* ]] && return 1
  local -a w; w=(${(z)line})
  (( $#w < 3 )) && return 1
  # first word must be an English-collision command OR not a real command at all
  local head=$w[1]
  if (( ${_FX_EN_CMDS[(Ie)$head]} == 0 )); then
    # real non-English command (git, npm, ls, …) → leave it alone
    (( ${+commands[$head]} || ${+builtins[$head]} || ${+aliases[$head]} || ${+functions[$head]} )) && return 1
  fi
  local a
  for a in $w; do
    [[ "$a" == -* || "$a" == *=* ]] && return 1
    # plain word: letters/digits with optional apostrophe or hyphen inside
    [[ "$a" =~ '^[A-Za-z0-9][A-Za-z0-9'\''-]*$' ]] || return 1
  done
  return 0
}

# Intercept English sentences at Enter, before builtins like `where` run.
_fx_accept_line() {
  local full="$BUFFER"
  if _fx_is_english_line "$full"; then
    BUFFER=""
    zle -I
    _fx_ai_resolve "$full"
    zle reset-prompt
    return
  fi
  zle .accept-line
}

# Confirm/run a suggestion using plain read(1) on /dev/tty.
# (vared/print -z/ZLE all fail inside command_not_found_handler)
# Enter = run · e = edit then run · n / Ctrl-C = cancel
_fx_confirm_run() {
  local cmd="$1" key
  [[ -z "$cmd" ]] && return 1
  print -u2 -P "%F{cyan}→ $cmd%f"
  print -u2 -n "$(print -P '%F{cyan}[Enter] run  [e] edit  [n] cancel%f ')"
  read -r -k 1 key </dev/tty || return 1
  print -u2
  case "$key" in
    $'\n'|$'\r'|'y'|'Y'|'')
      eval "$cmd"
      ;;
    e|E)
      print -u2 -n "$(print -P '%F{cyan}$%f ')"
      read -r cmd </dev/tty || return 1
      [[ -z "${cmd// /}" ]] && return 1
      eval "$cmd"
      ;;
    *)
      return 1
      ;;
  esac
}

command_not_found_handler() {
  local cmd="$1"; shift
  local full="$cmd${@:+ $*}"
  local out d best rc

  # Natural language ("list all files") → AI, don't fuzzy-match the first word
  if _fx_looks_like_nl "$@"; then
    _fx_ai_resolve "$full"; return $?
  fi

  out=$(print -rl -- ${(k)commands} ${(k)aliases} ${(k)functions} ${(k)builtins} | _fx_best "$cmd")
  d=${out%%$'\t'*}; best=${out#*$'\t'}
  if [[ -n "$best" ]] && _fx_ok $d ${#cmd} 1; then
    if (( ${_FX_DANGEROUS[(Ie)$best]} )); then
      print -u2 -P "%F{yellow}? '$cmd' not found — closest: $best (not auto-running)%f"
      _fx_confirm_run "$best${@:+ $*}" && return $?
    else
      print -u2 -P "%F{yellow}↻ $cmd → $best%f"
      if "$best" "$@"; then
        return 0
      fi
      # Fuzzy guess was wrong (e.g. list→lint) — fall back to AI on original line
      _fx_ai_resolve "$full"; return $?
    fi
  elif (( $# == 0 )) && [[ -n "$best" && $d -le 2 ]]; then
    print -u2 -P "%F{yellow}? '$cmd' not found — closest: $best%f"
    _fx_confirm_run "$best" && return $?
  else
    _fx_ai_resolve "$full"; return $?
  fi
  return 127
}

# ---------- B. failed command with a typo'd file arg ----------
# Only read-only commands where re-running is guaranteed safe.
_FX_SAFE=(cd cat ls less more head tail wc stat file vim nano vi bat open code)

# Multi-command tools where a non-zero exit usually means a bad subcommand or
# usage mistake (go to desktop, git psuh, npm runn build, …). On failure these
# fall through to the AI resolver instead of staying quiet.
_FX_MULTICMD=(go git docker kubectl helm npm npx yarn pnpm brew gh aws gcloud az cargo pip pip3 make terraform systemctl apt apt-get snap dnf pacman gem bundle composer)

_fx_preexec() { _FX_LAST="$1"; _FX_FIXED=0 }
_fx_precmd() {
  local rc=$?
  { (( rc == 0 )) || (( _FX_FIXED )) } && return
  [[ -z "$_FX_LAST" ]] && return
  _FX_LASTFAIL="$_FX_LAST (exit $rc)"          # remember for the `fix` command
  local -a w; w=(${(z)_FX_LAST}); _FX_LAST=""
  if (( ${_FX_SAFE[(Ie)$w[1]]} )); then        # safe read-only cmd → try path-typo fix
    local i arg out d fixed
    for (( i=2; i<=$#w; i++ )); do
      arg=$w[$i]
      [[ "$arg" == -* || -e "$arg" ]] && continue
      out=$(find . -maxdepth 2 -not -path '*/.git*' 2>/dev/null | sed 's|^\./||' | _fx_best "${arg}")
      d=${out%%$'\t'*}; fixed=${out#*$'\t'}
      if [[ -n "$fixed" ]] && _fx_ok $d ${#arg} 2; then
        w[$i]=$fixed; _FX_FIXED=1
        print -u2 -P "%F{yellow}↻ $arg → $fixed%f"
        eval "${(@q)w}"
        return
      fi
    done
  fi
  # Failed multi-command tool → AI suggests the fix (still needs Enter).
  # Silent without a key; disable with FX_AI_ON_FAIL=0.
  (( ${FX_AI_ON_FAIL:-1} )) || return
  [[ -n "$OPENROUTER_API_KEY" ]] || return
  (( $#w >= 2 )) || return
  (( ${_FX_MULTICMD[(Ie)$w[1]]} )) || return
  _fx_ai_resolve "fix this failed command: $_FX_LASTFAIL"
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _fx_preexec
add-zsh-hook precmd  _fx_precmd
# Catch English sentences before builtins (where/which/find/…) execute them
zle -N accept-line _fx_accept_line

# ================= Stage 2: AI resolver (OpenRouter) =================
# Needs: export OPENROUTER_API_KEY=sk-or-...
# AI suggestion is confirmed via _fx_confirm_run (Enter / e / n).
FX_MODEL=${FX_MODEL:-deepseek/deepseek-v4-flash}

_fx_ai_http() {  # $1=json body -> raw api response (overridable in tests)
  curl -sS --connect-timeout 10 --max-time 45 --retry 1 --retry-delay 1 \
    https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" -d "$1"
}

_fx_ai() {  # $* = intent or failed command -> prints one suggested command
  local ctx="OS: $(uname -sm); shell: zsh; cwd: $PWD; files here: $(ls -1 2>/dev/null | head -15 | tr '\n' ' ')"
  local als=$(alias 2>/dev/null | head -30)
  local intent="$*" body
  body=$(FX_CTX="$ctx" FX_ALS="$als" FX_INTENT="$intent" FX_MODEL="$FX_MODEL" python3 <<'PY'
import json, os
sys_p = (
    "You translate user intent or broken shell commands into ONE correct "
    "shell command line for their machine. Reply with ONLY the command on the "
    "first line — no markdown fences, no backticks, no explanation, no thinking. "
    "Use the user's own aliases when they fit. "
    "If the action is destructive or irreversible, prefix with: # DANGER: "
)
print(json.dumps({
    "model": os.environ["FX_MODEL"],
    "max_tokens": 800,
    "messages": [
        {"role": "system", "content": sys_p},
        {"role": "user", "content": (
            os.environ["FX_CTX"] + "\nMy aliases:\n" + os.environ["FX_ALS"]
            + "\nTask/failed input: " + os.environ["FX_INTENT"]
        )},
    ],
}))
PY
)
  # -c gets the script via command substitution; stdin stays as the API response pipe
  _fx_ai_http "$body" | python3 -c "$(cat <<'PY'
import json, sys, re
HEADS = {
    "find","ls","cd","cat","grep","rg","fd","mdfind","locate","open","git",
    "npm","brew","echo","pwd","mkdir","cp","mv","rm","head","tail","wc","du",
    "df","ps","curl","ssh","tar","python","python3","node","docker","sed",
    "awk","chmod","touch","which","where","type","tree","bat","eza","clear",
    "gls","mdls","xargs","sort","uniq","zip","unzip","kill","scp","kubectl",
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
            return "\n".join(lines[i:i+2])
        if ln.startswith("#") or PROSE.match(ln):
            continue
        if head_of(ln) in HEADS or (
            len(ln.split()) >= 2 and re.match(r"^[a-zA-Z0-9_./~+-]+(\s|$)", ln)
        ):
            return ln
    return ""

try:
    r = json.load(sys.stdin)
    if "error" in r:
        err = r["error"]
        msg = err.get("message", err) if isinstance(err, dict) else err
        sys.stderr.write(f"AI error: {msg}\n")
        sys.exit(0)
    msg = (r.get("choices") or [{}])[0].get("message") or {}
    t = msg.get("content")
    if not (isinstance(t, str) and t.strip()):
        parts = []
        if isinstance(msg.get("reasoning"), str):
            parts.append(msg["reasoning"])
        for d in (msg.get("reasoning_details") or []):
            if isinstance(d, dict) and d.get("text"):
                parts.append(d["text"])
        t = "\n".join(parts)
    out = extract(t if isinstance(t, str) else "")
    if out:
        print(out)
except Exception as e:
    sys.stderr.write(f"AI parse error: {e}\n")
PY
)"
}

# hook into the no-local-match branch of the not-found handler
_fx_ai_resolve() {   # called with the full original line
  if [[ -z "$OPENROUTER_API_KEY" ]]; then
    print -u2 -P "%F{red}? set OPENROUTER_API_KEY for AI%f"
    return 127
  fi
  print -u2 -P "%F{cyan}…resolving%f"
  local sug
  sug="$(_fx_ai "$@")"
  if [[ -z "$sug" ]]; then
    print -u2 -P "%F{red}? AI gave no answer (timeout/network?)%f"
    return 127
  fi
  _fx_confirm_run "$sug" && return $?
  return 127
}

# `fix` — send the last failed command for a corrected version
# (_FX_LASTFAIL is saved by _fx_precmd above)
fix() { [[ -z "$_FX_LASTFAIL" ]] && { echo "nothing failed recently"; return }; _fx_ai_resolve "fix this failed command: $_FX_LASTFAIL" }
