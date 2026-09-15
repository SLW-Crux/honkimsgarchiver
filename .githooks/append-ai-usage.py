#!/usr/bin/env python3
# append-ai-usage.py  (CROSS-PLATFORM: Python 3.9+, standard library only)
#
# Port of append-ai-usage.ps1. Reads AI-agent session logs since the last git
# commit, auto-detects mechanism categories from tool names, optionally
# accepts a developer note at commit time, and appends AI-*/Lines-*/Tests-*
# trailers to the commit message. Output is byte-identical to the PowerShell
# version for the same inputs, except for the five deliberate fixes marked
# FIX-W1 .. FIX-W5 below, and the two python-only detectors (Codex CLI and
# GitHub Copilot CLI — see DETECTORS.md) which the .ps1 does not yet carry.
#
# Detectors (all feed the SAME AI-Sessions / AI-Interactions / AI-<category> /
# Tests-Executed counters; AI-Tool lists every tool that fired):
#   claude    ~/.claude/projects/<encoded repo>/*.jsonl      (full counts)
#   codex     ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl   (full counts)
#   copilot   ~/.copilot/session-state/<id>/events.jsonl     (full counts,
#             built from the documented layout — unverified against real logs)
#   aider     <repo>/.aider.chat.history.md mtime            (presence only)
#   continue  ~/.continue/sessions/** mtime                  (presence only)
#
# The hook must NEVER block a commit on its own error: every failure path
# exits 0. Tracking is best-effort; the CI trailer check is the real gate.
#
# Trailers written (example):
#
#   AI-Usage: yes
#   AI-Tool: claude, codex
#   AI-Sessions: 2
#   AI-Interactions: 23
#   AI-file-edit: 8
#   AI-file-read: 4
#   AI-planning: 2
#   AI-research: 3
#   AI-terminal: 6
#   Tests-Executed: 5
#   Lines-Added: 142
#   Lines-Removed: 38
#   Lines-Net: 104
#   Docs-Files: 2
#   Docs-InCode: yes
#   Tests-Files: 3
#   AI-Note: security review on auth module
#
# EXECUTION FLOW, IN ORDER (mirrors the .ps1):
#   1. Constants     — tool→category map, file-type patterns, comment markers
#   2. Helpers       — locate log folders, classify a tool, shared tally helpers
#   3. Code metrics  — parse `git diff --cached` for line counts, docs, tests
#   4. Log scan      — one scanner per tool (Claude, Codex, Copilot), all
#                      accumulating into one shared tally since the last commit
#   5. Optional note — one skippable prompt, shown only when not in a Claude session
#   6. Build trailers— append the block to the commit message

import json
import os
import re
import subprocess
import sys
from pathlib import Path

# ── Constants ─────────────────────────────────────────────────────────────────

IS_WINDOWS = os.name == "nt"

# Key = trailer suffix, value = tool names (matched case-insensitively, in order).
CATEGORIES = {
    "file-edit": ("write", "edit", "multiedit"),
    "file-read": ("read",),
    "terminal": ("bash", "computer"),
    "research": ("websearch", "webfetch"),
    "planning": ("todowrite", "todoread", "task"),
}

# Codex CLI tool names (payload.name of custom_tool_call / function_call, or
# the payload.type itself for local_shell_call / web_search_call).
CODEX_CATEGORIES = {
    "file-edit": ("apply_patch", "write_file", "edit_file", "create_file"),
    "file-read": ("read_file", "list_dir", "grep", "view_image"),
    "terminal": ("exec", "shell", "local_shell_call"),
    "research": ("web_search", "web_search_call", "fetch"),
    "planning": ("update_plan", "plan"),
}

# GitHub Copilot CLI tool names (data.toolName of tool.execution_start events).
COPILOT_CATEGORIES = {
    "file-edit": ("str_replace_editor", "create", "edit", "write"),
    "file-read": ("view", "read", "grep", "glob", "list"),
    "terminal": ("bash", "shell", "powershell"),
    "research": ("web_fetch", "web_search", "fetch"),
    "planning": ("task", "plan"),
}

# Terminal commands matching these count as a test run (max +1 per call).
TEST_CMD_RE = re.compile(
    r"\.test\.|\.spec\.|test_|_test\.|jest|pytest|vitest|mocha|nunit|xunit", re.I
)

