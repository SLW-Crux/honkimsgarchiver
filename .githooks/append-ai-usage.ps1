# append-ai-usage.ps1  (CROSS-PLATFORM: Windows PowerShell 5.1 + macOS/Linux pwsh 7+)
#
# DETECTOR PARITY NOTE — python-only for now:
#   The Python twin (append-ai-usage.py, preferred by commit-msg whenever
#   python3 exists) carries two extra log-based detectors that are NOT yet
#   ported here. Commits made via this .ps1 will not attribute them:
#     * codex   — Codex CLI      ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
#     * copilot — Copilot CLI    ~/.copilot/session-state/<id>/events.jsonl
#   See DETECTORS.md for the formats and the shared category mapping.
#
# Reads Claude Code JSONL session logs since the last git commit.
# Auto-detects mechanism categories from tool names + file extensions.
# Optionally accepts a developer note at commit time (single prompt, skippable).
#
# Portability: the ONLY OS-specific bits are the Claude log location and how the
# project path is encoded into the log folder name — both branch on $IsUnixHost
# below. Everything else (git, JSON parsing, trailer writing) is identical on
# all platforms. On macOS/Linux this runs under `pwsh`; the commit-msg shim
# picks pwsh vs powershell.exe automatically.
#
# Trailers written to every commit (example):
#
#   AI-Usage: yes
#   AI-Sessions: 2
#   AI-Interactions: 23
#   AI-file-edit: 8
#   AI-file-read: 4
#   AI-terminal: 6
#   AI-research: 3
#   AI-planning: 2
#   AI-Note: security review on auth module
#
# Code metrics (all staged changes, regardless of AI involvement):
#   Lines-Added: 142
#   Lines-Removed: 38
#   Lines-Net: 104
#   Docs-Files: 2
#   Docs-InCode: yes
#   Tests-Files: 3
#   Tests-Executed: 5
#
# If no Claude activity detected, AI-* counts are 0/omitted but the
# code metrics above are still recorded on every commit.
#
# Trailer names are fixed-width and grep-friendly for GitHub Actions parsing.
#
# ───────────────────────────────────────────────────────────────────────────────
# SYSTEM ARCHITECTURE — how this script fits the wider tracking system
#
#   [developer machine]                         [GitHub]
#   git commit                                  org-ai-usage-report.yml (weekly)
#     └─ .githooks/commit-msg (sh shim)           └─ reads commit messages via API
#          └─ THIS SCRIPT                             └─ parses the trailers below
#               ├─ reads Claude Code JSONL logs          └─ aggregates per developer
#               │   (~/.claude/projects/<repo>)              + per repo into one issue
#               └─ reads git's staged diff
#                    └─ writes AI-* / Lines-* / Tests-* trailers onto the commit
#
#   The script is the ONLY place AI activity is measured. Everything downstream
#   (the weekly report, the process-compliance view) just parses the trailers
#   this script writes. If a commit bypasses this script (web-UI commit, no
#   setup, or --no-verify), it carries no trailers and is counted as
#   "untracked" by the report.
#
# EXECUTION FLOW BELOW, IN ORDER:
#   1. Constants     — tool→category map, file-type patterns, comment markers
#   2. Helpers       — locate the Claude log folder, classify a tool, read summaries
#   3. Code metrics  — parse `git diff --cached` for line counts, docs, tests
#   4. Log scan      — walk JSONL sessions since the last commit, tally tool use
#   5. Optional note — one skippable prompt, shown only when AI activity is found
#   6. Build trailers— append the AI-*/Lines-*/Tests-* block to the commit message
# ───────────────────────────────────────────────────────────────────────────────

param(
    [Parameter(Mandatory=$true)]
    [string]$CommitMsgFile      # path to the temp commit-message file, passed by git
)

# StrictMode Off + SilentlyContinue: the hook must NEVER block a commit on its
# own error. If anything in here fails, the commit should still go through —
# tracking is best-effort, not a gate. (The CI check is the real enforcement.)
Set-StrictMode -Off
$ErrorActionPreference = "SilentlyContinue"

