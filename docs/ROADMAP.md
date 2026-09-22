# Roadmap

Work tracked after the security hardening round. Each item becomes a commit with
a regression eval. Items that need an owner action are marked **[owner]**.

## Phase 0 — Preparation
- [x] `docs/threat-model.md`
- [x] `docs/ROADMAP.md`
- [x] `CHANGELOG.md`
- [x] SBOM attached to releases (`syft`)

## Phase 1 — Windows CI + native installer
- [ ] `windows-latest` job running `bash evals/run.sh` (Git Bash), sandbox e2e skipped
- [ ] Portable interpreter resolution (`python3` -> `python`)
- [ ] `install.ps1` (copy files, config, hooks)
- [ ] Portability audit of shell GNU-isms
- [ ] `evals/windows-evals.sh` (backslash paths, PowerShell tool, CRLF)

## Phase 2 — Harness coverage
- [ ] Shared write-safety module (`scripts/lib/paths.py`)
- [ ] Claude `Write|Edit` gate (sensitive paths)
- [ ] Claude `@`-reference mitigation via plugin `settings.json` deny rules
- [ ] Claude `Grep` guidance via `additionalContext`
- [ ] Cursor `beforeReadFile` (file + `attachments`) and `preToolUse` `Write`
- [ ] Codex `apply_patch` sensitive-write gate and `mcp__*read*` reads
- [ ] OpenCode `write`/`edit`/`multiedit` gate and `grep` guidance
- [ ] Antigravity `write_to_file`/`replace_file_content` gate
- [ ] `evals/coverage-evals.sh` validating the harness matrix

## Phase 3 — `doctor` + packaging
- [ ] `shunt-local doctor` (`scripts/lib/doctor.sh`, `--json`)
- [ ] `evals/doctor-evals.sh`
- [ ] Self-hosted Claude marketplace manifest **[owner: submit]**
- [ ] Cursor directory submission **[owner]**
- [ ] Codex plugin distribution **[owner]**
- [ ] OpenCode npm package `opencode-shunt-local` **[owner: npm account]**

## Phase 4 — Independent audit  **[owner: engage firm]**
- [ ] Audit brief + SBOM + pinned commit (`docs/audit-brief.md`)
- [ ] External review (agent<->shell boundary, sandbox, supply chain, injection)
- [ ] Remediation with per-fix evals
- [ ] Public advisory

## Phase 5 — Continuous
- [ ] Contract tests per harness (detect API changes early)
- [ ] Token-savings / delegation metrics
- [ ] Per-harness install and troubleshooting docs
- [ ] Version/changelog discipline
