---
name: bulk-reader
description: "Delegate bulk file reading to a local LLM. Use when you need to read files >350 lines, answer questions across 3+ files, or summarize large diffs."
---

# Bulk Reader (Local LLM)

Delegate file reading and analysis to your local LLM (e.g. Qwen 3.8 / llama.cpp / Ollama) to save tokens in the main agent context.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/bulk-read --question "<question>" --paths <file1> [<file2> ...]
```

## Guidelines

- Each call is independent and self-contained. To ask a follow-up, ask again with the same `--paths` — the files go to the local LLM directly, never into your context window.
- The local LLM returns structured bullet points with exact symbols, types, and line numbers.
- Verify specific line numbers or exact values with targeted reads (using `offset`/`limit`) before applying edits.
