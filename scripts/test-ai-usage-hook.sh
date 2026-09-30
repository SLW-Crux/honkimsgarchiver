#!/usr/bin/env bash
# scripts/test-ai-usage-hook.sh — end-to-end test of the commit-msg AI-usage hook
#
# Builds a throwaway git repo with a fake HOME containing a Claude Code JSONL
# session log, stages a couple of files, runs .githooks/commit-msg on a
# commit-message file and asserts the exact trailer block. Also asserts the
# Merge-skip rule and the anchored idempotency check (FIX-W2), then the
# Codex CLI and Copilot CLI detectors (separate fake HOMEs) and a combined
# Claude+Codex HOME whose counts must sum into the same trailers. Finally the
# Claude config-dir lookup ($CLAUDE_CONFIG_DIR, ~/.claude, ~/.claude-*) for
# both the Python hook and the PowerShell twin (the latter only when pwsh is
# installed).
#
#   bash scripts/test-ai-usage-hook.sh
#
# Exit 0 = all assertions passed; exit 1 = a failure (diff printed).
set -u

TEMPLATE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$TEMPLATE_ROOT/.githooks/commit-msg"
PS1="$TEMPLATE_ROOT/.githooks/append-ai-usage.ps1"

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
# Claude Code's rule: every non-alphanumeric character of the path → "-".
ENCODED="$(printf '%s' "$REPO_ROOT" | sed 's/[^A-Za-z0-9]/-/g')"
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
  # RUNTIME=ps1 runs the PowerShell twin directly; default is the real
  # commit-msg entry point (which prefers python3).
  local runner=("$HOOK" "$msg")
  [ "${RUNTIME:-py}" = "ps1" ] && runner=(pwsh -NoProfile -File "$PS1" -CommitMsgFile "$msg")
  ( cd "$REPO" && env HOME="$home" CLAUDECODE= AI_AGENT= CLAUDE_CODE_ENTRYPOINT= \
      CLAUDE_CONFIG_DIR= \
      CODEX_HOME= COPILOT_HOME= XDG_CONFIG_HOME= \
      CODEX_SANDBOX= CODEX_THREAD_ID= CODEX_CI= COPILOT_CLI= GITHUB_COPILOT_CLI= \
      "$@" "${runner[@]}" </dev/null 2>"$WORK/stderr" )
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

