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

if FX_TEST_FORCE_PROVIDER_FAILURE=1 bash tests/test_shell.sh >/dev/null 2>&1; then
  err "Shell failure propagation self-test unexpectedly passed"
  exit 1
fi
ok "Shell failure propagation self-test passed"

info "Shell syntax checks"
bash -n install.sh src/fixit-common.sh src/fixit.bash
if ! command -v zsh >/dev/null 2>&1; then
  err "zsh is required for the syntax gate"
  exit 1
fi
zsh -n src/fixit.zsh
ok "Shell syntax OK"

info "User-facing product naming"
if grep -Eiq 'fixit(\.zsh)? (installer|installed|uninstalled|for bash|block)|installing fixit|uninstalling fixit|remove fixit' \
  install.sh package.json README.md; then
  err "Found a user-facing fixit product-name regression"
  exit 1
fi
ok "User-facing product naming is consistent"

if ! command -v shellcheck >/dev/null 2>&1; then
  err "shellcheck is required (install it with brew or your package manager)"
  exit 1
fi
info "shellcheck"
shellcheck -S warning install.sh src/fixit-common.sh src/fixit.bash
ok "shellcheck clean"

ok "All tests passed"
