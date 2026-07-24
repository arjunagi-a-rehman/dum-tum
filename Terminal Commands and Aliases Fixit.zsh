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

command_not_found_handler() {
  local cmd="$1"; shift
  local full="$cmd${@:+ $*}"
  local out d best

  # Natural language ("list all files") → AI, don't fuzzy-match the first word
  if _fx_looks_like_nl "$@"; then
    _fx_ai_resolve "$full" || print -u2 -P "%F{red}? no match (set OPENROUTER_API_KEY for AI)%f"
    return 127
  fi

  out=$(print -rl -- ${(k)commands} ${(k)aliases} ${(k)functions} ${(k)builtins} | _fx_best "$cmd")
  d=${out%%$'\t'*}; best=${out#*$'\t'}
  if [[ -n "$best" ]] && _fx_ok $d ${#cmd} 1; then
    if (( ${_FX_DANGEROUS[(Ie)$best]} )); then
      print -u2 -P "%F{yellow}? '$cmd' not found — closest: $best (not auto-running)%f"
      print -z -- "$best $*"
    else
      print -u2 -P "%F{yellow}↻ $cmd → $best%f"
      if "$best" "$@"; then
        return 0
      fi
      # Fuzzy guess was wrong (e.g. list→lint) — fall back to AI on original line
      _fx_ai_resolve "$full" || print -u2 -P "%F{red}? '$cmd' — no match (set OPENROUTER_API_KEY for AI)%f"
    fi
  elif (( $# == 0 )) && [[ -n "$best" && $d -le 2 ]]; then
    print -u2 -P "%F{yellow}? '$cmd' not found — closest: $best%f"
    print -z -- "$best"
  else
    _fx_ai_resolve "$full" || print -u2 -P "%F{red}? '$cmd' — no match (set OPENROUTER_API_KEY for AI)%f"
  fi
  return 127
}

# ---------- B. failed command with a typo'd file arg ----------
# Only read-only commands where re-running is guaranteed safe.
_FX_SAFE=(cd cat ls less more head tail wc stat file vim nano vi bat open code)

_fx_preexec() { _FX_LAST="$1"; _FX_FIXED=0 }
_fx_precmd() {
  local rc=$?
  { (( rc == 0 )) || (( _FX_FIXED )) } && return
  [[ -z "$_FX_LAST" ]] && return
  _FX_LASTFAIL="$_FX_LAST (exit $rc)"          # remember for the `fix` command
  local -a w; w=(${(z)_FX_LAST}); _FX_LAST=""
  (( ${_FX_SAFE[(Ie)$w[1]]} )) || return       # not a safe command → stay quiet
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
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _fx_preexec
add-zsh-hook precmd  _fx_precmd

# ================= Stage 2: AI resolver (OpenRouter) =================
# Needs: export OPENROUTER_API_KEY=sk-or-...
# Never auto-runs AI output — suggestion is pre-typed at the next prompt;
# you press Enter to accept, or edit/clear it.
FX_MODEL=${FX_MODEL:-deepseek/deepseek-v4-flash}

_fx_ai_http() {  # $1=json body -> raw api response (overridable in tests)
  curl -sS --max-time 15 https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" -d "$1"
}

_fx_ai() {  # $* = intent or failed command -> prints one suggested command
  local ctx="OS: $(uname -sm); shell: zsh; cwd: $PWD; files here: $(ls -1 2>/dev/null | head -15 | tr '\n' ' ')"
  local als=$(alias 2>/dev/null | head -30)
  local body=$(python3 -c '
import json,sys,os
sys_p=("You translate user intent or broken shell commands into ONE correct "
 "shell command line for their machine. Output ONLY the command, no markdown, "
 "no backticks, no explanation. Use the user\u0027s own aliases when they fit. "
 "If the action is destructive or irreversible, prefix with: # DANGER: ")
print(json.dumps({"model":sys.argv[4],"max_tokens":200,
 "messages":[{"role":"system","content":sys_p},
 {"role":"user","content":sys.argv[1]+"\nMy aliases:\n"+sys.argv[2]+"\nTask/failed input: "+sys.argv[3]}]}))' \
    "$ctx" "$als" "$*" "$FX_MODEL")
  _fx_ai_http "$body" | python3 -c '
import json,sys,re
try:
    r=json.load(sys.stdin)
    if "error" in r:
        sys.stderr.write("AI error: "+str(r["error"].get("message",r["error"]))+"\n")
        sys.exit(0)
    t=r["choices"][0]["message"]["content"].strip()
    t=re.sub(r"^```(?:\w+)?\s*","",t)
    t=re.sub(r"\s*```$","",t)
    t=t.strip().strip("`").strip()
    # keep only the first non-empty, non-comment line (unless DANGER prefix)
    lines=[ln for ln in t.splitlines() if ln.strip()]
    if lines:
        print(lines[0] if not lines[0].startswith("# DANGER:") else "\n".join(lines[:2]))
except Exception as e:
    sys.stderr.write("AI parse error: "+str(e)+"\n")'
}

_fx_suggest() {  # print suggestion + pre-type it at the next prompt
  local sug="$1"
  [[ -z "$sug" ]] && { print -u2 -P "%F{red}? AI gave no answer%f"; return 1 }
  print -u2 -P "%F{cyan}→ $sug%f   (Enter to run, or edit)"
  print -z -- "$sug"
}

# hook into the no-local-match branch of the not-found handler
_fx_ai_resolve() {   # called with the full original line
  [[ -z "$OPENROUTER_API_KEY" ]] && return 1
  print -u2 -P "%F{cyan}…resolving%f"
  _fx_suggest "$(_fx_ai "$@")"
  return 0   # handled (success or already printed "no answer")
}

# `fix` — send the last failed command for a corrected version
# (_FX_LASTFAIL is saved by _fx_precmd above)
fix() { [[ -z "$_FX_LASTFAIL" ]] && { echo "nothing failed recently"; return }; _fx_ai_resolve "fix this failed command: $_FX_LASTFAIL" }