# Staged-file path patterns for documentation files.
DOC_FILE_RE = re.compile(
    r"\.md$|\.rst$|\.txt$|\.adoc$|/docs/|^docs/|README|CHANGELOG|CONTRIBUTING", re.I
)

# Staged-file path patterns for test files.
TEST_FILE_RE = re.compile(
    r"\.test\.|\.spec\.|(^|/)test_|_test\.|(^|/)tests?/|\.feature$|Test\.java$|Tests\.cs$|_spec\.rb$",
    re.I,
)

# Comment markers by (lowercase) file extension for the in-code docs flag.
C_STYLE = ("//", "/*", "*")
COMMENT_MARKERS = {
    ".js": C_STYLE, ".ts": C_STYLE, ".jsx": C_STYLE, ".tsx": C_STYLE,
    ".java": C_STYLE, ".cs": C_STYLE, ".go": C_STYLE, ".c": C_STYLE,
    ".cpp": C_STYLE, ".h": C_STYLE, ".php": ("//", "/*", "*", "#"),
    ".py": ("#", '"""', "'''"), ".rb": ("#",), ".sh": ("#",), ".ps1": ("#", "<#"),
    ".yml": ("#",), ".yaml": ("#",),
    ".sql": ("--", "/*"), ".r": ("#",), ".lua": ("--",), ".pl": ("#",),
}


# ── Helpers ───────────────────────────────────────────────────────────────────

def git(*args):
    """Run git, return stdout as text ('' on any failure). Never raises."""
    try:
        res = subprocess.run(
            ["git", *args], capture_output=True, check=False
        )
        if res.returncode != 0:
            return ""
        return res.stdout.decode("utf-8", errors="replace")
    except Exception:
        return ""


def home_dir():
    if IS_WINDOWS:
        return os.environ.get("USERPROFILE") or os.environ.get("HOME") or ""
    return os.environ.get("HOME") or ""


def claude_log_root():
    return Path(home_dir()) / ".claude" / "projects"


def get_last_commit_time():
    """Unix seconds of HEAD, or None when there is no HEAD (initial commit)."""
    raw = git("log", "-1", "--format=%ct").strip()
    if re.fullmatch(r"\d+", raw):
        return int(raw)
    return None


def is_newer(path, last_commit):
    """mtime > last commit; with no HEAD everything counts."""
    if last_commit is None:
        return True
    try:
        return os.stat(path).st_mtime > last_commit
    except OSError:
        return False


def encode_project_path(repo_root):
    # Claude Code encodes the project's absolute path into the log folder name:
    #   Windows: C:\Users\me\repo     -> C--Users-me-repo
    #   macOS  : /Users/me/My Project -> -Users-me-My-Project
    if IS_WINDOWS:
        s = repo_root.replace("\\", "/")
        s = re.sub(r"^/", "", s)
        return re.sub(r"[/:]", "-", s)
    return re.sub(r"[/ .:]", "-", repo_root)


def get_project_log_folder(repo_root):
    if not repo_root:
        return None
    root = claude_log_root()
    encoded = encode_project_path(repo_root)
    candidate = root / encoded
    if candidate.exists():
        return candidate

    # FIX-W4: the fallback fuzzy match uses the ENCODED repo leaf (a leaf such
    # as "my.repo" appears as "my-repo" in the folder name, so matching on the
    # raw leaf could never hit).
    leaf = os.path.basename(repo_root.rstrip("/\\")) or repo_root
    leaf_enc = encode_project_path(leaf).lower()
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return None
    for name in names:
        p = root / name
        if p.is_dir() and leaf_enc in name.lower():
            return p
    return None


def classify(tool_name, table, mcp_prefixes=("mcp__",)):
    """Shared category lookup: exact (case-insensitive) match in `table`, else
    any MCP-style prefix → planning (orchestration), else None (ignored)."""
    name = str(tool_name or "").lower()
    for cat, tools in table.items():
        if name in tools:
            return cat
    if any(name.startswith(pfx) for pfx in mcp_prefixes):
        return "planning"
    return None  # unknown tools ignored rather than polluting counts


def get_category(tool_name):
    """Claude Code tool → category (unchanged behaviour)."""
    return classify(tool_name, CATEGORIES)


