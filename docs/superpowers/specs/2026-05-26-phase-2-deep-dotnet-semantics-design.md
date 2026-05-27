# Phase 2 Deep .NET Semantics Design

## Goal

Expand the Roslyn-backed C# indexer from basic symbol extraction into the semantic relationships that matter for real .NET code understanding, while preserving the existing JSONL graph contracts and the mixed Roslyn/PowerShell workflow.

## Approved Direction

Build Phase 2 by extending the existing Roslyn tool and its PowerShell integration rather than introducing a separate post-processing pipeline.

The Roslyn path remains the source of truth for C# semantic facts. The PowerShell path still indexes non-C# files and keeps the mixed-language graph usable, but Phase 2 adds richer compiler-derived semantics only for C#.

The target result is a graph that can answer higher-value .NET questions without changing downstream consumers:

- What does this type inherit from or implement?
- What symbols does this method call?
- What parameter and return types shape this contract?
- What files are controllers, handlers, middleware, DTOs, or test code?

## Scope

### In scope

- Roslyn semantic extraction for C# files already routed through `-Indexer roslyn`
- Relationship edges for:
  - `defines`
  - `inherits`
  - `implements`
  - `invokes`
  - `references`
  - `returns`
  - `parameter-types`
- Framework-aware classification for:
  - ASP.NET controllers and endpoints
  - Minimal APIs
  - dependency injection registrations
  - EF Core `DbContext` and entities
  - MediatR handlers
  - validators
  - middleware
  - DTOs and API contracts
- Test-to-production mapping heuristics based on names, symbols, references, and project structure
- Preservation of existing JSONL artifact names and current CLI behavior

### Out of scope

- Phase 3 query ranking and context packet generation
- Phase 4 incremental caching and stale-section tracking
- Multi-language analyzer expansion beyond C#
- Replacing the current PowerShell non-C# path
- Introducing a database or changing graph storage format

## Design

### 1. Extend the existing Roslyn pass

The current Roslyn indexer already opens solutions and resolves semantic models. Phase 2 extends that same tool so it emits richer semantic facts for each C# document in one pass.

The Roslyn tool should continue to:

- load the `.sln`
- iterate C# projects and documents
- resolve semantic models for compilable source files
- emit JSONL rows into the same `.wi/graph` contract

New extraction logic should be organized as small helper stages so that symbol discovery, relationship discovery, and framework classification remain independently testable.

### 2. Treat `defines` as the base relationship

`defines` remains the foundational edge between a file and the symbols declared inside it.

For each declared symbol, the tool should continue to emit:

- `files.jsonl` records for the file itself
- `symbols.jsonl` records for the declared symbol
- `edges.jsonl` `defines` records

This keeps existing consumers stable and gives all higher-level relationships a consistent anchor.

### 3. Add compiler-derived relationship edges

Phase 2 should add semantic edges only when Roslyn can resolve them confidently.

The intended relationship meaning is:

- `inherits`: a type extends a base class
- `implements`: a type implements an interface
- `invokes`: a method invocation or call site points to a resolved symbol
- `references`: a symbol usage or type reference is resolved, but not necessarily a direct call
- `returns`: a method returns a resolved type or symbol
- `parameter-types`: a method or constructor parameter resolves to a type symbol

The implementation should prefer precise edges over broad heuristics. If Roslyn cannot resolve a target symbol with enough confidence, the edge should be omitted rather than guessed.

### 4. Add framework-aware classification as metadata, not as a separate analyzer

Framework detection should be a classification layer on top of the semantic facts, not a separate codepath with its own output format.

The classifier should use a combination of symbol names, attributes, method signatures, inheritance, and references to assign file or symbol kinds such as:

- ASP.NET controller
- ASP.NET endpoint
- minimal API
- DI registration
- EF Core `DbContext`
- EF Core entity
- MediatR handler
- validator
- middleware
- DTO
- API contract

The classification output should remain compatible with the current JSONL shape. If a record needs a stronger label, add it as an additional field only when it is stable and useful to downstream consumers.

