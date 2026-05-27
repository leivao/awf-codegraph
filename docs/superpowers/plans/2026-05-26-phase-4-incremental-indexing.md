# Phase 4 Incremental Indexing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Roslyn-backed graph refreshes incremental and explicit about freshness, confidence, and stale sections without changing the public CLI surface.

**Architecture:** Keep the incremental logic inside `src/Awf.CodeGraph.psm1` so it can reuse the current change detection, file discovery, and Roslyn invocation flow. The implementation should preserve unchanged graph areas where safe, reindex only the affected scope when possible, and annotate output records with additive freshness and confidence metadata that later phases can trust.

**Tech Stack:** PowerShell, JSONL graph artifacts, the existing Roslyn tool, the current PowerShell update path, and the fixture-driven `tests/run-tests.ps1` harness.

---

### Task 1: Add incremental refresh coverage for changed Roslyn inputs

**Files:**
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `tests/run-tests.ps1`
- Modify: `tests/fixtures/roslyn-sample/src/RoslynSample/Class1.cs`

- [ ] **Step 1: Write the failing incremental refresh test**

Add a regression that changes one C# file in the Roslyn sample and verifies the update path only refreshes the changed input while leaving the rest of the graph intact.

```powershell
Invoke-Test "Roslyn update incrementally refreshes changed C# inputs" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-incremental-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-sample") $repoPath

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath
        $firstState = Get-Content -LiteralPath (Join-Path $repoPath ".wi/graph/graph-state.json") -Raw -Encoding UTF8 | ConvertFrom-Json

        Set-Content -LiteralPath (Join-Path $repoPath "src/RoslynSample/Class1.cs") -Value 'namespace RoslynSample; public sealed class Class1 { public string Ping() => "updated"; }' -Encoding UTF8
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $graphPath = Join-Path $repoPath ".wi/graph"
        $files = @(Get-Content -LiteralPath (Join-Path $graphPath "files.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $symbols = @(Get-Content -LiteralPath (Join-Path $graphPath "symbols.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $state = Get-Content -LiteralPath (Join-Path $graphPath "graph-state.json") -Raw -Encoding UTF8 | ConvertFrom-Json

        Assert-True -Condition (@($files | Where-Object { $_.path -eq "src/RoslynSample/Class1.cs" }).Count -gt 0) -Message "Changed C# file should still be indexed."
        Assert-True -Condition (@($symbols | Where-Object { $_.file -eq "src/RoslynSample/Class1.cs" }).Count -gt 0) -Message "Changed C# file should still produce symbols."
        Assert-True -Condition ($state.indexedFileCount -ge $firstState.indexedFileCount) -Message "Incremental refresh should preserve the graph file count contract."
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

Expected: the update path still behaves like a broad refresh with no incremental awareness, so the test fails or cannot verify incremental preservation.

- [ ] **Step 3: Implement the minimal incremental refresh path**

Update `src/Awf.CodeGraph.psm1` so Roslyn updates can reuse the existing changed-file detection and scope the Roslyn pass to changed C# inputs where possible.

```powershell
function Get-AwfRoslynIncrementalScope {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [AllowEmptyCollection()][string[]]$RelativeFiles,
        [switch]$ChangedOnly
    )

    # Derive changed C# files and their containing projects.
    # Preserve unchanged graph areas when the scope is safe.
    # Return a structure that the update path can use to decide whether to refresh files or widen scope.
}
```

The update path should:
- reuse existing Roslyn and PowerShell graph generation where possible
- narrow Roslyn refreshes to changed `.cs` inputs when the scope is safe
- keep non-C# indexing behavior unchanged

- [ ] **Step 4: Run the test to confirm it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: changed C# files still index correctly, and the graph state remains coherent after a targeted refresh.

- [ ] **Step 5: Commit**

```bash
git add src/Awf.CodeGraph.psm1 tests/run-tests.ps1 tests/fixtures/roslyn-sample/src/RoslynSample/Class1.cs
git commit -m "feat: add incremental Roslyn refresh scope"
```

### Task 2: Add freshness and confidence metadata to graph outputs

**Files:**
- Modify: `tools/Awf.CodeGraph.RoslynIndexer/Program.cs`
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing metadata test**

Add a regression that checks the graph records contain additive freshness and confidence fields after a Roslyn update.

```powershell
Invoke-Test "Roslyn graph records include freshness and confidence metadata" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-metadata-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $graphPath = Join-Path $repoPath ".wi/graph"
        $files = @(Get-Content -LiteralPath (Join-Path $graphPath "files.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $edges = @(Get-Content -LiteralPath (Join-Path $graphPath "edges.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })

        Assert-True -Condition (@($files | Where-Object { $_.indexedUtc }).Count -gt 0) -Message "Files should include freshness timestamps."
        Assert-True -Condition (@($edges | Where-Object { $_.confidence -eq "high" }).Count -gt 0) -Message "Edges should include confidence metadata."
        Assert-True -Condition (@($edges | Where-Object { $_.source -eq "roslyn" }).Count -gt 0) -Message "Edges should include source metadata."
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

