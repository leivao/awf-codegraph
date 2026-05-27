# Phase 2 Deep .NET Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Roslyn-backed C# indexer so it emits deeper semantic graph facts for .NET code, including richer edges, framework-aware classifications, and heuristic test-to-production mapping, while preserving the existing JSONL graph contracts and mixed Roslyn/PowerShell workflow.

**Architecture:** Keep the Roslyn console tool as the only compiler-semantic engine. Add semantic edge extraction, classification, and test mapping inside that tool, then let the PowerShell module keep handling mixed-language discovery and record merging. The result stays in the existing `.wi/graph` contract so downstream commands do not need new storage or protocol changes.

**Tech Stack:** PowerShell, Git, JSONL, .NET 8 console app, Roslyn (`Microsoft.CodeAnalysis.*`), the existing script-level test harness in `tests/run-tests.ps1`.

---

### Task 1: Add semantic edge extraction to the Roslyn C# tool

**Files:**
- Modify: `tools/Awf.CodeGraph.RoslynIndexer/Program.cs`
- Modify: `tests/run-tests.ps1`
- Create or modify: `tests/fixtures/roslyn-semantics-sample/RoslynSemanticsSample.sln`
- Create or modify: `tests/fixtures/roslyn-semantics-sample/src/RoslynSemanticsSample/RoslynSemanticsSample.csproj`
- Create or modify: `tests/fixtures/roslyn-semantics-sample/src/RoslynSemanticsSample/*.cs`

- [ ] **Step 1: Write the failing tool-level test**

Add a new Roslyn fixture test that exercises inheritance, interface implementation, invocation, parameter types, and return types:

```powershell
Invoke-Test "Roslyn tool emits semantic edges for a representative C# project" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-semantics-test-" + [guid]::NewGuid().ToString("N"))
    $outPath = Join-Path $repoPath ".wi/graph"
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-semantics-sample") $repoPath
        & dotnet run --project (Join-Path $repoRoot "tools/Awf.CodeGraph.RoslynIndexer") -- --repo $repoPath --solution (Join-Path $repoPath "RoslynSemanticsSample.sln") --output $outPath

        $edges = @(Get-Content -LiteralPath (Join-Path $outPath "edges.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "inherits" }).Count -gt 0) -Message "Roslyn should emit inherits edges."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "implements" }).Count -gt 0) -Message "Roslyn should emit implements edges."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "invokes" }).Count -gt 0) -Message "Roslyn should emit invokes edges."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "parameter-types" }).Count -gt 0) -Message "Roslyn should emit parameter-types edges."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "returns" }).Count -gt 0) -Message "Roslyn should emit returns edges."
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

Expected: the new assertions fail because the current Roslyn tool only emits `defines` edges and does not yet resolve the deeper relationships.

- [ ] **Step 3: Implement the minimal semantic extraction**

Extend `Program.cs` in a narrow pass around the existing document loop:

```csharp
foreach (var node in root.DescendantNodes())
{
    // Keep the existing declared-symbol extraction.
    // Add relationship extraction for:
    // - inheritance and interface implementation from named types
    // - invocation and type reference edges from method bodies
    // - parameter and return type edges from symbols with semantic targets
    // Only emit edges when Roslyn resolves a stable target symbol.
}
```

Use the existing output contract and keep the current record keys:

```csharp
new
{
    from = $"file:{relativePath}",
    to = targetId,
    type = "inherits",
    confidence = "high",
    source = "roslyn"
}
```

Add the fixture sources needed to exercise the new edges:

```csharp
namespace RoslynSemanticsSample;

public interface IService
{
    string Execute(string input);
}

public abstract class BaseService
{
    public virtual string Format(string value) => value;
}

public sealed class Service : BaseService, IService
{
    public override string Format(string value) => value.ToUpperInvariant();
    public string Execute(string input) => Format(input);
}
```

```csharp
namespace RoslynSemanticsSample;

