# Roadmap

Work tracked after the security hardening round. Each item becomes a commit with
a regression eval. Items that need an owner action are marked **[owner]**.

## Phase 0 — Preparation
- [x] `docs/threat-model.md`
- [x] `docs/ROADMAP.md`
- [x] `CHANGELOG.md`
- [x] SBOM attached to releases (`syft`)

## Phase 1 — Windows CI + native installer
- [x] `windows-latest` job running `bash evals/run.sh` (Git Bash), sandbox e2e skipped
- [x] Portable interpreter resolution (`python3` -> `python`)
- [x] `install.ps1` (copy files, config, hooks)
- [x] Portability audit of shell GNU-isms
- [x] `evals/portability-evals.sh` (backslash paths, PowerShell tool, CRLF)

## Phase 2 — Harness coverage
- [x] Shared write-safety module (`scripts/lib/paths.py`)
- [x] Claude `Write|Edit` gate (sensitive paths)
- [x] Claude `@`-reference mitigation via plugin `settings.json` deny rules
- [x] Claude `Grep` guidance via `additionalContext`
- [x] Cursor `beforeReadFile` (file + `attachments`) and `preToolUse` `Write`
- [x] Codex `apply_patch` sensitive-write gate and `mcp__*read*` reads
- [x] OpenCode `write`/`edit`/`multiedit` gate and `grep` guidance
- [x] Antigravity `write_to_file`/`replace_file_content` gate
- [x] `evals/coverage-evals.sh` validating the harness matrix

## Phase 3 — `doctor` + packaging
- [x] `shunt-local doctor` (`scripts/lib/doctor.sh`, `--json`)
- [x] `evals/doctor-evals.sh`
- [x] Self-hosted Claude marketplace manifest (`.claude-plugin/marketplace.json`)
- [x] OpenCode npm package manifest (`plugins/opencode/package.json`)
- [x] Installer lifecycle tests (`evals/install-evals.sh`)
- [ ] Publish to the Claude community catalog **[owner: submit PR]**
- [ ] Cursor directory submission **[owner]**
- [ ] Codex plugin distribution **[owner]**
- [ ] `npm publish opencode-shunt-local` **[owner: npm account]**

## Phase 4 — Independent audit  **[owner: engage firm]**
- [x] Audit brief + SBOM + pinned commit (`docs/audit-brief.md`)
- [ ] External review (agent<->shell boundary, sandbox, supply chain, injection)
- [ ] Remediation with per-fix evals
- [ ] Public advisory

## Phase 5 — Continuous
- [x] Contract tests per harness (detect API changes early)
- [x] Delegation metrics (`shunt-local stats` over the audit log)
- [x] Per-harness install and troubleshooting docs (`docs/harnesses.md`)
- [x] Version/changelog discipline (0.2.0)
