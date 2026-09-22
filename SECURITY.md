# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in `shunt-local`, please report it responsibly:

1. **DO NOT** open a public GitHub issue for security vulnerabilities.
2. Email the maintainers at the address listed in the repository, or use [GitHub's private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability).
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

We will acknowledge receipt within 48 hours and aim to release a patch within 7 days for critical issues.

## Security Architecture

### Trust Boundaries

`shunt-local` operates at the boundary between **cloud AI agents** (Google Antigravity, Claude Code) and the **local operating system**. This makes security critical:

```
Cloud Agent (untrusted input via prompt injection)
        │
        ▼
  shunt-local hooks & scripts (trust boundary enforcement)
        │
        ▼
  Local LLM (localhost only by default)
        │
        ▼
  File System (CWD-restricted writes)
```

### Built-in Security Controls

1. **Endpoint Validation**: ANY non-localhost endpoint (HTTP **or** HTTPS) is blocked by default. Set `SHUNT_ALLOW_REMOTE=true` to explicitly allow remote endpoints; remote endpoints are only accepted over HTTPS (plain HTTP is always rejected). Only the `http`/`https` schemes are accepted at all — `file://`, `ftp://`, `gopher://` and other schemes are rejected. URLs containing embedded credentials (`http://127.0.0.1:8080@evil.com`) are rejected.
2. **API Key Protection**: The API key is passed to `curl` via a `0600` `--config` file rather than on the command line, so it is not exposed to other local users through `ps` / `/proc/<pid>/cmdline`. The health-check probe only sends the key to localhost. On the actual inference request the key is sent to the endpoint you configured — including a remote HTTPS endpoint you explicitly opted into with `SHUNT_ALLOW_REMOTE=true` — since that endpoint may require authentication.
3. **Command Validation**: `--test-cmd` / `--rollback-cmd` are tokenized literally and executed **without a shell**, so redirections, pipes, `;`, `&&`, `$(...)`, backticks, newlines, globbing and variable expansion have no effect. Each token must also match a strict allowlist (`A-Za-z0-9_./:=@+-`), and a denylist rejects network clients (`curl`, `wget`, `ssh`, …), secret readers (`cat`, `grep`, `sed`, …) and destructive tools (`rm`, `dd`, `chmod`, …). The `--allow-unsafe` escape hatch (which requires `SHUNT_ALLOW_UNSAFE=true` in the operator's environment) is the only path that uses a shell. A prompt-injected agent cannot enable it by itself.
4. **Path Traversal Prevention**: ALL file writes (including explicitly declared `--files` targets) are restricted to the current working directory with symlinks resolved. Home dotfiles (`~/.ssh`, `~/.gnupg`, `~/.bashrc`, …) are always protected, and VCS/CI/credential/build files (`.git/`, `.github/`, `.env`, `package.json`, lockfiles, `Makefile`, `Dockerfile`, …) are refused by default. Set `SHUNT_ALLOW_WRITES_OUTSIDE_CWD=true` to write outside the project tree, or `SHUNT_ALLOW_SENSITIVE_WRITES=true` to allow the protected files above.
5. **Temp File Security**: All temporary files are created with `umask 077` to prevent race-condition reads.
6. **Config Poisoning Protection**: Project-level `shunt.config.json` files are **ignored** unless `SHUNT_ALLOW_PROJECT_CONFIG=true` is set. A project cannot silently redirect your "local" inference to a remote server.
7. **Fail-Open Design**: When the local LLM is offline, hooks allow normal cloud agent operation — they never block the developer's workflow. Disallowed endpoints are treated as offline (fail-closed for the network, fail-open for the workflow).
8. **Supply-Chain Hardening**: `shunt-update` is a dry-run by default (`--yes` to apply) and refuses to pull from untrusted remotes unless `SHUNT_ALLOW_UNTRUSTED_REMOTE=true`. The remote host is compared by **exact hostname**, so spoofed hosts such as `github.com.evil.example` are rejected. The installer refuses to register a repository as trusted (`trustedFolders.json`) when it is not owned by you or is writable by group/other, and `uninstall.sh` removes the trust entry it added.
9. **Untrusted Output Labelling**: Local-model and command output is derived from untrusted repository content and is explicitly labelled as such in `bulk-read` output and the `task-exec` JSON payload (`untrusted_notice`). Agents must treat it as data, never as instructions.
10. **Command Sandboxing**: `--test-cmd` / `--rollback-cmd` are executed inside an OS sandbox when one is available (`bwrap`, `firejail`, or `docker`/`podman` via `SHUNT_SANDBOX`). The sandbox uses a read-only root, a read-write bind of the working directory only, a private `/tmp`, and **no network** unless `SHUNT_SANDBOX_NETWORK=true`. `SHUNT_SANDBOX_STRICT=true` refuses to run at all when no sandbox is available.
11. **Explicit Approval Before Writing/Executing**: `task-exec` and `code-write` never auto-apply. `--apply-mode confirm` (the default) returns a `needs_confirmation` plan to a non-interactive caller and prompts interactively; `--dry-run` stages changes and returns a proposed diff without writing or running anything. Auto-apply requires `--yes` / `SHUNT_ASSUME_YES=true`.
12. **Read Confinement**: `bulk-read`, `code-write` and `task-exec` refuse to read files outside the working directory (`SHUNT_ALLOW_READS_OUTSIDE_CWD=true` opts out).
13. **Secret Redaction**: Every outbound payload is scrubbed of private keys, cloud/API tokens and secret assignments (`scripts/lib/redact.py`). `SHUNT_BLOCK_ON_SECRETS=true` refuses the request instead of sending it.
14. **Key Sources**: `SHUNT_API_KEY_CMD` (e.g. a keyring lookup) or `SHUNT_API_KEY_FILE` resolve the key when `SHUNT_API_KEY` is unset, so secrets need not be stored in `config.json`.
15. **Audit Log**: `task-exec` and `code-write` append JSONL records (tool, status, files, sandbox, apply-mode) to `~/.config/shunt-local/audit.log` (0600). Summarize with `shunt-local stats`.
16. **Verifiable Updates**: `shunt-update --verify` (or `SHUNT_UPDATE_REQUIRE_SIGNATURE=true`) refuses to apply a fetched ref unless it carries a valid commit signature or a cosign-signed `SHA256SUMS`. Releases are built and signed in CI.
17. **Cross-Platform Guard**: the PreToolUse guard is `hooks/shunt_guard.py` (Python 3), so the same gate runs on Windows, macOS and Linux. The bash scripts under `hooks/` are thin wrappers.

### Opt-in escape hatches (all off by default)

| Environment variable | Effect |
| :--- | :--- |
| `SHUNT_ALLOW_REMOTE=true` | Allow remote LLM endpoints (HTTPS only). |
| `SHUNT_ALLOW_PROJECT_CONFIG=true` | Honor a repo-local `./shunt.config.json`. |
| `SHUNT_ALLOW_UNSAFE=true` | Let `--allow-unsafe` bypass command validation. |
| `SHUNT_ALLOW_WRITES_OUTSIDE_CWD=true` | Let `--files` targets be written outside the working directory. |
| `SHUNT_ALLOW_SENSITIVE_WRITES=true` | Allow writes to protected VCS/CI/credential/build files (`.git/`, `.github/`, `.env`, `package.json`, …). |
| `SHUNT_ALLOW_UNTRUSTED_REMOTE=true` | Let `shunt-update` pull from non-GitHub/GitLab/Bitbucket remotes. |
| `SHUNT_ALLOW_READS_OUTSIDE_CWD=true` | Let `bulk-read`/`code-write`/`task-exec` read files outside the working directory. |
| `SHUNT_SANDBOX=none` | Disable command sandboxing (default `auto`). |
| `SHUNT_SANDBOX_NETWORK=true` | Keep network access inside the sandbox (off by default). |
| `SHUNT_SANDBOX_STRICT=true` | Refuse to run when no sandbox backend is available. |
| `SHUNT_APPLY_MODE=auto` | Skip the confirmation gate (the CLI `--yes` is equivalent). |
| `SHUNT_REDACT_SECRETS=false` | Disable secret redaction of outbound payloads. |
| `SHUNT_BLOCK_ON_SECRETS=true` | Refuse to send a payload when secrets are detected. |
| `SHUNT_UPDATE_REQUIRE_SIGNATURE=true` | Require a verified signature before applying an update. |

### Harness compatibility

The hooks are emitted in each harness's native `PreToolUse` contract:

| Harness | Hook registration | Allow | Deny |
| :--- | :--- | :--- | :--- |
| Antigravity (`agy`) | `~/.gemini/config/hooks.json` | `{"decision":"allow"}` | `{"decision":"deny","reason":…}` |
| Claude Code | plugin `hooks/hooks.json` (`Read`, `Bash\|PowerShell`) | (no output → normal permission flow) | `hookSpecificOutput.permissionDecision:"deny"` |
| Codex | `.codex-plugin/plugin.json` → `hooks/hooks.json` (`Bash`) | (no output) | `hookSpecificOutput.permissionDecision:"deny"` |
| Cursor | `~/.cursor/hooks.json` (`preToolUse` `Read`/`Shell`) | `{"permission":"allow"}` | `{"permission":"deny","user_message":…,"agent_message":…}` |
| OpenCode | `~/.config/opencode/plugins/shunt-local.ts` | return normally | `throw new Error(…)` |

On the allow path, Claude Code and Codex receive **no decision** rather than `permissionDecision:"allow"`, so the plugin never silently auto-approves a tool call and the normal permission prompt still applies.

### Known Limitations

- **Sandbox is best-effort**: when `bwrap`/`firejail`/docker are unavailable the command still runs on the host (unless `SHUNT_SANDBOX_STRICT=true`), and a legitimate test runner executes project code inside the sandbox. Network and filesystem are restricted, but the sandbox is not a kernel-level guarantee for every platform.
- **No independent audit yet**: the controls above are self-assessed and covered by 279 evals, but the project has not undergone an external security review.
- **Compound test commands require opt-in**: Legitimate shell compound commands (pipes, `&&`, variable expansion) are blocked by default; enable them deliberately with `--allow-unsafe` + `SHUNT_ALLOW_UNSAFE=true`.
- **Untrusted model output**: The local model reads untrusted repository content and its output is labelled and redacted, not semantically sanitized. A prompt injection embedded in a file can be reproduced in the model's reply; treat all delegated output as data and never let it drive command or file-write decisions without review.
- **Read-gate coverage**: The read interceptor covers `Read`/`view_file` and shell reads (`cat`, `head`, `tail`, `less`, `more`, `bat`, `tac`, `nl`, `pr`). Other file-reading commands (e.g. `awk`, `sed`, `python -c`) are not intercepted.
- **Cursor integration**: the installer registers native Cursor `preToolUse` hooks and `beforeReadFile` (which gates `@`/attachment paths), but Cursor also offers advisory rules. Treat Cursor enforcement as best-effort.
- **Coverage gaps**: the gate covers `Read`/`view_file`, shell reads, `Write`/`Edit` (sensitive paths only), and `beforeReadFile`. `Grep` is *advisory* on Claude (an `additionalContext` hint, not a block). Claude `@`-references bypass PreToolUse, so they are mitigated by the plugin `settings.json` deny rules rather than a hook. MCP tools are matched by name (read-like names) and are otherwise best-effort.
- **Update verification**: `shunt-update --verify` accepts a signed commit or a cosign-signed `SHA256SUMS`; the latter requires the release artifacts (`SHA256SUMS`, `.sig`, `.pem`) to be present in the repository. Without a signed commit, download the release artifacts before verifying.

## Configuration Security

- Configuration directory (`~/.config/shunt-local/`) is created with `0700` permissions.
- Configuration file (`config.json`) is created with `0600` permissions.
- API keys stored in `config.json` are protected by filesystem permissions.
- Run `./uninstall.sh --purge` to securely remove all configuration including stored API keys.