# ── Constants ─────────────────────────────────────────────────────────────────

# Cross-platform OS detection. $PSVersionTable.Platform is 'Unix' on macOS/Linux
# under PowerShell (Core) 6+, and is absent ($null) on Windows PowerShell 5.1 —
# so this is true on Mac/Linux and false on Windows, on every PowerShell edition.
$IsUnixHost = ($PSVersionTable.Platform -eq 'Unix')

# Claude Code stores session logs under the user profile. The folder name and
# path separator differ by OS:
#   Windows : %USERPROFILE%\.claude\projects
#   macOS   : $HOME/.claude/projects
$ClaudeLogRoot = if ($IsUnixHost) {
    Join-Path $env:HOME ".claude/projects"
} else {
    Join-Path $env:USERPROFILE ".claude\projects"
}

# All five reliable auto-detected categories
# Key = trailer suffix   Value = detection rules (evaluated in order)
$Categories = [ordered]@{
    "file-edit"  = @{ tools = @("Write","Edit","MultiEdit") }
    "file-read"  = @{ tools = @("Read") }
    "terminal"   = @{ tools = @("Bash","Computer") }
    "research"   = @{ tools = @("WebSearch","WebFetch") }
    "planning"   = @{ tools = @("TodoWrite","TodoRead","Task") }
}

# Test/spec file patterns — terminal commands matching these are counted
# under file-edit rather than terminal (they're running tests on code)
$TestFilePatterns = @("\.test\.", "\.spec\.", "test_", "_test\.", "jest", "pytest", "vitest", "mocha", "nunit", "xunit")

# Staged-file path patterns for documentation files (committed as docs)
$DocFilePatterns = @('\.md$', '\.rst$', '\.txt$', '\.adoc$', '/docs/', '^docs/', 'README', 'CHANGELOG', 'CONTRIBUTING')

# Staged-file path patterns for test files (committed as tests)
$TestFileCommitPatterns = @('\.test\.', '\.spec\.', '(^|/)test_', '_test\.', '(^|/)tests?/', '\.feature$', 'Test\.java$', 'Tests\.cs$', '_spec\.rb$')

# Comment markers by file extension — used for the in-code documentation flag.
# A staged diff line counts as in-code documentation if its added content
# (after the leading +) starts with one of these markers for that file type.
$CommentMarkers = @{
    '.js'   = @('//','/*','*'); '.ts'  = @('//','/*','*'); '.jsx' = @('//','/*','*'); '.tsx' = @('//','/*','*')
    '.java' = @('//','/*','*'); '.cs'  = @('//','/*','*'); '.go'  = @('//','/*','*'); '.c'   = @('//','/*','*')
    '.cpp'  = @('//','/*','*'); '.h'   = @('//','/*','*'); '.php' = @('//','/*','*','#')
    '.py'   = @('#','"""',"'''"); '.rb' = @('#'); '.sh' = @('#'); '.ps1' = @('#','<#'); '.yml' = @('#'); '.yaml' = @('#')
    '.sql'  = @('--','/*'); '.r' = @('#'); '.lua' = @('--'); '.pl' = @('#')
}

# ── Helpers ───────────────────────────────────────────────────────────────────

function Get-LastCommitTime {
    try {
        $raw = git log -1 --format="%ct" 2>$null
        if ($raw -match '^\d+$') {
            return [DateTimeOffset]::FromUnixTimeSeconds([long]$raw).UtcDateTime
        }
    } catch {}
    return [DateTime]::MinValue
}

