#!/usr/bin/env python3
"""Shared write-safety rules for shunt-local (used by the CLI and the guards).

Keeping this in one module means task-exec, the PreToolUse guard and any future
harness adapter enforce exactly the same policy.
"""
import os
import re
import shutil
import subprocess

# Canonical list (scripts/lib/sensitive-names.txt). The embedded set is a
# fallback for when paths.py is used without its sibling data file.
_FALLBACK_SENSITIVE = {
    ".git", ".github", ".gitlab", ".circleci", ".husky", ".githooks",
    ".env", ".env.local", ".env.production", ".npmrc", ".pypirc", ".netrc",
    ".gitmodules", ".gitattributes", ".bashrc", ".profile", ".zshrc",
    "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock",
    "pnpm-lock.yaml", "Makefile", "makefile", "GNUmakefile", "Dockerfile",
    "docker-compose.yml", "docker-compose.yaml", "Gemfile", "Gemfile.lock",
    "Cargo.toml", "Cargo.lock", "go.mod", "go.sum", "pyproject.toml",
    "setup.py", "setup.cfg", "pytest.ini", "tox.ini", "requirements.txt",
    "poetry.lock", "shunt.config.json", "install.sh", "shunt-update",
    "authorized_keys", "id_rsa", "id_ed25519", "credentials",
}


def _load_sensitive_names() -> set:
    data_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sensitive-names.txt")
    try:
        with open(data_file, encoding="utf-8") as handle:
            names = {line.strip() for line in handle
                     if line.strip() and not line.lstrip().startswith("#")}
        return names or set(_FALLBACK_SENSITIVE)
    except OSError:
        return set(_FALLBACK_SENSITIVE)


SENSITIVE_NAMES = _load_sensitive_names()


def is_sensitive_name(name: str) -> bool:
    return name in SENSITIVE_NAMES or name.startswith(".env.")


def to_native(path: str) -> str:
    """Translate an MSYS/Cygwin-style path to a Windows path when needed.

    On Windows, agents and the test harness may hand us POSIX paths such as
    ``/tmp/x`` or ``/c/Users/...``; Python cannot open those directly.
    """
    if os.name == "nt" and path.startswith("/") and shutil.which("cygpath"):
        try:
            out = subprocess.run(["cygpath", "-w", "--", path],
                                 capture_output=True, text=True)
            return out.stdout.strip() or path
        except Exception:
            return path
    return path


def realpath(path: str) -> str:
    return os.path.realpath(os.path.abspath(to_native(path)))


def _parts(value: str):
    """Split on either separator so Windows paths are understood on any OS."""
    return [p for p in re.split(r"[\\/]+", value) if p]


def is_sensitive_path(abs_path: str, cwd: str) -> bool:
    try:
        rel = os.path.relpath(abs_path, cwd)
    except ValueError:
        return True
    if rel == ".." or rel.startswith(".." + os.sep):
        return True
    for part in _parts(rel):
        if is_sensitive_name(part):
            return True
    return False


def is_safe_write(path, cwd=None, home=None, allow_outside=False,
                  allow_sensitive=False, allowed_targets=None) -> bool:
    cwd = os.path.realpath(cwd or os.getcwd())
    home = home or os.path.expanduser("~")
    abs_t = realpath(path)

    if allow_outside and allowed_targets and abs_t in allowed_targets:
        if abs_t.startswith(home + os.sep + "."):
            return False
        if not allow_sensitive and is_sensitive_path(abs_t, cwd):
            return False
        return True

    if not (abs_t.startswith(cwd + os.sep) or abs_t == cwd):
        return False
    if abs_t.startswith(home + os.sep + "."):
        return False
    if not allow_sensitive and is_sensitive_path(abs_t, cwd):
        return False
    return True


def explain(path, cwd=None, home=None, allow_outside=False, allow_sensitive=False,
            allowed_targets=None) -> str:
    """Human-readable reason when is_safe_write() returns False."""
    cwd = os.path.realpath(cwd or os.getcwd())
    home = home or os.path.expanduser("~")
    abs_t = realpath(path)
    inside = abs_t.startswith(cwd + os.sep) or abs_t == cwd
    if not inside and not allow_outside:
        return f"'{path}' resolves outside the working directory ({abs_t})"
    if abs_t.startswith(home + os.sep + "."):
        return f"'{path}' is a home dotfile"
    if not allow_sensitive and is_sensitive_path(abs_t, cwd):
        return f"'{path}' is a protected VCS/CI/credential/build file"
    return f"'{path}' is not an allowed target"
