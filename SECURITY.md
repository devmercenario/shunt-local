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

### Opt-in escape hatches (all off by default)

| Environment variable | Effect |
| :--- | :--- |
| `SHUNT_ALLOW_REMOTE=true` | Allow remote LLM endpoints (HTTPS only). |
| `SHUNT_ALLOW_PROJECT_CONFIG=true` | Honor a repo-local `./shunt.config.json`. |
| `SHUNT_ALLOW_UNSAFE=true` | Let `--allow-unsafe` bypass command validation. |
| `SHUNT_ALLOW_WRITES_OUTSIDE_CWD=true` | Let `--files` targets be written outside the working directory. |
| `SHUNT_ALLOW_SENSITIVE_WRITES=true` | Allow writes to protected VCS/CI/credential/build files (`.git/`, `.github/`, `.env`, `package.json`, …). |
| `SHUNT_ALLOW_UNTRUSTED_REMOTE=true` | Let `shunt-update` pull from non-GitHub/GitLab/Bitbucket remotes. |

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

- **No sandboxing**: Commands passed to `--test-cmd` and `--rollback-cmd` execute directly on the host OS. Safe mode avoids a shell entirely and rejects network/reader/destructive programs, but a legitimate test runner (e.g. `npm test`, `pytest`) still executes project code. Consider using `firejail` or `bwrap` for high-security environments.
- **Compound test commands require opt-in**: Legitimate shell compound commands (pipes, `&&`, variable expansion) are blocked by default; enable them deliberately with `--allow-unsafe` + `SHUNT_ALLOW_UNSAFE=true`.
- **Untrusted model output**: The local model reads untrusted repository content and its output is labelled, not sanitized. A prompt injection embedded in a file can be reproduced in the model's reply; treat all delegated output as data and never let it drive command or file-write decisions without review.
- **Bash hook coverage**: The bash read interceptor covers `cat`, `head`, `tail`, `less`, `more`, `bat`, `tac`, `nl`, and `pr`. Other file-reading commands (e.g., `awk`, `sed`, `python -c`) are not intercepted.
- **Cursor integration**: the installer registers native Cursor `preToolUse` hooks, but Cursor also offers advisory rules. The agent may still ignore the delegation guidance, and Cursor's `@`-style context attachments are not gated. Treat Cursor enforcement as best-effort.
- **Coverage gaps**: the read gate only matches `Read`/`view_file` and shell reads. It does not intercept `Grep`, `Write`/`Edit`, MCP tools, or files pulled in via `@`/context attachments (the harness runs no `PreToolUse` hook for those). On Codex only the `Bash` path is gated; Codex file reads through MCP are not.

## Configuration Security

- Configuration directory (`~/.config/shunt-local/`) is created with `0700` permissions.
- Configuration file (`config.json`) is created with `0600` permissions.
- API keys stored in `config.json` are protected by filesystem permissions.
- Run `./uninstall.sh --purge` to securely remove all configuration including stored API keys.