function Get-ProjectLogFolder {
    $repoRoot = git rev-parse --show-toplevel 2>$null
    if (-not $repoRoot) { return $null }

    # Claude encodes the project's absolute path into the log folder name by
    # replacing path-structure characters with hyphens. The exact rule differs
    # by OS, matching how Claude Code itself names the folder:
    #   Windows: C:\Users\me\repo        -> C--Users-me-repo
    #            (\ -> /, then / and : -> -)
    #   macOS  : /Users/me/My Project    -> -Users-me-My-Project
    #            (leading / kept as leading -, and / . : and SPACE all -> -)
    if ($IsUnixHost) {
        $encoded = $repoRoot -replace '[/ .:]', '-'
    } else {
        $encoded = $repoRoot -replace '\\', '/' -replace '^/', '' -replace '[/:]', '-'
    }

    $candidate = Join-Path $ClaudeLogRoot $encoded
    if (Test-Path $candidate) { return $candidate }

    # Fallback: fuzzy match on repo leaf name
    # FIX-W4: match on the ENCODED leaf ("my.repo" appears as "my-repo" in the folder name)
    $repoLeaf = Split-Path $repoRoot -Leaf
    if ($IsUnixHost) { $repoLeaf = $repoLeaf -replace '[/ .:]', '-' } else { $repoLeaf = $repoLeaf -replace '[/:]', '-' }
    $folders  = Get-ChildItem -Path $ClaudeLogRoot -Directory -ErrorAction SilentlyContinue
    foreach ($f in $folders) {
        if ($f.Name -like "*$repoLeaf*") { return $f.FullName }
    }
    return $null
}

function Get-Category {
    param([string]$ToolName, [object]$ToolInput)

    foreach ($cat in $Categories.Keys) {
        if ($Categories[$cat].tools -contains $ToolName) {
            return $cat
        }
    }

    # MCP tools → planning (they're orchestration)
    if ($ToolName -like "mcp__*") { return "planning" }

    return $null   # unknown tools ignored rather than polluting counts
}

function Get-SessionSummary {
    # Reads the auto-generated summary Claude Code writes at session end.
    # Returns the first summary found in the file, trimmed to 120 chars.
    param([string]$FilePath)
    $summary = ""
    Get-Content $FilePath -ErrorAction SilentlyContinue | ForEach-Object {
        if ($summary) { return }
        try {
            $entry = $_ | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($entry.type -eq "summary" -and $entry.summary) {
                $summary = $entry.summary.Trim() -replace '\s+', ' '
                if ($summary.Length -gt 120) { $summary = $summary.Substring(0,117) + "..." }
            }
        } catch {}
    }
    return $summary
}

# ── Code metrics from staged changes ──────────────────────────────────────────

function Get-StagedCodeMetrics {
    # Reads git's own staged diff stats. Counts ALL staged lines regardless
    # of whether Claude was involved — this is the commit-level change volume.
    $result = @{
        added       = 0
        removed     = 0
        net         = 0
        docFiles    = 0
        testFiles   = 0
        docsInCode  = "no"
    }

    # --numstat gives: <added>\t<removed>\t<path> per file
    $numstat = git diff --cached --numstat 2>$null
    if (-not $numstat) { return $result }

    foreach ($line in $numstat) {
        $parts = $line -split "`t"
        if ($parts.Count -lt 3) { continue }

        $add  = $parts[0]
        $del  = $parts[1]
        $path = $parts[2]

        # Binary files show "-" for counts — skip those toward line totals
        if ($add -match '^\d+$') { $result.added   += [int]$add }
        if ($del -match '^\d+$') { $result.removed += [int]$del }

        # Documentation files
        foreach ($pat in $DocFilePatterns) {
            if ($path -match $pat) { $result.docFiles++; break }
        }

        # Test files
        foreach ($pat in $TestFileCommitPatterns) {
            if ($path -match $pat) { $result.testFiles++; break }
        }
    }

    $result.net = $result.added - $result.removed

    # In-code documentation flag: scan the staged diff for added comment lines
    $result.docsInCode = Get-InCodeDocsFlag

    return $result
}