def command_is_test(cmd):
    """True when a terminal command (str or argv list) runs a test runner."""
    if isinstance(cmd, list):
        cmd = " ".join(str(c) for c in cmd)
    if not cmd:
        return False
    return bool(TEST_CMD_RE.search(str(cmd)))


def new_tally():
    """One shared accumulator for every detector."""
    return {
        "sessions": 0,
        "interactions": 0,
        "counts": {cat: 0 for cat in CATEGORIES},
        "tests": 0,
        "summaries": [],
    }


def tally_call(tally, cat, command=None):
    """Count one tool call in `cat`; a terminal call whose command matches
    TEST_CMD_RE also bumps Tests-Executed. Returns True when counted."""
    if not cat or cat not in tally["counts"]:
        return False
    tally["counts"][cat] += 1
    tally["interactions"] += 1
    if cat == "terminal" and command_is_test(command):
        tally["tests"] += 1
    return True


def path_within(child, root):
    """True when `child` is `root` or inside it (realpath-compared)."""
    if not child or not root:
        return False
    try:
        c = os.path.realpath(str(child))
        r = os.path.realpath(str(root))
    except Exception:
        return False
    if IS_WINDOWS:
        c, r = c.lower(), r.lower()
    return c == r or c.startswith(r.rstrip("/\\") + os.sep)


def parse_json_maybe(value):
    """A dict as-is; a JSON-object string parsed; anything else → {}."""
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            obj = json.loads(value)
        except Exception:
            return {}
        if isinstance(obj, dict):
            return obj
    return {}