### 5. Map tests to production code using heuristics

Test mapping should remain heuristic, but it should be grounded in semantic evidence rather than filename matching alone.

The recommended ranking signals are:

- same or adjacent namespace
- test project references to production project
- `Test`/`Tests` naming patterns
- production symbols referenced from test methods
- attributes such as `Fact`, `Theory`, `TestMethod`, `TestClass`, `TestFixture`
- file and project adjacency in the solution graph

The output should support later query and context ranking work, but Phase 2 only needs enough fidelity to distinguish likely test files and the production symbols they exercise.

## Architecture

```text
awf.ps1
  -> src/Awf.CodeGraph.psm1
     -> Roslyn tool for C# files
        -> solution loading
        -> semantic model resolution
        -> declared symbol extraction
        -> relationship extraction
        -> framework classification
        -> test mapping heuristics
        -> JSONL graph records
     -> existing PowerShell parser for non-C# files
     -> merge both record sets into .wi/graph
```

The Roslyn tool remains the only place that understands compiler semantics. The PowerShell module continues to decide when the Roslyn path runs and how records are merged back into the shared graph files.

## Data Flow

1. `awf.ps1 update -Indexer roslyn` resolves the repo and calls the graph update path.
2. `src/Awf.CodeGraph.psm1` discovers C# files and non-C# files separately.
3. The existing PowerShell parser indexes non-C# files as before.
4. The Roslyn tool loads the solution and semantic model for each C# document.
5. The Roslyn tool emits file, symbol, edge, and summary records with richer semantic data.
6. The PowerShell layer merges both record sets into the existing `.wi/graph` files.
7. `graph-state.json` continues to record the chosen indexer and freshness metadata such as `lastUpdatedUtc` and `indexedFileCount`.

## Error Handling

Phase 2 should fail and surface an actionable error when the Roslyn analysis cannot run at the repo level, including:

- no discoverable `.sln`
- solution load failure
- workspace or restore failure
- inability to construct semantic models for the requested C# project graph

Partial document-level gaps should not fail the whole graph update. If one document cannot produce a semantic model, the tool should skip that document, keep the rest of the graph, and emit a clear warning when verbose output is enabled.

The classifier should also be conservative: when a framework pattern is ambiguous, it should omit the classification rather than emit a wrong label.

## Testing

Phase 2 needs coverage at two levels:

### Tool-level tests

- Roslyn emits the richer edge types for a representative C# fixture
- type inheritance and interface implementation are captured
- method calls are represented as `invokes`
- parameter and return-type relationships are emitted when resolved
- framework classifiers identify representative ASP.NET, DI, EF Core, MediatR, validator, middleware, and DTO patterns
- the tool remains stable when a semantic model is unavailable for one document

### Graph-level tests

- `awf.ps1 update -Indexer roslyn` still produces the mixed graph
- the shared JSONL contract remains intact
- test files are recognized and mapped to production code with the new heuristics
- `awf.ps1 status` still reflects the selected indexer and current graph state

The tests should use small fixture solutions with explicit assertions on the emitted JSONL rows rather than only checking for command success.

## Acceptance Criteria

Phase 2 is complete when:

- the Roslyn indexer emits semantic edges beyond `defines` for representative C# fixtures
- framework-aware classifications are present for common .NET application shapes
- test files can be identified and associated with production code at a useful heuristic level
- the mixed Roslyn/PowerShell update path still works end to end
- the existing JSONL contract remains stable
- the full regression suite passes

## Risks and Constraints

- Roslyn semantic resolution can be expensive on large solutions, so extraction should stay single-pass and avoid duplicate work where possible.
- Framework detection can become noisy if it is too eager. The classifier should remain conservative and prefer omission over false positives.
- The graph contract must stay stable for later Phase 3 retrieval work, so fields should only be added when they are clearly useful and consistently derivable.

## Notes For Later Phases

Phase 3 should consume the richer graph facts produced here rather than re-derive them.

Phase 4 should use the same semantic extraction boundaries to determine what can be cached safely and what needs invalidation when projects change.
