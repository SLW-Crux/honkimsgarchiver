#!/usr/bin/env bash
# scripts/test-ai-usage-hook.sh — end-to-end test of the commit-msg AI-usage hook
#
# Builds a throwaway git repo with a fake HOME containing a Claude Code JSONL
# session log, stages a couple of files, runs .githooks/commit-msg on a
# commit-message file and asserts the exact trailer block. Also asserts the
# Merge-skip rule and the anchored idempotency check (FIX-W2), then the
# Codex CLI and Copilot CLI detectors (separate fake HOMEs) and a combined
# Claude+Codex HOME whose counts must sum into the same trailers.
#
#   bash scripts/test-ai-usage-hook.sh
#
# Exit 0 = all assertions passed; exit 1 = a failure (diff printed).
set -u

TEMPLATE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$TEMPLATE_ROOT/.githooks/commit-msg"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { printf '\033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
pass() { printf '\033[32mok\033[0m   %s\n' "$1"; }

# ── 1. Temp repo with one commit dated in the past ──────────────────────────
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Hook Test"
git -C "$REPO" config commit.gpgsign false
echo "seed" > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" \
  git -C "$REPO" commit -q -m "initial" >/dev/null 2>&1 || fail "could not create initial commit"
REPO_ROOT="$(git -C "$REPO" rev-parse --show-toplevel)"

