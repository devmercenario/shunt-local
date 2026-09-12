---
name: code-writer
description: "Delegate boilerplate code generation to a local LLM. Use for tests, config, docstrings, type stubs, or any generation where >80% is predictable from reference files."
---

# Code Writer (Local LLM)

Delegate boilerplate code generation to your local LLM (e.g. Qwen 2.5 Coder / llama.cpp / Ollama) to save tokens and avoid clogging your context.

```bash
# Generate and write directly to target file
code-write --spec "<what to generate>" --reference <reference-file> --target <output-path>

# Output to stdout instead (omit --target)
code-write --spec "<what to generate>" --reference <reference-file>

# (Or in Claude Code: ${CLAUDE_PLUGIN_ROOT}/scripts/code-write)
```

## Guidelines

- Each call is independent. Always pass a relevant `--reference` file so the local model matches your project's naming conventions, imports, test style, and architecture.
- To build incrementally on previously generated code, pass that generated file as the `--reference` for subsequent calls.
- After generation, review the output and make surgical edits for the ~10-20% that requires the primary agent's judgment.
