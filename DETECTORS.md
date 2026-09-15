# AI-usage detectors — how the commit-msg hook attributes tools

The `commit-msg` hook (`.githooks/append-ai-usage.py`, Python 3.9+, stdlib only)
reads each AI tool's local session logs written **since the last commit** and
folds everything it finds into one set of trailers. This file is the
reference for what each detector reads, how it counts, and how to add one.
The PowerShell twin (`append-ai-usage.ps1`) carries only the Claude detector
plus the two presence-only ones; Codex and Copilot are **python-only for now**.

## The shared model

Every detector accumulates into the **same tally**, so the trailers are
tool-agnostic sums:

| Trailer            | Meaning                                                       |
|--------------------|---------------------------------------------------------------|
| `AI-Tool`          | Sorted, de-duplicated list of every tool that fired           |
| `AI-Sessions`      | Session files/dirs with at least one counted call, all tools  |
| `AI-Interactions`  | Counted tool calls, all tools                                 |
| `AI-<category>`    | Per-category calls (`file-edit`, `file-read`, `terminal`, `research`, `planning`) |
| `Tests-Executed`   | Terminal calls whose command matched `TEST_CMD_RE`            |

Shared helpers in the hook:

| Helper                          | Role                                                                  |
|---------------------------------|-----------------------------------------------------------------------|
| `classify(name, table, mcp_prefixes)` | Case-insensitive lookup in a per-tool table; MCP-prefixed names → `planning`; unknown → `None` (ignored) |
| `command_is_test(cmd)`          | `str` or argv `list` matched against `TEST_CMD_RE` (`pytest`, `jest`, `vitest`, `.test.`, `test_`, …) |
| `new_tally()` / `tally_call(tally, cat, command)` | The single accumulator; a `terminal` call whose command is a test run also bumps `tests` |
| `entry_in_window(entry, last_commit)` | FIX-W1: a file's mtime is only a coarse filter — each record's own `timestamp` must also be after HEAD; unparseable timestamps are counted (never under-report) |
| `path_within(child, root)`      | realpath compare used to scope a session to this repo                  |
| `iter_jsonl(path)`, `parse_json_maybe(v)` | Tolerant JSONL reader (bad lines skipped) and dict-or-JSON-string parser |

Two rules apply to every log-based detector:

1. **Window**: select files with mtime > HEAD's commit time, then count only
   records whose own timestamp is also > HEAD (W1). With no HEAD (initial
   commit) everything counts.
2. **Never block a commit**: each scanner is wrapped so any exception counts
   nothing for that file/session and moves on; `main` is wrapped so the hook
   always exits 0.

## Detector table

