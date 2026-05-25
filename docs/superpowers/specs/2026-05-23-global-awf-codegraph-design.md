# Global AWF Graph Command Design

## Goal

Install AWF Code Graph once as a global PowerShell command while keeping code graph artifacts project-local. The tool should help AI coding agents reduce token usage by producing fast, bounded, graph-derived context for the current repository.

## Approved Direction

Use a global `awf-graph` command that defaults to the current directory:

```powershell
awf-graph init
awf-graph update
awf-graph update -ChangedOnly
awf-graph context -Query "billing"
awf-graph impact
awf-graph query -Query "StudentService"
awf-graph status
```

All generated artifacts remain under the target project:

```text
.wi/graph
.wi/runtime
.wi/logs
```

This avoids copying the application into every repository while preserving per-project graph state.

## Architecture

The implementation keeps the existing PowerShell-first architecture:

```text
global awf-graph command
  -> installed AWF toolkit
    -> target project .wi/graph
    -> target project .wi/runtime
```

The global command is a launcher. It delegates to the installed toolkit and passes through command arguments. If `-RepoPath` is omitted, the CLI resolves it as `.` from the caller's current working directory.

The existing repo-local copy model is no longer the primary workflow. It can remain as a compatibility path if useful, but the optimized UX is a single user-level install with the purpose-specific `awf-graph` command.

The global command should not require the existing `graph` area argument. Since the executable name already scopes the command to graph operations, `awf-graph update` is preferred over `awf-graph graph update`.

## Installer

The installer should:

1. Install the toolkit into a stable user-level directory.
2. Create an `awf-graph` launcher available from normal PowerShell sessions.
3. Avoid modifying each target repository.
4. Detect optional supporting tools such as `rg` or `gh`.
5. Ask before installing any missing optional tool.
6. Use `winget` for optional tool installation when the user approves.
7. Print clear next-step commands after installation.

The installer must not require admin rights for the default path. If PATH modification is needed, it should be scoped to the current user and documented clearly.

Optional tools are enhancements, not hard requirements. For example:

- `rg` improves file discovery performance.
- `gh` may help future GitHub-oriented workflows, but is not required for graph generation.

If an optional component is missing, the installer should explain why it is useful and ask for consent before running an install command. If the user declines, installation should continue with reduced capability and a clear fallback message.

## Graph Storage

The graph storage format remains JSONL-based and project-local:

```text
.wi/graph/files.jsonl
.wi/graph/symbols.jsonl
.wi/graph/edges.jsonl
.wi/graph/summaries.jsonl
.wi/graph/graph-state.json
.wi/graph/changed-files.txt
.wi/graph/impact.md
```

Keeping these contracts stable lets existing agent workflows continue to work while the CLI and scanner improve.

## Performance

File discovery should prefer `rg --files` when available, because it is faster on large repositories and respects common ignore files. If `rg` is not available, AWF falls back to the existing PowerShell recursive scan.

The scanner should still apply AWF's configured extension allowlist and exclude directory rules after discovery. This keeps behavior predictable across both scanner paths.

`graph-state.json` should record useful metadata such as:

```json
{
  "indexer": "powershell-regex-mvp",
  "fileDiscovery": "rg",
  "lastUpdatedUtc": "2026-05-23T00:00:00.0000000Z"
}
```

## Configuration

The existing `config/awf-codegraph.config.json` remains the source of default graph settings:

- workspace paths
- runtime paths
- source extensions
- excluded directories
- context packet limits
- future analyzer hooks

The immediate implementation should use this configuration for extensions, excluded directories, and context limits. If no config is available, the current defaults remain embedded as fallbacks.

## Graph Quality

The first upgrade remains dependency-light. It does not implement Roslyn, tree-sitter, CodeQL, a database, or AI-generated summaries.

The regex indexer remains responsible for:

- file metadata
- symbols
- imports
- low-confidence call candidates
- heuristic summaries

