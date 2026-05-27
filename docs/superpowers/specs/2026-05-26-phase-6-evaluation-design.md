# Phase 6 Evaluation Design

## Goal

Prove that the Roslyn-enhanced graph and retrieval layer improve agent behavior on the tasks this roadmap cares about, using repeatable fixture-based measurements instead of ad hoc observations.

## Approved Direction

Phase 6 should live inside the existing test harness first. The evaluation must be deterministic, versioned with the repo, and able to fail when graph quality regresses. That means the initial implementation belongs in `tests/run-tests.ps1` and the existing fixture repos, not in a separate benchmark-only tool.

The phase should compare the current graph flow against the retrieval-aware flow where possible, then measure whether the graph actually reduces unnecessary file reads and context size while keeping task selection accurate.

## Scope

### In scope

- Deterministic benchmark-style regression tests in `tests/run-tests.ps1`
- Fixture repos that exercise:
  - symbol lookup
  - impact analysis
  - endpoint tracing
  - test selection
  - code review targeting
- Measurements for:
  - files opened or read
  - context packet size
  - relevant test quality
  - retrieval correctness for known seeds
  - baseline versus Roslyn-enhanced behavior where applicable
- Small, explicit pass/fail thresholds
- Optional machine-readable reporting for debugging failures

### Out of scope

- New public CLI commands
- New storage backends
- New analyzers
- Multi-language expansion
- User-facing dashboards
- Non-deterministic “best effort” benchmark runs

## Design

### 1. Evaluation should be deterministic

Phase 6 should use fixed fixtures and fixed seeds so the same code produces the same assertions.

The harness should avoid timing-based assertions and avoid relying on machine-specific throughput. If performance is measured, it should use stable proxies such as:

- number of files opened
- size of returned context packets
- number of candidate items selected
- whether the expected files or tests appear in the top-ranked results

That keeps the phase useful in CI and makes regressions easy to diagnose.

### 2. Evaluation should be task-shaped

The benchmarks should reflect how agents actually use the graph:

- symbol lookup: find the files and declarations connected to a symbol seed
- impact analysis: identify likely blast-radius files and dependent symbols
- endpoint tracing: follow controller or endpoint entrypoints to handlers and implementations
- test selection: rank the tests most likely to cover a change
- code review targeting: surface the files and symbols most relevant to review after a change

Each benchmark case should define:

- the fixture repository
- the seed query or symbol
- the expected relevant files or tests
- the maximum acceptable context size
- the metric that indicates success

### 3. Evaluation should compare the right baselines

Phase 6 should compare:

- a baseline graph path without retrieval ranking, where available
- the retrieval-aware path from Phase 3
- Roslyn-enhanced graph output versus regex-only heuristics where the fixture supports both

The goal is not to invent a perfect score. The goal is to prove that the richer graph path is measurably better for the tasks we care about.

### 4. Evaluation should live close to the fixtures

The first implementation should stay inside `tests/run-tests.ps1` so the benchmark logic runs with the rest of the regression suite.

That gives us:

- one canonical place to run checks
- fixture-driven failures instead of separate benchmark drift
- easier integration with the existing PowerShell toolkit

If later we need richer reporting, we can add a small helper script that emits JSON or CSV, but the authoritative checks should stay in the test suite.

### 5. Results should be small and inspectable

The evaluation harness should emit compact, structured results that are easy to read when a test fails.

Useful fields include:

- seed
- fixture
- filesRead
- contextSize
- topFiles
- topTests
- pass/fail
- notes

That makes the harness useful for both regression detection and quick diagnosis.

## Data Flow

1. A benchmark fixture repo is copied to a temp workspace.
2. The graph is generated or refreshed using the existing `awf.ps1 update` flow.
3. The retrieval layer is called with a known seed or query.
4. The harness records the candidate files, tests, and context packet size.
5. The harness asserts that the results meet the expected quality thresholds.
6. The harness optionally compares the retrieval-aware result against a baseline path.

## Error Handling

If a fixture is missing, the benchmark should fail clearly.

If a benchmark cannot produce a meaningful baseline comparison, it should fail with a precise message rather than silently skip the check.

If the graph data is incomplete, the test should report which artifact or metric was missing so regressions are easy to debug.

## Testing

Phase 6 is itself a testing phase, so the implementation should add regression cases that prove:

- known symbol seeds return the intended files and tests
- context packets stay under a fixed size limit
- baseline versus retrieval-aware behavior is measurable
- Roslyn-backed graph data improves task-shaped selection where applicable
- the harness stays deterministic across repeated runs

The tests should use realistic fixtures already present in the repo or small new fixtures added specifically for benchmark coverage.

## Acceptance Criteria

Phase 6 is complete when:

- benchmark-style evaluation cases exist in the test harness
- the evaluation is deterministic and repeatable
- the evaluation measures file reads or equivalent proxy signals
- the evaluation measures context packet size
- the evaluation covers symbol lookup, impact analysis, endpoint tracing, test selection, and review targeting
- the suite can compare baseline and retrieval-aware behavior where appropriate
- regressions in graph quality or packet size fail the build

## Risks and Constraints

- Real performance measurements can be noisy, so the first phase should rely on stable proxies more than wall-clock time.
- The evaluation should not become a second product surface; it is a regression harness first.
- If fixtures are too small, the benchmark may not surface meaningful differences, so the fixtures need to represent realistic .NET project shapes.
- The evaluation must stay compatible with earlier graph phases so it can run on the same repos and artifact schema.

## Notes For Later Phases

Phase 7 can reuse the same benchmark shape when new language analyzers are added.

If later we want deeper telemetry, we can add a separate reporting script, but it should read the same evaluation cases rather than define a parallel benchmark taxonomy.
