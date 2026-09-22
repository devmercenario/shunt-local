# Contributing

Thanks for helping improve `shunt-local`.

## Pull requests only

The `main` branch is protected: **direct pushes are blocked**. Every change
must come through a pull request, and the PR must pass the full CI matrix
before it can be merged:

- Evals — `ubuntu-latest`, `macos-latest`, `windows-latest`
- ShellCheck
- Secret scan

## Before opening a PR

1. Branch from a current `main` (`git fetch origin && git checkout -b <branch> origin/main`).
2. Run the full suite locally: `bash evals/run.sh`.
3. Keep every new control covered by an eval (`evals/*-evals.sh`).
4. Never weaken a default to make a test pass — add an opt-in env var instead.

## Commit style

Follow the existing conventional-commit prefixes (`feat:`, `fix:`, `docs:`,
`refactor:`, `test:`, `chore:`, `security:`) and keep each commit scoped to one
concern.
