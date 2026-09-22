#!/usr/bin/env python3
"""Cross-platform PreToolUse guard for shunt-local.

Reads the hook payload on stdin and blocks large direct file reads (redirecting
to the bulk-reader skill) using each harness's native decision contract:

  * Antigravity : {"decision": "allow"|"deny", "reason": ...}
  * Claude/Codex: {"hookSpecificOutput": {"permissionDecision": "deny", ...}}
                  (nothing is emitted to allow, so no silent auto-approval)
  * Cursor      : {"permission": "allow"|"deny", "user_message"/"agent_message"}

Usage: shunt_guard.py [--harness auto|antigravity|claude|cursor] [--kind auto|read|bash]
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

# Share the write-safety policy with the CLI.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "lib"))
try:
    import paths as shunt_paths
except Exception:  # pragma: no cover - guard still works without the module
    shunt_paths = None


def native(path_str):
    """Translate MSYS-style paths to Windows paths when running on Windows."""
    if shunt_paths is not None and hasattr(shunt_paths, "to_native"):
        return shunt_paths.to_native(path_str)
    return path_str

DEFAULT_ENDPOINT = "http://127.0.0.1:8080/v1/chat/completions"
DEFAULT_MIN_LINES = 350
LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1", "0.0.0.0"}
READ_VERBS = ("cat", "head", "tail", "less", "more", "bat", "tac", "nl", "pr")
WRITE_TOOLS = {"write", "edit", "multiedit", "apply_patch", "write_to_file",
               "replace_file_content", "multi_replace_file_content", "notebook_edit"}


def load_config():
    home = os.path.expanduser("~")
    cfg = {"enabled": True, "min_lines": DEFAULT_MIN_LINES, "endpoint": DEFAULT_ENDPOINT,
           "view": True, "run": True}

    if os.path.exists(os.path.join(home, ".config", "shunt-local", "disabled")):
        cfg["enabled"] = False
        return cfg

    cfg_path = ""
    env_cfg = os.environ.get("SHUNT_CONFIG_PATH")
    if env_cfg and os.path.exists(env_cfg):
        cfg_path = env_cfg
    elif os.environ.get("SHUNT_ALLOW_PROJECT_CONFIG") == "true" and os.path.exists("./shunt.config.json"):
        cfg_path = "./shunt.config.json"
    else:
        user = os.path.join(home, ".config", "shunt-local", "config.json")
        if os.path.exists(user):
            cfg_path = user

    raw = {}
    if cfg_path:
        try:
            with open(cfg_path, encoding="utf-8") as handle:
                raw = json.load(handle)
        except Exception:
            raw = {}

    def pick(env, key, default):
        if env in os.environ and os.environ[env] != "":
            return os.environ[env]
        return raw.get(key, default)

    enabled = str(pick("SHUNT_ENABLED", "enabled", True)).lower()
    cfg["enabled"] = enabled not in ("false", "0", "no")

    try:
        cfg["min_lines"] = int(str(pick("SHUNT_MIN_LINES", "min_lines", DEFAULT_MIN_LINES)))
    except (TypeError, ValueError):
        cfg["min_lines"] = DEFAULT_MIN_LINES

    cfg["endpoint"] = str(pick("SHUNT_ENDPOINT", "endpoint", DEFAULT_ENDPOINT))
    cfg["api_key"] = os.environ.get("SHUNT_API_KEY") or str(raw.get("api_key") or "")
    if not cfg["api_key"] and os.environ.get("SHUNT_API_KEY_CMD"):
        import subprocess
        try:
            cfg["api_key"] = subprocess.run(
                os.environ["SHUNT_API_KEY_CMD"], shell=True, capture_output=True,
                text=True, timeout=5).stdout.strip()
        except Exception:
            cfg["api_key"] = ""

    hooks = raw.get("hooks") or {}
    view = pick("SHUNT_HOOK_VIEW_FILE", "view_file", hooks.get("view_file", True))
    run = pick("SHUNT_HOOK_RUN_COMMAND", "run_command", hooks.get("run_command", True))
    cfg["view"] = str(view).lower() not in ("false", "0", "no")
    cfg["run"] = str(run).lower() not in ("false", "0", "no")
    return cfg


def endpoint_allowed(endpoint):
    if "@" in endpoint:
        return False
    try:
        parts = urllib.parse.urlsplit(endpoint)
    except ValueError:
        return False
    scheme = (parts.scheme or "http").lower()
    if scheme not in ("http", "https"):
        return False
    host = (parts.hostname or "").lower()
    if host in LOCAL_HOSTS:
        return True
    if os.environ.get("SHUNT_ALLOW_REMOTE") != "true":
        return False
    return scheme == "https"


def is_online(cfg):
    if os.environ.get("__SHUNT_TEST_MOCK_ONLINE") == "1" or os.environ.get("SHUNT_MOCK_ONLINE") == "1":
        return True
    if os.environ.get("SHUNT_MOCK_ONLINE") == "0":
        return False
    endpoint = cfg["endpoint"]
    if not endpoint_allowed(endpoint):
        return False
    base = endpoint.rstrip("/")
    if base.endswith("/v1/chat/completions"):
        health = base[: -len("/v1/chat/completions")] + "/v1/models"
    else:
        health = base
    req = urllib.request.Request(health, method="GET")
    host = (urllib.parse.urlsplit(endpoint).hostname or "").lower()
    if cfg["api_key"] and host in LOCAL_HOSTS:
        req.add_header("Authorization", "Bearer " + cfg["api_key"])
    try:
        urllib.request.urlopen(req, timeout=0.5)
        return True
    except urllib.error.HTTPError:
        return True
    except Exception:
        return False


def emit(harness, decision, reason=""):
    if harness == "antigravity":
        out = {"decision": "allow"} if decision == "allow" else {"decision": "deny", "reason": reason}
    elif harness == "cursor":
        out = ({"permission": "allow"} if decision == "allow"
               else {"permission": "deny", "user_message": reason, "agent_message": reason})
    else:
        if decision == "allow":
            return
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                      "permissionDecision": "deny",
                                      "permissionDecisionReason": reason}}
    sys.stdout.write(json.dumps(out) + "\n")


def emit_context(harness, text):
    """Allow the tool but attach guidance (Claude/Codex only)."""
    if harness in ("antigravity", "cursor"):
        emit(harness, "allow")
        return
    out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": text}}
    sys.stdout.write(json.dumps(out) + "\n")


def count_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return sum(1 for _ in handle)
    except Exception:
        return 0


def detect_harness(payload, requested):
    if requested and requested != "auto":
        return requested
    env = os.environ.get("SHUNT_HOOK_HARNESS")
    if env:
        return env
    return "antigravity" if "toolCall" in payload else "claude"


def tool_info(payload):
    """Return (kind, name, args)."""
    if "toolCall" in payload and isinstance(payload["toolCall"], dict):
        call = payload["toolCall"]
        return call.get("name", ""), (call.get("args") or {})
    return payload.get("tool_name", ""), (payload.get("tool_input") or {})


def infer_kind(name):
    lowered = str(name).lower()
    if lowered in ("read", "read_file", "view_file", "file_read"):
        return "read"
    if lowered in ("bash", "shell", "run_command", "powershell", "exec", "exec_command", "terminal"):
        return "bash"
    if lowered in WRITE_TOOLS:
        return "write"
    if lowered in ("grep", "grep_search", "search"):
        return "grep"
    if lowered.startswith("mcp__") and re.search(r"(read|view|cat|get|fetch|list)", lowered):
        return "read"
    return "other"


def before_read_paths(payload):
    """Cursor beforeReadFile: the file plus any prompt attachments."""
    out = []
    if isinstance(payload.get("file_path"), str):
        out.append(payload["file_path"])
    for att in payload.get("attachments") or []:
        if isinstance(att, dict) and isinstance(att.get("file_path"), str):
            out.append(att["file_path"])
    return out


def is_sensitive_read(path_str):
    if shunt_paths is None:
        return False
    abs_p = shunt_paths.realpath(path_str)
    home = os.path.expanduser("~")
    if abs_p.startswith(home + os.sep + "."):
        return True
    for part in re.split(r"[\\/]+", abs_p):
        if part in shunt_paths.SENSITIVE_NAMES:
            return True
    return False



def resolve_working_dir(args, targets=None):
    """Resolve the effective working directory, accounting for harness daemons running in ~/.gemini."""
    for key in ("Cwd", "cwd", "working_dir", "workingDirectory"):
        if args.get(key):
            return os.path.realpath(str(args[key]))
    proc_cwd = os.path.realpath(os.getcwd())
    home = os.path.expanduser("~")
    gemini_dir = os.path.join(home, ".gemini")
    if proc_cwd.startswith(gemini_dir) or proc_cwd == home or proc_cwd.startswith("/tmp"):
        if targets:
            for t in targets:
                abs_t = os.path.realpath(t)
                cur = os.path.dirname(abs_t) if (os.path.isfile(abs_t) or not os.path.exists(abs_t)) else abs_t
                while cur and cur != os.path.dirname(cur) and cur != home:
                    if os.path.exists(os.path.join(cur, ".git")):
                        return cur
                    cur = os.path.dirname(cur)
        trusted_file = os.path.join(gemini_dir, "trustedFolders.json")
        if os.path.isfile(trusted_file) and targets:
            try:
                with open(trusted_file, "r", encoding="utf-8") as tf_handle:
                    tf = json.load(tf_handle)
                for t in targets:
                    abs_t = os.path.realpath(t)
                    for folder, status in tf.items():
                        if status == "TRUST_FOLDER" and (abs_t.startswith(folder + os.sep) or abs_t == folder):
                            return folder
            except Exception:
                pass
    return proc_cwd


def extract_write_paths(name, args):
    """Return the file paths a write tool intends to touch."""
    patch = str(args.get("command") or "") if "command" in args else ""
    if str(name).lower() == "apply_patch" or "***" in patch:
        found = set()
        for line in patch.splitlines():
            match = re.match(r"\*\*\* (?:Add|Update|Delete) File: (.+)", line)
            if match:
                found.add(match.group(1).strip())
            elif line.startswith("+++ ") or line.startswith("--- "):
                candidate = line[4:].strip()
                if candidate and candidate != "/dev/null":
                    found.add(re.sub(r"^[ab]/", "", candidate))
        if found:
            return sorted(found)
    for key in ("file_path", "filePath", "path", "TargetFile", "AbsolutePath", "absolutePath", "target_file"):
        if args.get(key):
            return [str(args[key])]
    return []


def read_path_from_args(args):
    for key in ("AbsolutePath", "absolutePath", "absolute_path", "file_path", "filePath", "path"):
        if key in args and args[key]:
            return str(args[key])
    return ""


def offset_from_args(args):
    for key in ("StartLine", "startLine", "start_line", "offset"):
        if key in args and args[key] not in (None, "", 0, "0"):
            return True
    for key in ("EndLine", "endLine", "end_line", "limit"):
        if key in args and args[key] not in (None, "", 0, "0"):
            return True
    return False


def extract_read_command_path(command):
    tokens = command.split()
    if not tokens:
        return ""
    if tokens[0] not in READ_VERBS:
        return ""
    args = tokens[1:]
    skip_next = False
    for token in args:
        if skip_next:
            skip_next = False
            continue
        if token in ("-n", "-c", "--lines", "--bytes"):
            if tokens[0] in ("head", "tail"):
                skip_next = True
            continue
        if token.startswith("-"):
            continue
        return token.strip("\"'")
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--harness", default="auto")
    parser.add_argument("--kind", default="auto")
    opts = parser.parse_args()

    if os.environ.get("__SHUNT_TEST_FORCE_CRASH") == "1":
        raise RuntimeError("Forced test crash")
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        payload = {}

    harness = detect_harness(payload if isinstance(payload, dict) else {}, opts.harness)
    name, args = tool_info(payload if isinstance(payload, dict) else {})
    kind = opts.kind if opts.kind != "auto" else infer_kind(name)

    def allow():
        emit(harness, "allow")
        return 0

    if kind == "other":
        return allow()

    cfg = load_config()
    if not cfg["enabled"] or (kind == "read" and not cfg["view"]) or (kind == "bash" and not cfg["run"]):
        return allow()

    if kind == "grep":
        # Guidance only: grep is a targeted read, but content output can still
        # pull many lines. Claude/Codex get additionalContext; others just allow.
        mode = str(args.get("output_mode") or args.get("outputMode") or "")
        if mode == "content":
            emit_context(harness,
                         "Grep with output_mode=content can pull many lines into context. "
                         "For whole-file questions prefer the /bulk-reader skill (bulk-read).")
        else:
            emit(harness, "allow")
        return 0

    if kind == "read":
        br_paths = before_read_paths(payload)
        if br_paths and not isinstance(payload.get("tool_input"), dict):
            if os.environ.get("SHUNT_ALLOW_SENSITIVE_READS") != "true":
                for p in br_paths:
                    if is_sensitive_read(p):
                        emit(harness, "deny",
                             f"shunt-local blocked reading protected file '{p}'. "
                             "Set SHUNT_ALLOW_SENSITIVE_READS=true to allow.")
                        return 0
            content = payload.get("content")
            lines = content.count("\n") if isinstance(content, str) else count_lines(native(br_paths[0]))
            if lines > cfg["min_lines"] and is_online(cfg):
                emit(harness, "deny",
                     f"File is {lines} lines (threshold: {cfg['min_lines']}). Use the /bulk-reader "
                     "skill to delegate this read to your local LLM instead of reading it directly.")
                return 0
            return allow()
        path = read_path_from_args(args)
        if not path or offset_from_args(args):
            return allow()
        if os.environ.get("SHUNT_ALLOW_SENSITIVE_READS") != "true" and is_sensitive_read(path):
            emit(harness, "deny",
                 f"shunt-local blocked reading protected file '{path}'. "
                 "Set SHUNT_ALLOW_SENSITIVE_READS=true to allow.")
            return 0
        if not os.path.isfile(native(path)):
            return allow()
        lines = count_lines(native(path))
        if lines <= cfg["min_lines"]:
            return allow()
        if not is_online(cfg):
            return allow()
        reason = (f"File is {lines} lines (threshold: {cfg['min_lines']}). Use the /bulk-reader skill "
                  "to delegate this read to your local LLM instead of reading it directly. If you need "
                  "exact content for editing, re-read with a line range for just the section you need.")
        emit(harness, "deny", reason)
        return 0

    if kind == "write":
        targets = extract_write_paths(name, args)
        if not targets or shunt_paths is None:
            return allow()
        allow_outside = os.environ.get("SHUNT_ALLOW_WRITES_OUTSIDE_CWD") == "true"
        allow_sensitive = os.environ.get("SHUNT_ALLOW_SENSITIVE_WRITES") == "true"
        cwd = resolve_working_dir(args, targets)
        home = os.path.expanduser("~")
        allowed = {shunt_paths.realpath(t) for t in targets}
        for target in targets:
            if not shunt_paths.is_safe_write(target, cwd=cwd, home=home,
                                             allow_outside=allow_outside,
                                             allow_sensitive=allow_sensitive,
                                             allowed_targets=allowed):
                reason = ("shunt-local blocked this write: "
                          + shunt_paths.explain(target, cwd=cwd, home=home,
                                                allow_outside=allow_outside,
                                                allow_sensitive=allow_sensitive,
                                                allowed_targets=allowed)
                          + ". Set SHUNT_ALLOW_SENSITIVE_WRITES=true or "
                            "SHUNT_ALLOW_WRITES_OUTSIDE_CWD=true if this is intentional.")
                emit(harness, "deny", reason)
                return 0
        return allow()

    # kind == "bash"
    command = str(args.get("command") or args.get("CommandLine") or "")
    if not command or "|" in command or ">" in command:
        return allow()
    path = extract_read_command_path(command)
    if not path or not os.path.isfile(native(path)):
        return allow()
    lines = count_lines(native(path))
    if lines <= cfg["min_lines"]:
        return allow()
    if not is_online(cfg):
        return allow()
    reason = (f"File is {lines} lines (threshold: {cfg['min_lines']}). Use the /bulk-reader skill "
              "to delegate this read to your local LLM instead of cat/head/tail.")
    emit(harness, "deny", reason)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        if os.environ.get("SHUNT_DEBUG") == "true":
            import traceback
            traceback.print_exc(file=sys.stderr)
        # Fail-open: never block host harness or other plugins on internal error.
        harness = "antigravity" if ("--harness" in sys.argv and "antigravity" in sys.argv) else "claude"
        emit(harness, "allow")
        raise SystemExit(0)
