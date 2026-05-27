# Phase 6 Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing graph and retrieval behavior into a deterministic evaluation harness that proves the Roslyn-enhanced path reduces noise and stays relevant on the agent tasks this roadmap cares about.

**Architecture:** Keep Phase 6 inside the current PowerShell test harness first. Add one small internal helper that produces structured evaluation metrics from the existing graph/context-packet APIs, then add a fixed benchmark matrix in `tests/run-tests.ps1` for symbol lookup, impact analysis, endpoint tracing, test selection, and review targeting. Use stable proxy signals for file-read cost and packet size so the results stay deterministic in CI.

**Tech Stack:** PowerShell, the existing Roslyn fixtures, `.wi/graph` JSONL artifacts, `src/Awf.ContextPacket.psm1`, and the current `tests/run-tests.ps1` harness.

---

### Task 1: Add a reusable evaluation metrics helper

**Files:**
- Modify: `src/Awf.ContextPacket.psm1`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Add the failing smoke test for the helper**

Add one small regression near the existing retrieval tests so the harness expects a metrics helper that does not exist yet.

```powershell
Invoke-Test "Evaluation helper returns deterministic packet metrics" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-eval-helper-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Import-Module (Join-Path $repoRoot "src/Awf.ContextPacket.psm1") -Force
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $graphPath = Join-Path $repoPath ".wi/graph"
        $metrics = Get-AwfContextPacketEvaluation -RepoPath $repoPath -GraphPath $graphPath -Seed "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs" -Query "ServiceCollectionExtensions" -Budget 8

        Assert-True -Condition ([bool]$metrics) -Message "Evaluation helper should return a metrics object."
        Assert-True -Condition ($metrics.packetBytes -gt 0) -Message "Evaluation helper should measure packet size."
        Assert-True -Condition ($metrics.contextFileCount -le $metrics.baselineCount) -Message "Evaluation helper should expose a file-read proxy signal."
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

Expected: the new helper is missing, so the evaluation smoke test fails before implementation.

- [ ] **Step 3: Implement the helper in the context packet module**

Add a small internal helper in `src/Awf.ContextPacket.psm1` that wraps the existing packet and search functions and returns a structured metrics object.

```powershell
function Get-AwfContextPacketEvaluation {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$GraphPath,
        [Parameter(Mandatory)][string]$Seed,
        [Parameter(Mandatory)][string]$Query,
        [int]$Budget = 10
    )

    $packet = Get-AwfGraphContextPacket -GraphPath $GraphPath -Seed $Seed -Budget $Budget
    $packetPath = New-AwfContextPacket -RepoPath $RepoPath -Query $Query
    $baseline = @(Search-AwfCodeGraph -RepoPath $RepoPath -Query $Query)
    $packetSize = (Get-Item -LiteralPath $packetPath).Length

    [pscustomobject]@{
        seed = $Seed
        query = $Query
        baselineCount = $baseline.Count
        contextFileCount = $packet.contextFiles.Count
        relatedTestCount = $packet.relatedTests.Count
        packetBytes = $packetSize
        packetPath = $packetPath
        topFiles = @($packet.contextFiles | Select-Object -First 5 | ForEach-Object { $_.path })
        topTests = @($packet.relatedTests | Select-Object -First 5 | ForEach-Object { $_.path })
        packet = $packet
    }
}
```

The helper should be internal only. It is not a new CLI surface; it just exposes deterministic metrics to the evaluation tests.

- [ ] **Step 4: Run the smoke test to confirm it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: the helper smoke test passes and the rest of the suite stays green.

- [ ] **Step 5: Commit**

```bash
git add src/Awf.ContextPacket.psm1 tests/run-tests.ps1
git commit -m "feat: add evaluation metrics helper"
```

### Task 2: Add the Phase 6 benchmark matrix

**Files:**
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Add the benchmark matrix and five deterministic cases**

Add a small helper in `tests/run-tests.ps1` that runs the same evaluation helper against a fixed matrix of seeds, queries, and thresholds. Keep the matrix concrete so each case reflects one roadmap task shape.

```powershell
$evaluationCases = @(
    @{
        Name = "Phase 6 symbol lookup benchmark"
        Fixture = "tests/fixtures/roslyn-framework-sample"
        Seed = "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs"
        Query = "ServiceCollectionExtensions"
        Budget = 8
        ExpectedFiles = @("src/RoslynFrameworkSample/ServiceCollectionExtensions.cs")
        MinimumRelatedTests = 0
        MaxPacketBytes = 4096
    }
    @{
        Name = "Phase 6 impact analysis benchmark"
        Fixture = "tests/fixtures/roslyn-semantics-sample"
        Seed = "src/RoslynSemanticsSample/Consumer.cs"
        Query = "Service"
        Budget = 8
        ExpectedFiles = @("src/RoslynSemanticsSample/Consumer.cs", "src/RoslynSemanticsSample/Services.cs")
        MinimumRelatedTests = 0
        MaxPacketBytes = 4096
    }
    @{
        Name = "Phase 6 endpoint tracing benchmark"
        Fixture = "tests/fixtures/roslyn-framework-sample"
        Seed = "src/RoslynFrameworkSample/ValuesController.cs"
        Query = "ValuesController"
        Budget = 8
        ExpectedFiles = @("src/RoslynFrameworkSample/ValuesController.cs")
        MinimumRelatedTests = 1
        MaxPacketBytes = 4096
    }
    @{
        Name = "Phase 6 test selection benchmark"
        Fixture = "tests/fixtures/roslyn-framework-sample"
        Seed = "src/RoslynFrameworkSample/ProductionService.cs"
        Query = "ProductionService"
        Budget = 8
        ExpectedFiles = @("src/RoslynFrameworkSample/ProductionService.cs")
        ExpectedTests = @("tests/TestServiceTests.cs")
        MaxPacketBytes = 4096
    }
    @{
        Name = "Phase 6 review targeting benchmark"
        Fixture = "tests/fixtures/roslyn-framework-sample"
        Seed = "src/RoslynFrameworkSample/RequestTimingMiddleware.cs"
        Query = "RequestTimingMiddleware"
        Budget = 8
        ExpectedFiles = @("src/RoslynFrameworkSample/RequestTimingMiddleware.cs")
        MinimumRelatedTests = 0
        MaxPacketBytes = 4096
    }
)
```

Then use a single loop to run each case through `Get-AwfContextPacketEvaluation` and assert:

- the seed file appears in the packet
- the expected tests appear when the graph has enough evidence
- the related-test count meets any configured minimum
- the packet stays under the byte budget
- the packet uses fewer candidate files than the baseline match count

- [ ] **Step 2: Run the benchmark cases to confirm the first pass fails where the thresholds are too strict**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: at least one case should fail until the thresholds and assertions are tuned against the real retrieval output.

- [ ] **Step 3: Tighten the assertions until all benchmark cases pass**

Tune the thresholds in the benchmark loop, but keep the same task-shaped coverage:

- symbol lookup should prefer the seed and its direct symbol neighbors
- impact analysis should reduce broad graph matches compared with the baseline
- endpoint tracing should preserve the controller entrypoint and relevant tests
- test selection should surface the best matching production tests
- review targeting should keep the packet compact and anchored on the changed file

Do not loosen the cases into generic “something was returned” checks. The point is to lock in useful context quality.

- [ ] **Step 4: Run the benchmark suite and then the full harness**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: all benchmark cases pass, and the existing graph, retrieval, and Roslyn tests still pass.

- [ ] **Step 5: Commit**

```bash
git add tests/run-tests.ps1
git commit -m "test: add phase 6 evaluation benchmarks"
```

### Task 3: Update the phase tracker

**Files:**
- Modify: `progress.txt`

- [ ] **Step 1: Mark Phase 6 complete once the benchmark suite is green**

Update the tracker to reflect the actual Wave 1 status.

```text
Wave 1 Progress

Phase 1: done
Phase 2: done
Phase 3: done
Phase 4: done
Phase 5: not started
Phase 6: done
Phase 7: not started
```

- [ ] **Step 2: Commit the tracker update**

```bash
git add progress.txt
git commit -m "docs: mark phase 6 evaluation complete"
```
