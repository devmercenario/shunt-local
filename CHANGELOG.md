# Changelog

All notable changes to this project are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
