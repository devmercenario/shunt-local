# External audit brief

Preparation package for an independent security review of `shunt-local`.
The engagement, remediation SLAs and public advisory are owner actions; this
document is what an auditor needs to start.

## Target

- Repository: `https://github.com/devmercenario/shunt-local`
- Target commit/tag: the `v0.1.0` tag (record the exact SHA at engagement time).
- Artifacts provided: repository archive, SBOM (`shunt-local.spdx.json` from the
  release workflow), `docs/threat-model.md`, `SECURITY.md`, this brief.

## Scope

In scope:

- The command allowlist and shell-free execution (`scripts/lib/local-llm.sh`).
- The OS sandbox (`shunt_run_command`, bwrap/firejail/docker backends).
- Path confinement and the sensitive-path policy (`scripts/lib/paths.py`).
- Secret redaction (`scripts/lib/redact.py`) and key handling.
- The PreToolUse guard (`hooks/shunt_guard.py`) and the per-harness decision
  contracts (Antigravity, Claude Code, Codex, Cursor).
- The OpenCode plugin (`plugins/opencode/shunt-local.ts`).
- Update and release integrity (`scripts/lib/update-verify.sh`, CI workflows).
- Cross-platform behaviour (Windows/Git Bash).

Out of scope (state explicitly to avoid duplicate findings):

- The local inference server (llama.cpp/Ollama/vLLM) itself.
- The harness software (Claude Code, Cursor, Codex, OpenCode, Antigravity).
- The cloud LLM provider.

## Questions for the auditor

1. Can an attacker with control of repository content achieve command execution
   or file writes outside the sandbox/CWD via any delegation tool?
2. Can the sandbox be escaped (network, `/proc`, `/dev`, namespace tricks, the
   `docker`/`podman` backend, `--allow-unsafe` + `SHUNT_ALLOW_UNSAFE=true`)?
3. Is the secret redaction bypassable (encoding, line breaks, large files, the
   `SHUNT_REDACT_SECRETS=false` path)?
4. Does the guard's per-harness output ever fail **open** where it should deny
   (e.g. harness API changes, malformed payloads)?
5. Can a prompt injection from a repository file survive the local model and
   drive a privileged action despite the approval gate and labels?
6. Is the update path forgeable (hostname check, commit signature, cosign
   identity regexp, dry-run default)?
7. Any memory/parsing bug in the Python/Bash/TypeScript code that leads to a
   security-relevant failure?

## Suggested methodology

- Manual review of the trust boundaries in `docs/threat-model.md`.
- Targeted fuzzing of `shunt_validate_exec_command`, `shunt_validate_endpoint`
  and the guard (the project already ships `evals/fuzz_validate.py`).
- Active sandbox-escape attempts against the bwrap and docker backends.
- Payload matrix across all five harness input shapes.

## Deliverables expected

- Report with severity, exploitability, reproduction steps and evidence.
- Retest after remediation.
- Optional: a short list of hardening recommendations.

## Current controls (starting evidence)

`SECURITY.md` lists controls 1-17; `bash evals/run.sh` runs 224 checks including
security, sandbox, fuzz, redaction and harness-compliance suites. Known
limitations (sandbox best-effort, read-gate coverage, Cursor best-effort) are
documented — treat them as accepted risk unless a bypass is demonstrated.

## Logistics

- Point of contact: repository maintainers (`SECURITY.md`).
- Coordinated disclosure: 90 days or a fix, whichever is sooner.
- Remediation SLA: critical <= 7 days, high <= 30 days, each fix with an eval.
