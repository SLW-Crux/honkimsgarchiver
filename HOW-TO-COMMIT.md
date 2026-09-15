# How to commit so your work is tracked

AI-usage tracking runs from a **local git hook**. The hook only fires when you
commit **on your own machine**. Commits made in the GitHub website never run it,
so they show up as untracked in the weekly report.

Two things must be true for a commit to count:

1. You ran `setup-dev-environment.ps1` once in this clone.
2. The commit is a real local `git commit` — not a browser edit, not `--no-verify`.

---

## ✅ DO — this gets you tracked

1. **Clone** the repo to your machine (once):
   ```
   git clone https://github.com/ANZSFinPlan/<repo>.git
   ```
2. **Run setup** once in that clone (wires the hook + execution policy):
   ```powershell
   .\setup-dev-environment.ps1      # Windows
   ```
   **macOS / Linux:** install PowerShell first (`brew install --cask
   powershell@preview`; needs an admin password — no sudo? see
   AI-TRACKING-SETUP.md step 2 for the portable install), then run the shell
   helper:
   ```sh
   ./setup-dev-environment.sh       # or: git config core.hooksPath .githooks
   ```
   (No `pwsh` installed? Commits still work — they're just not tracked.)
3. **Edit** in your IDE / editor.
4. **Commit locally:**
   ```
   git add .
   git commit -m "your message"
   ```
   A one-line **note prompt** appears when AI activity is detected — that prompt
   is proof the hook ran. Type a note or press Enter to skip.
5. **Push and open a PR:**
   ```
   git push
   ```

## ❌ DON'T — these make your work vanish from the report

- ❌ Editing files with the **"Edit this file" pencil** on github.com.
- ❌ **"Commit suggestion"** buttons or merging/editing in the browser.
- ❌ `git commit --no-verify` (explicitly skips the hook).
- ❌ Committing from a clone where you never ran `setup-dev-environment.ps1`.

---

## How do I know it worked?

One command, green or red — before or after committing:

```
.\scripts\verify-tracking.ps1      # Windows
./scripts/verify-tracking.sh       # macOS / Linux
```

`TRACKING ACTIVE` means your next commit carries trailers; anything broken is
listed with its exact fix. (Manual alternative: `git log -1 --format="%B"`
after a commit should end with trailer lines like `AI-Usage: yes`,
`Lines-Added: 142`, …)

No trailers on a commit = the hook didn't run — run the verify script, apply
the fix it names, make sure you're committing locally, then commit again.

---

## Why this exists

The weekly **Org AI Usage Report** — centralised in the
[`ai-usage-tracking-anyai`](https://github.com/SLW-Crux/ai-usage-tracking-anyai)
repo (`reports` branch + rolling issue there; contract in that repo's
`docs/reporting/REPORT-SPEC.md`) — scans this repo along with every other
repo in the estate and groups developers by GitHub login, showing a
**Process compliance** table:

| Bucket | What it means |
|---|---|
| **Tracked ✅** | proper local commit — you're done right |
| **Web-UI ✋** | committed in the browser — the hook couldn't run |
| **Local-untracked ⚠** | local commit but no trailer — setup missing or `--no-verify` |

Nobody is blocked. But a row of 0% tracked is visible to everyone — the fix is
simply to commit locally.
