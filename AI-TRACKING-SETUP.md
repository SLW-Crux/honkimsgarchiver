# AI Usage Tracking — Setup Guide

> **This capture-side setup lives in every repo derived from this template.**
> The weekly report and its dashboard live centrally in
> <https://github.com/SLW-Crux/ai-usage-tracking-anyai> — this repo only
> carries the hook that writes the trailers, not the reporting core. If you
> received this file by email or chat, treat the central repo as canonical
> for anything reporting-related below.

## What gets written to every commit

Every commit automatically gains trailers. No AI activity:

    AI-Usage: no
    AI-Sessions: 0
    AI-Interactions: 0

With AI activity (counts are summed across every detected tool):

    AI-Usage: yes
    AI-Tool: claude, codex
    AI-Sessions: 2
    AI-Interactions: 23
    AI-file-edit: 8
    AI-file-read: 4
    AI-terminal: 6
    AI-research: 3
    AI-planning: 2
    Tests-Executed: 5
    Lines-Added: 142
    Lines-Removed: 38
    Lines-Net: 104
    Docs-Files: 2
    Docs-InCode: yes
    Tests-Files: 3
    AI-Note: security review on auth module

Only AI categories with non-zero counts appear. `AI-Note` only appears
if the developer typed something at the optional prompt. The code metrics
(Lines-*, Docs-*, Tests-Files) are recorded on every commit regardless of
AI involvement. `Tests-Executed` appears only when an AI tool ran a test
runner.

---

## Detected tools

Every detector feeds the **same** trailers — sessions, interactions,
categories and `Tests-Executed` accumulate across tools, and `AI-Tool` lists
each tool that fired. Full formats, mappings and how to add a detector:
[DETECTORS.md](DETECTORS.md).