public sealed class Consumer
{
    public string Run(IService service)
    {
        return service.Execute("ping");
    }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: the new Roslyn semantics test passes and the existing Roslyn tool tests still pass.

- [ ] **Step 5: Commit**

```bash
git add tools/Awf.CodeGraph.RoslynIndexer tests/fixtures/roslyn-semantics-sample tests/run-tests.ps1
git commit -m "feat: add Roslyn semantic edge extraction"
```

### Task 2: Add framework-aware classification and test mapping

**Files:**
- Modify: `tools/Awf.CodeGraph.RoslynIndexer/Program.cs`
- Modify: `tests/run-tests.ps1`
- Create or modify: `tests/fixtures/roslyn-framework-sample/RoslynFrameworkSample.sln`
- Create or modify: `tests/fixtures/roslyn-framework-sample/src/RoslynFrameworkSample/RoslynFrameworkSample.csproj`
- Create or modify: `tests/fixtures/roslyn-framework-sample/src/RoslynFrameworkSample/*.cs`
- Create or modify: `tests/fixtures/roslyn-framework-sample/tests/*.cs`

- [ ] **Step 1: Write the failing classifier test**

Add a fixture that contains a controller, a handler, a DbContext, a validator, middleware, a DTO, and a test project that references production code:

```powershell
Invoke-Test "Roslyn tool classifies common .NET app shapes and test files" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-framework-test-" + [guid]::NewGuid().ToString("N"))
    $outPath = Join-Path $repoPath ".wi/graph"
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & dotnet run --project (Join-Path $repoRoot "tools/Awf.CodeGraph.RoslynIndexer") -- --repo $repoPath --solution (Join-Path $repoPath "RoslynFrameworkSample.sln") --output $outPath

        $files = @(Get-Content -LiteralPath (Join-Path $outPath "files.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True -Condition (@($files | Where-Object { $_.kind -eq "api-controller" }).Count -gt 0) -Message "Controller files should be classified."
        Assert-True -Condition (@($files | Where-Object { $_.kind -eq "test" }).Count -gt 0) -Message "Test files should be classified."
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

Expected: the classifier assertions fail because the current Roslyn tool only emits generic file kinds and basic summaries.

- [ ] **Step 3: Implement the minimal classification helpers**

Add small helper functions in `Program.cs` that classify each document after semantic extraction:

```csharp
static string GetFrameworkKind(INamedTypeSymbol? typeSymbol, string relativePath, string declaredName)
{
    // Prefer explicit semantic signals over filename-only guesses.
    // Return values should stay stable and conservative:
    // - api-controller
    // - api-endpoint
    // - dto
    // - validator
    // - middleware
    // - ef-dbcontext
    // - ef-entity
    // - mediatr-handler
    // - di-registration
    // - test
    // - source
}
```

Use the same semantic walk to capture test-to-production signals:

```csharp
static bool IsTestProject(Project project)
{
    return project.Name.Contains("Test", StringComparison.OrdinalIgnoreCase) ||
           project.Name.Contains("Tests", StringComparison.OrdinalIgnoreCase);
}
```

Emit the classification into existing graph records by setting `kind` and, where needed, a stable additional field only if it is already useful to downstream consumers.

Add the fixture sources needed for the classifier to observe real patterns:

```csharp
[ApiController]
[Route("api/[controller]")]
public sealed class ValuesController : ControllerBase { }
```

```csharp
public sealed class AppDbContext : DbContext { }
```

```csharp
public sealed class CreateThingValidator : AbstractValidator<CreateThingRequest> { }
```

```csharp
public sealed class TestService
{
    [Fact]
    public void UsesProductionService()
    {
        var service = new ProductionService();
        Assert.NotNull(service);
    }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: the framework classification and test mapping assertions pass, and the existing Roslyn semantics coverage still passes.

- [ ] **Step 5: Commit**

```bash
git add tools/Awf.CodeGraph.RoslynIndexer tests/fixtures/roslyn-framework-sample tests/run-tests.ps1
git commit -m "feat: classify .NET framework shapes in Roslyn graph"
```

### Task 3: Tighten graph-level regression coverage and document the Phase 2 contract

**Files:**
- Modify: `tests/run-tests.ps1`
- Modify: `docs/roslyn-upgrade-path.md`
- Modify: `README.md`
- Modify: `docs/design.md`

- [ ] **Step 1: Add a mixed-level regression for deep semantics output**

Add a graph-level assertion that confirms the richer semantics do not break the mixed Roslyn/PowerShell path:

```powershell
Invoke-Test "Roslyn update preserves mixed graph output with semantic enrichment" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-semantic-mixed-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        Set-Content -LiteralPath (Join-Path $repoPath "notes.txt") -Value "keep me" -Encoding UTF8

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $graphPath = Join-Path $repoPath ".wi/graph"
        $files = @(Get-Content -LiteralPath (Join-Path $graphPath "files.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True -Condition (@($files | Where-Object { $_.path -eq "notes.txt" }).Count -gt 0) -Message "Non-C# files should still be indexed."
        Assert-True -Condition (@($files | Where-Object { $_.kind -eq "api-controller" }).Count -gt 0) -Message "Framework-aware C# classification should still be present."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}
```

- [ ] **Step 2: Run the test to confirm it fails if needed**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: if the new classifier or semantic edges destabilized the mixed path, this test exposes it before the plan is considered complete.

- [ ] **Step 3: Update the docs to reflect the Phase 2 contract**

Update the user-facing docs so they describe the richer Roslyn graph correctly:

```markdown
Roslyn now emits deeper semantic edges for C# and classifies common .NET framework shapes, while the PowerShell path continues to handle non-C# files.
```

Keep the docs explicit that:

- Phase 2 expands the Roslyn C# graph, not the non-C# parser
- the JSONL contract stays stable
- the retrieval and caching work belongs to later phases

- [ ] **Step 4: Run the full regression suite**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: `PASSED`

- [ ] **Step 5: Commit**

```bash
git add tests/run-tests.ps1 docs/roslyn-upgrade-path.md README.md docs/design.md
git commit -m "test: verify phase 2 deep semantics"
```