Expected: metadata is not yet present on all produced records in a way the test can verify.

- [ ] **Step 3: Add additive metadata to the produced records**

Update the Roslyn tool and the PowerShell graph merge path so records consistently include:

```powershell
@{
    source = "roslyn"
    confidence = "high"
    indexedUtc = (Get-Date).ToUniversalTime().ToString("o")
}
```

The PowerShell path should keep its existing `powershell-regex-mvp` source markers and annotate lower-confidence heuristic data where appropriate.

- [ ] **Step 4: Run the test to confirm it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: file, symbol, and edge records include freshness and confidence metadata without breaking the JSONL contract.

- [ ] **Step 5: Commit**

```bash
git add tools/Awf.CodeGraph.RoslynIndexer/Program.cs src/Awf.CodeGraph.psm1 tests/run-tests.ps1
git commit -m "feat: add graph freshness metadata"
```

### Task 3: Mark stale sections when partial refreshes are widened or deferred

**Files:**
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing stale-state test**

Add a regression that forces a partial-refresh ambiguity and checks that the graph state marks the affected area as stale instead of pretending it is fresh.

```powershell
Invoke-Test "Roslyn update marks stale graph sections when a partial refresh is unsafe" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-stale-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        Set-Content -LiteralPath (Join-Path $repoPath "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs") -Value 'namespace RoslynFrameworkSample; public static class ServiceCollectionExtensions { }' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repoPath "src/RoslynFrameworkSample/ValuesController.cs") -Value 'namespace RoslynFrameworkSample; public sealed class ValuesController { }' -Encoding UTF8
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $state = Get-Content -LiteralPath (Join-Path $repoPath ".wi/graph/graph-state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True -Condition ([bool]($state.PSObject.Properties.Name -contains "staleSections")) -Message "Graph state should expose stale section tracking."
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

Expected: the graph state does not yet expose explicit stale-section tracking.

- [ ] **Step 3: Implement stale-section tracking**

Extend the update path so it records stale regions when a safe partial refresh is not possible.

```powershell
@{
    staleSections = @(
        [pscustomobject]@{
            path = "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs"
            reason = "dependency scope widened"
            staleUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
    )
}
```

Keep the stale markers additive in `graph-state.json` and do not change the existing core keys.

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: stale sections are explicitly represented, and the rest of the regression suite still passes.

- [ ] **Step 5: Commit**

```bash
git add src/Awf.CodeGraph.psm1 tests/run-tests.ps1
git commit -m "feat: mark stale sections in incremental updates"
```

### Task 4: Update the phase tracker

**Files:**
- Modify: `progress.txt`

- [ ] **Step 1: Update the tracker after Phase 4 lands**

Set the phase status lines to reflect the completed work:

```text
Wave 1 Progress

Phase 1: done
Phase 2: done
Phase 3: done
Phase 4: done
Phase 5: not started
Phase 6: not started
Phase 7: not started
```

- [ ] **Step 2: Commit the tracker update**

```bash
git add progress.txt
git commit -m "docs: mark phase 4 incremental indexing complete"
```
