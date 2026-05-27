# Phase 3 Retrieval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an internal retrieval layer in the PowerShell module that ranks blast radius, related tests, and compact context packets from the existing graph artifacts without changing the public CLI surface.

**Architecture:** Keep retrieval inside `src/Awf.CodeGraph.psm1` so it can read the existing `.wi/graph` JSONL files directly and reuse the Phase 2 Roslyn facts plus the existing PowerShell graph data. The retrieval helpers will return plain PowerShell objects with deterministic ranking and a bounded packet shape, which keeps the logic testable now and leaves the CLI surface unchanged until a later phase.

**Tech Stack:** PowerShell, JSONL, the existing `.wi/graph` artifacts, Roslyn-enhanced C# graph output from Phase 2, and the fixture-driven harness in `tests/run-tests.ps1`.

---

### Task 1: Add the internal graph retrieval helpers

**Files:**
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing retrieval test**

Add a fixture-backed test that builds a Roslyn graph from the existing framework sample and asks for a retrieval packet from one of the production files.

```powershell
Invoke-Test "Graph retrieval ranks blast radius, tests, and context packets" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-retrieval-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $graphPath = Join-Path $repoPath ".wi/graph"
        $packet = Get-AwfGraphContextPacket -GraphPath $graphPath -Seed "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs" -Budget 10

        Assert-True -Condition ([bool]$packet) -Message "Retrieval should return a packet object."
        Assert-True -Condition ($packet.primary -eq "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs") -Message "The packet should preserve the seed."
        Assert-True -Condition (@($packet.blastRadius | Where-Object { $_.path -eq "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs" }).Count -gt 0) -Message "Blast radius should include the seed file."
        Assert-True -Condition (@($packet.relatedTests | Where-Object { $_.path -like "*tests*" }).Count -gt 0) -Message "Related tests should be ranked into the packet."
        Assert-True -Condition (@($packet.contextFiles).Count -le 10) -Message "Context packet should stay bounded."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: the new helper does not exist yet, so the test fails with `The term 'Get-AwfGraphContextPacket' is not recognized`.

- [ ] **Step 3: Implement the minimal retrieval layer**

Add internal helpers in `src/Awf.CodeGraph.psm1` that read the existing JSONL graph and return ranked PowerShell objects:

```powershell
function Get-AwfGraphBlastRadius {
    param(
        [Parameter(Mandatory)][string]$GraphPath,
        [Parameter(Mandatory)][string]$Seed
    )

    # Read files.jsonl, symbols.jsonl, edges.jsonl, and summaries.jsonl.
    # Rank direct neighbors first, then one-hop neighbors, then same-project and same-namespace neighbors.
    # Return ordered objects with path, symbol, score, and reason.
}

function Get-AwfGraphRelatedTests {
    param(
        [Parameter(Mandatory)][string]$GraphPath,
        [Parameter(Mandatory)][string]$Seed
    )

    # Prefer files already marked as test, then test projects that reference production code,
    # then naming/path heuristics, then direct references from the seed.
    # Return ordered objects with path, score, and reason.
}

function Get-AwfGraphContextPacket {
    param(
        [Parameter(Mandatory)][string]$GraphPath,
        [Parameter(Mandatory)][string]$Seed,
        [int]$Budget = 10
    )

    # Build a bounded packet with:
    # - primary
    # - blastRadius
    # - relatedTests
    # - contextFiles
    # - contextSymbols
    # Sort ties deterministically by path, then symbol id.
}
```

Keep the ranking conservative:
- direct graph edges outrank heuristics
- source-backed symbols outrank inferred matches
- test files outrank non-test files for test selection
- equal scores sort by path and then symbol id

- [ ] **Step 4: Run the test to confirm it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: the retrieval test passes and the existing Roslyn indexing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/Awf.CodeGraph.psm1 tests/run-tests.ps1
git commit -m "feat: add internal graph retrieval helpers"
```

### Task 2: Add negative-path and determinism coverage

**Files:**
- Modify: `tests/run-tests.ps1`
- Modify: `src/Awf.CodeGraph.psm1`

- [ ] **Step 1: Write the failing negative-path test**

Add a regression that calls the helper against an empty graph directory and expects a clear error mentioning the missing JSONL files.

```powershell
Invoke-Test "Graph retrieval fails clearly when graph artifacts are missing" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-retrieval-missing-test-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $repoPath ".wi/graph") | Out-Null

        $failed = $false
        $message = ""
        try {
            Get-AwfGraphContextPacket -GraphPath (Join-Path $repoPath ".wi/graph") -Seed "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs"
        }
        catch {
            $failed = $true
            $message = $_.Exception.Message
        }

        Assert-True -Condition $failed -Message "Retrieval should fail when the graph is incomplete."
        Assert-True -Condition ($message -match "files\.jsonl|symbols\.jsonl|edges\.jsonl") -Message "The error should name the missing graph artifacts."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: the helper either succeeds incorrectly or throws a generic error that does not mention the missing graph artifacts.

- [ ] **Step 3: Tighten the retrieval implementation**

Make the helper validate the graph path before ranking:

```powershell
if (!(Test-Path -LiteralPath (Join-Path $GraphPath "files.jsonl")) -or
    !(Test-Path -LiteralPath (Join-Path $GraphPath "symbols.jsonl")) -or
    !(Test-Path -LiteralPath (Join-Path $GraphPath "edges.jsonl"))) {
    throw "Graph retrieval requires files.jsonl, symbols.jsonl, and edges.jsonl in '$GraphPath'."
}
```

Add a deterministic-order check so repeated calls return the same order:

```powershell
Invoke-Test "Graph retrieval is deterministic for repeated calls" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-retrieval-deterministic-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $graphPath = Join-Path $repoPath ".wi/graph"
        $first = Get-AwfGraphContextPacket -GraphPath $graphPath -Seed "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs" -Budget 10
        $second = Get-AwfGraphContextPacket -GraphPath $graphPath -Seed "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs" -Budget 10

        Assert-True -Condition ((ConvertTo-Json $first -Depth 20) -eq (ConvertTo-Json $second -Depth 20)) -Message "Repeated retrieval calls should return the same ordering."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: both retrieval regression tests pass and the existing Roslyn coverage still passes.

- [ ] **Step 5: Commit**

```bash
git add src/Awf.CodeGraph.psm1 tests/run-tests.ps1
git commit -m "test: cover graph retrieval failure and stability"
```

### Task 3: Mark Phase 3 complete in the progress tracker

**Files:**
- Modify: `progress.txt`

- [ ] **Step 1: Update the tracker after the retrieval helpers land**

Set the phase status lines to reflect the completed work:

```text
Wave 1 Progress

Phase 1: done
Phase 2: done
Phase 3: done
Phase 4: not started
Phase 5: not started
Phase 6: not started
Phase 7: not started
```

- [ ] **Step 2: Commit the tracker update**

```bash
git add progress.txt
git commit -m "docs: mark phase 3 retrieval complete"
```
