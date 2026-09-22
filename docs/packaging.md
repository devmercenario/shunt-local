# Packaging and distribution

Manifests shipped in this repository and the owner actions needed to publish
them. Run `shunt-local doctor` after installing to confirm registration.

## Claude Code

- Manifest: `.claude-plugin/plugin.json` (plugin) and
  `.claude-plugin/marketplace.json` (this repository can be added as a
  marketplace).
- Test locally:
  ```bash
  claude --plugin-dir .
  # or, as a marketplace:
  claude plugin marketplace add devmercenario/shunt-local
  claude plugin install shunt-local@shunt-local
  ```
- Submission form fields (`https://clau.de/plugin-directory-submission`):
  - **Name:** `shunt-local`
  - **Repository / Homepage:** `https://github.com/devmercenario/shunt-local`
  - **License:** Apache-2.0
  - **Description:** Shunts large file reads and boilerplate generation to a
    local LLM (llama.cpp/Ollama/vLLM) to save cloud tokens, with a sandboxed,
    approval-gated subtask worker, secret redaction, read/write confinement and
    an audit log.
  - **Keywords:** tokens, local-llm, delegation, sandbox
- **[owner]** To publish in the community catalog, submit via
  `https://clau.de/plugin-directory-submission`. The catalog repository
  (`anthropics/claude-plugins-community`) is a read-only mirror and closes
  direct PRs automatically, so there is no PR to open. Until it is approved,
  users can install from this repository directly
  (`claude plugin marketplace add devmercenario/shunt-local`). The plugin
  defaults to `confirm` apply mode and never auto-approves.

## Cursor

- Rule: `.cursor/rules/shunt-local.mdc`; hooks are installed into
  `~/.cursor/hooks.json` by `install.sh` / `install.ps1`.
- **[owner]** Submit to the Cursor directory via their submission form. Until
  then users install by cloning and running `./install.sh`.

## Codex

- Plugin manifest: `.codex-plugin/plugin.json` → `hooks/hooks.json`.
- Users must enable lifecycle hooks (`features.hooks`) and trust the plugin.
- **[owner]** Publish through the Codex plugin distribution channel.

## OpenCode

- Package: `plugins/opencode/package.json` (`opencode-shunt-local`).
- Test locally by copying `shunt-local.ts` into `~/.config/opencode/plugins/`.
- **[owner]** `cd plugins/opencode && npm publish --access public`, then users
  add `"plugin": ["opencode-shunt-local"]` to `opencode.json`.

## Antigravity

- `install.sh` registers `~/.gemini/config/hooks.json` and runs
  `agy plugin install`.
- **[owner]** Submit to the Antigravity marketplace.

## Release checklist (all channels)

1. `bash evals/run.sh` is green.
2. Bump `version` in `plugin.json`, `.claude-plugin/plugin.json`,
   `.claude-plugin/marketplace.json`, `.codex-plugin/plugin.json`,
   `plugins/opencode/package.json` and `CHANGELOG.md`.
3. Tag `vX.Y.Z`; the release workflow builds `shunt-local.tar.gz`, signs
   `SHA256SUMS` with cosign and attaches the SBOM.
4. Verify the published checksum/signature before announcing.
