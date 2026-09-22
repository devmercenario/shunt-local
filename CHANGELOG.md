# Changelog

All notable changes to this project are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Split `local-llm.sh` into `common/config/validate/sandbox/audit/http/hooks`
  modules behind a thin loader.
- Extract the subtask worker helpers into `scripts/lib/task.sh` and the code
  writer into `scripts/lib/apply_changes.py` (`task-exec` is now orchestration).
- Cache the sandbox backend selection per process; validate `install.ps1` in CI;
  add a shallow harness e2e smoke (`evals/harness-e2e.sh`).

## [0.2.0] - 2026-09-22

### Security
- Command execution in a sandbox (`bwrap`/`firejail`/docker, no network by
  default) with `SHUNT_SANDBOX_STRICT`.
- Explicit approval before writing or running (`--apply-mode confirm|auto|dry-run`).
- Read confinement, secret redaction and keyring key sources.
- Verified updates (signed commit / cosign attestation).
- Property fuzzing of the command allowlist and endpoint validator; fixed an
  `inline_eval` state leak.

### Added
- Cross-platform PreToolUse guard (`hooks/shunt_guard.py`).
- `AGENTS.md`, `docs/threat-model.md`, `docs/ROADMAP.md`.
- CI (evals on Linux/macOS, ShellCheck, gitleaks) and signed releases with SBOM.
