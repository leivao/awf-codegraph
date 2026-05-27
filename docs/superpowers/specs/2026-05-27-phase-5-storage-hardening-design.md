# Phase 5 Storage Hardening Design

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an internal SQLite query store that speeds up graph lookups and gives the system a clear validation and repair path without changing the existing JSONL graph contract.

**Architecture:** Keep `files.jsonl`, `symbols.jsonl`, `edges.jsonl`, `summaries.jsonl`, and `graph-state.json` as the authoritative export format. Add a derived SQLite cache under `.wi/runtime` that mirrors the current graph data, is rebuilt from JSONL when missing or stale, and is used first by internal query helpers. Store metadata that lets the code detect corruption, version skew, and incomplete refreshes so the system can fall back to JSONL or rebuild the cache instead of returning misleading results.

**Tech Stack:** PowerShell 7, the existing JSONL graph format, SQLite via the .NET runtime available to PowerShell, existing test harness in `tests/run-tests.ps1`.

---

### Task 1: Define the SQLite cache contract

**Files:**
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `src/Awf.ContextPacket.psm1`
- Test: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
Invoke-Test "Graph cache reports a sqlite-backed store path and versioned metadata" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-phase5-cache-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -LiteralPath $PSScriptRoot -Destination $repoPath -Recurse -Force
        Initialize-AwfCodeGraph -RepoPath $repoPath
        Update-AwfCodeGraph -RepoPath $repoPath -Indexer roslyn

        $status = Get-AwfCodeGraphStatus -RepoPath $repoPath

        Assert-True -Condition ($status.GraphCachePath -like "*.sqlite") -Message "Status should expose the sqlite cache path."
        Assert-True -Condition ($status.GraphCacheVersion -ne $null) -Message "Status should expose cache metadata."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`
Expected: FAIL because the status object does not yet expose SQLite cache metadata.

- [ ] **Step 3: Write minimal implementation**

Add a cache path and cache version to the graph status object and wire them through the existing status/reporting helpers.

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

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`
Expected: PASS for the new cache-contract test.

- [ ] **Step 5: Commit**

```bash
git add tests/run-tests.ps1 src/Awf.CodeGraph.psm1 src/Awf.ContextPacket.psm1
git commit -m "feat: define sqlite graph cache contract"
```

### Task 2: Sync JSONL data into SQLite

**Files:**
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `src/Awf.Util.psm1`
- Test: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
Invoke-Test "Graph update syncs jsonl artifacts into a sqlite cache" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-phase5-sync-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -LiteralPath $PSScriptRoot -Destination $repoPath -Recurse -Force
        Initialize-AwfCodeGraph -RepoPath $repoPath
        Update-AwfCodeGraph -RepoPath $repoPath -Indexer roslyn

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

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`
Expected: FAIL because no SQLite cache sync exists yet.

- [ ] **Step 3: Write minimal implementation**

Create an internal helper that reads the current JSONL graph files and writes a transactional SQLite cache with `files`, `symbols`, `edges`, `summaries`, and `graph_state` tables.

```powershell
function Sync-AwfGraphSqliteCache {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$GraphPath
    )

    $cachePath = Join-Path $RepoPath ".wi/runtime/graph.sqlite"
    New-AwfDirectory (Split-Path -Parent $cachePath)
    # Load JSONL files, recreate the cache in a transaction, and stamp graph-state metadata.
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`
Expected: PASS for the cache sync test.

- [ ] **Step 5: Commit**

```bash
git add tests/run-tests.ps1 src/Awf.CodeGraph.psm1 src/Awf.Util.psm1
git commit -m "feat: sync graph jsonl into sqlite cache"
```

### Task 3: Use SQLite for internal queries and add repair fallback

**Files:**
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `src/Awf.ContextPacket.psm1`
- Test: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
Invoke-Test "Graph retrieval falls back to jsonl when the sqlite cache is missing or corrupt" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-phase5-repair-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -LiteralPath $PSScriptRoot -Destination $repoPath -Recurse -Force
        Initialize-AwfCodeGraph -RepoPath $repoPath
        Update-AwfCodeGraph -RepoPath $repoPath -Indexer roslyn

        $cachePath = Join-Path $repoPath ".wi/runtime/graph.sqlite"
        Remove-Item -LiteralPath $cachePath -Force

        $results = @(Search-AwfCodeGraph -RepoPath $repoPath -Query "Controller")
        Assert-True -Condition ($results.Count -gt 0) -Message "Search should still work from JSONL after cache loss."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`
Expected: FAIL because the query path does not yet use cache-aware fallback behavior.

- [ ] **Step 3: Write minimal implementation**

Teach the query helpers to prefer SQLite when available, validate store metadata before use, and fall back to JSONL if the cache is missing or invalid. If the cache is invalid, rebuild it after the JSONL path succeeds.

```powershell
function Get-AwfGraphStore {
    param([Parameter(Mandatory)][string]$RepoPath)

    $cachePath = Join-Path $RepoPath ".wi/runtime/graph.sqlite"
    if (Test-AwfGraphStore -Path $cachePath) {
        return @{ Path = $cachePath; Kind = "sqlite" }
    }

    return @{ Path = Join-Path $RepoPath ".wi/graph"; Kind = "jsonl" }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`
Expected: PASS for the fallback and repair test.

- [ ] **Step 5: Commit**

```bash
git add tests/run-tests.ps1 src/Awf.CodeGraph.psm1 src/Awf.ContextPacket.psm1
git commit -m "feat: add graph cache fallback and repair path"
```

### Task 4: Refresh the progress tracker and verify the full harness

**Files:**
- Modify: `progress.txt`
- Test: `tests/run-tests.ps1`

- [ ] **Step 1: Update the tracker**

Mark Phase 5 as `done` only after the cache sync, query fallback, and repair behavior all pass in the harness.

```text
Phase 5: done
```

- [ ] **Step 2: Run the full harness**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`
Expected: PASSED

- [ ] **Step 3: Commit**

```bash
git add progress.txt tests/run-tests.ps1
git commit -m "docs: mark phase 5 storage hardening complete"
```
