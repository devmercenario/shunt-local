#!/usr/bin/env python3
"""Redact obvious secrets from a text stream (stdin -> stdout).

Prints a summary of what was redacted to stderr. Exit code is always 0; the
caller decides whether a detection should block the request.
"""
import re
import sys

PRIVATE_KEY = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.S,
)
PATTERNS = [
    ("private-key", PRIVATE_KEY),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\b")),
    ("npm-token", re.compile(r"\bnpm_[A-Za-z0-9]{36}\b")),
    ("anthropic-key", re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{20,}\b")),
    ("openai-key", re.compile(r"\bsk-[A-Za-z0-9]{20,}\b")),
]
ASSIGN = re.compile(
    r"(?i)\b(pass(?:word|wd)?|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)"
    r"\b(\s*[:=]\s*)[\"']?([^\s\"',;]{6,})[\"']?"
)


def redact_assign(match: "re.Match[str]") -> str:
    return f"{match.group(1)}{match.group(2)}[REDACTED]"


def main() -> int:
    # Use binary streams so Windows does not translate \n to \r\n (which would
    # corrupt payloads and break exact-content assertions).
    data = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    counts: dict[str, int] = {}
    for name, pattern in PATTERNS:
        data, n = pattern.subn(lambda _m, name=name: f"[REDACTED:{name}]", data)
        if n:
            counts[name] = counts.get(name, 0) + n
    data, n = ASSIGN.subn(redact_assign, data)
    if n:
        counts["secret-assignment"] = counts.get("secret-assignment", 0) + n
    sys.stdout.buffer.write(data.encode("utf-8"))
    if counts:
        summary = ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))
        sys.stderr.write(f"{summary}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
