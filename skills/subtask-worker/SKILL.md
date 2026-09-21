---
name: subtask-worker
description: "Delegate mechanical code edits, migrations, new test files, or refactoring to an autonomous local LLM worker with automated test verification, self-correction loop, and rollback."
---

# Subtask Worker (Autonomous Local Execution)

Delegate mechanical implementation tasks to your local GPU LLM (`Qwen2.5-Coder-14B-Instruct` on `llama-server` / `Ollama`) to save 80% to 94% of cloud tokens and keep the primary context lean.

The worker autonomously generates code, applies changes to disk, runs your verification command, and self-corrects using error output for up to `--max-retries` attempts before reporting back.

```bash
# Direct CLI invocation
shunt-local exec \
  --instruction "Implement validateToken method in auth service and handle expiration" \
  --files "src/auth/jwt.ts" \
  --read-files "src/auth/types.ts" \
  --test-cmd "npm test -- tests/auth.test.ts" \
  --max-retries 3

# Or via TaskContract JSON spec
shunt-local exec --spec '{
  "instruction": "Create migration adding status column to users",
  "target_files": ["migrations/20260921_add_status_to_users.sql"],
  "read_files": ["prisma/schema.prisma"],
  "verification_command": "npx prisma migrate dev --dry-run",
  "rollback_command": "rm -f migrations/20260921_add_status_to_users.sql",
  "max_retries": 3
}'
```

---

## 🏛️ Architect Engineering Protocol: Investigation, Grill-Me & TDD

As the **Cloud Architect Agent**, you operate at the level of a **Principal / Staff Software Architect**. You do NOT jump blindly into planning or code generation. You follow a rigorous, 5-phase engineering protocol:

### Phase 0: Codebase Pre-Investigation & The "Grill-Me" Alignment (Mandatory)
Before proposing any plan or writing code, the Architect MUST conduct a deep pre-investigation followed by an architectural interview with the user:

1. **Autonomous Pre-Investigation (The Audit)**:
   - **Codebase Conventions**: Inspect existing files, naming standards, error response formats, validation libraries (e.g. Zod, Pydantic), and database patterns already adopted in the project.
   - **Incongruity & Debt Detection**: Identify existing anti-patterns, duplicated logic (violations of DRY), or conflicting patterns in related files before adding new code.
   - **Security Vectors**: Audit authentication/authorization boundaries, input sanitization, injection risks, secret handling, and permission scopes.
   - **Performance & Scalability**: Identify potential query bottlenecks (N+1 queries, missing indexes, unindexed foreign keys), memory leaks, unbounded arrays, or blocking I/O on hot paths.
   - **Maintainability & Clean Code**: Enforce Single Responsibility (SRP), loose coupling, and clean boundaries across Controller -> Service -> Repository layers.

2. **The "Grill-Me" Interview (Interactive Alignment)**:
   - Present your findings directly to the user (using `ask_question` for decisions or clear direct questions).
   - Never assume ambiguous requirements. Formulate concrete architectural options with clear trade-offs and your technical recommendation:
     * *Architectural Trade-offs*: "Option A (Event-driven with Redis) vs Option B (Direct DB transaction). Recommendation: Option B for atomic consistency."
     * *Edge Cases & Failure Modes*: "How should the system behave when third-party provider X times out or returns 429?"
     * *Security & Boundaries*: "Should role validation happen at the middleware layer or inside the domain service?"
     * *Data Integrity & Rollback*: "If step 2 fails halfway, do we need a compensating transaction or soft-delete?"
   - **Outcome**: The user confirms the architectural decisions, constraints, and acceptance criteria before any planning begins.

### Phase 1: Contract-Driven Specification (Interface-First)
With decisions sealed from Phase 0:
1. Establish the canonical contracts first: TypeScript interfaces, Pydantic schemas, database migrations, or protobuf/DTO definitions.
2. Ensure interfaces are strictly typed, self-documenting, and enforce single responsibility.
3. These contract files become the foundational `read_files` passed to the local worker in subsequent phases, preventing interface mismatch.

### Phase 2: Strict Test-Driven Development (TDD) Lifecycle
Every micro-task MUST adhere to the Red-Green-Refactor discipline:

1. **Step 1 — RED (Test First)**:
   - Write or generate the test suite (`tests/...`) *before* writing the implementation.
   - The test asserts all positive paths, negative paths, security boundaries, and edge cases agreed upon in Phase 0.
   - The test MUST deterministically fail against the initial empty/stub implementation (`exit code != 0`).
2. **Step 2 — GREEN (Local Worker Execution)**:
   - Dispatch to `shunt-local exec`:
     - `--read-files`: Interface contract files + newly written failing test file.
     - `--files`: The implementation file to create or modify.
     - `--test-cmd`: Command executing the test suite (e.g. `npm test -- tests/feature.test.ts` or `pytest tests/test_feature.py`).
   - The local Qwen 14B model uses its 40k context to read the test assertions and writes the minimal, clean code required to turn the tests GREEN.
   - If tests fail, the worker's internal self-correction loop catches stderr and fixes the code autonomously without cloud agent intervention.
3. **Step 3 — REFACTOR (Clean Code, DRY & Maintenance)**:
   - Verify code is clean, free of duplicate logic (DRY), idiomatic, and adheres to linters (`npx eslint`, `cargo check`, `ruff check`, `npm run typecheck`).
   - All tests must remain 100% green throughout refactoring.

### Phase 3: The 3-File Hard Constraint
To maintain maximum accuracy and speed on the local model:
- Total files per subtask must never exceed 3:
  - 1 to 2 `target_files` (files modified or created).
  - 1 to 2 `read_files` (reference interfaces, schemas, or test files).

### Phase 4: Sequential Atomic Progression
Execute one subtask at a time:
1. `step-01-schema-contracts`: Schemas, migrations, and base type definitions.
2. `step-02-unit-tests-red`: Tests asserting domain service contracts.
3. `step-03-service-green`: Local worker implements domain logic satisfying tests.
4. `step-04-controller-integration`: API routes/controllers wired to the service.
5. `step-05-e2e-regression`: End-to-end verification and full suite execution.

Dispatch one subtask at a time and inspect the returned JSON before proceeding to the next step.

---

## 📋 Response Format (Clean JSON)

The worker suppresses intermediate generation tokens and returns a concise JSON summary:

### On Success:
```json
{
  "status": "success",
  "task_id": "step-01-jwt",
  "attempts": 2,
  "files_modified": ["src/auth/jwt.ts"],
  "test_output": "3 passed, 0 failed in 0.42s",
  "diff_summary": "+24 lines, -6 lines"
}
```

### On Failure (after retries exhausted):
```json
{
  "status": "failed",
  "task_id": "step-01-jwt",
  "attempts": 3,
  "files_modified": ["src/auth/jwt.ts"],
  "rolled_back": true,
  "error": "Verification failed after 3 attempts",
  "stderr_tail": "Error at JWT.verify (src/auth/jwt.ts:42)..."
}
```
If a subtask fails, the architect receives the exact error output in `stderr_tail` to replan the approach at a high level.
