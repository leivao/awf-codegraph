# Roslyn Upgrade Path Design

## Goal

Add an explicit Roslyn-backed upgrade path for C# indexing in AWF Code Graph without replacing the current PowerShell regex MVP. The Roslyn path should improve symbol and relationship quality for C# repositories while preserving the existing workflow, JSONL contracts, and non-C# handling.

## Approved Direction

Expose Roslyn as an option on the existing update flow:

```powershell
awf-graph update -Indexer powershell
awf-graph update -Indexer roslyn
```

The default remains `powershell`, which preserves current behavior.

When `-Indexer roslyn` is selected:

- Roslyn is used for C# files only.
- The existing PowerShell parser still handles non-C# files.
- The graph output contracts stay the same.
- The command fails clearly if Roslyn cannot run for the repo.

This makes Roslyn an upgrade path rather than a breaking switch.

## User Experience

The primary user-facing change is a new explicit selector on `awf-graph update`:

```powershell
awf-graph update
awf-graph update -Indexer roslyn
awf-graph update -Indexer powershell
awf-graph update -ChangedOnly -Indexer roslyn
```

`awf-graph status` should report which indexer was used most recently so users can tell whether the graph came from the MVP path or the Roslyn path.

The existing `init`, `impact`, `context`, `query`, and `agents install` commands do not need new user-visible behavior for this upgrade path.

## Architecture

The implementation keeps the current PowerShell orchestration layer and adds a Roslyn-backed C# indexing pipeline behind a flag:

```text
awf.ps1
  -> src/Awf.CodeGraph.psm1
     -> powershell indexer path
     -> roslyn indexer path for .cs files only
        -> reads .sln/.csproj
        -> builds compilation
        -> extracts C# symbols and relationships
        -> writes the same JSONL graph contracts
```

The Roslyn path is an enrichment layer, not a new storage model. The same graph files remain the integration boundary:

```text
.wi/graph/files.jsonl
.wi/graph/symbols.jsonl
.wi/graph/edges.jsonl
.wi/graph/summaries.jsonl
.wi/graph/graph-state.json
.wi/graph/changed-files.txt
```

This preserves compatibility with context packets, impact reports, and existing agent instructions.

## Indexer Behavior

### PowerShell MVP path

The current regex-based indexer remains the default and continues to support the mixed-language repository story. It is still responsible for lightweight indexing of non-C# files and for repositories that do not opt into Roslyn.

### Roslyn path

Roslyn should be used only for C# analysis. It is responsible for:

- parsing the solution and project graph
- resolving compilation and semantic models
- extracting namespaces, classes, interfaces, records, structs, methods, constructors, properties, and attributes
- resolving inheritance and implementation relationships
- resolving call and reference relationships where semantic data is available
- associating symbols with source files and line ranges

The Roslyn path should not attempt to replace the existing heuristics for non-C# languages in this phase.

## CLI And Configuration

The implementation should add a clear indexer selector to `awf-graph update`.

Recommended shape:

```powershell
[ValidateSet("powershell", "roslyn")]
[string]$Indexer = "powershell"
```

The selector should flow through `awf.ps1` into the graph update implementation. If the repo already uses config defaults, the command-line flag should override them.

The design does not require auto-detection. The explicit flag is the source of truth because it makes the upgrade path predictable and easy to debug.

If Roslyn is requested but the repo cannot be analyzed as a .NET solution/project, the command should stop with an actionable error instead of silently falling back to regex.

## Data Model

The Roslyn path must continue to emit the same JSONL contracts used by the current toolkit:

- `files.jsonl`
- `symbols.jsonl`
- `edges.jsonl`
- `summaries.jsonl`
- `graph-state.json`

The meaning of the records can become richer, but the file names and general shape must remain stable so downstream tools do not need to change.

`graph-state.json` should record enough metadata to show which path produced the current graph, for example:

```json
{
  "version": "0.1.0",
  "lastUpdatedUtc": "2026-05-24T00:00:00.0000000Z",
  "indexer": "roslyn",
  "languageScope": "csharp",
  "changedOnly": false
}
```

The output should remain deterministic where practical. Stable ordering matters because the graph is an agent input, not just a cache.

## Error Handling

The Roslyn path should fail loudly and specifically when:

- the repo does not contain a discoverable `.sln` or `.csproj` for C# analysis
- project restore or compilation construction fails
- a referenced project or package prevents semantic analysis
- the requested `-Indexer roslyn` path cannot index the selected C# files

The error message should tell the user whether the repo is missing .NET project structure, restore data, or a compilation dependency.

The update command should not degrade into a silent fallback when the user explicitly requested Roslyn.

## Testing

Add focused tests for:

- `awf-graph update` still uses the PowerShell path by default
- `awf-graph update -Indexer roslyn` records Roslyn in graph state
- Roslyn indexing preserves existing JSONL file contracts
- Roslyn indexes C# symbols and relationships for a representative project
- non-C# files still appear through the existing parser path
- invalid Roslyn inputs fail with actionable errors
- `awf-graph status` reports the last-used indexer

Tests should verify behavior at the command and graph-contract level, not just individual helper functions.

## Out Of Scope

- Replacing the PowerShell regex MVP as the default path
- Auto-detecting Roslyn without an explicit flag
- Roslyn support for non-C# languages in this phase
- Changing the JSONL file names or moving away from project-local graph storage
- Introducing a database or daemon
- Adding AI-generated summaries

## Implementation Notes

The likely implementation shape is a narrow set of changes in the existing graph module and CLI wiring:

- extend `awf.ps1` to accept the indexer selector
- branch update behavior inside `src/Awf.CodeGraph.psm1`
- add a Roslyn-specific C# analyzer path
- preserve the current file discovery, changed-file tracking, impact generation, and context packet flow

This keeps the upgrade path isolated and avoids a broader redesign of the toolkit.
