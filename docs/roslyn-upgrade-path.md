# Roslyn Upgrade Path for .NET Repositories

The included MVP parser is regex-based. For high-quality .NET analysis, add a Roslyn indexer.

## Recommended architecture

```text
PowerShell awf.ps1
  -> tools/Awf.CodeGraph.RoslynIndexer
     -> reads .sln/.csproj
     -> builds Compilation
     -> extracts symbols
     -> extracts references
     -> extracts interface implementations
     -> extracts inheritance
     -> extracts call graph candidates
     -> writes JSONL files
```

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
dotnet run --project tools/Awf.CodeGraph.RoslynIndexer -- `
  --repo . `
  --solution MySolution.sln `
  --changed-files .wi/graph/changed-files.txt `
  --output .wi/graph
```

## JSONL compatibility

The Roslyn indexer should emit the same contracts:

- `files.jsonl`
- `symbols.jsonl`
- `edges.jsonl`
- `summaries.jsonl`
- `graph-state.json`

This keeps the PowerShell workflow unchanged.

## Advanced features

- Map controllers to endpoints.
- Map tests to production classes.
- Detect DI registrations.
- Detect EF Core DbContext and entities.
- Detect MediatR handlers.
- Detect validators.
- Detect middleware.
- Detect API contracts and DTOs.
