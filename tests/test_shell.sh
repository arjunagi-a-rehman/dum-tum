#!/usr/bin/env bash
# Functional tests for src/fixit-common.sh helpers (bash).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../src/fixit-common.sh
source "$ROOT/src/fixit-common.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '\033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '\033[31m✗\033[0m %s\n' "$1"; }

check_eq() { # $1=desc $2=expected $3=actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
check_rc() { # $1=desc $2=expected rc $3...=cmd
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [[ "$got" == "$want" ]]; then ok "$desc"; else bad "$desc (expected rc $want, got $got)"; fi
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
cd "$TMPD"

# ---------- _fx_best (edit distance over stdin candidates) ----------
out=$(printf 'git\ngitx\nstatus\n' | _fx_best "git")
check_eq "_fx_best exact match" $'0\tgit' "$out"

out=$(printf 'git\ngo\ngrep\n' | _fx_best "gir")
check_eq "_fx_best typo distance 1" $'1\tgit' "$out"

out=$(printf 'abcdef\n' | _fx_best "ab")
check_eq "_fx_best length gap >2 rejected" $'99\t' "$out"

out=$(printf 'lss\nls\n' | _fx_best "lz")
check_eq "_fx_best tie picks shorter" "$(printf '1\tls')" "$out"

out=$(printf '\n\nls\n\n' | _fx_best "ls")
check_eq "_fx_best skips empty lines" $'0\tls' "$out"

out=$(printf 'cat\ncar\ncut\n' | _fx_best "cat")
check_eq "_fx_best early exit on distance 0" $'0\tcat' "$out"

out=$(printf 'brew\n' | _fx_best "zzzzzzzz")
check_eq "_fx_best no good candidate returns empty" $'99\t' "$out"

# ---------- _fx_ok ----------
check_rc "_fx_ok dist 0" 0 _fx_ok 0 3
check_rc "_fx_ok dist 1 len 3" 0 _fx_ok 1 3
check_rc "_fx_ok dist 2 len 3 default max 1" 1 _fx_ok 2 3
check_rc "_fx_ok dist 2 len 3 max 2" 0 _fx_ok 2 3 2
check_rc "_fx_ok dist 1 len 1 boundary" 0 _fx_ok 1 1
check_rc "_fx_ok dist 1 len 2 boundary" 0 _fx_ok 1 2

# ---------- _fx_in_list ----------
check_rc "_fx_in_list hit" 0 _fx_in_list git go git grep
check_rc "_fx_in_list miss" 1 _fx_in_list gitt go git grep
check_rc "_fx_in_list empty list" 1 _fx_in_list git

# ---------- _fx_looks_like_nl ----------
check_rc "_fx_looks_like_nl plain words" 0 _fx_looks_like_nl list all files
check_rc "_fx_looks_like_nl no args" 1 _fx_looks_like_nl
check_rc "_fx_looks_like_nl flag" 1 _fx_looks_like_nl list -la
check_rc "_fx_looks_like_nl path" 1 _fx_looks_like_nl list ./foo
touch realfile
check_rc "_fx_looks_like_nl existing file" 1 _fx_looks_like_nl show realfile

# ---------- _fx_has_secrets ----------
check_rc "_fx_has_secrets --password" 0 _fx_has_secrets 'curl --password=hunter2 x'
check_rc "_fx_has_secrets --token space" 0 _fx_has_secrets 'git clone --token abc123'
check_rc "_fx_has_secrets Bearer" 0 _fx_has_secrets 'curl -H "Authorization: Bearer abc.def.ghi"'
check_rc "_fx_has_secrets sk- key" 0 _fx_has_secrets 'export OPENAI_API_KEY=sk-abcdefghijklmnop'
check_rc "_fx_has_secrets KEY= env" 0 _fx_has_secrets 'OPENROUTER_API_KEY=zzz999'
check_rc "_fx_has_secrets plain command" 1 _fx_has_secrets 'git psuh origin main'
check_rc "_fx_has_secrets bare flag no value" 1 _fx_has_secrets 'curl --password'

# ---------- _fx_redact_secrets ----------
out=$(printf 'curl --password=hunter2 x\n' | _fx_redact_secrets)
check_eq "redact --password=" 'curl --password=[REDACTED] x' "$out"

out=$(printf 'curl --passwd secret x\n' | _fx_redact_secrets)
check_eq "redact --passwd space" 'curl --passwd [REDACTED] x' "$out"

out=$(printf 'curl --token=abc123 x\n' | _fx_redact_secrets)
check_eq "redact --token=" 'curl --token=[REDACTED] x' "$out"

out=$(printf 'Authorization: Bearer abc.def.ghi\n' | _fx_redact_secrets)
check_eq "redact Bearer" 'Authorization: Bearer [REDACTED]' "$out"

out=$(printf 'key sk-abcdefghijklmnop here\n' | _fx_redact_secrets)
check_eq "redact sk- key" 'key [REDACTED-KEY] here' "$out"

out=$(printf 'OPENROUTER_API_KEY=zzz999\n' | _fx_redact_secrets)
check_eq "redact KEY= env" 'OPENROUTER_API_KEY=[REDACTED]' "$out"

out=$(printf 'MY_SECRET_TOKEN=tok\n' | _fx_redact_secrets)
check_eq "redact SECRET_TOKEN env" 'MY_SECRET_TOKEN=[REDACTED]' "$out"

out=$(printf 'nothing secret here\n' | _fx_redact_secrets)
check_eq "redact leaves plain text" 'nothing secret here' "$out"

# ---------- _fx_strip_ctrl ----------
out=$(printf '\033[31mred\033[0m plain\n' | _fx_strip_ctrl)
check_eq "strip ANSI escapes" $'red plain' "$out"

out=$(printf 'a\007b\n' | _fx_strip_ctrl)
check_eq "strip bell byte" 'ab' "$out"

out=$(printf 'a\tb\n' | _fx_strip_ctrl)
check_eq "keeps tab and newline" $'a\tb' "$out"

# ---------- _fx_ai_ready ----------
(
  FX_PROVIDER=none
  check_rc "_fx_ai_ready none" 1 _fx_ai_ready
)
(
  FX_PROVIDER=openrouter
  unset OPENROUTER_API_KEY
  check_rc "_fx_ai_ready openrouter no key" 1 _fx_ai_ready
)
(
  FX_PROVIDER=openrouter
  OPENROUTER_API_KEY=dummy
  check_rc "_fx_ai_ready openrouter with key" 0 _fx_ai_ready
)
(
  FX_PROVIDER=bogus
  check_rc "_fx_ai_ready unknown provider" 1 _fx_ai_ready
)
(
  FX_PROVIDER=openai
  unset OPENAI_API_KEY
  check_rc "_fx_ai_ready openai no key" 1 _fx_ai_ready
)
(
  FX_PROVIDER=openai
  OPENAI_API_KEY=dummy
  check_rc "_fx_ai_ready openai with key" 0 _fx_ai_ready
)
(
  FX_PROVIDER=anthropic
  unset ANTHROPIC_API_KEY
  check_rc "_fx_ai_ready anthropic no key" 1 _fx_ai_ready
)
(
  FX_PROVIDER=anthropic
  ANTHROPIC_API_KEY=dummy
  check_rc "_fx_ai_ready anthropic with key" 0 _fx_ai_ready
)
(
  FX_PROVIDER=gemini
  unset GEMINI_API_KEY GOOGLE_API_KEY
  check_rc "_fx_ai_ready gemini no key" 1 _fx_ai_ready
)
(
  FX_PROVIDER=gemini
  GEMINI_API_KEY=dummy
  check_rc "_fx_ai_ready gemini with key" 0 _fx_ai_ready
)
(
  FX_PROVIDER=gemini
  unset GEMINI_API_KEY
  GOOGLE_API_KEY=dummy
  check_rc "_fx_ai_ready gemini with google key" 0 _fx_ai_ready
)
(
  FX_PROVIDER=opencode
  mkdir -p emptybin
  PATH="$TMPD/emptybin:/usr/bin:/bin"
  check_rc "_fx_ai_ready opencode missing binary" 1 _fx_ai_ready
)
(
  FX_PROVIDER=opencode
  mkdir -p bin
  printf '#!/bin/sh\nexit 0\n' > bin/opencode
  chmod +x bin/opencode
  PATH="$TMPD/bin:$PATH"
  check_rc "_fx_ai_ready opencode on PATH" 0 _fx_ai_ready
)
(
  FX_PROVIDER=claude
  mkdir -p emptybin
  PATH="$TMPD/emptybin:/usr/bin:/bin"
  check_rc "_fx_ai_ready claude missing binary" 1 _fx_ai_ready
)
(
  FX_PROVIDER=claude
  mkdir -p bin
  printf '#!/bin/sh\nexit 0\n' > bin/claude
  chmod +x bin/claude
  PATH="$TMPD/bin:$PATH"
  check_rc "_fx_ai_ready claude on PATH" 0 _fx_ai_ready
)
(
  FX_PROVIDER=off
  check_rc "_fx_ai_ready off alias" 1 _fx_ai_ready
)

# ---------- _fx_timeout ----------
check_rc "_fx_timeout fast command" 0 _fx_timeout 5 true
out=$(_fx_timeout 5 printf 'hello')
check_eq "_fx_timeout captures stdout" 'hello' "$out"
start=$SECONDS
_fx_timeout 2 sleep 10 >/dev/null 2>&1
rc=$?
elapsed=$((SECONDS - start))
if [[ $rc == 124 && $elapsed -lt 8 ]]; then ok "_fx_timeout kills slow command (rc 124)"; else bad "_fx_timeout kills slow command (rc=$rc elapsed=${elapsed}s)"; fi

# ---------- _fx_shell_name ----------
out=$(_fx_shell_name)
check_eq "_fx_shell_name under bash" 'bash' "$out"

# ---------- _fx_ai_sys_prompt ----------
out=$(_fx_ai_sys_prompt)
case "$out" in
  *"# DANGER: "*) ok "sys prompt mentions DANGER prefix" ;;
  *) bad "sys prompt mentions DANGER prefix" ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
