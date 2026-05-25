---
name: awf-codegraph
description: Use before planning, implementation, debugging, or review in repositories that contain AWF `.wi` graph artifacts.
---

# AWF Code Graph First

Use the repo-local AWF graph as the first navigation source before broad repository scans or deeper coding skills.

Before editing:
1. Read `.wi/runtime/context-packet.md` if it exists.
2. Use `.wi/graph/files.jsonl`, `.wi/graph/symbols.jsonl`, `.wi/graph/edges.jsonl`, and `.wi/graph/summaries.jsonl` to identify likely files and symbols.
3. Read `.wi/graph/impact.md` during review or regression analysis when it exists.
4. Treat graph data as guidance only. Verify exact source files before changing code.

After editing:
1. Run `awf-graph update -ChangedOnly`.
2. Run `awf-graph impact`.
3. Run the relevant build or test command.
4. Summarize changed files, changed symbols, tests run, and residual risks.

Token discipline:
- Do not load entire directories unless impact analysis requires it.
- Prefer symbol-level and file-summary context first.
- Request exact file contents only for files that must be edited or reviewed.
