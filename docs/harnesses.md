# Harness integration

Per-harness install, verification and troubleshooting. Run
`shunt-local doctor` after installing to confirm registration.

The single guard implementation is `hooks/shunt_guard.py`; the bash scripts in
`hooks/` are thin wrappers for Git Bash/Unix. Decision schemas are locked by
`evals/contract-evals.sh`.

## Antigravity (`agy`)

- Install: `./install.sh` writes `~/.gemini/config/hooks.json` (PreToolUse for
  `view_file`, `run_command`, `write_to_file|replace_file_content|...`,
  `grep_search`) and runs `agy plugin install`.
- Verify: the `shunt-local` key exists in `~/.gemini/config/hooks.json` and
  `shunt-local doctor` reports `pass harness-antigravity`.
- Notes: hooks run via `sh -c`; the command is an absolute path to
  `python3 …/hooks/shunt_guard.py --kind …`.

## Claude Code

- Install: `/plugin install shunt-local` (or `--plugin-dir .`); hooks come from
  the plugin `hooks/hooks.json`.
- Matchers: `Read`, `Bash|PowerShell`, `Write|Edit`, `Grep`.
- `@`-references bypass PreToolUse; the plugin `settings.json` therefore ships
  `permissions.deny` rules for secrets. User settings take priority.
- Verify: `/context` shows the skills; run a large read and expect a denial
  naming `/bulk-reader`.

## Codex

- Install: enable the plugin (`.codex-plugin/plugin.json` → `hooks/hooks.json`)
  and ensure `features.hooks` is on.
- Matchers: `Bash`, `apply_patch`/`Edit`/`Write`. Codex has no `Read` tool; MCP
  read tools are matched as reads by name.
- Verify: a `cat large-file` command returns the nested
  `hookSpecificOutput.permissionDecision:"deny"`.

## Cursor

- Install: `./install.sh` merges `~/.cursor/hooks.json` (`preToolUse`
  `Read`/`Shell`/`Write`/`Grep` and `beforeReadFile`).
- `beforeReadFile` sees `@`/attachment paths, so they are gated too.
- Verify: `shunt-local doctor` reports `pass harness-cursor`; denying a large
  read shows `permission: "deny"`.

## OpenCode

- Install: `./install.sh` copies `plugins/opencode/shunt-local.ts` to
  `~/.config/opencode/plugins/` (or use the npm package `opencode-shunt-local`).
- Hooks: `read`/`file_read`, `bash`/`shell`, `write`/`edit`/`multiedit`; writes
  to sensitive or out-of-project paths throw.
- Verify: reading a >350-line file throws with a `/bulk-reader` hint.

## Common troubleshooting

- **Hooks not firing**: check `shunt-local status` (master switch) and that the
  config `enabled` is true.
- **Everything allowed**: the local server may be offline — hooks fail open.
  Check `shunt-local doctor` (`endpoint-online`).
- **Hooks error in the transcript**: ensure `python3` and `jq` are on PATH.
- **Shell gate blocks a path**: `SHUNT_ALLOW_SENSITIVE_READS=true` /
  `SHUNT_ALLOW_WRITES_OUTSIDE_CWD=true` / `SHUNT_ALLOW_SENSITIVE_WRITES=true`.
