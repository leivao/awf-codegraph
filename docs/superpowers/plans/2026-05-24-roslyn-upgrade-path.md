# Roslyn Upgrade Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit Roslyn-backed C# indexing option to `awf-graph update` while keeping the current PowerShell regex indexer as the default and preserving the existing JSONL graph contracts.

**Architecture:** Keep `awf.ps1` as the CLI entry point, extend `src/Awf.CodeGraph.psm1` to branch between the current PowerShell path and a Roslyn path, and add a small .NET Roslyn console tool under `tools/` that emits the same graph records for C# files only. The PowerShell path continues to cover non-C# files, so the new option upgrades C# precision without rewriting the whole pipeline.

**Tech Stack:** PowerShell, Git, JSONL, .NET 8 console app, Roslyn (`Microsoft.CodeAnalysis.*`), the existing script-level test harness in `tests/run-tests.ps1`.

---

### Task 1: Add the `-Indexer` selector and graph-state plumbing

**Files:**
- Modify: `awf.ps1`
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `src/Awf.Util.psm1`
- Modify: `config/awf-codegraph.config.json`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing test**

Add this test block near the existing CLI tests in `tests/run-tests.ps1`:

```powershell
Invoke-Test "CLI update accepts an explicit Roslyn indexer selector" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-selector-test-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path $repoPath | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $repoPath ".git") | Out-Null
        Set-Content -LiteralPath (Join-Path $repoPath "Sample.cs") -Value "public class Sample { public void Run() {} }" -Encoding UTF8

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $statePath = Join-Path $repoPath ".wi/graph/graph-state.json"
        Assert-PathExists -Path $statePath -Message "Roslyn update should write graph-state.json."

        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True -Condition ($state.indexer -eq "roslyn") -Message "Graph state should record the Roslyn indexer."

        $statusText = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") status -RepoPath $repoPath | Out-String
        Assert-True -Condition ($statusText -match "roslyn") -Message "Status output should surface the last-used Roslyn indexer."
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

Expected: fail at parameter binding with an error like `Unexpected argument '-Indexer'` until `awf.ps1` learns the selector.

- [ ] **Step 3: Write minimal implementation**

Update the CLI and graph module with this shape:

```powershell
# awf.ps1
[switch]$VerboseOutput,

[ValidateSet("powershell", "roslyn")]
[string]$Indexer = "powershell"
```

```powershell
# awf.ps1 update branch
& $UpdateAwfCodeGraph -RepoPath $resolvedRepo -ChangedOnly:$ChangedOnly -VerboseOutput:$VerboseOutput -Indexer $Indexer
```

```powershell
# src/Awf.Util.psm1
graph = [pscustomobject]@{
    workspace = ".wi/graph"
    runtime = ".wi/runtime"
    logs = ".wi/logs"
    indexer = "powershell"
    extensions = @(".cs", ".ts", ".tsx", ".js", ".jsx", ".py", ".json", ".csproj", ".sln", ".props", ".targets")
    excludeDirectories = @(".git", ".wi", "node_modules", "bin", "obj", "dist", "build")
}
```

```powershell
# src/Awf.CodeGraph.psm1
function Update-AwfCodeGraph {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [ValidateSet("powershell", "roslyn")][string]$Indexer = "powershell",
        [switch]$ChangedOnly,
        [switch]$VerboseOutput
    )

    # Existing discovery and clear/remove logic stays in place.
    # If $Indexer -eq "roslyn", call a Roslyn helper for .cs files and keep the
    # PowerShell parser for non-C# files.
}
```

Update `config/awf-codegraph.config.json` so the graph default matches the new selector:

```json
{
  "graph": {
    "indexer": "powershell"
  }
}
```

Make `graph-state.json` write the selected indexer instead of the old internal label, and keep `Get-AwfCodeGraphStatus` reading that value back unchanged.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: the new selector test passes and the existing install/update tests still pass.

- [ ] **Step 5: Commit**

```bash
git add awf.ps1 src/Awf.CodeGraph.psm1 src/Awf.Util.psm1 config/awf-codegraph.config.json tests/run-tests.ps1
git commit -m "feat: add Roslyn indexer selector plumbing"
```

### Task 2: Add the Roslyn console indexer for C# files

**Files:**
- Create: `tools/Awf.CodeGraph.RoslynIndexer/Awf.CodeGraph.RoslynIndexer.csproj`
- Create: `tools/Awf.CodeGraph.RoslynIndexer/Program.cs`
- Create: `tests/fixtures/roslyn-sample/RoslynSample.sln`
- Create: `tests/fixtures/roslyn-sample/src/RoslynSample/RoslynSample.csproj`
- Create: `tests/fixtures/roslyn-sample/src/RoslynSample/Class1.cs`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing test**

Add a Roslyn tool integration test to `tests/run-tests.ps1`:

```powershell
Invoke-Test "Roslyn tool emits JSONL graph files for a small C# solution" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-tool-test-" + [guid]::NewGuid().ToString("N"))
    $outPath = Join-Path $repoPath ".wi/graph"
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-sample") $repoPath
        & dotnet run --project (Join-Path $repoRoot "tools/Awf.CodeGraph.RoslynIndexer") -- --repo $repoPath --solution (Join-Path $repoPath "RoslynSample.sln") --output $outPath

        Assert-PathExists -Path (Join-Path $outPath "files.jsonl") -Message "Roslyn tool should write files.jsonl."
        Assert-PathExists -Path (Join-Path $outPath "symbols.jsonl") -Message "Roslyn tool should write symbols.jsonl."
        $symbolsText = Get-Content -LiteralPath (Join-Path $outPath "symbols.jsonl") -Raw -Encoding UTF8
        Assert-True -Condition ($symbolsText -match "Class1") -Message "Roslyn tool should index the sample C# class."
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