# ── 2. Fake HOME with Claude Code session log for this repo ────────────────
FAKE_HOME="$WORK/home"
ENCODED="$(printf '%s' "$REPO_ROOT" | sed 's/[\/ .:]/-/g')"
LOGDIR="$FAKE_HOME/.claude/projects/$ENCODED"
mkdir -p "$LOGDIR"
cat > "$LOGDIR/session-1.jsonl" <<'JSONL'
{"type":"summary","summary":"  Add   feature x  ","leafUuid":"abc"}
{"type":"user","timestamp":"2020-01-01T00:05:00Z","message":{"role":"user","content":"do it"}}
{"type":"assistant","timestamp":"2019-12-31T23:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"old.py"}}]}}
{"type":"assistant","timestamp":"2020-01-01T00:10:00.123Z","message":{"role":"assistant","content":[{"type":"text","text":"working"},{"type":"tool_use","name":"Write","input":{"file_path":"x.py","content":"x = 1"}},{"type":"tool_use","name":"Read","input":{"file_path":"x.py"}}]}}
not json at all
{"type":"assistant","timestamp":"2020-01-01T00:11:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"pytest -q"}},{"type":"tool_use","name":"UnknownTool","input":{}}]}}
{"type":"assistant","timestamp":"2020-01-01T00:12:00Z","message":{"role":"assistant","content":"plain string content"}}
JSONL
# mtime must be newer than the 2020 commit — it is (file written just now).

# ── 3. Stage a .py with a comment line and a test file ─────────────────────
printf '# a comment\nx = 1\n' > "$REPO/x.py"
printf 'def test_x():\n    assert True\n' > "$REPO/test_x.py"
git -C "$REPO" add x.py test_x.py

# run_hook_home <HOME> <message file> [VAR=value ...]
# Every agent env hint is cleared, then the extra assignments are applied —
# each case sets exactly the "inside this agent's shell" hint it wants (which
# also suppresses the interactive prompts, as in real agent-driven commits).
run_hook_home() {
  local home="$1" msg="$2"; shift 2
  ( cd "$REPO" && env HOME="$home" CLAUDECODE= AI_AGENT= CLAUDE_CODE_ENTRYPOINT= \
      CODEX_HOME= COPILOT_HOME= XDG_CONFIG_HOME= \
      CODEX_SANDBOX= CODEX_THREAD_ID= CODEX_CI= COPILOT_CLI= GITHUB_COPILOT_CLI= \
      "$@" "$HOOK" "$msg" </dev/null 2>"$WORK/stderr" )
}
run_hook() {  # $1 = message file  (original Claude-session harness)
  run_hook_home "$FAKE_HOME" "$1" CLAUDECODE=1
}

# Shared tail of every trailer block for the staged x.py + test_x.py above.
CODE_METRICS='Lines-Added: 4
Lines-Removed: 0
Lines-Net: 4
Docs-Files: 0
Docs-InCode: yes
Tests-Files: 1'

# assert_trailers <label> <home> <expected AI-lines> [VAR=value ...]
assert_trailers() {
  local label="$1" home="$2" ai_lines="$3"; shift 3
  local msg="$WORK/msg-$(printf '%s' "$label" | tr -c 'a-z0-9' '-')"
  printf 'feat: add x\n\nSome body text.\n' > "$msg"
  run_hook_home "$home" "$msg" "$@" || fail "$label: hook exited non-zero: $(cat "$WORK/stderr")"
  local expected="$msg.expected"
  printf 'feat: add x\n\nSome body text.\n\n%s\n%s\n' "$ai_lines" "$CODE_METRICS" > "$expected"
  if cmp -s "$msg" "$expected"; then
    pass "$label"
  else
    echo "--- expected / +++ actual"; diff "$expected" "$msg"; fail "$label: trailer block mismatch"
  fi
}

# Fixture writers — each takes the HOME to populate. Timestamps after the
# 2020-01-01 seed commit count; the 2019 records must be excluded (FIX-W1).
write_codex_fixture() {  # $1 = HOME
  local d="$1/.codex/sessions/2026/09/14"
  mkdir -p "$d"
  cat > "$d/rollout-2026-09-14T01-46-43-x.jsonl" <<JSONL
{"timestamp":"2020-01-01T00:01:00Z","type":"session_meta","payload":{"id":"x","timestamp":"2020-01-01T00:01:00Z","cwd":"$REPO_ROOT","cli_version":"0.0.0","originator":"codex_cli_rs"}}
{"timestamp":"2019-12-31T23:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"pytest -q","call_id":"c0","status":"completed"}}
{"timestamp":"2020-01-01T00:05:00.100Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2020-01-01T00:05:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"ls -la","call_id":"c1","status":"completed"}}
{"timestamp":"2020-01-01T00:05:02Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"seed.txt"}}
{"timestamp":"2020-01-01T00:05:03Z","type":"response_item","payload":{"type":"function_call","name":"read_file","arguments":"{\"path\":\"seed.txt\"}","call_id":"c2"}}
{"timestamp":"2020-01-01T00:05:04Z","type":"response_item","payload":{"type":"function_call","name":"apply_patch","arguments":"{\"input\":\"*** Begin Patch\\n*** End Patch\"}","call_id":"c3"}}
{"timestamp":"2020-01-01T00:05:05Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"pytest -q","call_id":"c4","status":"completed"}}
{"timestamp":"2020-01-01T00:05:06Z","type":"response_item","payload":{"type":"function_call","name":"totally_unknown","arguments":"{}","call_id":"c5"}}
{"timestamp":"2020-01-01T00:05:07Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}
JSONL
  # A second session for ANOTHER repo must be ignored entirely.
  cat > "$d/rollout-2026-09-14T02-00-00-other.jsonl" <<JSONL
{"timestamp":"2020-01-01T00:01:00Z","type":"session_meta","payload":{"id":"y","cwd":"$WORK/elsewhere","cli_version":"0.0.0"}}
{"timestamp":"2020-01-01T00:05:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"pytest","call_id":"d1"}}
JSONL
}

write_copilot_fixture() {  # $1 = HOME
  local d="$1/.copilot/session-state/11111111-2222-3333-4444-555555555555"
  mkdir -p "$d"
  cat > "$d/events.jsonl" <<JSONL
{"type":"session.start","timestamp":"2020-01-01T00:02:00Z","data":{"sessionId":"1111","cwd":"$REPO_ROOT"}}
{"type":"user.message","timestamp":"2020-01-01T00:02:01Z","data":{"content":"do it"}}
{"type":"tool.execution_start","timestamp":"2019-12-31T23:00:00Z","data":{"toolCallId":"t0","toolName":"bash","arguments":{"command":"pytest -q"}}}
{"type":"tool.execution_start","timestamp":"2020-01-01T00:03:00Z","data":{"toolCallId":"t1","toolName":"bash","arguments":{"command":"ls"}}}
{"type":"tool.execution_complete","timestamp":"2020-01-01T00:03:01Z","data":{"toolCallId":"t1","success":true}}
{"type":"tool.execution_start","timestamp":"2020-01-01T00:03:02Z","data":{"toolCallId":"t2","toolName":"view","arguments":{"path":"seed.txt"}}}
{"type":"tool.execution_start","timestamp":"2020-01-01T00:03:03Z","data":{"toolCallId":"t3","toolName":"str_replace_editor","arguments":{"command":"create","path":"x.py"}}}
{"type":"tool.execution_start","timestamp":"2020-01-01T00:03:04Z","data":{"toolCallId":"t4","toolName":"bash","arguments":{"command":"npx vitest run"}}}
{"type":"tool.execution_start","timestamp":"2020-01-01T00:03:05Z","data":{"toolCallId":"t5","toolName":"github-mcp-server-get_issue","arguments":{"issue_number":1}}}
{"type":"tool.execution_start","timestamp":"2020-01-01T00:03:06Z","data":{"toolCallId":"t6","toolName":"some_future_tool","arguments":{}}}
{"type":"assistant.message","timestamp":"2020-01-01T00:03:07Z","data":{"content":"done"}}
JSONL
  # A session for another workspace must be ignored.
  local o="$1/.copilot/session-state/99999999-0000-0000-0000-000000000000"
  mkdir -p "$o"
  printf '{"type":"session.start","timestamp":"2020-01-01T00:02:00Z","data":{"cwd":"%s"}}\n{"type":"tool.execution_start","timestamp":"2020-01-01T00:03:00Z","data":{"toolName":"bash","arguments":{"command":"pytest"}}}\n' "$WORK/elsewhere" > "$o/events.jsonl"
  # Malformed session dir (no events.jsonl / garbage) must be tolerated.
  mkdir -p "$1/.copilot/session-state/broken"; printf 'not json' > "$1/.copilot/session-state/broken/events.jsonl"
  mkdir -p "$1/.copilot/history-session-state"; printf '{}' > "$1/.copilot/history-session-state/x.json"
}

# ── 4. Main case: exact trailer block ──────────────────────────────────────
MSG="$WORK/msg1"
printf 'feat: add x\n\nSome body text.\n' > "$MSG"
run_hook "$MSG" || fail "hook exited non-zero ($?): $(cat "$WORK/stderr")"

EXPECTED="$WORK/expected1"
cat > "$EXPECTED" <<'EOF'
feat: add x

Some body text.

AI-Usage: yes
AI-Tool: claude
AI-Sessions: 1
AI-Interactions: 3
AI-file-edit: 1
AI-file-read: 1
AI-terminal: 1
Tests-Executed: 1
Lines-Added: 4
Lines-Removed: 0
Lines-Net: 4
Docs-Files: 0
Docs-InCode: yes
Tests-Files: 1
EOF
if cmp -s "$MSG" "$EXPECTED"; then
  pass "trailer block is byte-exact (W1 filtered the pre-commit entry)"
else
  echo "--- expected / +++ actual"; diff "$EXPECTED" "$MSG"; fail "trailer block mismatch"
fi
if grep -q $'\r' "$MSG"; then fail "CR found in output"; fi
if head -c 3 "$MSG" | od -An -tx1 | grep -q 'ef bb bf'; then fail "BOM found in output"; fi

# ── 5. Merge commits are left untouched ────────────────────────────────────
MSG2="$WORK/msg2"
printf "Merge branch 'feature' into main\n" > "$MSG2"
cp "$MSG2" "$WORK/msg2.orig"
run_hook "$MSG2" || fail "hook exited non-zero on merge message"
cmp -s "$MSG2" "$WORK/msg2.orig" && pass "merge message skipped" || fail "merge message was modified"

# ── 6. W2: idempotency anchor ──────────────────────────────────────────────
# (a) a real trailer line already present → skipped
MSG3="$WORK/msg3"
printf 'fix: thing\n\nAI-Usage: no\nLines-Added: 0\n' > "$MSG3"
cp "$MSG3" "$WORK/msg3.orig"
run_hook "$MSG3" || fail "hook exited non-zero on already-trailered message"
cmp -s "$MSG3" "$WORK/msg3.orig" && pass "W2: existing AI-Usage trailer line → skipped" \
  || fail "W2: message with existing trailer was modified"

# (b) the phrase in prose (not at line start) → NOT skipped, trailers appended
MSG4="$WORK/msg4"
printf 'docs: explain the AI-Usage: trailer format\n' > "$MSG4"
run_hook "$MSG4" || fail "hook exited non-zero on prose message"
if [ "$(grep -c '^AI-Usage: yes$' "$MSG4")" = "1" ]; then
  pass "W2: 'AI-Usage:' mid-line in prose does not suppress trailers"
else
  cat "$MSG4"; fail "W2: prose mention wrongly suppressed the trailers"
fi

# ── 7. Empty message → untouched, exit 0 ───────────────────────────────────
MSG5="$WORK/msg5"; : > "$MSG5"
run_hook "$MSG5" || fail "hook exited non-zero on empty message"
[ ! -s "$MSG5" ] && pass "empty message left empty" || fail "empty message was modified"

# ── 8. Codex CLI detector (own fake HOME, no Claude logs) ──────────────────
CODEX_HOME_DIR="$WORK/home-codex"; mkdir -p "$CODEX_HOME_DIR"
write_codex_fixture "$CODEX_HOME_DIR"
assert_trailers "codex: exact trailer block (W1 + cwd scoping)" "$CODEX_HOME_DIR" 'AI-Usage: yes
AI-Tool: codex
AI-Sessions: 1
AI-Interactions: 4
AI-file-edit: 1
AI-file-read: 1
AI-terminal: 2
Tests-Executed: 1' CODEX_THREAD_ID=thread-1

# ── 9. Copilot CLI detector (synthetic events.jsonl — documented layout) ───
COPILOT_HOME_DIR="$WORK/home-copilot"; mkdir -p "$COPILOT_HOME_DIR"
write_copilot_fixture "$COPILOT_HOME_DIR"
assert_trailers "copilot: exact trailer block (synthetic fixture)" "$COPILOT_HOME_DIR" 'AI-Usage: yes
AI-Tool: copilot
AI-Sessions: 1
AI-Interactions: 5
AI-file-edit: 1
AI-file-read: 1
AI-planning: 1
AI-terminal: 2
Tests-Executed: 1' COPILOT_CLI=1

# ── 10. Combined: Claude + Codex logs in one HOME → summed counts ──────────
COMBO_HOME="$WORK/home-combo"
mkdir -p "$COMBO_HOME/.claude/projects"
cp -R "$LOGDIR" "$COMBO_HOME/.claude/projects/$ENCODED"
write_codex_fixture "$COMBO_HOME"
assert_trailers "combined: claude + codex sum into one block" "$COMBO_HOME" 'AI-Usage: yes
AI-Tool: claude, codex
AI-Sessions: 2
AI-Interactions: 7
AI-file-edit: 2
AI-file-read: 2
AI-terminal: 3
Tests-Executed: 2' CLAUDECODE=1

# ── 11. Env hints: no logs at all, but an agent env var → AI-Tool only ─────
EMPTY_HOME="$WORK/home-empty"; mkdir -p "$EMPTY_HOME"
MSG6="$WORK/msg6"; printf 'chore: env hint\n' > "$MSG6"
run_hook_home "$EMPTY_HOME" "$MSG6" CODEX_THREAD_ID=abc || fail "env-hint hook exited non-zero"
grep -q '^AI-Tool: codex$' "$MSG6" && grep -q '^AI-Interactions: 0$' "$MSG6" \
  && pass "env hint: CODEX_THREAD_ID alone → AI-Tool: codex, zero counts" \
  || { cat "$MSG6"; fail "env hint: codex not attributed from CODEX_THREAD_ID"; }

echo
printf '\033[32mALL HOOK TESTS PASSED\033[0m\n'
exit 0
