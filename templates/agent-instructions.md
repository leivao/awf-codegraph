# Agent Instructions: Using AWF Code Graph

You are working in a repository with a repo-local code graph under `.wi/graph`.

Before editing:
1. Read `.wi/runtime/context-packet.md`.
2. Read only the recommended files first.
3. Use the graph packet to understand likely impact.
4. Do not assume the graph is perfect; verify exact code before modifying.

After editing:
1. Run:
   ```powershell
   awf-graph update -ChangedOnly
   ```
2. Run:
   ```powershell
   awf-graph impact
   ```
3. Review `.wi/graph/impact.md`.
4. Run build/tests.
5. Summarize changed files, changed symbols, tests run, and residual risks.

Token discipline:
- Do not load entire directories unless impact analysis requires it.
- Prefer symbol-level and file-summary context.
- Request exact file contents only for files that must be edited or reviewed.