The goal is not perfect semantic analysis. The goal is a fast navigation map that helps an AI agent decide which files to read first.

## AI Agent Code Graph Practices

The graph should optimize for agent usefulness, not exhaustive documentation. Every output should help an AI agent answer one of these questions:

- What changed?
- What should I read first?
- Which symbols or files are likely related?
- Which tests or review areas are likely relevant?
- How fresh and trustworthy is this graph data?

Graph records should preserve provenance and confidence where applicable. Regex-derived relationships must stay marked as advisory, while file metadata and direct symbol definitions can be treated as higher confidence.

Generated packets should avoid embedding full source file contents by default. The graph should point agents to exact files, symbols, and line numbers so they can read only the code needed for the current task.

Freshness should be visible. `graph-state.json` and `context-packet.json` should include enough metadata for an agent or workflow to detect stale context, including the last update time, changed-only mode, indexed file count, and discovery method.

## Context Packet Output

`awf-graph context` should generate both:

```text
.wi/runtime/context-packet.md
.wi/runtime/context-packet.json
```

Both outputs must be generated from the same candidate set.

The Markdown packet is for direct agent and human reading. It should continue to answer:

- what task or query is being handled
- which files changed
- which symbols are relevant
- which summaries are relevant
- which files should be read first
- which workflow instructions protect token budget

The JSON packet is for skills, Obra workflows, MCP adapters, batch runners, and other automation. It should include:

```json
{
  "generatedUtc": "2026-05-23T00:00:00.0000000Z",
  "repoPath": "C:/repo",
  "task": {},
  "query": "billing",
  "changedFiles": [],
  "recommendedFiles": [],
  "symbols": [],
  "summaries": [],
  "limits": {},
  "graphState": {}
}
```

The JSON packet should be deterministic for the same graph inputs where practical. Stable ordering improves diffs, cacheability, and repeatability in agent workflows.

## Candidate Selection

Context selection should stay conservative:

1. Include changed files first.
2. Include query matches second.
3. Include symbols and summaries connected to candidate files.
4. If there is no signal, return a bounded starter set.
5. Apply configured limits before writing output.

This prevents the graph from becoming another full-repository dump.

Candidate ranking should prefer high-signal context:

- changed files and their symbols
- direct query matches in symbol names, file paths, and summaries
- tests related by naming conventions
- files with matching imports or low-confidence call candidates
- bounded starter files only when no better signal exists

The context packet should include the applied limits so agents can tell whether recommendations were truncated.

## Superpowers And Obra Compatibility

Integration remains file-based. Skills and automation can read:

```text
.wi/runtime/context-packet.md
.wi/runtime/context-packet.json
.wi/graph/impact.md
```

No service, daemon, database server, or custom protocol is required. This keeps AWF easy to combine with Superpowers-style workflows where the graph packet becomes an input to planning, implementation, review, or verification skills.

## Error Handling

The CLI should fail with actionable messages when:

- the target repository path does not exist
- the task file path is invalid
- graph files are missing or malformed
- the installer cannot create the launcher
- PATH changes require opening a new shell
- the legacy `graph` area is supplied to `awf-graph`, if compatibility is not implemented

`rg` absence is not an error. It should silently fall back to PowerShell discovery or report the fallback only in verbose output.

## Testing

The implementation should be validated with script-level checks:

- global-style invocation defaults to the current directory
- `awf-graph update` works without the redundant `graph` area
- explicit `-RepoPath` still works
- `awf-graph update` writes graph files
- `awf-graph context` writes both Markdown and JSON packets
- JSON packet parses successfully
- scanner works when `rg` is available
- fallback scanner works when `rg` is unavailable

Because this repository is not currently a git repository, commit-based workflow steps are skipped unless git is initialized later.

## Out Of Scope

The following are intentionally excluded from this pass:

- Roslyn implementation
- tree-sitter integration
- CodeQL integration
- SQLite or graph database storage
- background daemon
- AI-generated summaries
- cross-project shared graph cache
- generic `awf` global command
