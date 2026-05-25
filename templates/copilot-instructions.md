# AWF Code Graph

Before planning, implementation, debugging, or review, use the repo-local AWF graph as the first navigation source.

Read `.wi/runtime/context-packet.md` when present. Use `.wi/graph/files.jsonl`, `.wi/graph/symbols.jsonl`, `.wi/graph/edges.jsonl`, and `.wi/graph/summaries.jsonl` to choose the first files to inspect. Use `.wi/graph/impact.md` during review and regression analysis.

Treat graph artifacts as guidance, not truth. Verify exact source code before editing.

After edits, run:

```powershell
awf-graph update -ChangedOnly
awf-graph impact
```

Then run relevant build/tests and summarize changed files, changed symbols, tests run, and residual risks.
