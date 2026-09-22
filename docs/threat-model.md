# Threat model

`shunt-local` sits between a **cloud AI agent** and the **local operating
system**. This document lists what we are trying to protect, from whom, and
which controls apply. It is the input for the external audit (see
`docs/ROADMAP.md`, Phase 4).

## Assets

| Asset | Why it matters |
| :--- | :--- |
| Developer workstation (files, shells, credentials) | The delegation tools write files and run commands on it |
| Source code and secrets (`.env`, `~/.ssh`, cloud credentials) | Sent to the local LLM and possibly a remote endpoint |
| Cloud agent context | Injected text can steer the agent into unsafe actions |
| Update channel | A compromised upstream becomes code execution on every machine |

## Trust boundaries

```
[ repository content ] --untrusted--> [ local LLM ] --output--> [ cloud agent ]
                                                                            |
                                                                            v
                                                            [ shunt-local tools ]
                                                                            |
                                                          [ sandbox / OS / FS ]
```

- Repository content is **untrusted** (dependencies, PRs, downloaded archives).
- The cloud agent is **prompt-injectable** by that content.
- The local LLM output is **untrusted data**, never instructions.
- The operator's environment variables (`SHUNT_ALLOW_*`) are **trusted**.

## Adversaries

1. **Malicious repository** — carries a prompt injection the local model echoes
   back into the agent context.
2. **Prompt-injected agent** — calls `shunt-local exec` / `code-write` with
   attacker-chosen instructions, targets, or commands.
3. **Local attacker (same user or other user)** — tampers with the clone, reads
   process arguments, or races a symlink.
4. **Compromised upstream / update channel** — pushes a backdoored commit.

## STRIDE summary

| Threat | Scenario | Control |
| :--- | :--- | :--- |
| Spoofing | Endpoint impersonation | Endpoint allowlist (localhost / opted-in HTTPS), no userinfo |
| Tampering | Generated code written to `.git/`, CI, lockfiles | Sensitive-path denylist, approval gate, audit log |
| Repudiation | No record of delegated actions | JSONL audit log (0600) |
| Information disclosure | Secrets in the payload; API key in `ps` | Secret redaction, `--config` auth, read confinement |
| Denial of service | Huge files, slow endpoint, unbounded retries | Line threshold, timeouts, retry cap |
| Elevation of privilege | `--test-cmd` shell, network exfiltration | No-shell allowlist + OS sandbox, no network by default |

## Controls (see SECURITY.md for detail)

Command sandboxing, strict token allowlist, explicit approval before
write/execute, path confinement, secret redaction, key sources, verifiable
updates, cross-platform guard.

## Out of scope

- The security of the local inference server (llama.cpp/Ollama/vLLM) itself.
- Harness code (Claude Code, Cursor, Codex, OpenCode, Antigravity).
- Malware already running with the user's privileges.

## Residual risk

See "Known Limitations" in `SECURITY.md`: sandbox is best-effort, the read gate
does not cover every read path, and the project has not yet had an independent
audit.
