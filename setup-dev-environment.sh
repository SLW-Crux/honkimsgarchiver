#!/bin/sh
# ============================================================================
# setup-dev-environment.sh — one-time per-clone activation (macOS / Linux)
# ============================================================================
# Shell equivalent of setup-dev-environment.ps1. Run once from the repo root:
#     ./setup-dev-environment.sh
# ============================================================================

QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
# Fast path for automated callers (Claude Code SessionStart hook): if the clone
# is already activated and the hook self-test passed before, say nothing.
if [ "$QUIET" -eq 1 ] && [ "$(git config core.hooksPath 2>/dev/null)" = ".githooks" ] \
   && [ -f .git/ai-usage-selftest.ok ] && [ .git/ai-usage-selftest.ok -nt .githooks/append-ai-usage.py ]; then
  exit 0
fi
[ "$QUIET" -eq 1 ] && exec >/dev/null
echo "Setting up developer environment..."

# The single switch that turns tracking on for this clone: route git hooks to
# the version-controlled .githooks/ folder.
git config core.hooksPath .githooks
echo "  [OK] git hooks configured (core.hooksPath = .githooks)"

# Interpreter: the hook prefers python3 and falls back to PowerShell 7 (pwsh).
if command -v python3 >/dev/null 2>&1; then
  echo "  [OK] python3 found ($(command -v python3)) — the hook will use append-ai-usage.py"
elif command -v pwsh >/dev/null 2>&1; then
  echo "  [OK] PowerShell 7 found ($(command -v pwsh)) — the hook will use append-ai-usage.ps1"
else
  echo "  [X]  Neither python3 nor pwsh found. AI-usage tracking is mandatory; commits are blocked until one is installed:"
  echo "         macOS:  xcode-select --install      (python3)   or   brew install powershell"
  echo "         Linux:  apt/dnf install python3     or   https://learn.microsoft.com/powershell/scripting/install/"
  exit 1
fi

# Dry run: prove the hook actually produces trailers on THIS machine before the
# developer's first real commit. Prompts are suppressed for the self-test.
SELFTEST="$(mktemp 2>/dev/null || echo "/tmp/ai-usage-selftest.$$")"
printf 'chore: hook self-test\n' > "$SELFTEST"
GIT_CONFIG_PARAMETERS="'ai-tracking.selfdeclare=off'" \
  .githooks/commit-msg "$SELFTEST" </dev/null 2>/dev/null
if grep -q '^AI-Usage:' "$SELFTEST" 2>/dev/null; then
  echo "  [OK] hook self-test passed — AI usage tracking is active on this clone."
  rm -f "$SELFTEST"
  touch .git/ai-usage-selftest.ok 2>/dev/null || true
else
  echo "  [X]  hook self-test FAILED — .githooks/commit-msg did not add an AI-Usage trailer."
  echo "       Run it by hand to see the error:  .githooks/commit-msg $SELFTEST"
  exit 1
fi

echo ""
echo "Setup complete. Check the whole chain any time with: ./scripts/verify-tracking.sh"