Expected: fail because `tools/Awf.CodeGraph.RoslynIndexer` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create a small .NET 8 console app with these files:

```xml
<!-- tools/Awf.CodeGraph.RoslynIndexer/Awf.CodeGraph.RoslynIndexer.csproj -->
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.Build.Locator" Version="1.6.10" />
    <PackageReference Include="Microsoft.CodeAnalysis.CSharp.Workspaces" Version="4.11.0" />
  </ItemGroup>
</Project>
```

```csharp
// tools/Awf.CodeGraph.RoslynIndexer/Program.cs
using Microsoft.Build.Locator;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.MSBuild;

static string GetArg(string[] args, string name)
{
    var index = Array.IndexOf(args, name);
    if (index < 0 || index + 1 >= args.Length)
    {
        throw new ArgumentException($"Missing required argument '{name}'.");
    }

    return args[index + 1];
}

var repoPath = GetArg(args, "--repo");
var solutionPath = GetArg(args, "--solution");
var outputPath = GetArg(args, "--output");

MSBuildLocator.RegisterDefaults();
using var workspace = MSBuildWorkspace.Create();
var solution = await workspace.OpenSolutionAsync(solutionPath);

Directory.CreateDirectory(outputPath);

foreach (var project in solution.Projects.Where(p => p.Language == LanguageNames.CSharp))
{
    foreach (var document in project.Documents.Where(d => d.FilePath is not null))
    {
        var syntaxTree = await document.GetSyntaxTreeAsync();
        var root = await syntaxTree!.GetRootAsync();
        // Walk the syntax tree, resolve symbols through the semantic model,
        // and emit AWF-compatible JSONL rows for files, symbols, edges, and summaries.
    }
}
```

The first pass only needs the shape of the tool and the JSONL writers. Use the same record keys the PowerShell graph already expects: `id`, `path`, `language`, `kind`, `hash`, `lineCount`, `startLine`, `endLine`, `signature`, `from`, `to`, `type`, `confidence`, `source`, `summary`, `generatedBy`, and `generatedUtc`.

Create a tiny fixture solution so the test does not depend on a developer's local repository state:

