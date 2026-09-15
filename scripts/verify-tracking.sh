#!/usr/bin/env bash
# scripts/verify-tracking.sh — is AI tracking working in THIS clone? (macOS/Linux)
#
# One command, one green/red answer (FR-03). Checks the whole local chain and
# prints the exact fix for anything missing. Exit 0 = tracking will work on
# your next commit; exit 1 = at least one check failed.
#
#   ./scripts/verify-tracking.sh
#
# Windows: scripts/verify-tracking.ps1

pass=0; fail=0
ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m[X]\033[0m  %s\n       fix: %s\n' "$1" "$2"; fail=$((fail+1)); }
note() { printf '  \033[33m[i]\033[0m  %s\n' "$1"; }

echo "Verifying AI usage tracking in this clone..."

# 1. Hooks routed to .githooks (the single activation switch)
if [ "$(git config core.hooksPath)" = ".githooks" ]; then
  ok "git hooks routed to .githooks (core.hooksPath)"
else
  bad "git hooks NOT routed to .githooks — the tracking hook never runs" \
      "./setup-dev-environment.sh   (or: git config core.hooksPath .githooks)"
fi

# 2. Interpreter available (python3 preferred, pwsh fallback — either passes)
if command -v python3 >/dev/null 2>&1; then
  ok "python3 found ($(command -v python3)) — hook will use .githooks/append-ai-usage.py"
elif command -v pwsh >/dev/null 2>&1; then
  ok "PowerShell 7 found ($(command -v pwsh)) — hook will use .githooks/append-ai-usage.ps1"
else
  bad "neither python3 nor pwsh found — the commit-msg hook will BLOCK every commit" \
      "xcode-select --install (python3)  or  brew install powershell  — see AI-TRACKING-SETUP.md"
fi

# 3. Hook files present and executable
if [ -x .githooks/commit-msg ]; then
  ok ".githooks/commit-msg present and executable"
else
  bad ".githooks/commit-msg missing or not executable" \
      "git checkout .githooks && chmod +x .githooks/commit-msg"
fi

# 4. Secret gate still chained (activating .githooks bypasses .git/hooks)
if command -v pre-commit >/dev/null 2>&1; then
  ok "pre-commit framework on PATH (secret gate active via .githooks/pre-commit)"
else
  note "pre-commit framework not installed — gitleaks secret gate will be skipped locally (CI still enforces). Install: brew install pre-commit"
fi

# 5. Evidence: did the last local commit get trailers? (informational — a
#    fresh clone legitimately has none yet)
if git log -1 --format=%B 2>/dev/null | grep -qi '^AI-Usage:'; then
  ok "last commit carries AI-Usage trailers"
else
  note "last commit has no AI-Usage trailer (fine if it predates activation — the NEXT commit is what counts)"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mTRACKING ACTIVE\033[0m — your next commit will carry AI-Usage trailers.\n'
  exit 0
else
  printf '\033[31mTRACKING BROKEN\033[0m — %d check(s) failed, fixes above. Commits still succeed but will show as Local-untracked ⚠ in the weekly report.\n' "$fail"
  exit 1
fi
