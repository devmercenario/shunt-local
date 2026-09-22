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
- **[owner]** To publish in the community catalog, open a PR against
  `anthropics/claude-plugins-community` adding this plugin (it is pinned to a
  commit SHA by their CI). The hardened plugin defaults to `confirm` apply mode
  and never auto-approves.

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
