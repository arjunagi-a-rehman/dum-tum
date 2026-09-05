#!/usr/bin/env bash
# Test runner: Python tests + shell tests + required syntax and shellcheck gates.
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

for mode in assertion abort; do
  if FX_TEST_HARNESS_MODE="$mode" bash tests/test_shell.sh >/dev/null 2>&1; then
    err "Shell $mode propagation self-test unexpectedly passed"
    exit 1
  fi
done
ok "Shell failure propagation self-test passed"

info "Shell syntax checks"
for script in install.sh src/fixit-common.sh src/fixit.bash; do
  bash -n "$script"
done
if ! command -v zsh >/dev/null 2>&1; then
  err "zsh is required for the syntax gate"
  exit 1
fi
zsh -n src/fixit.zsh
ok "Shell syntax OK"

if ! command -v shellcheck >/dev/null 2>&1; then
  err "shellcheck is required (install it with brew or your package manager)"
  exit 1
fi
info "shellcheck"
shellcheck -S warning install.sh src/fixit-common.sh src/fixit.bash
ok "shellcheck clean"

ok "All tests passed"
