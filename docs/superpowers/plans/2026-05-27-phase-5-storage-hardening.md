# Phase 5 Storage Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an internal SQLite cache for graph queries, plus validation and repair behavior, without changing the JSONL graph contract that existing commands and fixtures depend on.

**Architecture:** Keep JSONL as the canonical export and interchange format. Add a derived SQLite cache under `.wi/runtime` that is rebuilt from JSONL after updates, checked before query use, and repaired when missing or corrupt. Keep the new logic inside the current PowerShell modules so the public CLI and JSONL artifacts stay stable while internal queries get faster and more robust.

**Tech Stack:** PowerShell 7, the existing JSONL graph artifacts, a .NET SQLite provider usable from PowerShell, and the fixture-driven `tests/run-tests.ps1` harness.

---

### Task 1: Add the SQLite cache contract to graph status

**Files:**
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing test**

Add a status regression that proves the graph reports an internal SQLite cache path and a version marker after a normal update.

```powershell
Invoke-Test "Graph status exposes the sqlite cache contract" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-phase5-status-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $status = Get-AwfCodeGraphStatus -RepoPath $repoPath

        Assert-True -Condition ($status.GraphCachePath -like "*.sqlite") -Message "Status should expose the sqlite cache path."
        Assert-True -Condition ($status.GraphCacheVersion -eq "1") -Message "Status should expose the cache version."
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
Expected: the status object does not yet expose SQLite cache metadata.

- [ ] **Step 3: Add the minimal contract fields**

Update `Get-AwfCodeGraphStatus` in `src/Awf.CodeGraph.psm1` so it always returns:

```powershell
[pscustomobject]@{
    RepoPath = $RepoPath
    GraphPath = $graph
    GraphCachePath = Join-Path $RepoPath ".wi/runtime/graph.sqlite"
    GraphCacheVersion = "1"
    Files = $files.Count
    Symbols = $symbols.Count
    Edges = $edges.Count
    LastUpdatedUtc = if ($state) { $state.lastUpdatedUtc } else { $null }
    Indexer = if ($state) { $state.indexer } else { $null }
}
```

Do not change the JSONL graph output or the existing status fields.

- [ ] **Step 4: Run the test to confirm it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`
Expected: the new status regression passes.

- [ ] **Step 5: Commit**

```bash
git add src/Awf.CodeGraph.psm1 tests/run-tests.ps1
git commit -m "feat: expose graph sqlite cache contract"
```

### Task 2: Sync JSONL graph data into SQLite after updates

**Files:**
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing test**

Add a regression that proves a graph update creates the SQLite cache and persists current graph metadata into it.

```powershell
Invoke-Test "Graph update syncs jsonl artifacts into sqlite" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-phase5-sync-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-sample") $repoPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $cachePath = Join-Path $repoPath ".wi/runtime/graph.sqlite"
        Assert-PathExists -Path $cachePath -Message "Graph update should create the sqlite cache."

        $status = Get-AwfCodeGraphStatus -RepoPath $repoPath
        Assert-True -Condition ($status.Files -gt 0) -Message "Graph status should still report indexed files."
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
Expected: the cache file does not yet exist.

- [ ] **Step 3: Add the cache sync helper**

Implement a helper in `src/Awf.CodeGraph.psm1` that rebuilds `.wi/runtime/graph.sqlite` from the current JSONL files in one transaction.

```powershell
function Sync-AwfGraphSqliteCache {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$GraphPath
    )

    $cachePath = Join-Path $RepoPath ".wi/runtime/graph.sqlite"
    New-AwfDirectory (Split-Path -Parent $cachePath)
    # Read files.jsonl, symbols.jsonl, edges.jsonl, summaries.jsonl, and graph-state.json.
    # Recreate the SQLite file and stamp graph-state metadata and a schema version.
}
```

Call the sync helper at the end of `Update-AwfCodeGraph`, after the JSONL files are written.

- [ ] **Step 4: Run the test to confirm it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`
Expected: the cache file exists after update and the suite stays green.

- [ ] **Step 5: Commit**

```bash
git add src/Awf.CodeGraph.psm1 tests/run-tests.ps1
git commit -m "feat: sync graph jsonl into sqlite cache"
```

### Task 3: Route queries through SQLite first and repair stale caches

**Files:**
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `src/Awf.ContextPacket.psm1`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing test**

Add a regression that deletes the SQLite cache and proves search and retrieval still work from JSONL, then rebuild the cache on demand.

```powershell
Invoke-Test "Graph retrieval falls back to jsonl and repairs the sqlite cache" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-phase5-repair-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $cachePath = Join-Path $repoPath ".wi/runtime/graph.sqlite"
        Remove-Item -LiteralPath $cachePath -Force

        $search = @(Search-AwfCodeGraph -RepoPath $repoPath -Query "Controller")
        Assert-True -Condition ($search.Count -gt 0) -Message "Search should still work when the cache is missing."

        $metrics = Get-AwfContextPacketEvaluation -RepoPath $repoPath -GraphPath (Join-Path $repoPath ".wi/graph") -Seed "src/RoslynFrameworkSample/ValuesController.cs" -Query "ValuesController" -Budget 8
        Assert-True -Condition ($metrics.packetBytes -gt 0) -Message "Evaluation should still produce a packet after repair."
        Assert-PathExists -Path $cachePath -Message "Querying should rebuild the sqlite cache."
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
Expected: query helpers do not yet validate the cache or repair it when missing.

- [ ] **Step 3: Add cache-aware query routing**

Teach `Search-AwfCodeGraph`, `Get-AwfGraphContextPacket`, and `Get-AwfContextPacketEvaluation` to read from SQLite first when the cache is valid. If the cache is missing, corrupt, or version-mismatched, fall back to JSONL and rebuild the cache after the successful JSONL read.

```powershell
function Get-AwfGraphStore {
    param([Parameter(Mandatory)][string]$RepoPath)

    $cachePath = Join-Path $RepoPath ".wi/runtime/graph.sqlite"
    if (Test-AwfGraphStore -Path $cachePath) {
        return [pscustomobject]@{ Kind = "sqlite"; Path = $cachePath }
    }

    return [pscustomobject]@{ Kind = "jsonl"; Path = Join-Path $RepoPath ".wi/graph" }
}
```

Add the validation helper and keep the JSONL fallback path explicit rather than silent.

- [ ] **Step 4: Run the test to confirm it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`
Expected: search and evaluation still work after cache deletion, and the cache is repaired.

- [ ] **Step 5: Commit**

```bash
git add src/Awf.CodeGraph.psm1 src/Awf.ContextPacket.psm1 tests/run-tests.ps1
git commit -m "feat: add sqlite cache fallback and repair"
```

### Task 4: Update the progress tracker and verify the full harness

**Files:**
- Modify: `progress.txt`
- Test: `tests/run-tests.ps1`

- [ ] **Step 1: Mark Phase 5 complete**

Update the tracker only after the cache sync, query fallback, and repair behavior are all passing.

```text
Wave 1 Progress

Phase 1: done
Phase 2: done
Phase 3: done
Phase 4: done
Phase 5: done
Phase 6: done
Phase 7: not started
```

- [ ] **Step 2: Run the full harness**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`
Expected: `PASSED`

- [ ] **Step 3: Commit**

```bash
git add progress.txt tests/run-tests.ps1
git commit -m "docs: mark phase 5 storage hardening complete"
```
