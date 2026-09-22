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

1. **Endpoint Validation**: ANY non-localhost endpoint (HTTP **or** HTTPS) is blocked by default. Set `SHUNT_ALLOW_REMOTE=true` to explicitly allow remote endpoints; remote endpoints are only accepted over HTTPS (plain HTTP is always rejected). URLs containing embedded credentials (`http://127.0.0.1:8080@evil.com`) are rejected.
2. **API Key Protection**: The API key is only ever sent to localhost endpoints and is never transmitted to remote hosts (including the health check).
3. **Command Validation**: Verification and rollback commands are checked against a blocklist of dangerous patterns **and** a default-deny on shell metacharacters (`;`, `|`, `&`, `$(`, backticks). The `--allow-unsafe` escape hatch only works when `SHUNT_ALLOW_UNSAFE=true` is set in the operator's environment (a prompt-injected agent cannot enable it by itself).
4. **Path Traversal Prevention**: ALL file writes (including explicitly declared `--files` targets) are restricted to the current working directory with symlinks resolved. Home dotfiles (`~/.ssh`, `~/.gnupg`, etc.) are always protected. Set `SHUNT_ALLOW_WRITES_OUTSIDE_CWD=true` to opt out for legitimate edge cases.
5. **Temp File Security**: All temporary files are created with `umask 077` to prevent race-condition reads.
6. **Config Poisoning Protection**: Project-level `shunt.config.json` files are **ignored** unless `SHUNT_ALLOW_PROJECT_CONFIG=true` is set. A project cannot silently redirect your "local" inference to a remote server.
7. **Fail-Open Design**: When the local LLM is offline, hooks allow normal cloud agent operation — they never block the developer's workflow. Disallowed endpoints are treated as offline (fail-closed for the network, fail-open for the workflow).
8. **Supply-Chain Hardening**: `shunt-update` is a dry-run by default (`--yes` to apply) and refuses to pull from untrusted remotes unless `SHUNT_ALLOW_UNTRUSTED_REMOTE=true`.

### Opt-in escape hatches (all off by default)

| Environment variable | Effect |
| :--- | :--- |
| `SHUNT_ALLOW_REMOTE=true` | Allow remote LLM endpoints (HTTPS only). |
| `SHUNT_ALLOW_PROJECT_CONFIG=true` | Honor a repo-local `./shunt.config.json`. |
| `SHUNT_ALLOW_UNSAFE=true` | Let `--allow-unsafe` bypass command validation. |
| `SHUNT_ALLOW_WRITES_OUTSIDE_CWD=true` | Let `--files` targets be written outside the working directory. |
| `SHUNT_ALLOW_UNTRUSTED_REMOTE=true` | Let `shunt-update` pull from non-GitHub/GitLab/Bitbucket remotes. |

### Known Limitations

- **No sandboxing**: Commands passed to `--test-cmd` and `--rollback-cmd` execute directly on the host OS. The blocklist + metacharacter default-deny stop obvious attacks but cannot guarantee safety against sophisticated payloads. Consider using `firejail` or `bwrap` for high-security environments.
- **Compound test commands require opt-in**: Legitimate shell compound commands (pipes, `&&`, variable expansion) are blocked by default; enable them deliberately with `--allow-unsafe` + `SHUNT_ALLOW_UNSAFE=true`.
- **Bash hook coverage**: The bash read interceptor covers `cat`, `head`, `tail`, `less`, `more`, `bat`, `tac`, `nl`, and `pr`. Other file-reading commands (e.g., `awk`, `sed`, `python -c`) are not intercepted.
- **Cursor integration**: Cursor support relies on `.cursorrules` rather than hard hook interception. The agent may choose to ignore delegation instructions.

## Configuration Security

- Configuration directory (`~/.config/shunt-local/`) is created with `0700` permissions.
- Configuration file (`config.json`) is created with `0600` permissions.
- API keys stored in `config.json` are protected by filesystem permissions.
- Run `./uninstall.sh --purge` to securely remove all configuration including stored API keys.