| `AI-Tool`  | Detected from                                              | Counts        | Runtime      | Confidence |
|------------|------------------------------------------------------------|---------------|--------------|------------|
| `claude`   | Claude Code JSONL logs, `~/.claude/projects/<repo>/`       | Full          | .py and .ps1 | High (verified) |
| `codex`    | Codex CLI logs, `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, scoped by session `cwd` | Full | .py only | High (verified against real logs) |
| `copilot`  | Copilot CLI logs, `~/.copilot/session-state/<id>/events.jsonl`, scoped by `cwd` | Full | .py only | Built from documented format — unverified against real logs |
| `aider`    | `.aider.chat.history.md` in the repo, modified since HEAD  | Presence only | both         | Medium |
| `continue` | `~/.continue/sessions/` modified since HEAD                | Presence only | both         | Low |
| *(any)*    | Self-declared at the prompt (copilot inline, cursor, chatgpt…) | None      | both         | As typed |

Env hints also attribute a tool when the commit is made from inside its
shell even if no log matched: `CLAUDECODE` / `CLAUDE_CODE_ENTRYPOINT`
(claude), `CODEX_SANDBOX` / `CODEX_THREAD_ID` / `CODEX_CI` (codex),
`COPILOT_CLI` / `GITHUB_COPILOT_CLI` (copilot).

**Cloud agents (Copilot coding agent, Codex cloud)** never run this hook —
their commits are made on the provider's infrastructure, so they carry no
trailers. They are attributed in CI and the weekly report by bot committer
identity instead; the trailer gate warns rather than fails for them, as it
does for web-UI commits.

---

## The five auto-detected categories

| Trailer        | What it counts                                      | Confidence |
|----------------|-----------------------------------------------------|------------|
| `AI-file-edit` | Claude wrote or edited a file (Write/Edit tools)    | High       |
| `AI-file-read` | Claude read a file to understand context            | High       |
| `AI-terminal`  | Claude ran a terminal/bash command                  | High       |
| `AI-research`  | Claude did a web search or fetched a URL            | High       |
| `AI-planning`  | Claude used todo/task planning tools or sub-agents  | High       |

All five are detected automatically from tool names in Claude Code, Codex
CLI and Copilot CLI logs (see **Detected tools** above). No developer input
required for these counts.

---

## Code & quality metrics (every commit)

These are recorded on every commit from git's own staged diff, regardless
of whether Claude was involved. They give you output volume to correlate
against AI activity.

| Trailer           | What it counts                                          | Confidence |
|-------------------|---------------------------------------------------------|------------|
| `Lines-Added`     | Lines added across all staged files                     | Exact      |
| `Lines-Removed`   | Lines removed across all staged files                   | Exact      |
| `Lines-Net`       | Added minus removed                                      | Exact      |
| `Docs-Files`      | Staged files matching doc patterns (.md, /docs/, etc.)  | High       |
| `Docs-InCode`     | yes/no — did the commit add any comments or docstrings  | Medium     |
| `Tests-Files`     | Staged files matching test patterns (.test., /tests/)   | High       |
| `Tests-Executed`  | Test-runner commands an AI tool ran (from its logs)     | Partial    |

Two honest caveats:

- **Lines counts are commit-wide, not AI-attributed.** The hook cannot
  reliably know which specific lines Claude wrote versus the developer.
  The number tells you "this commit changed N lines and had M Claude
  interactions" — the correlation, without false precision.
- **`Tests-Executed` only captures tests Claude ran** via its terminal
  tool. Tests a developer runs manually in their own terminal are not
  visible to the hook. For definitive test-run verification, rely on CI.
- **`Docs-InCode` is a flag, not a count.** A commented-out line of code
  looks identical to a real comment, so a count would mislead. The flag
  reliably answers "were any comments/docstrings added in this commit."

---

## The optional note

When Claude activity is detected, the developer sees one prompt:

    Claude activity detected: 23 interactions across 2 session(s)
    Auto-categorised: file-edit(8), terminal(6), file-read(4), research(3), planning(2)
    Last session: Refactored payment handler, added null checks

    Note (optional — press Enter to skip): _

The developer types a short description ("security review on auth")
or presses Enter. Either way the commit proceeds.

When *nothing* is auto-detected, the hook instead asks `AI tool used this
commit?` so undetectable tools (Copilot inline, ChatGPT-paste) can be
self-declared. Both prompts are tunable per clone — see
**Tuning the self-declare prompt** below.

Notes aggregate into a section in the weekly report — useful for
understanding *intent* behind the activity counts.

---

## One-time setup per developer

### 1. Run the setup script (once per clone, from the repo root)

    .\setup-dev-environment.ps1      # Windows
    ./setup-dev-environment.sh       # macOS / Linux

It routes git hooks to `.githooks/` (the single activation switch) and checks
the PowerShell runtime. Non-technical? Use the assisted path instead:
[docs/setup/DEV-SETUP-claude-prompt.md](docs/setup/DEV-SETUP-claude-prompt.md)
— paste one message into Claude Code and it walks you through everything.

### 2. Install PowerShell 7 (macOS / Linux — the hook's runtime)

Windows needs nothing (built-in PowerShell 5.1 is used). On macOS:

    brew install --cask powershell@preview   # needs an admin password (sudo)

**No admin password / unattended machine?** Use the portable build — no sudo:

    curl -sL $(gh api repos/PowerShell/PowerShell/releases/latest \
      --jq '.assets[] | select(.name|test("osx-arm64.tar.gz$")) | .browser_download_url') \
      | tar xz -C ~/.local/opt/powershell --strip-components=0
    ln -sf ~/.local/opt/powershell/pwsh /opt/homebrew/bin/pwsh

(Create `~/.local/opt/powershell` first; on Intel Macs use `osx-x64`.)
Linux: <https://learn.microsoft.com/powershell/scripting/install/>.
Without pwsh, commits still succeed — they just carry no trailers and show as
**Local-untracked ⚠** in the weekly report.

### 3. Allow PowerShell execution (Windows only, if blocked)

Run once in PowerShell (not as admin):

    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

### 4. Verify — one command, green or red

    ./scripts/verify-tracking.sh       # macOS / Linux
    .\scripts\verify-tracking.ps1      # Windows

`TRACKING ACTIVE` (exit 0) means your next commit will carry trailers;
anything broken is listed with its exact fix. No git-output archaeology.

## Tuning the self-declare prompt (per clone)

When no AI tool is auto-detected, the hook asks "AI tool used this commit?" —
the only way undetectable tools (Copilot inline, ChatGPT-paste) get recorded.
If that per-commit prompt is a toll you don't want, tune it:

    git config ai-tracking.selfdeclare always     # default here: always ask on zero-detection
    git config ai-tracking.selfdeclare detected   # only the note prompt when a detector fired
    git config ai-tracking.selfdeclare off        # never prompt; detectors only

Trade-off (coverage vs per-commit friction) and rationale:
[docs/reporting/DESIGN.md §6](https://github.com/SLW-Crux/ai-usage-tracking-anyai/blob/main/docs/reporting/DESIGN.md)
in the central reporting repo. `detected` is the recommended default for
low-AI or client repos.

### 4. macOS / Linux developers

The hook is cross-platform — it runs the same tracking logic under PowerShell 7
(`pwsh`) on macOS/Linux as it does under Windows PowerShell on Windows.

1. **Install PowerShell 7** (once per machine):

       brew install powershell        # macOS (Homebrew)
       # Linux: see https://learn.microsoft.com/powershell/scripting/install/

   Without `pwsh`, commits still succeed — they're just not tracked (the hook
   prints a one-line notice and exits cleanly).

2. **Configure the hooks path.** `setup-dev-environment.ps1` needs PowerShell,
   so if you haven't installed `pwsh` yet, run the shell helper instead:

       ./setup-dev-environment.sh      # or simply: git config core.hooksPath .githooks

3. **No chmod needed** — `commit-msg` is committed with the executable bit set,
   which git on macOS/Linux requires (a non-executable hook is silently skipped).

4. **Verify** exactly as in step 3 above. A commit made *after running Claude in
   that repo* should show `AI-Usage: yes` with real counts.

---

## CI enforcement

The **"Verify AI-Usage trailers present"** step inside the `lint-test` job of
[.github/workflows/ci.yml](.github/workflows/ci.yml) (folded in 2026-07-18
from a formerly-separate `ci-ai-usage-check.yml` workflow — a standalone
workflow billed its own 1-minute checkout+queue+boot cycle on every PR, so it
was merged in as a step instead) runs on every PR and fails any local commit
missing the `AI-Usage:` trailer — the anti-gaming control against
`git commit --no-verify`. Two classes warn instead of failing (they can't be
fixed without rewriting pushed history): web-UI commits (the browser can't
run the hook — they show as **Web-UI ✋** in the weekly report) and commits
made before a clone activated tracking (a maintainer applies the
`ai-tracking-exempt` PR label; the exemption is listed in the job summary,
so it stays auditable). `lint-test` is already a required status check via
branch protection (see `.github/CI.md`), so this has been a gate, not just
signal, since the fold.

---

## Weekly report

This repo does **not** run the report itself — reporting is centralised in
one repo per estate so a scan doesn't need N cross-repo tokens for N derived
repos. The central
[`ai-usage-tracking-anyai`](https://github.com/SLW-Crux/ai-usage-tracking-anyai)
repo's `org-ai-usage-report.yml` runs every Monday 00:00 UTC: `collect.ps1`
scans every non-archived repo in the estate (all branches, including this
one) → dataset JSON → `render.ps1` → delivery. The report lands in three
places there: the `reports` branch (canonical `.md` + `.json`, full history),
a rolling GitHub Issue labelled `ai-usage-report`, and the workflow run's job
summary. What the report says — every section, column, and accounting rule —
is defined normatively in
[docs/reporting/REPORT-SPEC.md](https://github.com/SLW-Crux/ai-usage-tracking-anyai/blob/main/docs/reporting/REPORT-SPEC.md)
in that repo.

---

## Files in this solution

Capture-side (in this repo):

```
.githooks/
  commit-msg                       ← git hook entry point (sh; python3, else pwsh)
  append-ai-usage.py               ← reads Claude/Codex/Copilot logs, writes trailers, shows prompt
  append-ai-usage.ps1              ← PowerShell twin (Claude + presence detectors only)
  pre-commit                       ← chains the pre-commit framework (secret gate)
.github/workflows/
  ci.yml                            ← lint-test job's "Verify AI-Usage trailers
                                       present" step: PR gate, every local
                                       commit carries trailers
scripts/
  verify-tracking.sh / .ps1        ← "is tracking working here?" — one green/red command
setup-dev-environment.ps1 / .sh    ← one-time per-clone activation
docs/setup/DEV-SETUP-claude-prompt.md ← assisted setup via Claude Code
AI-TRACKING-SETUP.md               ← this file
DETECTORS.md                       ← per-tool log formats, category mapping, how to add a detector
```

Reporting-side (centralised in
[`ai-usage-tracking-anyai`](https://github.com/SLW-Crux/ai-usage-tracking-anyai),
**not copied here** — one instance serves the whole estate):

```
.github/workflows/org-ai-usage-report.yml  ← weekly report pipeline
scripts/report/collect.ps1 / render.ps1    ← the reporting core
identities/<login>.json                    ← login → display-name mapping
docs/reporting/REPORT-SPEC.md              ← the report contract (normative)
docs/reporting/DESIGN.md                   ← reporting architecture
```

`.githooks/` is version-controlled and shared across the team.
`.git/hooks/` is local only and not tracked.