def iter_jsonl(path):
    """Yield parsed JSON objects line by line; bad lines are skipped."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if isinstance(obj, dict):
                    yield obj
    except OSError:
        return


def get_session_summary(path):
    """First 'summary' entry with non-empty text, whitespace-collapsed, ≤120 chars."""
    for entry in iter_jsonl(path):
        if str(entry.get("type") or "").lower() != "summary":
            continue
        s = entry.get("summary")
        if not isinstance(s, str):
            continue
        s = re.sub(r"\s+", " ", s.strip())
        if not s:
            continue
        if len(s) > 120:
            s = s[:117] + "..."
        return s
    return ""


_TS_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?"
    r"(Z|[+-]\d{2}:?\d{2})?$",
    re.I,
)


def _days_from_civil(y, m, d):
    """Days since 1970-01-01 for a proleptic Gregorian date (stdlib-free)."""
    y -= m <= 2
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def parse_iso_ts(value):
    """ISO 8601 (optionally ending in Z) → unix seconds, or None if unparseable."""
    if not isinstance(value, str):
        return None
    m = _TS_RE.match(value.strip())
    if not m:
        return None
    try:
        y, mo, d, hh, mm = (int(m.group(i)) for i in range(1, 6))
        ss = int(m.group(6) or 0)
        frac = m.group(7) or ""
        micro = int((frac + "000000")[:6]) if frac else 0
        if not (1 <= mo <= 12 and 1 <= d <= 31 and hh < 24 and mm < 60 and ss < 61):
            return None
        secs = _days_from_civil(y, mo, d) * 86400 + hh * 3600 + mm * 60 + ss + micro / 1e6
        tz = m.group(8)
        if tz and tz.upper() != "Z":
            sign = 1 if tz[0] == "+" else -1
            tzd = tz[1:].replace(":", "")
            secs -= sign * (int(tzd[:2]) * 3600 + int(tzd[2:4]) * 60)
        return secs
    except Exception:
        return None


def entry_in_window(entry, last_commit):
    # FIX-W1: a session file is only a coarse filter (its mtime moves on every
    # write). Additionally require each entry's own timestamp to be after the
    # last commit. Entries without a parseable timestamp are counted
    # (conservative — never under-report).
    if last_commit is None:
        return True
    ts = parse_iso_ts(entry.get("timestamp"))
    if ts is None:
        return True
    return ts > last_commit



# ── Log scanners (one per tool, all feed the shared tally) ────────────────────

def scan_claude(log_folder, last_commit, tally):
    """Claude Code: ~/.claude/projects/<encoded repo>/**/*.jsonl.
    Returns True when at least one tool call was counted."""
    if not (log_folder and log_folder.exists()):
        return False
    had_any = False
    files = [p for p in log_folder.rglob("*.jsonl") if p.is_file() and is_newer(p, last_commit)]
    files.sort(key=lambda p: os.stat(p).st_mtime)
    for fpath in files:
        session_had_activity = False
        for entry in iter_jsonl(fpath):
            if str(entry.get("type") or "").lower() != "assistant":
                continue
            message = entry.get("message")
            if not isinstance(message, dict):
                continue
            content = message.get("content")
            if not isinstance(content, list):
                continue
            if not entry_in_window(entry, last_commit):  # FIX-W1
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if str(block.get("type") or "").lower() != "tool_use":
                    continue
                name = str(block.get("name") or "")
                cmd = None
                tool_input = block.get("input")
                if isinstance(tool_input, dict):
                    cmd = tool_input.get("command")
                if tally_call(tally, get_category(name), cmd):
                    session_had_activity = True
        if session_had_activity:
            had_any = True
            tally["sessions"] += 1
            summary = get_session_summary(fpath)
            if summary:
                tally["summaries"].append(summary)
    return had_any


def codex_sessions_root():
    base = os.environ.get("CODEX_HOME") or os.path.join(home_dir(), ".codex")
    return Path(base) / "sessions"


def codex_call(payload):
    """(tool_name, command) for a Codex tool-call payload, or (None, None).
    Handles custom_tool_call, function_call, local_shell_call, web_search_call."""
    ptype = str(payload.get("type") or "").lower()
    if ptype == "custom_tool_call":
        name = payload.get("name")
        cmd = payload.get("input")
        return (str(name or ""), cmd if isinstance(cmd, (str, list)) else None)
    if ptype == "function_call":
        name = str(payload.get("name") or "")
        args = parse_json_maybe(payload.get("arguments"))
        cmd = args.get("command") or args.get("cmd")
        return (name, cmd if isinstance(cmd, (str, list)) else None)
    if ptype == "local_shell_call":
        action = payload.get("action")
        cmd = action.get("command") if isinstance(action, dict) else None
        return ("local_shell_call", cmd if isinstance(cmd, (str, list)) else None)
    if ptype == "web_search_call":
        return ("web_search_call", None)
    return (None, None)


def scan_codex(repo_root, last_commit, tally):
    """Codex CLI: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, one file per
    session. First record is session_meta (payload.cwd scopes it to a repo);
    tool calls are response_item records (W1 per-record timestamp rule)."""
    if not repo_root:
        return False
    root = codex_sessions_root()
    try:
        if not root.is_dir():
            return False
        files = [p for p in root.rglob("rollout-*.jsonl") if p.is_file() and is_newer(p, last_commit)]
        files.sort(key=lambda p: os.stat(p).st_mtime)
    except Exception:
        return False
    had_any = False
    for fpath in files:
        try:
            session_had_activity = False
            in_scope = None  # unknown until session_meta seen
            for entry in iter_jsonl(fpath):
                etype = str(entry.get("type") or "").lower()
                payload = entry.get("payload")
                if not isinstance(payload, dict):
                    continue
                if etype == "session_meta":
                    in_scope = path_within(payload.get("cwd"), repo_root)
                    if not in_scope:
                        break
                    continue
                if in_scope is not True or etype != "response_item":
                    continue
                if not entry_in_window(entry, last_commit):  # FIX-W1
                    continue
                name, cmd = codex_call(payload)
                if name is None:
                    continue
                if tally_call(tally, classify(name, CODEX_CATEGORIES, ("mcp",)), cmd):
                    session_had_activity = True
            if session_had_activity:
                had_any = True
                tally["sessions"] += 1
        except Exception:
            continue
    return had_any


def copilot_home_candidates():
    out = []
    if os.environ.get("COPILOT_HOME"):
        out.append(Path(os.environ["COPILOT_HOME"]))
    out.append(Path(home_dir()) / ".copilot")
    if os.environ.get("XDG_CONFIG_HOME"):
        out.append(Path(os.environ["XDG_CONFIG_HOME"]) / "copilot")
    return out


def copilot_session_cwd(session_dir, events_path):
    """cwd from a workspace.yaml/json next to events.jsonl or from the
    session.start event; None when not discoverable."""
    for fname in ("workspace.yaml", "workspace.yml", "workspace.json"):
        wp = session_dir / fname
        try:
            if wp.is_file():
                text = wp.read_text(encoding="utf-8", errors="replace")
                m = re.search(r'^\s*"?cwd"?\s*:\s*"?([^"\n]+?)"?\s*,?\s*$', text, re.M)
                if m and m.group(1).strip():
                    return m.group(1).strip()
        except Exception:
            pass
    for entry in iter_jsonl(events_path):
        if str(entry.get("type") or "").lower() != "session.start":
            continue
        data = entry.get("data")
        for src in (data if isinstance(data, dict) else {}, entry):
            for key in ("cwd", "workingDirectory", "working_directory"):
                v = src.get(key)
                if isinstance(v, str) and v.strip():
                    return v.strip()
        break
    return None


def copilot_event_ts(entry):
    ts = entry.get("timestamp") or entry.get("ts") or entry.get("time")
    if ts is None and isinstance(entry.get("data"), dict):
        ts = entry["data"].get("timestamp")
    return ts


def copilot_call(entry):
    """(tool_name, command) for a tool.execution_start event."""
    data = entry.get("data")
    if not isinstance(data, dict):
        data = {}
    name = data.get("toolName") or data.get("tool_name") or data.get("name") or entry.get("toolName")
    if not isinstance(name, str) or not name:
        return (None, None)
    cmd = None
    for key in ("arguments", "input", "args", "parameters"):
        args = data.get(key)
        if isinstance(args, str) and key != "arguments":
            cmd = args
            break
        args = parse_json_maybe(args)
        if args:
            c = args.get("command") or args.get("cmd")
            if isinstance(c, (str, list)):
                cmd = c
                break
    return (name, cmd)


def scan_copilot(repo_root, last_commit, tally):
    """GitHub Copilot CLI (standalone `copilot` agent): <home>/session-state/
    <session-id>/events.jsonl. Built from the documented layout and tolerant
    of drift: anything unexpected counts nothing rather than crashing."""
    if not repo_root:
        return False
    had_any = False
    seen = set()
    for home in copilot_home_candidates():
        try:
            state = home / "session-state"
            if not state.is_dir():
                continue
            for sdir in sorted(state.iterdir()):
                try:
                    if not sdir.is_dir() or sdir.resolve() in seen:
                        continue
                    seen.add(sdir.resolve())
                    events = sdir / "events.jsonl"
                    if not events.is_file():
                        continue
                    if not any(is_newer(p, last_commit) for p in sdir.rglob("*") if p.is_file()):
                        continue
                    cwd = copilot_session_cwd(sdir, events)
                    if cwd and not path_within(cwd, repo_root):
                        continue
                    session_had_activity = False
                    for entry in iter_jsonl(events):
                        if str(entry.get("type") or "").lower() != "tool.execution_start":
                            continue
                        if not entry_in_window({"timestamp": copilot_event_ts(entry)}, last_commit):
                            continue
                        name, cmd = copilot_call(entry)
                        if name is None:
                            continue
                        cat = classify(name, COPILOT_CATEGORIES, ("github-mcp", "mcp"))
                        if tally_call(tally, cat, cmd):
                            session_had_activity = True
                    if session_had_activity:
                        had_any = True
                        tally["sessions"] += 1
                except Exception:
                    continue
        except Exception:
            continue
    return had_any


# ── Code metrics from staged changes ──────────────────────────────────────────

def path_extension(path):
    """Mirror System.IO.Path.GetExtension: '' when no dot in the last segment
    or the dot is the final character; otherwise from the last dot."""
    seg = re.split(r"[/\\]", path)[-1]
    i = seg.rfind(".")
    if i < 0 or i == len(seg) - 1:
        return ""
    return seg[i:].lower()


def get_in_code_docs_flag():
    diff = git("diff", "--cached", "--unified=0")
    if not diff:
        return "no"
    current_ext = ""
    for line in diff.splitlines():
        m = re.match(r"^\+\+\+ b/(.+)$", line, re.I)
        if m:
            current_ext = path_extension(m.group(1))
            continue
        if line.startswith("+++ /dev/null"):
            # FIX-W5: a deleted file has no "+++ b/" header; without this reset
            # the previous file's extension would leak into the next hunk.
            current_ext = ""
            continue
        if line.startswith("+") and not line.startswith("+++"):
            content = line[1:].lstrip()
            if not content:
                continue
            markers = COMMENT_MARKERS.get(current_ext)
            if markers and any(content.startswith(mk) for mk in markers):
                return "yes"
    return "no"


def get_staged_code_metrics():
    result = {"added": 0, "removed": 0, "net": 0, "docFiles": 0, "testFiles": 0,
              "docsInCode": "no"}
    numstat = git("diff", "--cached", "--numstat")
    if numstat:
        for line in numstat.splitlines():
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            add, rem, path = parts[0], parts[1], parts[2]
            # Binary files show "-" for counts — skip those toward line totals
            if re.fullmatch(r"\d+", add):
                result["added"] += int(add)
            if re.fullmatch(r"\d+", rem):
                result["removed"] += int(rem)
            if DOC_FILE_RE.search(path):
                result["docFiles"] += 1
            if TEST_FILE_RE.search(path):
                result["testFiles"] += 1
        result["net"] = result["added"] - result["removed"]
        result["docsInCode"] = get_in_code_docs_flag()
    return result


# ── Prompting ─────────────────────────────────────────────────────────────────

def err(text=""):
    try:
        sys.stderr.write(text + "\n")
        sys.stderr.flush()
    except Exception:
        pass


def err_nonl(text):
    try:
        sys.stderr.write(text)
        sys.stderr.flush()
    except Exception:
        pass


def read_line():
    """One line of user input, or None on EOF/error.
    FIX-W3: git runs hooks with stdin not attached to the terminal, so read
    from /dev/tty when it can be opened; fall back to sys.stdin."""
    try:
        with open("/dev/tty", "r") as tty:
            line = tty.readline()
    except Exception:
        try:
            line = sys.stdin.readline()
        except Exception:
            return None
    if line == "":
        return None
    return line.rstrip("\r\n")


# ── Main ──────────────────────────────────────────────────────────────────────

def main(argv):
    if len(argv) < 2:
        return 0
    commit_msg_file = argv[1]

    last_commit = get_last_commit_time()
    repo_root = git("rev-parse", "--show-toplevel").strip()
    log_folder = get_project_log_folder(repo_root)

    # ── Scan every detector's logs into one shared tally ──────────────────
    tally = new_tally()
    tools_used = []
    if scan_claude(log_folder, last_commit, tally):
        tools_used.append("claude")
    if scan_codex(repo_root, last_commit, tally):
        tools_used.append("codex")
    if scan_copilot(repo_root, last_commit, tally):
        tools_used.append("copilot")
    session_count = tally["sessions"]
    total_interactions = tally["interactions"]
    counts = tally["counts"]
    tests_executed = tally["tests"]
    session_summaries = tally["summaries"]

    # ── Read existing commit message ───────────────────────────────────────
    try:
        with open(commit_msg_file, "r", encoding="utf-8-sig", errors="replace", newline="") as fh:
            commit_msg = fh.read()
    except OSError:
        return 0
    if not commit_msg:
        return 0

    # Skip merge / rebase
    if re.match(r"\A(Merge |Rebase )", commit_msg, re.I):
        return 0
    # FIX-W2: idempotency — only a real trailer LINE counts, not the phrase
    # "AI-Usage:" appearing somewhere in the prose of the message.
    if re.search(r"^AI-Usage:", commit_msg, re.I | re.M):
        return 0

    # ── Detect AI tools used + optional note ───────────────────────────────
    dev_note = ""

    # Agent/orchestrator-driven commits: the Claude Code runtime sets these
    # env vars in the (sub)agent's shell; their presence here is proof.
    env = os.environ
    in_claude_session = (
        env.get("CLAUDECODE") == "1"
        or (env.get("AI_AGENT") or "").lower().startswith("claude-code")
        or bool(env.get("CLAUDE_CODE_ENTRYPOINT"))
    )
    if in_claude_session and "claude" not in tools_used:
        tools_used.append("claude")

    # Same idea for the other terminal agents: a commit made from inside their
    # sandbox/shell is attributed even when no log was found. (Codex var names
    # taken from its sandbox/CI docs — not verified on this machine; Copilot
    # CLI's are the documented COPILOT_CLI / GITHUB_COPILOT_CLI.)
    in_codex_session = any(
        env.get(k) for k in ("CODEX_SANDBOX", "CODEX_THREAD_ID", "CODEX_CI")
    )
    if in_codex_session and "codex" not in tools_used:
        tools_used.append("codex")
    in_copilot_session = any(env.get(k) for k in ("COPILOT_CLI", "GITHUB_COPILOT_CLI"))
    if in_copilot_session and "copilot" not in tools_used:
        tools_used.append("copilot")
    # Any agent-driven shell has no interactive tty — suppress the prompts.
    in_agent_session = in_claude_session or in_codex_session or in_copilot_session

    # FR-13: git config ai-tracking.selfdeclare <always|detected|off>
    self_declare = git("config", "ai-tracking.selfdeclare").strip().lower()
    if self_declare not in ("always", "detected", "off"):
        self_declare = "always"

    # Best-effort extra detectors
    if repo_root:
        aider_log = os.path.join(repo_root, ".aider.chat.history.md")
        if os.path.isfile(aider_log) and is_newer(aider_log, last_commit):
            if "aider" not in tools_used:
                tools_used.append("aider")
    cont_dir = Path(home_dir()) / ".continue" / "sessions"
    if cont_dir.exists():
        recent = False
        try:
            for p in cont_dir.rglob("*"):
                if p.is_file() and is_newer(p, last_commit):
                    recent = True
                    break
        except Exception:
            pass
        if recent and "continue" not in tools_used:
            tools_used.append("continue")

    if tools_used and not in_agent_session:
        order = list(CATEGORIES)
        detected = sorted(
            ((k, v) for k, v in counts.items() if v > 0),
            key=lambda kv: (-kv[1], order.index(kv[0])),
        )
        detected_summary = ", ".join("%s(%d)" % (k, v) for k, v in detected)
        err("")
        err("  AI activity detected: %s  (%d interactions, %d session(s))"
            % (", ".join(tools_used), total_interactions, session_count))
        if detected_summary:
            err("  Auto-categorised: " + detected_summary)
        if session_summaries:
            err("  Last session: " + session_summaries[-1])
        err("")
        if self_declare != "off":
            err_nonl("  Note (optional — press Enter to skip): ")
            raw = read_line()
            if raw is not None:
                dev_note = raw.strip()
            err("")
    elif self_declare == "always" and not in_agent_session:
        err("")
        err_nonl("  AI tool used this commit? (e.g. copilot, cursor, chatgpt, gemini — Enter for none): ")
        raw_tool = read_line()
        if raw_tool:
            t = raw_tool.strip().lower()
            if t and t != "none":
                tools_used.append(t)
        if tools_used:
            err_nonl("  Note (optional — press Enter to skip): ")
            raw = read_line()
            if raw is not None:
                dev_note = raw.strip()
        err("")

    # ── Build and append trailers ──────────────────────────────────────────
    code = get_staged_code_metrics()
    ai_usage = "yes" if tools_used else "no"

    trailers = [""]
    trailers.append("AI-Usage: " + ai_usage)
    if tools_used:
        uniq = {}
        for t in tools_used:
            uniq.setdefault(t.lower(), t)
        trailers.append("AI-Tool: " + ", ".join(uniq[k] for k in sorted(uniq)))
    trailers.append("AI-Sessions: %d" % session_count)
    trailers.append("AI-Interactions: %d" % total_interactions)
    for cat in sorted(counts):
        if counts[cat] > 0:
            trailers.append("AI-%s: %d" % (cat, counts[cat]))
    if tests_executed > 0:
        trailers.append("Tests-Executed: %d" % tests_executed)
    trailers.append("Lines-Added: %d" % code["added"])
    trailers.append("Lines-Removed: %d" % code["removed"])
    trailers.append("Lines-Net: %d" % code["net"])
    trailers.append("Docs-Files: %d" % code["docFiles"])
    trailers.append("Docs-InCode: " + code["docsInCode"])
    trailers.append("Tests-Files: %d" % code["testFiles"])
    if dev_note:
        clean = re.sub(r"[\r\n]", " ", dev_note)
        if len(clean) > 200:
            clean = clean[:197] + "..."
        trailers.append("AI-Note: " + clean)

    new_msg = commit_msg.rstrip() + "\n" + "\n".join(trailers) + "\n"
    with open(commit_msg_file, "w", encoding="utf-8", newline="") as fh:
        fh.write(new_msg)
    return 0


if __name__ == "__main__":
    try:
        main(sys.argv)
    except BaseException:
        # Tracking is best-effort — never block the commit.
        pass
    sys.exit(0)
