# Roslyn Upgrade Path for .NET Repositories

The included MVP parser is regex-based. For higher-quality C# analysis, AWF now ships a mixed Roslyn upgrade path behind an explicit selector:

```powershell
awf-graph update -Indexer roslyn
awf-graph update -ChangedOnly -Indexer roslyn
```

This does not replace the default PowerShell path. It upgrades only `.cs` files to Roslyn while keeping non-C# files on the existing PowerShell parser.

## Recommended architecture

```text
PowerShell awf.ps1
  -> PowerShell indexer for non-C# files
  -> tools/Awf.CodeGraph.RoslynIndexer for .cs files
     -> reads .sln/.csproj
     -> builds Compilation
     -> extracts symbols
     -> extracts references
     -> writes JSONL files to a temp output folder
  -> merge both outputs into .wi/graph
```

## Current behavior

- `-Indexer roslyn` is explicit. The default indexer remains `powershell`.
- Non-C# files still use the PowerShell parser and land in the same graph files.
- C# files use the Roslyn console tool and their JSONL records are merged into the main `.wi/graph` files.
- `-ChangedOnly` still removes and rewrites only the changed graph entries where possible; the merged graph state continues to reflect the selected indexer.
- If no `.sln` can be found for a requested Roslyn C# pass, the update stops with an actionable error instead of silently falling back.

## Roslyn indexer responsibilities

- Parse solution and projects.
- Resolve semantic model.
- Extract:
  - namespaces
  - classes
  - interfaces
  - records
  - structs
  - methods
  - constructors
  - properties
  - attributes
  - endpoint attributes
  - dependency injection registrations
- Resolve:
  - implements
  - inherits
  - invokes
  - references
  - returns
  - parameter types

## Suggested CLI

```powershell
awf-graph update -Indexer roslyn
```

## JSONL compatibility

The Roslyn tool emits the same contracts as the PowerShell path:

- `files.jsonl`
- `symbols.jsonl`
- `edges.jsonl`
- `summaries.jsonl`
- `graph-state.json`

That compatibility is what allows the mixed update path to merge C# and non-C# records without changing downstream commands such as `impact`, `context`, or `status`.

## Advanced features

- Map controllers to endpoints.
- Map tests to production classes.
- Detect DI registrations.
- Detect EF Core DbContext and entities.
- Detect MediatR handlers.
- Detect validators.
- Detect middleware.
- Detect API contracts and DTOs.