```powershell
# tests/fixtures/roslyn-sample/src/RoslynSample/Class1.cs
namespace RoslynSample;
public class Class1
{
    public string Ping() => "pong";
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: the Roslyn tool test passes and the output JSONL files contain the sample class.

- [ ] **Step 5: Commit**

```bash
git add tools/Awf.CodeGraph.RoslynIndexer tests/fixtures/roslyn-sample tests/run-tests.ps1
git commit -m "feat: add Roslyn C# indexer tool"
```

### Task 3: Wire the mixed Roslyn/PowerShell update path and update docs

**Files:**
- Modify: `src/Awf.CodeGraph.psm1`
- Modify: `docs/roslyn-upgrade-path.md`
- Modify: `README.md`
- Modify: `docs/design.md`

- [ ] **Step 1: Write the failing test**

Add a regression test for mixed-language repos:

```powershell
Invoke-Test "Roslyn update keeps non-C# files in the graph" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-mixed-test-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $repoPath ".git") | Out-Null
        Set-Content -LiteralPath (Join-Path $repoPath "Sample.cs") -Value "namespace Demo; public class Sample { public void Run() {} }" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repoPath "notes.txt") -Value "keep me" -Encoding UTF8

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $filesText = Get-Content -LiteralPath (Join-Path $repoPath ".wi/graph/files.jsonl") -Raw -Encoding UTF8
        Assert-True -Condition ($filesText -match "notes\.txt") -Message "Non-C# files should still be indexed by the PowerShell path."
        Assert-True -Condition ($filesText -match "Sample\.cs") -Message "C# files should still appear in the combined graph."
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

Expected: fail because the Roslyn branch is still not merging C# and non-C# outputs together.

- [ ] **Step 3: Write minimal implementation**

Add a mixed update helper in `src/Awf.CodeGraph.psm1` that does three things when `-Indexer roslyn` is selected:

```powershell
function Update-AwfCodeGraph {
    # ...
    if ($Indexer -eq "roslyn") {
        $csharpFiles = @($relativeFiles | Where-Object { [System.IO.Path]::GetExtension($_).ToLowerInvariant() -eq ".cs" })
        $nonCSharpFiles = @($relativeFiles | Where-Object { [System.IO.Path]::GetExtension($_).ToLowerInvariant() -ne ".cs" })

        # 1. Index non-C# files with the existing PowerShell parser.
        # 2. Call the Roslyn tool for C# files.
        # 3. Append both sets of JSONL records to the same graph files.
    }
}
```

Keep `graph-state.json` simple and explicit:

```json
{
  "version": "0.1.0",
  "lastUpdatedUtc": "2026-05-24T00:00:00.0000000Z",
  "indexer": "roslyn",
  "changedOnly": false,
  "indexedFileCount": 2
}
```

Update the docs so they describe the actual user-facing behavior:

- `docs/roslyn-upgrade-path.md` should say Roslyn is selected with `-Indexer roslyn`, is C# only, and leaves non-C# files on the PowerShell path.
- `README.md` should show the new explicit flag in the command examples.
- `docs/design.md` should reflect that Roslyn is now an upgrade option, not just a future evolution item.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: the mixed-language regression passes and the README/design docs match the implemented behavior.

- [ ] **Step 5: Commit**

```bash
git add src/Awf.CodeGraph.psm1 docs/roslyn-upgrade-path.md README.md docs/design.md
git commit -m "feat: wire Roslyn mixed indexing path"
```

### Task 4: Run the full regression sweep and fix any edge cases

**Files:**
- Modify: `tests/run-tests.ps1` if any additional assertions are needed

- [ ] **Step 1: Write the failing test**

If the earlier tasks expose a gap, add the smallest missing assertion in `tests/run-tests.ps1` rather than inventing a new harness. The final suite should cover:

```powershell
awf.ps1 update -Indexer powershell
awf.ps1 update -Indexer roslyn
awf.ps1 status
dotnet run --project tools/Awf.CodeGraph.RoslynIndexer
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: any remaining mismatch should show up here before the work is considered done.

- [ ] **Step 3: Write minimal implementation**

Fix only the smallest issue revealed by the regression run. Do not broaden the scope. Keep the output contracts stable and avoid refactoring unrelated code.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1`

Expected: `PASSED`

- [ ] **Step 5: Commit**

```bash
git add tests/run-tests.ps1 src/Awf.CodeGraph.psm1 awf.ps1 tools/Awf.CodeGraph.RoslynIndexer
git commit -m "test: verify Roslyn upgrade path"
```