| `AI-Tool` | Source read                                                       | What is counted                                                                                  | Confidence |
|-----------|-------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|------------|
| `claude`  | `~/.claude/projects/<encoded repo path>/**/*.jsonl`               | `assistant` records → `message.content[].type == "tool_use"`; name via `CATEGORIES` (`Write/Edit/MultiEdit`, `Read`, `Bash/computer`, `WebSearch/WebFetch`, `TodoWrite/TodoRead/Task`, `mcp__*`); `input.command` for tests | High — verified against real logs |
| `codex`   | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (`$CODEX_HOME` honoured) | First record `session_meta` → `payload.cwd` must be this repo (or inside it) or the file is skipped. `response_item` payloads of type `custom_tool_call` (`name`, `input` string), `function_call` (`name`, `arguments` JSON string → `command`/`cmd`), `local_shell_call` (`action.command` list), `web_search_call`. Mapping: `exec`/`shell`/`local_shell_call` → terminal; `apply_patch`/`write_file`/`edit_file`/`create_file` → file-edit; `read_file`/`list_dir`/`grep`/`view_image` → file-read; `web_search`/`web_search_call`/`fetch` → research; `update_plan`/`plan`/`mcp*` → planning | High for `custom_tool_call exec` (verified against real logs on 2026-09-14); the other three payload types are handled per the Codex schema but were not present in local logs |
| `copilot` | `~/.copilot/session-state/<session-id>/events.jsonl` (`$COPILOT_HOME`, then `~/.copilot`, then `$XDG_CONFIG_HOME/copilot`) | Session dirs with any file mtime > HEAD. cwd from `workspace.yaml`/`.json` or the `session.start` event's `data.cwd`; if found and outside this repo the session is skipped, if not discoverable the session is counted. `tool.execution_start` events → `data.toolName`: `bash`/`shell`/`powershell` → terminal; `str_replace_editor`/`create`/`edit`/`write` → file-edit; `view`/`read`/`grep`/`glob`/`list` → file-read; `web_fetch`/`web_search`/`fetch` → research; `task`/`plan`/`github-mcp*`/`mcp*` → planning. Command from `data.arguments.command` | **Built from the documented format, unverified against real logs** (Copilot CLI is not installed on the authoring machine). Only `~/.copilot` and `COPILOT_HOME` are confirmed by GitHub's docs; the `session-state/…/events.jsonl` layout and event names are the community-documented shape. If the layout differs the detector silently counts nothing |
| `aider`   | `<repo>/.aider.chat.history.md` mtime                             | Presence only — adds the tool name, no counts                                                    | Medium     |
| `continue`| `~/.continue/sessions/**` mtime                                   | Presence only — adds the tool name, no counts                                                    | Low (not repo-scoped) |

### Environment hints (no logs needed)

A commit made from *inside* an agent's shell is attributed even when no log
matched, and the interactive prompts are suppressed (there is no tty):

| Tool      | Env vars (any non-empty)                              | Note |
|-----------|-------------------------------------------------------|------|
| `claude`  | `CLAUDECODE=1`, `AI_AGENT=claude-code*`, `CLAUDE_CODE_ENTRYPOINT` | verified |
| `codex`   | `CODEX_SANDBOX`, `CODEX_THREAD_ID`, `CODEX_CI`        | taken from Codex's sandbox/CI conventions; `codex` was not installed here to confirm, so treat as best-effort |
| `copilot` | `COPILOT_CLI`, `GITHUB_COPILOT_CLI`                   | best-effort, unverified |

## Adding a detector

1. Add a `<TOOL>_CATEGORIES` table mapping the five category keys to the
   tool's lower-case tool names (leave out anything you would not want
   counted — unknown names are ignored, never mis-binned).
2. Write `scan_<tool>(repo_root, last_commit, tally) -> bool`:
   - locate the log root (honour the tool's home-override env var);
   - pre-filter files by `is_newer(path, last_commit)`;
   - scope to the repo with `path_within(cwd, repo_root)` whenever the log
     carries a working directory;
   - for each record, check `entry_in_window` (W1), then
     `tally_call(tally, classify(name, TABLE, prefixes), command)`;
   - bump `tally["sessions"]` once per session that counted something;
   - wrap per-file work in `try/except Exception: continue`.
3. Call it from `main` next to the others and append the tool name when it
   returns True; add an env-hint block if the tool sets a shell variable.
4. Add a fixture + exact-trailer assertion to `scripts/test-ai-usage-hook.sh`
   (include one pre-commit record that must be excluded and one session for
   another repo that must be skipped), and a row to the table above.
5. Note in `append-ai-usage.ps1`'s header that the detector is python-only
   until ported.

## Cloud agents (Copilot coding agent, Codex cloud)

Cloud-hosted agents — GitHub's Copilot coding agent working an issue, or
Codex running in OpenAI's cloud — never execute this hook: their commits are
produced on the provider's infrastructure, not from a developer clone with
`core.hooksPath` set, so they carry no `AI-*` trailers. Attribution for those
commits happens on the CI/report side by **bot committer identity**
(`copilot-swe-agent[bot]`, `github-actions[bot]`, Codex's connector author,
etc.), which the central `ai-usage-tracking-anyai` collector classifies
separately from local commits. The trailer-presence CI check treats them the
same way it treats web-UI commits: warn, not fail.
