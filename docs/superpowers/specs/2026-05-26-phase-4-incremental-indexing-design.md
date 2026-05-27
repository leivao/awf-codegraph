# Phase 4 Incremental Indexing Design

## Goal

Make Roslyn-backed graph refreshes incremental and explicit about what is compiler-derived, heuristic, and potentially stale.

## Approved Direction

Build Phase 4 inside the existing PowerShell orchestration and Roslyn indexing path. The current graph artifacts stay the same, but update logic should prefer changed-project or changed-file reindexing when possible, then annotate the output with freshness and confidence information so downstream phases can tell what is current and what is derived.

This phase is still internal infrastructure. It does not add a new public command, a new query layer, or a new storage backend. It strengthens the existing update path so repeated indexing runs are faster and the resulting graph is easier to trust.

## Scope

### In scope

- Changed-file and changed-project incremental reindexing
- Cache-aware reuse of previous graph facts when inputs have not changed
- Freshness metadata for graph records
- Confidence metadata for compiler-derived versus heuristic facts
- Stale-section marking when dependencies changed but a full refresh did not run
- Fixture-driven regression tests in `tests/run-tests.ps1`

### Out of scope

- New user-facing retrieval commands
- New query endpoints
- New storage engine or database layer
- Multi-language analyzer expansion
- Reworking the graph schema beyond additive metadata

## Design

### 1. Incremental indexing should reuse existing graph boundaries

Phase 4 should preserve the current split between Roslyn-backed C# processing and PowerShell-backed non-C# processing. The update path should use the existing change detection already present in the PowerShell module, then decide whether a project or file needs a Roslyn refresh.

The key rule is that unchanged graph areas should not be recomputed just to rebuild the same output. If a project or file has not changed and its upstream dependencies are stable, its previously produced records should be reused or preserved.

### 2. Incremental refresh should be conservative

The refresh logic should prefer correctness over cleverness.

The intended behavior is:

- reindex changed files directly
- reindex their containing project when project-level inputs changed
- preserve cached outputs for unaffected files
- force a broader refresh when dependency changes make the cached result unsafe

If the system cannot prove that a partial refresh is safe, it should widen the refresh scope rather than produce a misleading partial graph.

### 3. Freshness metadata should be first-class

Graph records should carry enough metadata to explain when they were produced and what kind of evidence they represent.

The minimum metadata should distinguish:

- `source` values for compiler-derived versus heuristic facts
- `confidence` values that separate high-confidence Roslyn facts from lower-confidence fallback data
- `indexedUtc` timestamps for when a file or symbol was last produced

That metadata should stay additive and compatible with the current JSONL contract. Consumers that do not care about freshness can ignore it, while retrieval and evaluation phases can use it later.

### 4. Staleness should be explicit

When an incremental refresh cannot fully recompute a dependent area, the graph should not silently pretend the data is current.

Stale sections should be marked so that:

- downstream retrieval can lower confidence or avoid over-trusting the area
- later full refreshes can reconcile the stale area cleanly
- operators can tell which graph facts came from the last partial run

The design should keep staleness visible in the graph state or per-record metadata rather than burying it in logs only.

### 5. The existing CLI surface stays stable

Phase 4 should keep using `awf.ps1 update` and the current graph artifact layout. The user-facing flow does not gain a separate incremental command; it just gets smarter about what it recomputes when update is run again.

That keeps Phase 4 aligned with the current workflow and avoids introducing a second update model before the existing one is trusted.

## Data Flow

1. `awf.ps1 update` or `awf.ps1 update -Indexer roslyn` determines changed files and projects.
2. The PowerShell layer decides whether a Roslyn refresh can be scoped to changed inputs.
3. Unchanged graph areas are preserved, while changed areas are reindexed.
4. The Roslyn and PowerShell outputs are merged back into the shared `.wi/graph` contract.
5. Records and graph state are annotated with freshness and confidence metadata.
6. Stale regions are marked when a safe full refresh did not occur.

## Error Handling

If the change set is ambiguous, the system should fail open toward a broader refresh rather than fail closed with partial incorrect data.

If a partial refresh cannot be proven safe, the update path should either:

- widen to a full refresh of the affected scope, or
- preserve the previous data and mark the region stale

It should not emit a graph that looks authoritative when it is not.

## Testing

Phase 4 should be covered by fixture-driven tests that prove:

- an unchanged repo does not recompute everything unnecessarily
- a changed C# file triggers a targeted Roslyn refresh
- unchanged files retain their prior graph facts
- freshness metadata appears in the produced records
- stale markers appear when a safe partial refresh is not possible

The tests should use real solution fixtures so the incremental path is exercised against the same Roslyn and mixed-language data flow the rest of the roadmap depends on.

## Acceptance Criteria

Phase 4 is complete when:

- incremental refresh works for changed Roslyn inputs
- unchanged areas are preserved instead of recomputed
- graph records carry freshness and confidence metadata
- stale graph sections are explicitly marked when needed
- the public CLI behavior remains stable
- the regression suite passes

## Risks and Constraints

- Incremental indexing is easy to make wrong if dependency scope is underestimated, so the implementation must remain conservative.
- Confidence and freshness metadata can become noisy if it is applied too broadly, so the values should stay small and well-defined.
- The graph contract must stay compatible with earlier phases and later retrieval logic, so additions should be additive rather than structural.

## Notes For Later Phases

Phase 5 can use the same metadata to decide which graph data belongs in a denser query store.

Phase 6 can use the freshness and confidence fields as evaluation features when comparing retrieval quality and update cost.
