#!/usr/bin/env bash
# Test runner: python unit tests + shell syntax checks + shellcheck (if present).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

info "Python unit tests"
python3 -m unittest discover -s tests -p 'test_*.py' -v
ok "Python tests passed"

info "Shell function tests"
bash tests/test_shell.sh
ok "Shell function tests passed"

info "Shell syntax checks"
bash -n install.sh src/fixit-common.sh src/fixit.bash
if command -v zsh >/dev/null 2>&1; then
  zsh -n src/fixit.zsh
else
  err "zsh not found — skipped src/fixit.zsh syntax check"
fi
ok "Shell syntax OK"

if command -v shellcheck >/dev/null 2>&1; then
  info "shellcheck"
  shellcheck -S warning install.sh src/fixit-common.sh src/fixit.bash
  ok "shellcheck clean"
else
  err "shellcheck not installed — skipped (brew install shellcheck)"
fi

ok "All tests passed"