function Get-InCodeDocsFlag {
    # Returns "yes" if any added line in the staged diff is an in-code
    # comment/docstring, based on the file extension's comment markers.
    # Reliability is intentionally a flag, not a count.
    $diff = git diff --cached --unified=0 2>$null
    if (-not $diff) { return "no" }

    $currentExt = ""
    foreach ($line in $diff) {
        # Track which file we're in
        if ($line -match '^\+\+\+ b/(.+)$') {
            $path = $Matches[1]
            $currentExt = [System.IO.Path]::GetExtension($path).ToLower()
            continue
        }
        # FIX-W5: a deleted file has no "+++ b/" header — reset so the previous
        # file's extension doesn't leak into the next hunk
        if ($line -match '^\+\+\+ /dev/null') { $currentExt = ""; continue }
        # Only added lines (start with + but not the +++ header)
        if ($line -match '^\+' -and $line -notmatch '^\+\+\+') {
            $content = $line.Substring(1).TrimStart()
            if (-not $content) { continue }
            $markers = $CommentMarkers[$currentExt]
            if ($markers) {
                foreach ($m in $markers) {
                    if ($content.StartsWith($m)) { return "yes" }
                }
            }
        }
    }
    return "no"
}

# ── Read JSONL logs ───────────────────────────────────────────────────────────

$lastCommit  = Get-LastCommitTime
$logFolder   = Get-ProjectLogFolder

$sessionCount      = 0
$totalInteractions = 0
$counts            = @{}
$testsExecuted     = 0
$sessionSummaries  = [System.Collections.Generic.List[string]]::new()

foreach ($cat in $Categories.Keys) { $counts[$cat] = 0 }

if ($logFolder -and (Test-Path $logFolder)) {

    $jsonlFiles = Get-ChildItem -Path $logFolder -Filter "*.jsonl" -Recurse -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTimeUtc -gt $lastCommit } |
                  Sort-Object LastWriteTimeUtc

    foreach ($file in $jsonlFiles) {
        $sessionHadActivity = $false

        Get-Content $file.FullName -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $entry = $_ | ConvertFrom-Json -ErrorAction SilentlyContinue
                if (-not $entry) { return }

                if ($entry.type -eq "assistant" -and $entry.message -and $entry.message.content) {
                    foreach ($block in $entry.message.content) {
                        if ($block.type -eq "tool_use") {
                            $cat = Get-Category -ToolName $block.name -ToolInput $block.input
                            if ($cat) {
                                $counts[$cat]++
                                $totalInteractions++
                                $sessionHadActivity = $true
                            }

                            # Tests executed: Bash commands that run a test runner
                            if (($block.name -eq "Bash" -or $block.name -eq "Computer") -and $block.input -and $block.input.command) {
                                $cmd = "$($block.input.command)"
                                foreach ($pat in $TestFilePatterns) {
                                    if ($cmd -match $pat) { $testsExecuted++; break }
                                }
                            }
                        }
                    }
                }
            } catch {}
        }

        if ($sessionHadActivity) {
            $sessionCount++
            $summary = Get-SessionSummary -FilePath $file.FullName
            if ($summary) { $sessionSummaries.Add($summary) }
        }
    }
}

# ── Read existing commit message ──────────────────────────────────────────────

$commitMsg = Get-Content $CommitMsgFile -Raw -ErrorAction SilentlyContinue
if (-not $commitMsg) { exit 0 }

# Skip merge / rebase / amend
if ($commitMsg -match '^Merge |^Rebase ') { exit 0 }
# FIX-W2: idempotency — only a real trailer LINE counts, not the phrase in prose
if ($commitMsg -match '(?m)^AI-Usage:') { exit 0 }

# ── Detect AI tools used + optional note (generalised: ANY AI) ─────────────────
# Claude Code is auto-detected from its JSONL logs above. Other tools are
# best-effort: we look for local history that some leave behind. Anything that
# leaves no reliable local trace (Copilot inline, web ChatGPT/Gemini, etc.) is
# captured by the self-declare prompt. To support a new tool, add a detector to
# the block below that appends its name to $toolsUsed when it sees recent activity.

