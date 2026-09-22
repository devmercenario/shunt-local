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

1. **Endpoint Validation**: Non-localhost HTTP endpoints are blocked by default. Set `SHUNT_ALLOW_REMOTE=true` to override.
2. **API Key Protection**: API keys cannot be sent over plain HTTP to non-localhost endpoints.
3. **Command Validation**: Verification and rollback commands are checked against a blocklist of dangerous shell patterns. Use `--allow-unsafe` to bypass for legitimate edge cases.
4. **Path Traversal Prevention**: File writes are restricted to the current working directory. Home dotfiles (`~/.ssh`, `~/.gnupg`, etc.) are explicitly protected.
5. **Temp File Security**: All temporary files are created with `umask 077` to prevent race-condition reads.
6. **Config Poisoning Warning**: Project-level `shunt.config.json` files trigger a visible stderr warning.
7. **Fail-Open Design**: When the local LLM is offline, hooks allow normal cloud agent operation — they never block the developer's workflow.

### Known Limitations

- **No sandboxing**: Commands passed to `--test-cmd` and `--rollback-cmd` execute directly on the host OS. The blocklist prevents obvious attacks but cannot guarantee safety against sophisticated payloads. Consider using `firejail` or `bwrap` for high-security environments.
- **Bash hook coverage**: The bash read interceptor covers `cat`, `head`, `tail`, `less`, `more`, `bat`, `tac`, `nl`, and `pr`. Other file-reading commands (e.g., `awk`, `sed`, `python -c`) are not intercepted.
- **Cursor integration**: Cursor support relies on `.cursorrules` rather than hard hook interception. The agent may choose to ignore delegation instructions.

## Configuration Security

- Configuration directory (`~/.config/shunt-local/`) is created with `0700` permissions.
- Configuration file (`config.json`) is created with `0600` permissions.
- API keys stored in `config.json` are protected by filesystem permissions.
- Run `./uninstall.sh --purge` to securely remove all configuration including stored API keys.
