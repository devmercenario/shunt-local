#!/usr/bin/env python3
"""Shared write-safety rules for shunt-local (used by the CLI and the guards).

Keeping this in one module means task-exec, the PreToolUse guard and any future
harness adapter enforce exactly the same policy.
"""
import os

# Files/directories whose modification enables code execution, credential theft
# or CI/supply-chain persistence. Writable inside the CWD, but not by default.
SENSITIVE_NAMES = {
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


def realpath(path: str) -> str:
    return os.path.realpath(os.path.abspath(path))


def is_sensitive_path(abs_path: str, cwd: str) -> bool:
    try:
        rel = os.path.relpath(abs_path, cwd)
    except ValueError:
        return True
    if rel == ".." or rel.startswith(".." + os.sep):
        return True
    for part in rel.split(os.sep):
        if part in SENSITIVE_NAMES:
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
