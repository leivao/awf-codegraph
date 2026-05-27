# Phase 3 Retrieval Design

## Goal

Add an internal retrieval layer that ranks graph facts for blast radius, related tests, and compact context packets without changing the public CLI surface.

## Approved Direction

Build Phase 3 inside `src/Awf.CodeGraph.psm1` so it can consume the existing `.wi/graph` JSONL artifacts directly. The retrieval layer should reuse the current graph schema, the Roslyn-enhanced C# facts from Phase 2, and the PowerShell-generated non-C# facts without introducing a new storage format or a new user-facing command.

The first version of retrieval should be internal only. It should return plain PowerShell objects that later phases can reuse for CLI commands, prompt assembly, or context packets. That keeps the ranking logic testable without freezing a public API too early.

## Scope

### In scope

- Internal PowerShell helpers for graph retrieval and ranking
- Blast-radius scoring for a seed symbol or file
- Related-test discovery for a seed symbol or file
- Compact context packet assembly from ranked graph facts
- Deterministic, explainable ranking based on graph data already on disk
- Fixture-driven regression tests in `tests/run-tests.ps1`

### Out of scope

- New public `awf.ps1` retrieval commands
- New graph storage or database layers
- Incremental reindexing or stale-section tracking
- New analyzer types or multi-language expansion
- Re-deriving facts that already exist in the graph

## Design

### 1. Retrieval stays internal to the PowerShell module

The retrieval layer belongs in `src/Awf.CodeGraph.psm1` next to the existing graph update helpers. That keeps the implementation close to the current file discovery, graph merge, and state management logic.

The module should expose internal helpers that accept a graph path and a seed, then read `files.jsonl`, `symbols.jsonl`, `edges.jsonl`, and `summaries.jsonl` from disk. The helpers should return PowerShell objects, not serialized files, so later command work can build on the same ranking functions.

### 2. Ranking should be conservative and deterministic

Ranking should prefer direct, compiler-derived evidence over heuristics.

The intended ordering is:

1. Direct symbol and file connections from the seed
2. One-hop neighbors through existing graph edges
3. Files and symbols in the same project or namespace
4. Test files and test projects that reference production code
5. Heuristic matches from naming and path conventions

When two candidates have the same score, the result should sort deterministically by path and then by symbol id. That keeps test output stable and makes ranking easier to reason about.

### 3. Context packets should be bounded and reusable

The packet assembler should take the ranked candidates and produce a small object with a fixed shape. The packet should include:

- the seed or primary target
- a bounded blast-radius list
- a bounded related-test list
- a bounded list of supporting context files
- a bounded list of supporting symbols

The assembler should respect a hard budget so later prompt assembly does not accidentally expand into a broad graph dump. The exact budget can stay small at first, as long as it is explicit and enforced.

### 4. Test selection should prefer evidence over naming alone

Phase 3 should reuse the test and project signals already emitted by Phase 2. Related-test selection should rank:

- files already classified as `test`
- test projects that reference production code
- files with test naming patterns
- files that directly reference the seed symbol or its neighbors

This layer should not try to infer new test semantics. It should only rank what already exists in the graph and in the project structure.

### 5. The public CLI remains unchanged

Phase 3 should not introduce a new user-facing command yet. The current `awf.ps1 update` and `awf.ps1 status` behavior remains the public surface, and the retrieval helpers stay internal until a later phase freezes the UX.

That separation matters because Phase 3 is about proving the ranking model first. Once the ranking behavior is stable, a later phase can decide whether to expose it through a command, a context packet pipeline, or another integration point.

## Data Flow

1. `awf.ps1 update -Indexer roslyn` continues to produce the shared `.wi/graph` artifacts.
2. A retrieval helper receives a seed symbol, file path, or query-derived seed.
3. The helper reads the existing JSONL graph files from `.wi/graph`.
4. The helper scores related files, symbols, and tests using deterministic rules.
5. The helper returns a bounded PowerShell object that represents the retrieval result.
6. Later phases can consume that object for CLI, prompt assembly, or test selection.

## Error Handling

The retrieval layer should fail clearly when the graph artifacts are missing or incomplete. If `files.jsonl`, `symbols.jsonl`, or `edges.jsonl` are not present, the helper should return a useful error rather than an empty or misleading packet.

The ranking logic should be conservative when the graph is sparse. If the seed cannot be resolved confidently, the helper should return the seed plus any high-confidence neighbors it can find, rather than inventing relevance.

## Testing

Phase 3 should be covered by fixture-driven tests that assert on the returned PowerShell objects and the existing JSONL graph artifacts.

The minimum coverage should prove that:

- blast radius includes the seed file and direct neighbors
- related tests are ranked ahead of unrelated source files
- context packets stay bounded
- deterministic sorting keeps results stable
- the helpers work against the graph produced by `awf.ps1 update -Indexer roslyn`

The tests should use realistic fixtures that already exercise the Phase 2 semantic and classification output, because Phase 3 depends on those facts being present.

## Acceptance Criteria

Phase 3 is complete when:

- internal retrieval helpers exist in `src/Awf.CodeGraph.psm1`
- blast-radius ranking works against existing graph artifacts
- related-test selection works against existing graph artifacts
- a compact context packet can be assembled from ranked results
- the public CLI surface remains unchanged
- the regression suite passes

## Risks and Constraints

- Retrieval quality depends on the semantic fidelity from Phases 1 and 2, so the ranking layer should stay conservative and avoid inventing facts.
- Context packets can become too large if the budget is not enforced strictly, so the packet builder needs a hard cutoff.
- If ranking rules become too heuristic too early, the results will be hard to trust. Direct graph facts should remain the primary signal.

## Notes For Later Phases

Phase 4 should reuse the same internal retrieval boundaries when it adds incremental indexing and stale-section tracking.

Phase 6 should measure whether the retrieval layer reduces file reads and token usage in practice.