$devNote   = ""
$toolsUsed = [System.Collections.Generic.List[string]]::new()
if ($totalInteractions -gt 0) { $toolsUsed.Add("claude") }

# Agent/orchestrator-driven commits: Claude Code SUBAGENTS log tool-use under the
# PARENT (orchestrator) project folder, not this repo's — so the repo-local scan
# above misses them and the commit was wrongly stamped "no". The Claude Code runtime
# sets these env vars in the (sub)agent's shell; their presence here is proof.
$inClaudeSession = (($env:CLAUDECODE -eq '1') -or ($env:AI_AGENT -like 'claude-code*') -or [bool]$env:CLAUDE_CODE_ENTRYPOINT)
if ($inClaudeSession -and -not $toolsUsed.Contains("claude")) { $toolsUsed.Add("claude") }

# ── FR-13: prompt behaviour is a per-clone setting, not hard-coded ────────────
#   git config ai-tracking.selfdeclare <always|detected|off>
#   always   (default) — zero-detection commits ask for a self-declared tool;
#            the only way undetectable tools (Copilot inline, ChatGPT-paste)
#            get recorded. The right default for AI-heavy repos like this one.
#   detected — prompt only when a detector fired (the optional-note prompt);
#            zero-detection commits record silently. Bello-parity; recommended
#            where the per-commit toll bites (client deployments).
#   off      — never prompt; trailers come from detectors alone.
# Decision + trade-off: docs/reporting/DESIGN.md §6.
$selfDeclare = git config ai-tracking.selfdeclare 2>$null
if ($selfDeclare) { $selfDeclare = "$selfDeclare".Trim().ToLower() }
if ($selfDeclare -notin @('always', 'detected', 'off')) { $selfDeclare = 'always' }

# ── Best-effort extra detectors ───────────────────────────────────────────────
$homeDir  = if ($IsUnixHost) { $env:HOME } else { $env:USERPROFILE }
$repoRoot = git rev-parse --show-toplevel 2>$null

# Aider — keeps a chat history file at the repo root
if ($repoRoot) {
    $aiderLog = Join-Path $repoRoot ".aider.chat.history.md"
    if ((Test-Path $aiderLog) -and ((Get-Item $aiderLog).LastWriteTimeUtc -gt $lastCommit)) {
        if (-not $toolsUsed.Contains("aider")) { $toolsUsed.Add("aider") }
    }
}
# Continue — keeps sessions under ~/.continue/sessions
$contDir = Join-Path $homeDir ".continue/sessions"
if (Test-Path $contDir) {
    $recent = Get-ChildItem $contDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -gt $lastCommit }
    if ($recent -and -not $toolsUsed.Contains("continue")) { $toolsUsed.Add("continue") }
}
# (Stubs for tools whose local logs vary by version — add as needed:
#  Cursor → workspaceStorage SQLite, GitHub Copilot → editor logs, Windsurf, Codeium.)

