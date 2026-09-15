# scripts/verify-tracking.ps1 — is AI tracking working in THIS clone? (Windows)
#
# One command, one green/red answer (FR-03). Checks the whole local chain and
# prints the exact fix for anything missing. Exit 0 = tracking will work on
# your next commit; exit 1 = at least one check failed.
#
#   .\scripts\verify-tracking.ps1
#
# macOS/Linux: scripts/verify-tracking.sh

$fail = 0
function OK($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Bad($m, $fix) { Write-Host "  [X]  $m" -ForegroundColor Red; Write-Host "       fix: $fix"; $script:fail++ }
function Note($m) { Write-Host "  [i]  $m" -ForegroundColor Yellow }

Write-Host "Verifying AI usage tracking in this clone..."

# 1. Hooks routed to .githooks (the single activation switch)
if ((git config core.hooksPath) -eq ".githooks") {
    OK "git hooks routed to .githooks (core.hooksPath)"
} else {
    Bad "git hooks NOT routed to .githooks — the tracking hook never runs" `
        ".\setup-dev-environment.ps1   (or: git config core.hooksPath .githooks)"
}

# 2. PowerShell available — this script IS running under PowerShell, so on
#    Windows (built-in powershell.exe) this is satisfied by construction.
OK "PowerShell available ($($PSVersionTable.PSVersion))"

# 3. Hook files present
if (Test-Path .githooks/commit-msg) {
    OK ".githooks/commit-msg present"
} else {
    Bad ".githooks/commit-msg missing" "git checkout .githooks"
}

# 4. Secret gate still chained (activating .githooks bypasses .git/hooks)
if (Get-Command pre-commit -ErrorAction SilentlyContinue) {
    OK "pre-commit framework on PATH (secret gate active via .githooks/pre-commit)"
} else {
    Note "pre-commit framework not installed — gitleaks secret gate will be skipped locally (CI still enforces). Install: pip install pre-commit"
}

# 5. Evidence: did the last local commit get trailers? (informational)
$lastMsg = git log -1 --format=%B 2>$null
if ($lastMsg -match '(?m)^AI-Usage:') {
    OK "last commit carries AI-Usage trailers"
} else {
    Note "last commit has no AI-Usage trailer (fine if it predates activation — the NEXT commit is what counts)"
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "TRACKING ACTIVE — your next commit will carry AI-Usage trailers." -ForegroundColor Green
    exit 0
} else {
    Write-Host "TRACKING BROKEN — $fail check(s) failed, fixes above. Commits still succeed but will show as Local-untracked in the weekly report." -ForegroundColor Red
    exit 1
}