# ── 12. Claude config dirs: $CLAUDE_CONFIG_DIR, ~/.claude, ~/.claude-* ─────
# One fixture session = 1 session, 3 interactions. All timestamps are after
# the 2020 seed commit so both runtimes count the same.
write_claude_session() {  # $1 = log folder, $2 = file name
  mkdir -p "$1"
  cat > "$1/$2" <<'JSONL'
{"type":"user","timestamp":"2020-01-01T00:05:00Z","message":{"role":"user","content":"go"}}
{"type":"assistant","timestamp":"2020-01-01T00:06:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"x.py"}},{"type":"tool_use","name":"Read","input":{"file_path":"x.py"}},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
JSONL
}

# assert_counts <label> <home> <sessions> <interactions> [VAR=value ...]
assert_counts() {
  local label="$1" home="$2" sessions="$3" interactions="$4"; shift 4
  local msg="$WORK/msg-$RUNTIME-$(printf '%s' "$label" | tr -c 'a-z0-9' '-')"
  printf 'feat: add x\n' > "$msg"
  run_hook_home "$home" "$msg" "$@" || fail "$RUNTIME $label: hook exited non-zero: $(cat "$WORK/stderr")"
  if grep -qx "AI-Sessions: $sessions" "$msg" && grep -qx "AI-Interactions: $interactions" "$msg"; then
    pass "$RUNTIME $label"
  else
    cat "$msg"; fail "$RUNTIME $label: expected AI-Sessions: $sessions, AI-Interactions: $interactions"
  fi
}

CFG="$WORK/cfg"; mkdir -p "$CFG"
# (a) logs only under a custom CLAUDE_CONFIG_DIR outside HOME
H_CUSTOM="$CFG/home-custom"; mkdir -p "$H_CUSTOM"
write_claude_session "$CFG/custom-config/projects/$ENCODED" a.jsonl
# (b) logs only under ~/.claude-other; variable unset
H_OTHER="$CFG/home-other"
write_claude_session "$H_OTHER/.claude-other/projects/$ENCODED" b.jsonl
# (c) logs under ~/.claude AND ~/.claude-other → counts add up
H_TWO="$CFG/home-two"
write_claude_session "$H_TWO/.claude/projects/$ENCODED" c1.jsonl
write_claude_session "$H_TWO/.claude-other/projects/$ENCODED" c2.jsonl
# (d) fuzzy fallback inside a non-default dir (folder name only contains the leaf)
H_FUZZY="$CFG/home-fuzzy"
write_claude_session "$H_FUZZY/.claude-other/projects/-moved-from-elsewhere-$(basename "$REPO_ROOT")" d.jsonl
# (e) ~/.claude-link is a symlink to ~/.claude-real → scanned once
H_LINK="$CFG/home-link"
write_claude_session "$H_LINK/.claude-real/projects/$ENCODED" e.jsonl
ln -s "$H_LINK/.claude-real" "$H_LINK/.claude-link"
# (g) a lookalike folder for ANOTHER repo whose name merely contains this
# repo's leaf ("...-repo-control") must not be picked up by the fuzzy fallback
H_LOOK="$CFG/home-lookalike"
write_claude_session "$H_LOOK/.claude/projects/-somewhere-else-$(basename "$REPO_ROOT")-control" g.jsonl
# (h) a repo whose path contains underscores: Claude Code writes its logs to
# ".../Under-Score/my-repo" (every non-alphanumeric → "-"); no fuzzy help,
# because the leaf "my_repo" must be encoded the same way to match.
UREPO="$WORK/Under_Score/my_repo"
mkdir -p "$UREPO"; git -C "$UREPO" init -q
git -C "$UREPO" -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
  commit -q --allow-empty -m initial --date=2020-01-01T00:00:00Z >/dev/null 2>&1
GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" git -C "$UREPO" -c user.email=t@e -c user.name=t \
  -c commit.gpgsign=false commit -q --amend --allow-empty -m initial --date=2020-01-01T00:00:00Z >/dev/null 2>&1
UROOT="$(git -C "$UREPO" rev-parse --show-toplevel)"
H_UNDER="$CFG/home-underscore"
write_claude_session "$H_UNDER/.claude/projects/$(printf '%s' "$UROOT" | sed 's/[^A-Za-z0-9]/-/g')" h.jsonl
# (f) no logs anywhere
H_NONE="$CFG/home-none"; mkdir -p "$H_NONE/.claude/projects" "$H_NONE/.claude-other"

RUNTIMES="py"
if command -v pwsh >/dev/null 2>&1; then RUNTIMES="py ps1"
else echo "note: pwsh not found — PowerShell config-dir cases skipped"; fi

WARN='^ai-usage hook: warning: Claude session detected but no Claude Code log folder'
for RUNTIME in $RUNTIMES; do
  assert_counts "config dir: custom CLAUDE_CONFIG_DIR only" "$H_CUSTOM" 1 3 \
    CLAUDECODE=1 CLAUDE_CONFIG_DIR="$CFG/custom-config"
  assert_counts "config dir: ~/.claude-other only, variable unset" "$H_OTHER" 1 3 CLAUDECODE=1
  assert_counts "config dir: two dirs, counts add up" "$H_TWO" 2 6 CLAUDECODE=1
  assert_counts "config dir: CLAUDE_CONFIG_DIR also matched by ~/.claude-* → no double count" \
    "$H_TWO" 2 6 CLAUDECODE=1 CLAUDE_CONFIG_DIR="$H_TWO/.claude-other"
  assert_counts "config dir: fuzzy fallback in ~/.claude-other" "$H_FUZZY" 1 3 CLAUDECODE=1
  assert_counts "config dir: symlinked ~/.claude-link counted once" "$H_LINK" 1 3 CLAUDECODE=1
  assert_counts "config dir: CLAUDE_CONFIG_DIR is a symlink to a scanned dir → counted once" \
    "$H_LINK" 1 3 CLAUDECODE=1 CLAUDE_CONFIG_DIR="$H_LINK/.claude-link"

  assert_counts "encoding: lookalike '<repo>-control' folder not counted" "$H_LOOK" 0 0 CLAUDECODE=1
  SAVED_REPO="$REPO"; REPO="$UREPO"
  assert_counts "encoding: underscores in the repo path (Xx_Github → Xx-Github)" "$H_UNDER" 1 3 CLAUDECODE=1
  REPO="$SAVED_REPO"

  # (f) Claude session, no logs anywhere → one warning naming the folders
  # checked, trailers still written, commit not blocked.
  assert_counts "no logs + Claude session: commit allowed, zero counts" "$H_NONE" 0 0 \
    CLAUDECODE=1 CLAUDE_CONFIG_DIR="$CFG/missing-config"
  if [ "$(grep -c "$WARN" "$WORK/stderr")" = "1" ] \
     && grep -q "$CFG/missing-config/projects" "$WORK/stderr" \
     && grep -q "$H_NONE/.claude/projects" "$WORK/stderr" \
     && grep -q "$H_NONE/.claude-other/projects" "$WORK/stderr"; then
    pass "$RUNTIME no logs + Claude session: one warning naming every folder checked"
  else
    cat "$WORK/stderr"; fail "$RUNTIME no logs + Claude session: warning missing or incomplete"
  fi
  # ...and no warning when logs were found, or when it isn't a Claude session.
  assert_counts "logs found: no warning" "$H_OTHER" 1 3 CLAUDECODE=1
  grep -q "$WARN" "$WORK/stderr" && { cat "$WORK/stderr"; fail "$RUNTIME warning printed although logs were found"; }
  MSGN="$WORK/msg-$RUNTIME-nosession"; printf 'feat: add x\n' > "$MSGN"
  run_hook_home "$H_NONE" "$MSGN" GIT_CONFIG_PARAMETERS="'ai-tracking.selfdeclare=off'" \
    || fail "$RUNTIME no-session hook exited non-zero"
  grep -q "$WARN" "$WORK/stderr" && { cat "$WORK/stderr"; fail "$RUNTIME warning printed outside a Claude session"; }
  pass "$RUNTIME no warning when logs are found or no Claude session is detected"
done

echo
printf '\033[32mALL HOOK TESTS PASSED\033[0m\n'
exit 0