if ($toolsUsed.Count -gt 0 -and -not $inClaudeSession) {
    # Auto-detected: show what was found, then ask for an optional note.
    $detectedSummary = ($counts.GetEnumerator() |
        Where-Object { $_.Value -gt 0 } |
        Sort-Object Value -Descending |
        ForEach-Object { "$($_.Key)($($_.Value))" }) -join ", "

    $host.UI.WriteLine("")
    $host.UI.WriteLine("  AI activity detected: $($toolsUsed -join ', ')  ($totalInteractions interactions, $sessionCount session(s))")
    if ($detectedSummary) { $host.UI.WriteLine("  Auto-categorised: $detectedSummary") }
    if ($sessionSummaries.Count -gt 0) {
        $host.UI.WriteLine("  Last session: $($sessionSummaries[$sessionSummaries.Count - 1])")
    }
    $host.UI.WriteLine("")
    if ($selfDeclare -ne 'off') {
        $host.UI.Write("  Note (optional — press Enter to skip): ")
        try { $rawInput = [Console]::In.ReadLine(); if ($null -ne $rawInput) { $devNote = $rawInput.Trim() } } catch {}
        $host.UI.WriteLine("")
    }
}
elseif ($selfDeclare -eq 'always' -and -not $inClaudeSession) {
    # Nothing auto-detected — let the developer self-declare any AI tool used
    # (Copilot, Cursor, ChatGPT, Gemini, …). Press Enter to record "no AI".
    # In 'detected'/'off' modes this prompt is skipped (FR-13) and the commit
    # records silently — undetectable tools then simply go unrecorded.
    $host.UI.WriteLine("")
    $host.UI.Write("  AI tool used this commit? (e.g. copilot, cursor, chatgpt, gemini — Enter for none): ")
    try {
        $rawTool = [Console]::In.ReadLine()
        if ($rawTool) {
            $t = $rawTool.Trim().ToLower()
            if ($t -and $t -ne "none") { $toolsUsed.Add($t) }
        }
    } catch {}
    if ($toolsUsed.Count -gt 0) {
        $host.UI.Write("  Note (optional — press Enter to skip): ")
        try { $rawInput = [Console]::In.ReadLine(); if ($null -ne $rawInput) { $devNote = $rawInput.Trim() } } catch {}
    }
    $host.UI.WriteLine("")
}

# ── Build and append trailers ─────────────────────────────────────────────────

# Code metrics from staged changes (all lines, regardless of AI involvement)
$code = Get-StagedCodeMetrics

# AI-Usage is "yes" if ANY tool was detected or self-declared
$aiUsage = if ($toolsUsed.Count -gt 0) { "yes" } else { "no" }

# Always write AI-Usage, AI-Tool, AI-Sessions, AI-Interactions
$trailerLines = [System.Collections.Generic.List[string]]::new()
$trailerLines.Add("")   # blank line separating commit body from trailers
$trailerLines.Add("AI-Usage: $aiUsage")
if ($toolsUsed.Count -gt 0) {
    $trailerLines.Add("AI-Tool: $(($toolsUsed | Sort-Object -Unique) -join ', ')")
}
$trailerLines.Add("AI-Sessions: $sessionCount")
$trailerLines.Add("AI-Interactions: $totalInteractions")

# Write a trailer for every category that has a non-zero count
# Zero-count categories are omitted to keep messages clean
foreach ($cat in $counts.Keys | Sort-Object) {
    if ($counts[$cat] -gt 0) {
        $trailerLines.Add("AI-$cat`: $($counts[$cat])")
    }
}

# Tests executed by Claude (from JSONL bash commands) — only if non-zero
if ($testsExecuted -gt 0) {
    $trailerLines.Add("Tests-Executed: $testsExecuted")
}

# Code metrics — always recorded on every commit
$trailerLines.Add("Lines-Added: $($code.added)")
$trailerLines.Add("Lines-Removed: $($code.removed)")
$trailerLines.Add("Lines-Net: $($code.net)")
$trailerLines.Add("Docs-Files: $($code.docFiles)")
$trailerLines.Add("Docs-InCode: $($code.docsInCode)")
$trailerLines.Add("Tests-Files: $($code.testFiles)")

# Developer note — only written if non-empty
if ($devNote -and $devNote.Length -gt 0) {
    # Sanitise: strip newlines, limit to 200 chars
    $cleanNote = $devNote -replace '[\r\n]', ' '
    if ($cleanNote.Length -gt 200) { $cleanNote = $cleanNote.Substring(0,197) + "..." }
    $trailerLines.Add("AI-Note: $cleanNote")
}

$newMsg = $commitMsg.TrimEnd() + "`n" + ($trailerLines -join "`n") + "`n"
Set-Content -Path $CommitMsgFile -Value $newMsg -NoNewline -Encoding UTF8

exit 0
